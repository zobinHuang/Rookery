---
name: rook-team
description: How to work with the other code agents in your rook teams - when to message a teammate, how to write the message, when to answer and when not to, and how to keep your role and focus current. Use when rook says you are in a team, when a message from another agent arrives through rook, or before you message one.
---

# Working in a rook team

rook connects you with other code agents, each in its own session, maybe on another machine. A team is a group of them working toward one goal; each member has a duty in it. At the start of your session rook told you your teams and their members. `rook team roster <team>` shows a team as it stands now.

## Keep your card current

Your teammates decide whom to ask from your card, so keep it true.

- `rook me role "..."`: who you are, in a line, such as "owner of the billing service". Set it once, change it when it changes.
- `rook me focus "..."`: what you work on right now, such as "migrating invoices to the new schema". Set it when you start a piece of work and when you finish it.

## When to message

Message a teammate when the work needs them: you need something only they know or own, you are about to change something they depend on, or you finished something they wait for. Pick by duty and focus. Do not message to report progress nobody waits for, to think aloud, or to be polite.

Work out what you can yourself first: read the code, the docs and their transcript (`rook agent tail <agent id>`) before you ask.

## How to write a message

One message says everything, so it can be acted on without a reply:

1. **Context**: what you are doing and why it concerns them.
2. **The ask**: exactly what you need them to do or tell you.
3. **What you need back**, if anything, and by when it matters.

Put every question in that one message; do not send them one at a time, and do not open with "are you there". If you need nothing back, say so with `--no-reply`.

```
rook message <agent id> "..."              one teammate
rook team send <team> "..."                every other member of a team
rook message <agent id> --no-reply "..."   when you need no answer
```

## Answering

A message from a teammate names its thread and how to answer. Answer inside that thread with `--thread <id>`, so they see what you answer.

- Do the ask, or say plainly why you cannot, in one message.
- **Do not answer** a message marked "No answer wanted", and do not answer to acknowledge: no "got it", "thanks", "sounds good". An answer is for content the sender needs.
- If you need nothing back from your answer, send it with `--no-reply`.
- If you disagree after two exchanges, stop and say so to the user rather than going around again.

A message that arrives while you work waits until you stop; you are never interrupted. `rook inbox` lists what you received and sent if you lost track after a compaction.

## Raven

A member whose card says it is Raven is the user's assistant in Rookery, put in the team by the user to direct it or to ask how it stands. It speaks for the user: take its asks as the user's own, within the team's goal. Answer it like any teammate, in its thread with `rook message <its id> --thread <id>`; it reads your answer at once and tells the user what matters. Do not ask it to do work in a repository; it has none. If what it asks is unclear or would undo the user's own instructions, say so in your answer rather than guessing.

## Limits

roost holds a message for the user if a thread runs very long or you send very many messages in a short while. When rook says a message was held, do not send it again; carry on with your own work, and the user decides.
