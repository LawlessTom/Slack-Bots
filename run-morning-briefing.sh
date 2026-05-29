#!/bin/bash
# Morning Briefing — wrapper invoked by cron.
# Generates the briefing body via Claude+MCPs, then POSTs to the Slack webhook.
#
# Self-update behavior:
#   - On every run, the wrapper does `git pull` in $KIT_DIR and refreshes:
#       * prompt.md  → copied to local cache (validated first)
#       * THIS FILE  → if changed and passes `bash -n`, copied + re-exec'd
#   - Set KIT_PIN=<sha-or-tag> in the env file to disable auto-updates and
#     stay on the wrapper version currently on disk.
#   - A bad wrapper push is contained by the bash -n syntax check: failing
#     wrappers are rejected and the current version keeps running.
#
# Preferences:
#   - Local file at ~/.config/morning-briefing.preferences.md
#   - Auto-synced from Slack "Tweaks and Settings" form submissions each run
#   - Hand-editable; survives kit updates (auto-update only touches prompt.md)

set -euo pipefail

cd "$HOME"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

# Cron skips /etc/profile.d, so SSH_AUTH_SOCK is unset under cron and
# `aifx` fails with "no valid uSSH certificate found". Point it at the
# devpod-maintained agent symlink (same eval the system profile.d does).
eval "$(/usr/local/bin/devpod-ssh-auth-sock)"

# Load personal config (KIT_DIR / KIT_PIN come from here)
source "$HOME/.config/morning-briefing.env"

LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/morning-briefing-$(date +%Y%m%d).log"

PROMPT_FILE="$HOME/.local/share/morning-briefing/prompt.md"
PROMPT_BACKUP="$PROMPT_FILE.bak"
PREFS_FILE="$HOME/.config/morning-briefing.preferences.md"
LAST_SYNC_FILE="$HOME/.config/morning-briefing.last-sync"

# ───────────────────────────────────────────────────────────
# Self-update: pull kit, refresh prompt + wrapper, re-exec if wrapper changed
# ───────────────────────────────────────────────────────────
update_from_kit() {
  [ -z "${KIT_DIR:-}" ] && return 0
  [ -n "${KIT_PIN:-}" ] && return 0
  [ ! -d "$KIT_DIR/.git" ] && return 0

  (
    cd "$KIT_DIR"
    git pull --rebase --quiet 2>/dev/null || true
  )

  # Refresh prompt
  if [ -s "$KIT_DIR/prompt.md" ] && grep -q '{{RECIPIENT_EMAIL}}' "$KIT_DIR/prompt.md"; then
    cp "$PROMPT_FILE" "$PROMPT_BACKUP" 2>/dev/null || true
    cp "$KIT_DIR/prompt.md" "$PROMPT_FILE"
  else
    echo "WARN: pulled prompt failed validation — keeping cached version" >&2
  fi

  # Refresh wrapper (if changed and syntax-valid) — re-exec under new version.
  # WRAPPER_SELF_UPDATED guard prevents infinite re-exec loops.
  local KIT_WRAPPER="$KIT_DIR/run-morning-briefing.sh"
  local SELF="$HOME/bin/run-morning-briefing.sh"
  if [ -f "$KIT_WRAPPER" ] && [ -z "${WRAPPER_SELF_UPDATED:-}" ]; then
    if ! cmp -s "$KIT_WRAPPER" "$SELF"; then
      if bash -n "$KIT_WRAPPER" 2>/dev/null; then
        cp "$SELF" "$SELF.bak"
        cp "$KIT_WRAPPER" "$SELF"
        chmod +x "$SELF"
        echo "=== wrapper updated from kit ($(cd "$KIT_DIR" && git rev-parse --short HEAD)) — re-execing under new version ==="
        WRAPPER_SELF_UPDATED=1 exec "$SELF" "$@"
      else
        echo "WARN: new wrapper failed bash -n syntax check — keeping current version" >&2
      fi
    fi
  fi
}

# ───────────────────────────────────────────────────────────
# Telemetry: anonymized per-fire health ping
#   - No-op if TELEMETRY_URL not set in env file
#   - user_hash = sha256(RECIPIENT_EMAIL)[0:8] — stable per user, no PII
#   - Emitted exactly once per run via EXIT trap (or explicit calls)
#   - Failures are non-fatal: bad telemetry doesn't fail the briefing
# ───────────────────────────────────────────────────────────
TELEMETRY_EMITTED=0
emit_telemetry() {
  [ "$TELEMETRY_EMITTED" -eq 1 ] && return 0
  TELEMETRY_EMITTED=1
  [ -z "${TELEMETRY_URL:-}" ] && return 0
  local exit_code="${1:-0}"
  local duration="${2:-0}"
  local stdout_bytes="${3:-0}"
  local http_code="${4:-}"

  local user_hash
  user_hash=$(printf '%s' "${RECIPIENT_EMAIL:-unknown}" | sha256sum | cut -c1-8)
  local kit_sha="unknown"
  if [ -n "${KIT_DIR:-}" ] && [ -d "$KIT_DIR/.git" ]; then
    kit_sha=$(cd "$KIT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo unknown)
  fi

  local payload
  payload=$(jq -nc \
    --arg user_hash "$user_hash" \
    --arg date_utc "$(date -u +%Y-%m-%d)" \
    --arg time_utc "$(date -u +%H:%M:%S)" \
    --argjson exit_code "$exit_code" \
    --argjson duration_s "$duration" \
    --argjson stdout_bytes "$stdout_bytes" \
    --arg http_code "$http_code" \
    --arg kit_sha "$kit_sha" \
    --arg host "$(hostname)" \
    '{user_hash:$user_hash, date_utc:$date_utc, time_utc:$time_utc, exit_code:$exit_code, duration_s:$duration_s, stdout_bytes:$stdout_bytes, http_code:$http_code, kit_sha:$kit_sha, host:$host}')

  echo "=== telemetry: emit user=$user_hash exit=$exit_code dur=${duration}s http=${http_code:-none} ==="
  if ! curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
       -d "$payload" "$TELEMETRY_URL" > /dev/null 2>&1; then
    echo "    WARN: telemetry POST failed (non-fatal)"
  fi
}

# ───────────────────────────────────────────────────────────
# Preferences: init local file if missing
# ───────────────────────────────────────────────────────────
init_prefs_file() {
  [ -f "$PREFS_FILE" ] && return 0
  cat > "$PREFS_FILE" <<'PREFS_INIT_EOF'
# Morning Briefing — Personal Preferences
# Hand-editable. Auto-synced from "Tweaks and Settings" form submissions in Slack.
# Persists across kit updates.

## Settings
hide_sections: (none)
timezone: Australia/Sydney
pause_until: (none)
last_synced_at: 1970-01-01T00:00:00Z

## Feedback rules (newest first; Claude follows these alongside the central template)
(none yet)
PREFS_INIT_EOF
}

# ───────────────────────────────────────────────────────────
# Main
# ───────────────────────────────────────────────────────────
update_from_kit "$@"
init_prefs_file

# Validate required env
: "${WEBHOOK_URL:?WEBHOOK_URL missing from morning-briefing.env}"
: "${RECIPIENT_EMAIL:?RECIPIENT_EMAIL missing from morning-briefing.env}"
RECIPIENT_NAME="${RECIPIENT_NAME:-$RECIPIENT_EMAIL}"
RECIPIENT_FIRST_NAME="${RECIPIENT_FIRST_NAME:-${RECIPIENT_NAME%% *}}"
RECIPIENT_USERNAME="${RECIPIENT_USERNAME:-${RECIPIENT_EMAIL%%@*}}"

TMP_BODY=$(mktemp)
TMP_BRIEFING=$(mktemp)
TMP_STDERR=$(mktemp)

# Telemetry state — read by EXIT trap. Updated as the run progresses.
RUN_START=$(date +%s)
CLAUDE_DURATION=0
CLAUDE_STDOUT_BYTES=0
HTTP_CODE=""

# Cleanup + telemetry on any exit (explicit, error, or signal).
# emit_telemetry has a TELEMETRY_EMITTED guard so explicit calls before
# `exit N` take precedence (with richer state). The trap is a safety net.
trap '
  EXIT_CODE=$?
  rm -f "$TMP_BODY" "$TMP_BRIEFING" "$TMP_STDERR"
  emit_telemetry "$EXIT_CODE" \
    "${CLAUDE_DURATION:-$(($(date +%s) - RUN_START))}" \
    "${CLAUDE_STDOUT_BYTES:-0}" \
    "${HTTP_CODE:-}"
' EXIT

SUBJECT="The Day Ahead — $(TZ=Australia/Sydney date '+%a %d %b')"

{
  echo "=== $(date -Iseconds) start ==="

  # Inside-block ERR trap: if any command exits non-zero under `set -e`,
  # log exit code + line + the failing command BEFORE the script dies.
  trap 'rc=$?; echo "!!! ERR trap: exit=$rc line=$LINENO cmd=[$BASH_COMMAND]"' ERR

  # ─── Preflight diagnostics ───
  echo "--- preflight ---"
  echo "host:        $(hostname)"
  echo "user:        $(whoami) (uid=$(id -u))"
  echo "shell:       bash $BASH_VERSION  pid=$$  ppid=$PPID  parent=$(ps -o comm= -p $PPID 2>/dev/null || echo unknown)"
  echo "pwd:         $(pwd)"
  echo "PATH:        $PATH"
  echo "HOME:        $HOME"
  echo "date utc:    $(date -u -Iseconds)"
  echo "date sydney: $(TZ=Australia/Sydney date -Iseconds)"
  echo "uptime:      $(uptime | sed 's/^ *//')"
  echo "disk(home):  $(df -h "$HOME" | tail -1)"
  echo "memory:      $(free -h | awk '/^Mem:/ {print "total="$2" used="$3" free="$4" avail="$7}')"
  echo "aifx:        $(/usr/bin/aifx --version 2>&1 | head -1)"
  echo "prompt:      $PROMPT_FILE ($(wc -c < "$PROMPT_FILE" 2>/dev/null || echo MISSING) bytes)"
  echo "env file:    $HOME/.config/morning-briefing.env ($([ -f "$HOME/.config/morning-briefing.env" ] && echo present || echo MISSING))"
  echo "prefs file:  $PREFS_FILE ($(wc -c < "$PREFS_FILE" 2>/dev/null || echo missing) bytes)"
  echo "log file:    $LOG_FILE"
  echo "kit dir:     ${KIT_DIR:-<unset>}  pin=${KIT_PIN:-<unset>}"
  if [ -n "${KIT_DIR:-}" ] && [ -d "$KIT_DIR/.git" ]; then
    echo "kit head:    $(cd "$KIT_DIR" && git log -1 --format='%h %ci %s' 2>&1 | head -1)"
  fi
  echo "recipient:   $RECIPIENT_EMAIL"
  echo "webhook:     $(echo "$WEBHOOK_URL" | sed 's|^\(https://[^/]*\).*|\1/...|')"
  echo "--- /preflight ---"

  # Substitute per-user variables in the prompt. The local prefs file is a
  # CACHE only — Claude rebuilds prefs from Slack on every run and outputs
  # the fresh snapshot, which the wrapper extracts below.
  PROMPT=$(sed \
    -e "s|{{RECIPIENT_NAME}}|$RECIPIENT_NAME|g" \
    -e "s|{{RECIPIENT_EMAIL}}|$RECIPIENT_EMAIL|g" \
    -e "s|{{RECIPIENT_FIRST_NAME}}|$RECIPIENT_FIRST_NAME|g" \
    -e "s|{{RECIPIENT_USERNAME}}|$RECIPIENT_USERNAME|g" \
    "$PROMPT_FILE")

  echo "=== running Claude (briefing + prefs snapshot) ==="
  echo "    cmd: /usr/bin/aifx agent run claude -p <prompt $(printf %s "$PROMPT" | wc -c) bytes>"
  CLAUDE_START=$(date +%s)
  set +e
  /usr/bin/aifx agent run claude -p "$PROMPT" > "$TMP_BODY" 2> "$TMP_STDERR"
  CLAUDE_EXIT=$?
  set -e
  CLAUDE_END=$(date +%s)
  CLAUDE_DURATION=$((CLAUDE_END - CLAUDE_START))
  CLAUDE_STDOUT_BYTES=$(wc -c < "$TMP_BODY")
  echo "    finished: exit=$CLAUDE_EXIT  duration=${CLAUDE_DURATION}s  stdout=${CLAUDE_STDOUT_BYTES} bytes  stderr=$(wc -c < "$TMP_STDERR") bytes"
  if [ -s "$TMP_STDERR" ]; then
    echo "    --- aifx stderr ---"
    sed 's/^/    | /' "$TMP_STDERR"
    echo "    --- /aifx stderr ---"
  fi
  if [ "$CLAUDE_EXIT" -ne 0 ] || [ ! -s "$TMP_BODY" ]; then
    FAIL_DIR="$LOG_DIR/failures/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$FAIL_DIR"
    cp "$TMP_BODY"   "$FAIL_DIR/stdout.txt" 2>/dev/null || true
    cp "$TMP_STDERR" "$FAIL_DIR/stderr.txt" 2>/dev/null || true
    printf '%s' "$PROMPT" > "$FAIL_DIR/prompt.txt"
    echo "$CLAUDE_EXIT" > "$FAIL_DIR/exit_code"
    echo "=== CLAUDE FAILED — exit=$CLAUDE_EXIT, artifacts saved to $FAIL_DIR ==="
    echo "=== $(date -Iseconds) exit=3 (claude failed) ==="
    exit 3
  fi
  echo "=== full Claude output ($(wc -c < "$TMP_BODY") bytes) ==="
  cat "$TMP_BODY"

  # Extract PREFS_SNAPSHOT block and write to prefs file
  if grep -q '^<<<PREFS_SNAPSHOT_START>>>$' "$TMP_BODY" && grep -q '^<<<PREFS_SNAPSHOT_END>>>$' "$TMP_BODY"; then
    awk '
      /^<<<PREFS_SNAPSHOT_START>>>$/ { in_snap=1; next }
      /^<<<PREFS_SNAPSHOT_END>>>$/   { in_snap=0; next }
      in_snap { print }
    ' "$TMP_BODY" > "$PREFS_FILE.new"
    if [ -s "$PREFS_FILE.new" ] && grep -q '^# Morning Briefing — Personal Preferences' "$PREFS_FILE.new"; then
      mv "$PREFS_FILE.new" "$PREFS_FILE"
      echo "=== prefs file updated from snapshot ==="
    else
      echo "WARN: snapshot extracted but failed validation — keeping existing prefs file"
      rm -f "$PREFS_FILE.new"
    fi
  else
    echo "WARN: Claude output missing PREFS_SNAPSHOT block — keeping existing prefs file"
  fi

  # Extract briefing body (everything BEFORE the snapshot start marker)
  sed '/^<<<PREFS_SNAPSHOT_START>>>$/,$d' "$TMP_BODY" | sed -e :a -e '/^$/{$d;N;ba' -e '}' > "$TMP_BRIEFING.raw"

  # Defensive preamble trim: Claude occasionally narrates before the briefing
  # despite the prompt rule. Strip anything before the first 🌅 line.
  if grep -q $'\xf0\x9f\x8c\x85' "$TMP_BRIEFING.raw"; then
    sed -n $'/\xf0\x9f\x8c\x85/,$p' "$TMP_BRIEFING.raw" > "$TMP_BRIEFING"
  else
    cp "$TMP_BRIEFING.raw" "$TMP_BRIEFING"
  fi
  rm -f "$TMP_BRIEFING.raw"

  # Pause check: if briefing starts with PAUSED_BRIEFING, don't post webhook
  if head -1 "$TMP_BRIEFING" | grep -q '^PAUSED_BRIEFING'; then
    echo "=== paused — skipping webhook post ==="
    echo "=== $(date -Iseconds) exit=0 (paused) ==="
    exit 0
  fi

  # Defensive: if Claude's output is essentially empty, don't deliver an empty DM
  if [ ! -s "$TMP_BRIEFING" ] || [ "$(wc -c < "$TMP_BRIEFING")" -lt 50 ]; then
    echo "=== ABORT: briefing body is empty or tiny (<50 chars) — Claude likely failed (missing MCP OAuth?) — skipping webhook ==="
    echo "Full Claude output was: $(cat "$TMP_BODY")"
    echo "=== $(date -Iseconds) exit=2 (empty body) ==="
    exit 2
  fi

  echo "=== posting to webhook ==="
  PAYLOAD=$(jq -n \
    --arg email "$RECIPIENT_EMAIL" \
    --arg subj  "$SUBJECT" \
    --rawfile body "$TMP_BRIEFING" \
    '{recipient_email: $email, subject: $subj, body: $body}')
  echo "    payload: $(printf %s "$PAYLOAD" | wc -c) bytes  body: $(wc -c < "$TMP_BRIEFING") bytes  subject: $SUBJECT"
  WEBHOOK_START=$(date +%s)
  set +e
  RESPONSE=$(curl -sS -w '\n__HTTP=%{http_code}__' -X POST \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" "$WEBHOOK_URL" 2>&1)
  CURL_EXIT=$?
  set -e
  WEBHOOK_END=$(date +%s)
  HTTP_CODE=$(printf '%s' "$RESPONSE" | grep -oE '__HTTP=[0-9]+__' | grep -oE '[0-9]+' | tail -1)
  HTTP_CODE=${HTTP_CODE:-???}
  RESPONSE_BODY=$(printf '%s' "$RESPONSE" | sed 's/__HTTP=[0-9]*__$//')
  echo "    finished: curl_exit=$CURL_EXIT  http=$HTTP_CODE  duration=$((WEBHOOK_END - WEBHOOK_START))s"
  echo "    response body: $RESPONSE_BODY"
  if [ "$CURL_EXIT" -ne 0 ] || [ "$HTTP_CODE" != "200" ]; then
    echo "=== WEBHOOK FAILED — curl_exit=$CURL_EXIT http=$HTTP_CODE ==="
    echo "=== $(date -Iseconds) exit=4 (webhook failed) ==="
    exit 4
  fi
  echo "=== $(date -Iseconds) exit=0 ==="
} >> "$LOG_FILE" 2>&1
