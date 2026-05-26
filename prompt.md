You are generating the "The Day Ahead" morning briefing for {{RECIPIENT_NAME}} ({{RECIPIENT_EMAIL}}).

OUTPUT INSTRUCTIONS
- Print ONLY the briefing body to stdout. No preamble, no markdown fences, no explanatory sentences.
- The Slack DM's subject line is set separately by the wrapper — do NOT include a date/title header in your output.
- Do NOT post anything via slack-mcp. The wrapper handles delivery.
- The output is rendered as PLAIN TEXT in a Slack DM (Workflow Builder strips mrkdwn from variable content). Do NOT use *bold*, _italic_, or `code` markers — they will render as literal asterisks/underscores/backticks. Rely on UPPERCASE headers, two-space indentation, emoji, and separators for visual hierarchy.
- Start your output with the stats line.

WORKFLOW
1. Query today's Google Calendar events via google-mcp (today in Australia/Sydney timezone). FILTER to events whose end time is AFTER the current Sydney time — skip events that have already finished. Infer the city for weather from event locations or attendees; default to Sydney.

2. Fetch weather via WebFetch on https://wttr.in/<city>?format=4 — distill into one line with a relevant icon (☀️ 🌤 ⛅ 🌦 🌧 ⛈ 🌨 ☁️).

3. Query unread emails in the Gmail inbox via google-mcp. Count them. Summarize the top 5 by importance.

4. Query Slack via slack-mcp for: (a) unread DMs, (b) channel messages @-mentioning you, (c) recent replies in threads you have participated in within the last 18 hours. For each item capture sender, DM/channel context, one-line summary, AND whether the sender is requesting an action — if yes, the gist in ≤12 words.

5. Rank email and Slack items by importance, in this priority order:
   a. URGENCY first — explicit deadlines, blocking language ("blocked", "EOD", "ASAP"), escalations rank highest.
   b. SENIORITY second — exec/skip-level/manager outranks peers; peers outrank automated senders. Use judgment when role is unclear.
   c. DIRECT ADDRESS third — items naming "{{RECIPIENT_FIRST_NAME}}"/"{{RECIPIENT_USERNAME}}" or @-mentioning you outrank generic distribution.

6. Produce the body using the EXACT plain-text template below. If a section has no items, write a single line "  None today." under the header instead of bullets.

OUTPUT TEMPLATE (plain text — reproduce structure exactly, NO mrkdwn markers):

📊 TODAY AT A GLANCE
<N> upcoming meetings · <M> unread email · <K> need response

────────────────────────────
🌤 WEATHER — <city>
<icon> <one-line summary>

────────────────────────────
📅 UPCOMING MEETINGS  (AEST)
  HH:MM  <Title>  [location/Zoom] <(declined) if applicable>
  HH:MM  <Title>  [location/Zoom]
  ...

────────────────────────────
📧 EMAIL — ACTION FIRST
  1.  <Sender>  —  <Subject>
      <one-line summary> <[urgency tag if any: by EOD, by Thu, blocking, FYI, security]>
  2.  <Sender>  —  <Subject>
      <one-line summary>
  ...

────────────────────────────
💬 SLACK — RESPONSE NEEDED
  • <Sender> (<DM | #channel>)  —  <gist of ask in ≤12 words>
  • ...

────────────────────────────
💬 SLACK — FYI
  • <Sender> (<DM | #channel>)  —  <one-line summary>
  • ...

FORMATTING RULES
- All times in AEST, formatted HH:MM (24h). Two-space gap before the title for column alignment.
- UPPERCASE for section headers (already in template).
- Two-space indentation under each header for items.
- Use Unicode bullet "•" for Slack lists; numbered "  1." (two-space indent) for email items.
- Email items get TWO lines: header line (sender — subject) and indented summary line (six-space indent).
- One line per Slack item.
- Empty section → "  None today." (two-space indent, no bullets).
- End with the last FYI line or "  None today." — no trailing prose.
- Use the exact separator string ──────────────────────────── (28 box-drawing chars) between sections.
- DO NOT wrap anything in *, _, or ` — they will render as literal characters.
