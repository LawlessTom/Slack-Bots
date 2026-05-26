# Morning Briefing — Install Kit

A daily personalized briefing delivered to your Slack DMs at 8:00 AEST, Mon–Fri.

Pulls from your Google Calendar, Gmail, and Slack via MCPs; ranks items by urgency / seniority / direct address; delivers via a shared Slack Workflow Builder webhook so push notifications actually fire on your phone.

**Kit owner:** DM Thomas Lawless (`@tlawle1`) on Slack — for the webhook URL and any setup help.

## What you get

A daily DM from **Morning Briefing Notifier** that looks like:

```
The Day Ahead — Tue 26 May

📊 TODAY AT A GLANCE
5 upcoming meetings · 12 unread email · 3 need response

────────────────────────────
🌤 WEATHER — Sydney
🌦 Showers, 19°C, SW wind 9 mph

────────────────────────────
📅 UPCOMING MEETINGS  (AEST)
  12:00  Lunch Break: ANZ Region
  15:00  AI Office Hours | Ally Price  [Zoom]
  ...

────────────────────────────
📧 EMAIL — ACTION FIRST
  1.  Leyre Herranz (Google Slides)  —  2026 Consumer Ops Team Meeting
      Action item assigned: lead AI Corner Thursday [by Thu 28 May]
  ...

────────────────────────────
💬 SLACK — RESPONSE NEEDED
  • Leyre Herranz (#anz-rider-ops)  —  prep and lead AI Corner section
  ...

────────────────────────────
💬 SLACK — FYI
  • Viviane Pretet (DM)  —  CBA matching segment too small for CRM
  ...
```

## One-paste install (the easy path)

On your **devpod** (not your Mac), paste this one line into the terminal:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LawlessTom/Slack-Bots/main/bootstrap.sh)
```

It will:
- Verify your prereqs (aifx, jq, GitHub SSH)
- Clone the kit, run the installer
- Prompt you for the webhook URL and confirm your email
- Launch Claude so you can OAuth google-mcp + slack-mcp (two browser clicks)
- Run a smoke test — you should get a Slack DM within ~30s
- Set up the 8am Sydney weekday cron

**Total time: ~3 minutes.** Before you run it, have:
- An **Uber devpod** ready (provision via [go/devpod](https://devpod.uberinternal.com), `base` flavor is fine)
- **GitHub SSH** working from the devpod — if `ssh git@github.com` doesn't say "Hi <your-user>!", see [GitHub SSH setup](#github-ssh-setup-one-time-on-your-mac) below
- The **shared webhook URL** — DM `@tlawle1` on Slack
- A **Slack profile email** ending in `@ext.uber.com` or `@uber.com`

If you'd rather see every step explicitly, the [manual install path](#manual-install-on-your-devpod) below does the same thing in pieces.

## Prerequisites (manual path)

1. **An Uber devpod.** Most engineers already have one. If not, provision via [go/devpod](https://devpod.uberinternal.com) — `base` flavor is fine.

2. **GitHub SSH access from your devpod.** A fresh devpod can't `git clone` from github.com until you set this up. ~5 min one-time. See "GitHub SSH setup" below.

3. **The shared webhook URL.** It's a secret, not committed to this repo. DM Thomas Lawless (`@tlawle1`) for it.

4. **A Slack profile email of `@ext.uber.com` or `@uber.com`** — the workflow looks you up by this email to send the DM.

## GitHub SSH setup (one-time, on your Mac)

If `ssh git@github.com` from your devpod returns `Hi <your-github-user>!`, skip this section.

On your **Mac** (not the devpod — ssh agent forwarding carries the identity through):

```bash
# 1. Verify your GitHub account is linked to Uber
open https://accounts.uberinternal.com/access_provisioning/user_access
# → "Add or update your GitHub username" if not already linked

# 2. Generate a fresh GitHub SSH key via ussh
ussh --ussh-replace --ussh-setup-github

# 3. Add the public key to GitHub (ussh copied it to clipboard)
open https://github.com/settings/ssh/new
# Paste key, name it "uber-laptop", click Add SSH key

# 4. Refresh ussh cert
ussh

# 5. Verify from Mac
ssh git@github.com
# Expect: "Hi <your-github-user>!..."
```

Then reconnect to your devpod (so the fresh ssh-agent forwards):

```bash
# In your devpod terminal
exit
ssh <your-devpod-host>
ssh git@github.com   # should succeed
```

Full troubleshooting: [go/DEV101](https://go/DEV101) or `#slack-bots-dev`.

## Manual install (on your devpod)

```bash
cd ~ && git clone git@github.com:LawlessTom/Slack-Bots.git morning-briefing-kit
cd morning-briefing-kit
chmod +x install.sh
./install.sh
```

The installer is idempotent — safe to re-run anytime you want to update the wrapper from a fresh clone.

It will:
1. Install Claude Code and the google-mcp + slack-mcp servers
2. Write permissions allowlist to `~/.claude/settings.json`
3. Drop the wrapper at `~/bin/run-morning-briefing.sh`
4. Drop the prompt at `~/.local/share/morning-briefing/prompt.md`
5. Schedule cron for 8am Sydney weekdays
6. Stub a config file at `~/.config/morning-briefing.env` for you to fill in
7. Record `KIT_DIR` so the wrapper can `git pull` prompt updates each morning

## Three manual steps after install

### 1. Fill in your config

```bash
nano ~/.config/morning-briefing.env
```

Set these two:

```bash
WEBHOOK_URL=https://hooks.slack.com/triggers/...   # DM @tlawle1 for this
RECIPIENT_EMAIL=you@ext.uber.com                   # your Uber/ext email
```

Optional (improves prompt personalization for direct-address ranking):

```bash
RECIPIENT_NAME="Firstname Lastname"
RECIPIENT_FIRST_NAME="Firstname"
RECIPIENT_USERNAME="yourhandle"
```

Save (`Ctrl+O`, `Enter`, `Ctrl+X`). The file is automatically `chmod 600` by the installer.

### 2. Authenticate Google + Slack MCPs (one-time, interactive)

The cron job runs headless and can't open OAuth browser flows. Complete OAuth once interactively to cache tokens:

```bash
aifx agent run claude
```

**First-run warning:** if this is your first time using Claude Code on the devpod, you'll hit a setup wizard (theme picker, etc.). Pick **Dark mode** (option 2) and step through any other screens — they're one-time.

Once you see the `❯` prompt, run two queries to trigger OAuth for each MCP:

```
list my next 3 google calendar events
```

A URL will print. **Open it in your Mac browser** (not the devpod) — completes OAuth via Uber SSO, redirects to confirm.

```
list my unread slack DMs from today
```

Same pattern — open URL in Mac browser, complete OAuth.

```
/exit
```

Tokens are now cached at `~/.aifx/` and the cron job can use them.

### 3. Smoke test

```bash
~/bin/run-morning-briefing.sh && tail -200 ~/.claude/logs/morning-briefing-$(date +%Y%m%d).log
```

You should:
- See `Webhook response: {"ok":true}` near the end of the log
- Receive a Slack DM from **Morning Briefing Notifier** within 10 seconds
- Get a phone push notification (assuming Slack notification settings are normal)

If any fail, see **Troubleshooting** below.

## Timezone & schedule

The cron is scheduled for **8:00 Sydney time, Mon–Fri** by default. The devpod is on UTC, but cron honors the `TZ=Australia/Sydney` line so this Just Works.

To change the time or timezone, edit your crontab:

```bash
crontab -e
```

You'll see:

```
TZ=Australia/Sydney
0 8 * * 1-5 /home/user/bin/run-morning-briefing.sh
```

Change `TZ=` to your zone (e.g. `America/Los_Angeles`, `Europe/London`, `America/New_York`) and the hour to your local 8am. Save.

## Phone notification settings

Slack DMs from "Morning Briefing Notifier" are messages from a workflow bot — they fire push notifications like any normal DM. Verify:

- Slack mobile → **Settings** → **Notifications** → "Direct messages, mentions & keywords" enabled
- If you have Do Not Disturb scheduled for 8am local time, exclude DMs from "Morning Briefing Notifier" or shift your DND window

## Auto-updates

When you installed from a git clone, the installer recorded `KIT_DIR=<your-clone>` in your env file. Each morning before generating the briefing, the wrapper:

1. `git pull --rebase --quiet` in `$KIT_DIR`
2. Validates the pulled `prompt.md` is non-empty and contains the required placeholders
3. Refreshes the runtime prompt at `~/.local/share/morning-briefing/prompt.md` (keeps the previous version as `.bak`)
4. Proceeds with the briefing

If the pull fails (network blip, git auth issue) or the new prompt fails validation, the wrapper falls back to the cached prompt — your briefing always runs.

**To opt out of auto-updates** (pin to your locally cached prompt), add to your env file:

```bash
KIT_PIN=local
```

**Wrapper script changes are NOT auto-updated** — only the prompt. To pick up wrapper changes:

```bash
cd $KIT_DIR && git pull && ./install.sh
```

## Customizing your briefing

The prompt is at `~/.local/share/morning-briefing/prompt.md` (auto-updated) or `$KIT_DIR/prompt.md` (canonical).

To experiment without your tweaks being overwritten by auto-update, set `KIT_PIN=local` in your env file. To upstream a useful change, edit `$KIT_DIR/prompt.md`, smoke-test, then `git commit && git push` — everyone gets it next morning.

Common tweaks:
- Add project keywords to importance ranking ("Cortana", "Pulse", "your-team")
- Add new sections (e.g. "GitHub PRs awaiting your review")
- Adjust the recipient name / personalization tone
- Change number of email items surfaced

## Troubleshooting

**Log shows `Webhook response: {"ok":false,...}` or DM doesn't arrive**
The Slack workflow rejected the payload. Most common cause: `RECIPIENT_EMAIL` doesn't match a Slack user (e.g. `@uber.com` instead of `@ext.uber.com`, or a typo). Check the workflow activity log at Slack → Workflow Builder → Morning Briefing Notifier → Activity.

**Log shows authentication errors from google-mcp or slack-mcp**
OAuth tokens have expired or aren't cached for `$HOME`. Re-run `aifx agent run claude` from your home directory and trigger each MCP once to refresh.

**Log file doesn't exist after 8:05am local**
Cron didn't fire. Check:
```bash
crontab -l                                                       # confirm entry exists
grep CRON /var/log/syslog | tail -40                             # or
journalctl -u cron --since "1 hour ago" 2>/dev/null | tail -40
```

**Briefing arrives but missing some Slack content (e.g. no @-mentions)**
The slack-mcp tool surface may differ from what the prompt expects. Run `aifx agent run claude` interactively and ask "what tools do you have available from slack-mcp" — adjust the prompt to use the actual tool names if needed.

**Briefing has literal `*` or `_` in the text instead of bold/italic**
Workflow Builder strips mrkdwn from variables. The prompt should produce plain text only. If you see asterisks, the local prompt cache might be stale — run `cd $KIT_DIR && git pull && cp prompt.md ~/.local/share/morning-briefing/prompt.md`.

**`failed to ensure marketplace uber-code/devexp-agent-marketplace` warning in log**
Harmless cosmetic. Your GitHub identity doesn't have access to the `uber-code` org. Doesn't affect the briefing — no plugin skills are used.

**Want to disable temporarily**
```bash
crontab -e   # comment out (#) or delete the morning-briefing line
```

## Uninstall

```bash
# 1. Remove cron entry
crontab -e   # delete the morning-briefing line and TZ=Australia/Sydney line

# 2. Remove kit files
rm -rf \
  ~/bin/run-morning-briefing.sh \
  ~/.config/morning-briefing.env \
  ~/.local/share/morning-briefing/ \
  ~/morning-briefing-kit/ \
  ~/.claude/logs/morning-briefing-*.log

# 3. (Optional) deauthorize the MCP in Slack — Slack apps page, revoke
# 4. (Optional) remove MCP registrations
#    aifx mcp remove google-mcp slack-mcp
```

## Architecture

```
cron (8am local TZ, weekdays)
  └─> ~/bin/run-morning-briefing.sh
        ├─> sources ~/.config/morning-briefing.env (WEBHOOK_URL, RECIPIENT_*, KIT_DIR)
        ├─> auto-update: cd $KIT_DIR && git pull (skipped if KIT_PIN set)
        ├─> validates + refreshes ~/.local/share/morning-briefing/prompt.md
        ├─> interpolates {{RECIPIENT_*}} placeholders
        ├─> aifx agent run claude -p "<prompt>"  → stdout = briefing body (plain text)
        │     uses google-mcp, slack-mcp, WebFetch(wttr.in)
        └─> curl POST <WEBHOOK_URL> with {recipient_email, subject, body}
              └─> Slack Workflow Builder: "Morning Briefing Notifier"
                    ├─> trigger: webhook (recipient_email typed as "Slack user email")
                    └─> step: Send a message to a person → bot DM, fires push
```

## Files in this kit

| File | Purpose |
|---|---|
| `bootstrap.sh` | One-paste installer — clones the kit, runs install.sh, prompts for webhook, OAuths MCPs, smoke-tests. |
| `install.sh` | Lower-level installer (idempotent). Called by bootstrap.sh; can also be run directly. |
| `prompt.md` | Briefing prompt template with `{{RECIPIENT_*}}` placeholders. Auto-updated. |
| `README.md` | This file. |

## Sharing & contributing

The prompt iterates. If you find a useful tweak, push it upstream — every adopter gets it next morning via auto-update. Coordinate larger changes via DM to `@tlawle1`.

## Open improvements (future work)

- Promote `WEBHOOK_URL` to uSecret (v2 needs proper namespace setup — currently kept as `chmod 600` .env file)
- Multi-recipient owner workflow for delivering to non-devpod users (PMs, data folks who only work in DSW)
- Optional per-section toggles in env file (disable weather, slack, email independently)
- Add `/briefing-now` Slack slash command for on-demand briefings (requires custom Slack app + EngSec)
