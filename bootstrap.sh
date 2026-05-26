#!/bin/bash
# Morning Briefing — one-paste bootstrap.
# Run this on your Uber devpod (NOT your Mac):
#
#   curl -fsSL https://raw.githubusercontent.com/LawlessTom/Slack-Bots/main/bootstrap.sh | bash
#
# It will:
#   1. Verify prereqs (aifx, jq, git)
#   2. Verify GitHub SSH works (fails fast with fix instructions if not)
#   3. Clone the kit + run install.sh
#   4. Prompt you (interactively) for the shared webhook URL
#   5. Auto-fill your email and write the config
#   6. Launch Claude so you can OAuth google-mcp + slack-mcp (2 browser clicks)
#   7. Smoke-test the briefing — you should get a Slack DM within ~30s
#
# Total time: ~3 min. After this, cron fires daily at 8am Sydney time.

set -euo pipefail

KIT_REPO="git@github.com:LawlessTom/Slack-Bots.git"
KIT_DIR="$HOME/morning-briefing-kit"
ENV_FILE="$HOME/.config/morning-briefing.env"

# We need /dev/tty for interactive prompts because stdin is the curl pipe.
if [ ! -r /dev/tty ]; then
  echo "✗ No controlling terminal. Re-run inside an interactive shell on your devpod."
  exit 1
fi

bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

echo ""
bold "═══════════════════════════════════════════════"
bold "  Morning Briefing — one-paste bootstrap"
bold "═══════════════════════════════════════════════"
echo ""

# ───────────────────────────────────────────────────────────
# 1. Prereqs
# ───────────────────────────────────────────────────────────
bold "[1/6] Checking prerequisites..."
for cmd in aifx git curl; do
  if ! command -v "$cmd" >/dev/null; then
    red "  ✗ '$cmd' not found. This script must run on an Uber devpod."
    exit 1
  fi
done
if ! command -v jq >/dev/null; then
  echo "  Installing jq..."
  sudo apt-get install -qq -y jq
fi
green "  ✓ aifx, git, curl, jq all present"

# ───────────────────────────────────────────────────────────
# 2. GitHub SSH
# ───────────────────────────────────────────────────────────
bold "[2/6] Verifying GitHub SSH access..."
# `ssh -T git@github.com` always exits 1 (GitHub denies shell), so capture
# output explicitly and grep on that rather than relying on the pipeline's
# exit code (which pipefail would treat as failure).
SSH_OUT=$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T git@github.com 2>&1 || true)
if ! echo "$SSH_OUT" | grep -q "successfully authenticated"; then
  red "  ✗ GitHub SSH not working from this devpod."
  echo ""
  yellow "  Fix on your Mac (not the devpod):"
  echo "    1. open https://accounts.uberinternal.com/access_provisioning/user_access"
  echo "       → link your GitHub username if not already"
  echo "    2. ussh --ussh-replace --ussh-setup-github"
  echo "    3. open https://github.com/settings/ssh/new"
  echo "       → paste the key ussh copied to clipboard, name it 'uber-laptop'"
  echo "    4. ussh   # refresh cert"
  echo "    5. ssh git@github.com   # should say 'Hi <user>!'"
  echo ""
  yellow "  Then reconnect to your devpod (exit + ssh back in to refresh agent forwarding)"
  yellow "  and re-run this bootstrap."
  exit 1
fi
green "  ✓ GitHub SSH works"

# ───────────────────────────────────────────────────────────
# 3. Clone kit
# ───────────────────────────────────────────────────────────
bold "[3/6] Cloning the kit..."
if [ -d "$KIT_DIR/.git" ]; then
  echo "  Kit already exists at $KIT_DIR — pulling latest..."
  (cd "$KIT_DIR" && git pull --rebase --quiet)
else
  git clone --quiet "$KIT_REPO" "$KIT_DIR"
fi
green "  ✓ Kit at $KIT_DIR"

# ───────────────────────────────────────────────────────────
# 4. Run installer
# ───────────────────────────────────────────────────────────
bold "[4/6] Running installer..."
chmod +x "$KIT_DIR/install.sh"
"$KIT_DIR/install.sh"

# ───────────────────────────────────────────────────────────
# 5. Collect config interactively
# ───────────────────────────────────────────────────────────
echo ""
bold "[5/6] Configuring..."

# Auto-detect email — devpod $USER is usually the uber username.
DEFAULT_EMAIL="${USER}@ext.uber.com"

echo ""
echo "  Your Slack email is used to DM you the briefing."
printf "  Email [%s]: " "$DEFAULT_EMAIL" > /dev/tty
read -r RECIPIENT_EMAIL < /dev/tty
RECIPIENT_EMAIL="${RECIPIENT_EMAIL:-$DEFAULT_EMAIL}"

echo ""
echo "  Paste the shared webhook URL (DM @tlawle1 on Slack for it)."
echo "  It looks like: https://hooks.slack.com/triggers/EQ.../11.../abc..."
printf "  Webhook URL: " > /dev/tty
read -r WEBHOOK_URL < /dev/tty
if [ -z "$WEBHOOK_URL" ]; then
  red "  ✗ Webhook URL is required. Re-run when you have it."
  exit 1
fi

echo ""
echo "  Optional — first name for prompt personalization (Enter to skip)."
printf "  First name: " > /dev/tty
read -r RECIPIENT_FIRST_NAME < /dev/tty

# Write env file (preserve KIT_DIR line if installer added it)
EXISTING_KIT_DIR=""
if [ -f "$ENV_FILE" ]; then
  EXISTING_KIT_DIR=$(grep '^KIT_DIR=' "$ENV_FILE" 2>/dev/null || true)
fi

{
  echo "# Morning Briefing — generated by bootstrap.sh on $(date -Iseconds)"
  echo "WEBHOOK_URL=$WEBHOOK_URL"
  echo "RECIPIENT_EMAIL=$RECIPIENT_EMAIL"
  [ -n "$RECIPIENT_FIRST_NAME" ] && echo "RECIPIENT_FIRST_NAME=\"$RECIPIENT_FIRST_NAME\""
  [ -n "$RECIPIENT_FIRST_NAME" ] && echo "RECIPIENT_NAME=\"$RECIPIENT_FIRST_NAME\""
  [ -n "$EXISTING_KIT_DIR" ] && echo "$EXISTING_KIT_DIR" || echo "KIT_DIR=$KIT_DIR"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
green "  ✓ Config written ($ENV_FILE, chmod 600)"

# ───────────────────────────────────────────────────────────
# 6. OAuth + smoke test
# ───────────────────────────────────────────────────────────
echo ""
bold "[6/6] OAuth + smoke test"
echo ""
yellow "  Claude will open in a moment. Run these THREE commands at the ❯ prompt:"
echo ""
echo "    list my next 3 google calendar events"
echo "    list my unread slack DMs from today"
echo "    /exit"
echo ""
yellow "  Each of the first two will print a URL — open it in your MAC browser"
yellow "  (not the devpod) to complete Uber SSO OAuth."
echo ""
printf "  Press Enter when ready to launch Claude... " > /dev/tty
read -r _ < /dev/tty

# Run interactively — needs /dev/tty for the TUI.
aifx agent run claude < /dev/tty || true

echo ""
bold "  Running smoke test..."
"$HOME/bin/run-morning-briefing.sh" || true

LOG_FILE="$HOME/.claude/logs/morning-briefing-$(date +%Y%m%d).log"
if grep -q '"ok":true' "$LOG_FILE" 2>/dev/null; then
  green "  ✓ Webhook accepted — check Slack for a DM from 'Morning Briefing Notifier'"
else
  yellow "  ⚠ Couldn't confirm webhook success. Inspect the log:"
  echo "      tail -200 $LOG_FILE"
fi

echo ""
bold "═══════════════════════════════════════════════"
green "✅ Done. Next briefing fires at 8:00 Sydney time (Mon–Fri)."
bold "═══════════════════════════════════════════════"
echo ""
echo "  Customize:    nano $ENV_FILE"
echo "  Change time:  crontab -e"
echo "  Logs:         ~/.claude/logs/morning-briefing-YYYYMMDD.log"
echo "  Uninstall:    see $KIT_DIR/README.md"
echo ""
