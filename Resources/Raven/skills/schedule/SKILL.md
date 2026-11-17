---
name: schedule
description: Propose adding, moving, changing or removing events on the user's calendars, or opening an invitation for the user to answer. Use when the user asks to schedule, book, move, cancel or decline something, or find a free time.
---

# Schedule

1. `list_accounts` for the calendars and their ids. Use the calendar the user named. If they named none, use their default calendar (`default: true`), or leave `calendar_id` out of `propose_event`, which means the same; only if they set no default, pick by the account (work events on the work account's calendar), one that takes events, and say which you picked.
2. `list_events` around the time asked to find a free slot or the event to change, and to spot clashes.
3. Propose:
   - a new event: `propose_event` with `title`, `start`, `end` (ISO 8601, the Mac's time zone unless said), `calendar_id` unless it is the default, and `location` or `notes`;
   - a change: `propose_event_change` with the `event_id` and only the fields that change;
   - a removal: `propose_event_removal`;
   - an invitation to answer: `propose_open_event`, as invitations cannot be answered otherwise.
4. Others cannot be invited this way. To invite people, add the event and propose a draft (`draft-reply`) inviting them with the time and link.
5. Say in a line what you proposed, on which calendar.
