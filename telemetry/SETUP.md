# Telemetry — Apps Script ingest + report

Anonymized per-fire health pings from every devpod running the morning-briefing
wrapper. No PII: `user_hash = sha256(RECIPIENT_EMAIL)[0:8]`. No Slack handles,
no names, no message content.

## What you get

- **Daily counts**: how many distinct users fired on each recent day
- **Failure flags**: per-day count of non-zero exits
- **Silent users**: hashes that fired in the last 7d but not yesterday/today
  (catches "Tom fired Monday but hasn't fired today" without ever learning Tom)

Wire it once, then a daily 8:30am Slack DM tells you who's drifting offline.

---

## One-time setup (~5 min, manual — Apps Script editor is not API-driven)

### 1. Create the Sheet

[https://sheets.new](https://sheets.new) → rename it `morning-briefing-telemetry`.

Don't add columns; the script creates the `fires` tab and header on first POST.

### 2. Open the Apps Script editor

In the Sheet: **Extensions → Apps Script**. Delete the boilerplate `Code.gs`.

### 3. Paste the code

Copy the contents of [ingest.gs](ingest.gs) into `Code.gs`. Save (⌘S).

### 4. Deploy as a web app

- **Deploy** (top-right) → **New deployment**
- Gear icon → **Web app**
- Description: `morning-briefing telemetry v1`
- Execute as: **Me** (your Uber account)
- Who has access: **Anyone within Uber** (devpods POST authenticated via the
  Apps Script's `Me` identity, but the *endpoint* still needs to be reachable;
  this is the most-restrictive setting that works)
- Click **Deploy** → authorize when prompted
- Copy the **Web app URL** (format: `https://script.google.com/macros/s/AKfy.../exec`)

### 5. Wire it into the wrapper

The wrapper reads `TELEMETRY_URL` from `~/.config/morning-briefing.env`. On
every devpod that should report telemetry, append the line:

```
TELEMETRY_URL=https://script.google.com/macros/s/AKfy.../exec
```

That's it. Next cron fire will POST a row. No env var → wrapper silently no-ops
(telemetry is opt-in per devpod).

---

## Verifying it works

After wiring `TELEMETRY_URL` on a devpod, trigger a manual run:

```
~/bin/run-morning-briefing.sh
```

Then in the Sheet: a new row should appear in the `fires` tab within seconds
of the wrapper's "=== telemetry: emit ... ===" log line.

To sanity-check the report endpoint, paste the web-app URL into a browser. It
returns JSON with `text` (Slack-formatted rollup) and `summary` (machine-readable).

---

## Daily Slack health report (Phase 2 — coming next)

A second cron entry at 8:30am AEST (22:30 UTC) will:

1. `curl` the web-app URL → JSON
2. Extract `.text` → POST to a Slack webhook (your DM, not the briefing channel)

That script + cron line lands once you confirm Phase 1 ingest is working. The
wrapper change (telemetry emit) is shipping now so the data starts collecting
immediately — no point building the report on an empty Sheet.

---

## Rotating / revoking

- **Revoke a devpod**: delete its `TELEMETRY_URL` line from
  `~/.config/morning-briefing.env`. Next fire stops posting. No deletion needed
  on the Sheet side.
- **Rotate the endpoint**: Apps Script → **Deploy → Manage deployments** →
  create a new version → distribute the new URL via the kit (could be added to
  `KIT_DIR/telemetry-url.txt` in a future iteration so it's centrally managed,
  but for now it's a per-devpod env line).
- **Wipe the data**: delete rows in the `fires` tab. The script will keep
  appending.

---

## Why Apps Script and not, e.g., a Cloud Function

- Zero infra: no GCP project, no Cloud Run, no IAM bindings.
- Free quota is enormous for this volume (one POST per user per day).
- The Sheet *is* the storage layer — you can pivot/chart it manually without
  exporting.
- The Web App URL is the public surface; auth lives in the deployment settings.

Tradeoff: Apps Script web apps have a soft latency floor of ~1–2s per request
(cold container spin). Wrapper POSTs with `-m 10` timeout; even a 5s response
is fine since it runs after the briefing has already been delivered.
