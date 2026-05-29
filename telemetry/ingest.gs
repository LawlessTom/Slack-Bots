// Morning Briefing — Telemetry ingest (Google Apps Script web app).
//
// Deploy as a web app and the wrapper will POST one row per fire to the
// resulting URL. See telemetry/SETUP.md for the 5-step deploy procedure.
//
// Data captured per fire (anonymized):
//   user_hash    — sha256(RECIPIENT_EMAIL)[0:8]; stable per user, no PII
//   date_utc     — YYYY-MM-DD when the fire ran (UTC)
//   time_utc     — HH:MM:SS when the fire ran (UTC)
//   exit_code    — 0=success, 2=empty body, 3=claude failed, 4=webhook failed
//   duration_s   — wall-clock seconds the wrapper ran
//   stdout_bytes — bytes Claude returned (0 if it crashed before output)
//   http_code    — Slack webhook HTTP status (empty if never reached webhook)
//   kit_sha      — short SHA of the kit version that ran (drift detection)
//   host         — devpod hostname (lets you correlate to a user later if needed)

const SHEET_NAME = 'fires';
const HEADER = [
  'received_at_utc', 'user_hash', 'date_utc', 'time_utc',
  'exit_code', 'duration_s', 'stdout_bytes', 'http_code',
  'kit_sha', 'host',
];

function doPost(e) {
  let data;
  try {
    data = JSON.parse(e.postData.contents);
  } catch (err) {
    return _json({ ok: false, error: 'invalid JSON' });
  }

  const sheet = _ensureSheet();
  sheet.appendRow([
    new Date().toISOString(),
    data.user_hash || '',
    data.date_utc || '',
    data.time_utc || '',
    data.exit_code !== undefined ? data.exit_code : '',
    data.duration_s !== undefined ? data.duration_s : '',
    data.stdout_bytes !== undefined ? data.stdout_bytes : '',
    data.http_code || '',
    data.kit_sha || '',
    data.host || '',
  ]);
  return _json({ ok: true });
}

// GET returns a rollup intended for the daily 8:30 health DM.
// Wrapper script: curl this URL, pipe the .text field into the Slack webhook.
function doGet(e) {
  const sheet = _ensureSheet();
  const rows = sheet.getDataRange().getValues().slice(1); // skip header

  const byDate = {};      // date → { users: Set, fails: count }
  const lastFire = {};    // user_hash → most recent date_utc
  const allUsers = new Set();

  for (const r of rows) {
    const [, user_hash, date_utc, , exit_code] = r;
    if (!user_hash || !date_utc) continue;
    allUsers.add(user_hash);
    if (!byDate[date_utc]) byDate[date_utc] = { users: new Set(), fails: 0 };
    byDate[date_utc].users.add(user_hash);
    if (exit_code !== 0) byDate[date_utc].fails++;
    if (!lastFire[user_hash] || lastFire[user_hash] < date_utc) {
      lastFire[user_hash] = date_utc;
    }
  }

  // Reference dates: today UTC and yesterday UTC.
  const today = new Date().toISOString().slice(0, 10);
  const ymdMinus = (n) => {
    const d = new Date(Date.now() - n * 86400000);
    return d.toISOString().slice(0, 10);
  };
  const yesterday = ymdMinus(1);

  // Recent days table (last 5 distinct dates seen, oldest → newest).
  const recentDates = Object.keys(byDate).sort().slice(-5);

  const lines = [];
  lines.push(`*Briefing health — ${today} (UTC)*`);
  lines.push('');
  lines.push('Recent days:');
  for (const d of recentDates) {
    const { users, fails } = byDate[d];
    const failMark = fails ? ` :x: ${fails} fail` : '';
    lines.push(`  ${d}: ${users.size} user${users.size === 1 ? '' : 's'}${failMark}`);
  }

  // Silent users: have fired in the lookback window but not yesterday or today.
  const lookbackStart = ymdMinus(7);
  const silent = [];
  for (const [u, last] of Object.entries(lastFire)) {
    if (last >= lookbackStart && last < yesterday) {
      silent.push({ user: u, last });
    }
  }
  silent.sort((a, b) => a.last.localeCompare(b.last));

  if (silent.length) {
    lines.push('');
    lines.push(':warning: Silent (fired in last 7d but not yesterday/today):');
    for (const { user, last } of silent) {
      lines.push(`  ${user} — last seen ${last}`);
    }
  } else {
    lines.push('');
    lines.push(':white_check_mark: No silent users in last 7d');
  }

  lines.push('');
  lines.push(`Total distinct users (all time): ${allUsers.size}`);

  return _json({
    ok: true,
    text: lines.join('\n'),
    summary: {
      today,
      yesterday,
      recent_dates: recentDates.map((d) => ({
        date: d,
        users: byDate[d].users.size,
        fails: byDate[d].fails,
      })),
      silent_users: silent,
      total_users_all_time: allUsers.size,
    },
  });
}

function _ensureSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = ss.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
    sheet.appendRow(HEADER);
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function _json(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
