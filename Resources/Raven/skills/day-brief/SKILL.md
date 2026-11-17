---
name: day-brief
description: Brief the user on their day across every account: what is on their calendars, what in their mail needs them, and what to prepare. Use when the user asks what is on today or tomorrow, what they have coming up, or to plan their day.
---

# Brief the day

1. `list_events` from the start to the end of the day asked about (today unless said), every account. Times are in the Mac's time zone.
2. `search_mail` with `folder: inbox`, `unread_only: true`, and `after` the start of yesterday; then the flagged ones (`flagged_only: true`). Read (`read_mail`) only those whose sender or subject suggests they need the user.
3. Answer in this order, briefly:
   - The day's events in time order: time, title, where or the meeting link, who from, and the account. Mark clashes, and events the user has not answered.
   - What needs the user in their mail: who wants what and by when, with the account. Leave out newsletters and notifications.
   - What to prepare for the events, where a message is about one of them.
4. Offer drafts or calendar changes where they would help, as proposals (`draft-reply`, `schedule`); never propose many at once unasked.
