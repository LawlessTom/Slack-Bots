#!/bin/bash
# Morning Briefing — Tier 2 installer
# Run once per teammate on an Uber devpod. Idempotent — safe to re-run.
#
# Usage:
#   curl -fsSL <kit-url>/install.sh | bash
#   OR (after git clone):
#   ./install.sh
#
# What it does:
#   1. Verifies prereqs (aifx, jq, claude)
#   2. Installs/updates Claude Code, google-mcp, slack-mcp
#   3. Writes Claude permissions allowlist (~/.claude/settings.json)
#   4. Drops the wrapper script (~/bin/run-morning-briefing.sh) and prompt
#   5. Schedules cron (8am Sydney time, weekdays)
#   6. Stubs a config file (~/.config/morning-briefing.env) for the user to fill in
#
# What it does NOT do (user must complete manually):
#   - OAuth Google + Slack MCPs (run `aifx agent run claude` interactively, fire one
#     calendar query and one slack DM query, approve in browser)
#   - Paste the shared webhook URL into ~/.config/morning-briefing.env
#   - Confirm phone notification settings allow DMs from "Morning Briefing Notifier"

set -euo pipefail

# ───────────────────────────────────────────────────────────
# Paths
# ───────────────────────────────────────────────────────────
CONFIG_DIR="$HOME/.config"
ENV_FILE="$CONFIG_DIR/morning-briefing.env"
BIN_DIR="$HOME/bin"
WRAPPER="$BIN_DIR/run-morning-briefing.sh"
PROMPT_DIR="$HOME/.local/share/morning-briefing"
PROMPT_FILE="$PROMPT_DIR/prompt.md"
LOG_DIR="$HOME/.claude/logs"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "═══════════════════════════════════════════════"
echo "  Morning Briefing — installer"
echo "═══════════════════════════════════════════════"
echo ""

# ───────────────────────────────────────────────────────────
# 1. Prereqs
# ───────────────────────────────────────────────────────────
echo "[1/7] Checking prerequisites..."
if ! command -v aifx >/dev/null; then
  echo "  ✗ aifx not found. This installer requires an Uber devpod."
  exit 1
fi
echo "  ✓ aifx ($(aifx --version 2>&1 | head -1))"

if ! command -v jq >/dev/null; then
  echo "  Installing jq..."
  sudo apt-get install -qq -y jq
fi
echo "  ✓ jq ($(jq --version))"

# ───────────────────────────────────────────────────────────
# 2. Claude Code
# ───────────────────────────────────────────────────────────
echo "[2/7] Ensuring Claude Code is installed..."
aifx agent install claude >/dev/null 2>&1 || true

# Ensure ~/.local/bin is on PATH for interactive use
if ! grep -q '\.local/bin' "$HOME/.zshrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
  echo "  ✓ Added ~/.local/bin to PATH in .zshrc"
fi
export PATH="$HOME/.local/bin:$PATH"
echo "  ✓ Claude Code ($(claude --version 2>&1 | head -1))"

# ───────────────────────────────────────────────────────────
# 3. MCP servers
# ───────────────────────────────────────────────────────────
echo "[3/7] Registering google-mcp and slack-mcp..."
aifx mcp add google-mcp >/dev/null 2>&1
aifx mcp add slack-mcp  >/dev/null 2>&1
echo "  ✓ MCPs registered (you must complete OAuth interactively — see next steps)"

# ───────────────────────────────────────────────────────────
# 4. Claude permissions
# ───────────────────────────────────────────────────────────
echo "[4/7] Writing Claude permissions allowlist..."
mkdir -p "$(dirname "$SETTINGS_FILE")"
if [ -f "$SETTINGS_FILE" ]; then
  cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak-$(date +%s)"
fi
cat > "$SETTINGS_FILE" <<'SETTINGS_EOF'
{
  "permissions": {
    "allow": [
      "mcp__google-mcp__*",
      "mcp__slack-mcp__*",
      "WebFetch(domain:wttr.in)"
    ]
  }
}
SETTINGS_EOF
echo "  ✓ Permissions written to $SETTINGS_FILE"

# ───────────────────────────────────────────────────────────
# 5. Directories
# ───────────────────────────────────────────────────────────
echo "[5/7] Creating directories..."
mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" "$PROMPT_DIR"

# ───────────────────────────────────────────────────────────
# 6. Prompt + wrapper
# ───────────────────────────────────────────────────────────
echo "[6/7] Installing prompt and wrapper..."

# Detect installer's directory (when run from `git clone` style) and capture for auto-update
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$INSTALLER_DIR/prompt.md" ]; then
  cp "$INSTALLER_DIR/prompt.md" "$PROMPT_FILE"
  cp "$INSTALLER_DIR/prompt.md" "$PROMPT_FILE.bak"   # last-known-good for fallback
  echo "  ✓ Prompt copied from $INSTALLER_DIR/prompt.md"
else
  echo "  ✗ prompt.md not found next to install.sh — aborting."
  echo "    (When piping from curl, download both files first.)"
  exit 1
fi

# Record KIT_DIR in env file so wrapper can git-pull updates each morning
if [ -d "$INSTALLER_DIR/.git" ]; then
  if grep -q '^KIT_DIR=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^KIT_DIR=.*|KIT_DIR=$INSTALLER_DIR|" "$ENV_FILE"
  else
    echo "KIT_DIR=$INSTALLER_DIR" >> "$ENV_FILE"
  fi
  echo "  ✓ KIT_DIR registered — wrapper will git-pull updates each morning"
else
  echo "  ! Installer dir is not a git repo — auto-updates disabled (kit will stay frozen)"
fi

cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/bin/bash
# Morning Briefing — wrapper invoked by cron.
# Generates the briefing body via Claude+MCPs, then POSTs to the Slack webhook.
#
# Auto-update behavior:
#   - If KIT_DIR is set and is a git repo, the wrapper does `git pull` at the start
#     of each run and refreshes the local prompt copy.
#   - Set KIT_PIN=<sha-or-tag> in the env file to opt out of auto-updates and
#     stay on a specific kit version.
#
# Preferences:
#   - Local file at ~/.config/morning-briefing.preferences.md
#   - Auto-synced from Slack "Tweaks and Settings" form submissions each run
#   - Hand-editable; survives kit updates (auto-update only touches prompt.md)

set -euo pipefail

cd "$HOME"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

# Load personal config
source "$HOME/.config/morning-briefing.env"

LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/morning-briefing-$(date +%Y%m%d).log"

PROMPT_FILE="$HOME/.local/share/morning-briefing/prompt.md"
PROMPT_BACKUP="$PROMPT_FILE.bak"
PREFS_FILE="$HOME/.config/morning-briefing.preferences.md"
LAST_SYNC_FILE="$HOME/.config/morning-briefing.last-sync"

# ───────────────────────────────────────────────────────────
# Auto-update prompt from kit repo
# ───────────────────────────────────────────────────────────
update_prompt_from_kit() {
  [ -z "${KIT_DIR:-}" ] && return 0
  [ -n "${KIT_PIN:-}" ] && return 0
  [ ! -d "$KIT_DIR/.git" ] && return 0
  [ ! -f "$KIT_DIR/prompt.md" ] && return 0

  (
    cd "$KIT_DIR"
    git pull --rebase --quiet 2>/dev/null || true
  )

  if [ -s "$KIT_DIR/prompt.md" ] && grep -q '{{RECIPIENT_EMAIL}}' "$KIT_DIR/prompt.md"; then
    cp "$PROMPT_FILE" "$PROMPT_BACKUP" 2>/dev/null || true
    cp "$KIT_DIR/prompt.md" "$PROMPT_FILE"
  else
    echo "WARN: pulled prompt failed validation — keeping cached version" >&2
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
update_prompt_from_kit
init_prefs_file

# Validate required env
: "${WEBHOOK_URL:?WEBHOOK_URL missing from morning-briefing.env}"
: "${RECIPIENT_EMAIL:?RECIPIENT_EMAIL missing from morning-briefing.env}"
RECIPIENT_NAME="${RECIPIENT_NAME:-$RECIPIENT_EMAIL}"
RECIPIENT_FIRST_NAME="${RECIPIENT_FIRST_NAME:-${RECIPIENT_NAME%% *}}"
RECIPIENT_USERNAME="${RECIPIENT_USERNAME:-${RECIPIENT_EMAIL%%@*}}"

TMP_BODY=$(mktemp)
TMP_BRIEFING=$(mktemp)
trap 'rm -f "$TMP_BODY" "$TMP_BRIEFING"' EXIT

SUBJECT="The Day Ahead — $(TZ=Australia/Sydney date '+%a %d %b')"

{
  echo "=== $(date -Iseconds) start ==="

  # Inject current prefs file into {{PREFERENCES}} placeholder, then substitute
  # per-user variables. awk handles the multi-line file injection cleanly.
  PREFS_CONTENT=$(cat "$PREFS_FILE")
  PROMPT=$(awk -v prefs="$PREFS_CONTENT" '
    index($0, "{{PREFERENCES}}") {
      sub("{{PREFERENCES}}", prefs)
    }
    { print }
  ' "$PROMPT_FILE" | sed \
    -e "s|{{RECIPIENT_NAME}}|$RECIPIENT_NAME|g" \
    -e "s|{{RECIPIENT_EMAIL}}|$RECIPIENT_EMAIL|g" \
    -e "s|{{RECIPIENT_FIRST_NAME}}|$RECIPIENT_FIRST_NAME|g" \
    -e "s|{{RECIPIENT_USERNAME}}|$RECIPIENT_USERNAME|g")

  echo "=== running Claude (briefing + prefs snapshot) ==="
  /usr/bin/aifx agent run claude -p "$PROMPT" > "$TMP_BODY"
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
  sed '/^<<<PREFS_SNAPSHOT_START>>>$/,$d' "$TMP_BODY" | sed -e :a -e '/^$/{$d;N;ba' -e '}' > "$TMP_BRIEFING"

  # Pause check: if briefing starts with PAUSED_BRIEFING, don't post webhook
  if head -1 "$TMP_BRIEFING" | grep -q '^PAUSED_BRIEFING'; then
    echo "=== paused — skipping webhook post ==="
    echo "=== $(date -Iseconds) exit=0 (paused) ==="
    exit 0
  fi

  echo "=== posting to webhook ==="
  PAYLOAD=$(jq -n \
    --arg email "$RECIPIENT_EMAIL" \
    --arg subj  "$SUBJECT" \
    --rawfile body "$TMP_BRIEFING" \
    '{recipient_email: $email, subject: $subj, body: $body}')
  RESPONSE=$(curl -s -X POST -H 'Content-Type: application/json' \
    -d "$PAYLOAD" "$WEBHOOK_URL")
  echo "Webhook response: $RESPONSE"
  echo "=== $(date -Iseconds) exit=$? ==="
} >> "$LOG_FILE" 2>&1
WRAPPER_EOF
chmod +x "$WRAPPER"
echo "  ✓ Wrapper installed at $WRAPPER"

# ───────────────────────────────────────────────────────────
# 7. Cron
# ───────────────────────────────────────────────────────────
echo "[7/7] Scheduling cron (8am Sydney weekdays)..."
CRON_CURRENT=$(crontab -l 2>/dev/null || true)
CRON_FILTERED=$(echo "$CRON_CURRENT" | grep -v 'run-morning-briefing.sh' | grep -v '^TZ=Australia/Sydney$' || true)
{
  echo "$CRON_FILTERED"
  echo 'TZ=Australia/Sydney'
  echo "0 8 * * 1-5 $WRAPPER"
} | grep -v '^$' | crontab -
echo "  ✓ Cron installed: 0 8 * * 1-5 (Sydney)"

# ───────────────────────────────────────────────────────────
# Env stub
# ───────────────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<'ENV_EOF'
# Morning Briefing — secrets and personal config
# Fill in your values. This file must stay chmod 600.

# === Webhook URL ===
# Preferred: pull from uSecret (no URL in plaintext anywhere on disk).
# Path follows /personal/<user>/... or /team/<group>/... convention.
# Set this and leave WEBHOOK_URL blank.
WEBHOOK_SECRET_PATH=

# Fallback: paste URL directly (only if uSecret isn't set up yet).
# Leave commented out when WEBHOOK_SECRET_PATH is in use.
# WEBHOOK_URL=

# === Recipient ===
# Your Uber email (resolved to your Slack user by the workflow).
RECIPIENT_EMAIL=

# Optional — used for prompt personalization (first-name pings, etc.)
# RECIPIENT_NAME="Firstname Lastname"
# RECIPIENT_FIRST_NAME="Firstname"
# RECIPIENT_USERNAME="firstinitiallastname"
ENV_EOF
  chmod 600 "$ENV_FILE"
  echo "  ✓ Stubbed $ENV_FILE — edit before first run."
else
  chmod 600 "$ENV_FILE"
  echo "  ✓ Existing $ENV_FILE preserved (chmod 600 enforced)."
fi

# ───────────────────────────────────────────────────────────
# Next steps
# ───────────────────────────────────────────────────────────
cat <<NEXTSTEPS

═══════════════════════════════════════════════
✅ Install complete. Three manual steps remain:
═══════════════════════════════════════════════

1. EDIT YOUR CONFIG ($ENV_FILE)
   nano $ENV_FILE
   - Paste the team WEBHOOK_URL (from uSecret — ask kit owner)
   - Set RECIPIENT_EMAIL to your Uber email
   - Optional: set RECIPIENT_NAME / RECIPIENT_FIRST_NAME for personalization

2. AUTHENTICATE GOOGLE + SLACK MCPS (one-time)
   aifx agent run claude
   At the prompt, run:
     list my next 3 google calendar events
     list my unread slack DMs from today
     /exit
   Approve any OAuth prompts in the browser that opens.

3. TEST THE BRIEFING IMMEDIATELY (don't wait for cron)
   $WRAPPER
   tail -200 $LOG_DIR/morning-briefing-\$(date +%Y%m%d).log

   You should receive a Slack DM from "Morning Briefing Notifier"
   with subject "The Day Ahead — <day> <date>".

═══════════════════════════════════════════════

Cron runs daily at 8:00 Sydney time, Mon-Fri.
Logs: $LOG_DIR/morning-briefing-YYYYMMDD.log
Edit cron with: crontab -e
Uninstall guide: see README.md

NEXTSTEPS
