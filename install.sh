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
#   1. Prompts for timezone + fire time (defaults: Australia/Sydney, 08:00)
#   2. Verifies prereqs (aifx, jq, claude)
#   3. Installs/updates Claude Code, google-mcp, slack-mcp
#   4. Writes Claude permissions allowlist (~/.claude/settings.json)
#   5. Drops the wrapper script (~/bin/run-morning-briefing.sh) and prompt
#   6. Schedules cron at chosen time, weekdays (UTC-hardcoded; DST flip = re-run)
#   7. Stubs a config file (~/.config/morning-briefing.env) for the user to fill in
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
# 0. User config: timezone + fire time
# ───────────────────────────────────────────────────────────
# Read previous choices (if any) to use as defaults on re-run.
DEFAULT_TZ="Australia/Sydney"
DEFAULT_TIME="08:00"
if [ -f "$ENV_FILE" ]; then
  EXISTING_TZ=$(grep -E '^USER_TZ=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)
  EXISTING_TIME=$(grep -E '^FIRE_TIME=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)
  DEFAULT_TZ="${EXISTING_TZ:-$DEFAULT_TZ}"
  DEFAULT_TIME="${EXISTING_TIME:-$DEFAULT_TIME}"
fi

validate_tz() {
  [ -n "$1" ] && [ -f "/usr/share/zoneinfo/$1" ]
}

# Accepts "HH:MM" (08:00), or natural forms parsable by `date -d` like
# "8am", "7:30pm", "noon", "midnight". Echoes normalized HH:MM on success.
parse_time() {
  local input="$1"
  if [[ "$input" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    local h="${input%%:*}" m="${input##*:}"
    printf "%02d:%02d" "$((10#$h))" "$((10#$m))"
    return 0
  fi
  local parsed
  if parsed=$(date -d "$input" +%H:%M 2>/dev/null) && [[ "$parsed" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
    echo "$parsed"
    return 0
  fi
  return 1
}

if [ -t 0 ]; then
  while true; do
    read -rp "Timezone for briefing schedule [$DEFAULT_TZ]: " INPUT_TZ
    USER_TZ="${INPUT_TZ:-$DEFAULT_TZ}"
    if validate_tz "$USER_TZ"; then break; fi
    echo "  ✗ Unknown timezone: '$USER_TZ'"
    echo "    Examples: Australia/Sydney, Australia/Perth, America/New_York, Europe/London, UTC"
    echo "    Full list: ls /usr/share/zoneinfo  (continent dirs contain the cities)"
  done

  while true; do
    read -rp "Fire time [$DEFAULT_TIME]: " INPUT_TIME
    INPUT_TIME="${INPUT_TIME:-$DEFAULT_TIME}"
    if FIRE_TIME=$(parse_time "$INPUT_TIME"); then break; fi
    echo "  ✗ Couldn't parse '$INPUT_TIME'. Try: 08:00, 8am, 7:30pm, or 8"
  done
else
  USER_TZ="$DEFAULT_TZ"
  FIRE_TIME="$DEFAULT_TIME"
  echo "  (non-interactive — using defaults: $USER_TZ $FIRE_TIME)"
  validate_tz "$USER_TZ" || { echo "  ✗ Invalid default timezone '$USER_TZ'"; exit 1; }
  FIRE_TIME=$(parse_time "$FIRE_TIME") || { echo "  ✗ Invalid default fire time"; exit 1; }
fi

echo "  ✓ Schedule: $FIRE_TIME $USER_TZ, Mon-Fri"
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
echo "[3/7] Registering google-mcp and slack-mcp for claude-code..."
for mcp in google-mcp slack-mcp; do
  if aifx mcp list --clients claude-code 2>/dev/null | grep -qw "$mcp"; then
    echo "  ✓ $mcp already registered for claude-code"
    continue
  fi
  echo "  Adding $mcp..."
  if aifx mcp add "$mcp" --clients claude-code 2>&1 | sed 's/^/      /'; then
    echo "  ✓ $mcp registered"
  else
    echo "  ! $mcp add returned non-zero — proceeding anyway."
    echo "    Run manually: aifx mcp add $mcp --clients claude-code"
  fi
done
echo "  (you must complete OAuth interactively — see next steps)"

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

# Wrapper now lives as a tracked file in the kit repo so updates can flow
# centrally (see run-morning-briefing.sh self-update logic). Copy it in.
if [ ! -f "$INSTALLER_DIR/run-morning-briefing.sh" ]; then
  echo "  ✗ $INSTALLER_DIR/run-morning-briefing.sh not found — aborting."
  echo "    (When piping from curl, download install.sh + run-morning-briefing.sh + prompt.md.)"
  exit 1
fi
if ! bash -n "$INSTALLER_DIR/run-morning-briefing.sh"; then
  echo "  ✗ run-morning-briefing.sh failed bash -n syntax check — refusing to install."
  exit 1
fi
cp "$INSTALLER_DIR/run-morning-briefing.sh" "$WRAPPER"
chmod +x "$WRAPPER"
echo "  ✓ Wrapper installed at $WRAPPER"

# ───────────────────────────────────────────────────────────
# 7. Cron
# ───────────────────────────────────────────────────────────
# Cron daemon on Uber devpods ignores `TZ=` env lines — the schedule is parsed
# in UTC regardless. Compute the UTC equivalent of $FIRE_TIME $USER_TZ for the
# current DST state and write that.
#
# DST flip: re-run ./install.sh after each local DST transition.
USER_DATE=$(TZ="$USER_TZ" date +%Y-%m-%d)
UTC_HOUR=$(date -u -d "TZ=\"$USER_TZ\" $USER_DATE $FIRE_TIME:00" +%-H)
UTC_MIN=$(date -u -d "TZ=\"$USER_TZ\" $USER_DATE $FIRE_TIME:00" +%-M)
USER_DOW=$(TZ="$USER_TZ" date -d "$USER_DATE $FIRE_TIME:00" +%u)
UTC_DOW=$(date -u -d "TZ=\"$USER_TZ\" $USER_DATE $FIRE_TIME:00" +%u)

# Day-of-week shift. ISO DoW 1=Mon..7=Sun. Normalize the diff to ±1 around 0.
DOW_DIFF=$((UTC_DOW - USER_DOW))
if [ "$DOW_DIFF" -lt -1 ]; then DOW_DIFF=$((DOW_DIFF + 7)); fi
if [ "$DOW_DIFF" -gt  1 ]; then DOW_DIFF=$((DOW_DIFF - 7)); fi

if [ "$DOW_DIFF" -eq -1 ]; then
  CRON_DAYS="0-4"   # UTC one day behind user (e.g., Sydney 8am AEST = prev-day 22:00 UTC)
elif [ "$DOW_DIFF" -eq 1 ]; then
  CRON_DAYS="2-6"   # UTC one day ahead of user (rare; late-evening fires in US west)
else
  CRON_DAYS="1-5"   # Same UTC day
fi

CRON_SCHED="$UTC_MIN $UTC_HOUR * * $CRON_DAYS"

echo "[7/7] Scheduling cron ($CRON_SCHED UTC = $FIRE_TIME $USER_TZ weekdays)..."
CRON_CURRENT=$(crontab -l 2>/dev/null || true)
CRON_FILTERED=$(echo "$CRON_CURRENT" \
  | grep -v 'run-morning-briefing.sh' \
  | grep -v 'UTC-hardcoded' \
  | grep -v '^TZ=Australia/Sydney$' \
  || true)
{
  echo "$CRON_FILTERED"
  echo "# $FIRE_TIME $USER_TZ weekdays (UTC-hardcoded; re-run install.sh after DST flips)"
  echo "$CRON_SCHED $WRAPPER"
} | grep -v '^$' | crontab -
echo "  ✓ Cron installed: $CRON_SCHED $WRAPPER"

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
# Persist USER_TZ / FIRE_TIME so re-runs default to current choices,
# and the value is recorded alongside other config.
# ───────────────────────────────────────────────────────────
for kv in "USER_TZ=$USER_TZ" "FIRE_TIME=$FIRE_TIME"; do
  key="${kv%%=*}"
  if grep -q "^$key=" "$ENV_FILE"; then
    sed -i "s|^$key=.*|$kv|" "$ENV_FILE"
  else
    echo "$kv" >> "$ENV_FILE"
  fi
done

# ───────────────────────────────────────────────────────────
# Seed/update prefs file's timezone so briefing DISPLAY times match
# the schedule timezone. (Wrapper's init_prefs_file is a no-op if file exists.)
# ───────────────────────────────────────────────────────────
PREFS_FILE="$CONFIG_DIR/morning-briefing.preferences.md"
if [ -f "$PREFS_FILE" ]; then
  sed -i "s|^timezone:.*|timezone: $USER_TZ|" "$PREFS_FILE"
else
  cat > "$PREFS_FILE" <<PREFS_EOF
# Morning Briefing — Personal Preferences
# Hand-editable. Auto-synced from "Tweaks and Settings" form submissions in Slack.
# Persists across kit updates.

## Settings
hide_sections: (none)
timezone: $USER_TZ
pause_until: (none)
last_synced_at: 1970-01-01T00:00:00Z

## Feedback rules (newest first; Claude follows these alongside the central template)
(none yet)
PREFS_EOF
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

Cron runs $FIRE_TIME $USER_TZ, Mon-Fri.
Logs: $LOG_DIR/morning-briefing-YYYYMMDD.log
Edit cron with: crontab -e
Uninstall guide: see README.md

NEXTSTEPS
