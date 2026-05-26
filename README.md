# Morning Briefing — Tier 2 Install Kit

A daily personalized briefing delivered to your Slack DMs at 8:00 AEST, Mon–Fri.

Pulls from your calendar, Gmail, and Slack via MCPs; ranks by urgency / seniority / direct address; delivers via a shared Slack Workflow Builder webhook so notifications actually fire on your phone.

## What you get

A daily DM from **Morning Briefing Notifier** that looks like:

```
The Day Ahead — Tue 26 May

📊 Today at a glance — 5 upcoming meetings · 12 unread email · 3 need response

────────────────────────────
🌤 Weather — Sydney
🌦 Showers, 19°C, SW wind 9 mph

────────────────────────────
📅 Upcoming meetings (AEST)
• 12:00 — Lunch Break: ANZ Region
• 15:00 — AI Office Hours | Ally Price [Zoom]
...

────────────────────────────
📧 Email — action first
1. Leyre Herranz — 2026 Consumer Ops Team Meeting
   Assigned action item: lead AI Corner Thursday [by Thu 28 May]
...

────────────────────────────
💬 Slack — response needed
• Leyre Herranz (#anz-rider-ops) — lead AI Corner, update deck
...

────────────────────────────
💬 Slack — FYI
• Viviane Pretet (DM) — CBA matching segment too small
...
```

## Prerequisites

- An Uber devpod (provision at [go/devpod](https://devpod.uberinternal.com) — `base` flavor is fine).
- 10–15 minutes for setup the first time.
- The team's shared Slack webhook URL (ask the kit owner).

## Quick install

On your devpod:

```bash
# Clone the kit (or copy the files to your devpod)
mkdir -p ~/src && cd ~/src
# git clone <internal-repo-url> morning-briefing-kit
# OR copy install.sh + prompt.md from the kit location

cd morning-briefing-kit
./install.sh
```

The installer is idempotent — safe to re-run if you want to update the prompt or wrapper.

It will:
1. Install Claude Code and the google-mcp + slack-mcp servers
2. Write permissions allowlist to `~/.claude/settings.json`
3. Drop the wrapper at `~/bin/run-morning-briefing.sh`
4. Drop the prompt at `~/.local/share/morning-briefing/prompt.md`
5. Schedule cron for 8am Sydney weekdays
6. Stub a config file at `~/.config/morning-briefing.env` for you to fill in

## Three manual steps after install

### 1. Fill in your config

```bash
nano ~/.config/morning-briefing.env
```

Required:
- **`WEBHOOK_SECRET_PATH`** — uSecret path holding the shared webhook URL (e.g. `/team/ai-enablement/morning-briefing-webhook`). Ask the kit owner for the exact path. **Or** fall back to `WEBHOOK_URL=` with the URL pasted directly if uSecret isn't set up yet.
- **`RECIPIENT_EMAIL`** — your Uber email (e.g. `you@ext.uber.com`).

Optional (improves prompt personalization):
- `RECIPIENT_NAME="Firstname Lastname"`
- `RECIPIENT_FIRST_NAME="Firstname"`
- `RECIPIENT_USERNAME="yourhandle"`

If you're using `WEBHOOK_SECRET_PATH`, make sure you have read access to that uSecret path (the kit owner adds your email or AD group to the secret's `--readable` list).

### 2. Authenticate the MCPs (interactive, one-time)

The cron job runs headless and can't open OAuth browser flows. You must complete OAuth once interactively, which caches the tokens:

```bash
aifx agent run claude
```

In the Claude session, run these two prompts (they trigger OAuth for each MCP):

```
list my next 3 google calendar events
list my unread slack DMs from today
/exit
```

Approve the OAuth prompts in the browser that opens. Done — tokens are now cached and the cron job can use them headlessly.

### 3. Smoke-test

```bash
~/bin/run-morning-briefing.sh
tail -200 ~/.claude/logs/morning-briefing-$(date +%Y%m%d).log
```

You should:
- See `Webhook response: {"ok":true}` near the end of the log
- Receive a Slack DM from **Morning Briefing Notifier** within 10 seconds
- Get a phone push notification (assuming Slack notification settings are normal)

If any of those fail, see **Troubleshooting** below.

## Phone notification settings

Slack DMs from "Morning Briefing Notifier" are treated as messages from a bot/app, not from you — so they fire normal push notifications. But verify:

- Slack mobile → **Settings** → **Notifications** → ensure "Direct messages, mentions & keywords" is enabled.
- If you have Do Not Disturb scheduled for 8am, exclude DMs from "Morning Briefing Notifier" (or disable DND).

## Shared webhook URL (uSecret)

There is ONE webhook URL for the whole team. The Workflow Builder workflow it triggers (`Morning Briefing Notifier`) accepts `recipient_email`, `subject`, and `body` as variables, then resolves the email to a Slack user and DMs them.

This means:
- ✅ One webhook serves the whole team
- ✅ No per-user Slack setup beyond filling in the env file
- ❗ The webhook URL is a secret — anyone with it can DM any teammate as the bot

**Storage:** the URL lives in uSecret. The kit owner creates the secret once with team-shared read access; adopters reference it by path in their env file.

### One-time kit-owner setup

```bash
# In a fresh devpod shell
cerberus -t usecret -s wonkamaster

# Create the secret (interactive — paste the webhook URL when prompted)
usec write \
  --path="/team/<your-team>/morning-briefing-webhook" \
  --owner="kit-owner@ext.uber.com" \
  --readable="kit-owner@ext.uber.com,AD:<your-team-AD-group>" \
  --writeable="kit-owner@ext.uber.com"
```

The `AD:<group>` entry in `--readable` lets every teammate in that AD group fetch the secret without you listing them individually. Find your team's AD group name in uHR / IDM, or list teammates' emails explicitly (comma-separated).

### Adopter usage

In `~/.config/morning-briefing.env`:

```bash
WEBHOOK_SECRET_PATH=/team/<your-team>/morning-briefing-webhook
```

The wrapper runs `cerberus -t usecret -s wonkamaster` then `usec read` at runtime — no plaintext URL ever lands on disk.

### Fallback: plaintext URL

If uSecret access isn't available (e.g. a teammate isn't in the AD group yet), the env file accepts a direct `WEBHOOK_URL=https://hooks.slack.com/triggers/...` as a fallback. Less secure; treat it like a password and `chmod 600` the env file.

**Do not** paste the URL into chat, wiki, or git repos under any circumstances.

## Customizing your briefing

The prompt lives at `~/.local/share/morning-briefing/prompt.md`. By default, the wrapper auto-updates it from the kit repo each morning (see "Auto-updates" below). To experiment with your own prompt tweaks WITHOUT auto-updates overwriting them, set `KIT_PIN=local` in your env file — the wrapper will skip the git-pull and keep using your edited local copy until you remove the pin.

Common tweaks:
- Change the importance signals (e.g. add project keywords)
- Add new sections (e.g. "GitHub PRs awaiting your review")
- Adjust formatting (sections, emoji, separators)

If your change is generally useful, propose it upstream — the kit owner can update the canonical `prompt.md` and the next morning everyone has it.

## Auto-updates

If the kit was installed from a git clone, the wrapper records `KIT_DIR=<path-to-clone>` in your env file. Each morning before generating the briefing, it:

1. `git pull --rebase --quiet` in `$KIT_DIR` (no-op if already up to date)
2. Validates the pulled `prompt.md` is non-empty and contains the required placeholders
3. Copies it to the runtime location (backs up the previous version as `prompt.md.bak`)
4. Proceeds with the briefing

If the pull fails (network blip, git auth issue) or the new prompt fails validation, the wrapper falls back to the cached `prompt.md` — your briefing always runs, even if updates can't reach you that day.

**To opt out of auto-updates** (pin to a specific version): edit `~/.config/morning-briefing.env` and add:

```bash
KIT_PIN=local          # stay on whatever's currently cached locally
# or
KIT_PIN=v1.3           # stay on a specific tag/commit (advanced — you'd need to checkout that ref in $KIT_DIR yourself)
```

**Wrapper script changes are NOT auto-updated** — only the prompt. If the kit owner ships a new wrapper, rerun `install.sh` to pick it up:

```bash
cd $KIT_DIR && git pull && ./install.sh
```

## Troubleshooting

**Log shows `Webhook response: {"ok":false,...}`**
The Slack workflow rejected the payload. Most likely cause: `RECIPIENT_EMAIL` doesn't match a Slack user (e.g. you used `@uber.com` instead of `@ext.uber.com`). Check the workflow's activity log in Slack → Workflow Builder → Morning Briefing Notifier → Activity.

**Log shows authentication errors from google-mcp or slack-mcp**
OAuth tokens have expired or aren't cached for this directory. Re-run `aifx agent run claude` from `$HOME` and trigger each MCP once to refresh.

**Log file doesn't exist at 8:05am**
Cron didn't fire. Check `grep CRON /var/log/syslog | tail -40` or `journalctl -u cron --since "1 hour ago"`. Verify `crontab -l` shows the entry.

**Briefing arrives but missing Slack section content**
The slack-mcp tool surface may differ from what the prompt expects. Run `aifx agent run claude` interactively and ask "what tools do you have available from slack-mcp" — adjust the prompt to use the actual tool names.

**`failed to ensure marketplace uber-code/devexp-agent-marketplace` warning**
Harmless. Your devpod doesn't have GitHub SSH keys for `code.uber.internal`. Fix by running `ussh` and setting up a GitHub SSH key (see internal docs).

**Want to disable temporarily**
```bash
crontab -e   # comment out or delete the morning-briefing line
```

## Uninstall

```bash
# Remove cron entry
crontab -e   # delete the morning-briefing line and TZ=Australia/Sydney line

# Remove files
rm -rf \
  ~/bin/run-morning-briefing.sh \
  ~/.config/morning-briefing.env \
  ~/.local/share/morning-briefing/ \
  ~/.claude/logs/morning-briefing-*.log

# (Optional) deauthorize the MCP workflow in Slack — visit your apps and revoke
```

The `aifx mcp add` registrations stay (they're useful for other Claude uses); remove with `aifx mcp remove google-mcp slack-mcp` if you want a complete cleanup.

## Architecture

```
cron (8am AEST weekdays)
  └─> ~/bin/run-morning-briefing.sh
        ├─> sources ~/.config/morning-briefing.env (WEBHOOK_URL, RECIPIENT_EMAIL, ...)
        ├─> interpolates ~/.local/share/morning-briefing/prompt.md
        ├─> aifx agent run claude -p "<prompt>"  → stdout = briefing body
        │     uses google-mcp, slack-mcp, WebFetch(wttr.in)
        └─> curl POST <WEBHOOK_URL> with {recipient_email, subject, body}
              └─> Slack Workflow Builder: "Morning Briefing Notifier"
                    ├─> trigger: webhook (recipient_email typed as "Slack user email")
                    └─> step: Send a message to a person → bot DM, fires push
```

## Files in this kit

| File | Purpose |
|---|---|
| `install.sh` | Installer (idempotent). Run on each teammate's devpod. |
| `prompt.md` | Briefing prompt template with `{{RECIPIENT_*}}` placeholders. |
| `README.md` | This file. |

## Open improvements (future work)

- ~~Promote `WEBHOOK_URL` storage from `.env` file to uSecret~~ ✅ done
- ~~Fix the `ussh` / GitHub key path so the marketplace warning stops printing~~ — documented in main wiki; not a kit concern
- Add a `/briefing-now` Slack slash command for on-demand briefings (requires custom Slack app + EngSec).
- Multi-timezone support — currently hardcoded to Australia/Sydney.
- Optional sections per-user — let env file toggle weather, email, slack independently.
