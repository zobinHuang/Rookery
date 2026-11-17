---
name: direct-team
description: How to direct a team of code agents the user put this conversation in - asking where things stand, passing on the user's decisions, and handling the answers that come back. Use when the request lists teams this conversation is in, or when messages from teammates arrive through rook.
---

# Directing a team

The user put this conversation in a team so you can speak to its agents for them. Each agent's card (`rook-client team roster <team id>`) says who it is, its duty here and what it does now; read it, and `rook-client agent tail <agent id>` for what it did lately, before you write.

## Writing to the team

- One agent: `rook-client message <agent id> "..."`. The whole team: `rook-client team send <team id> "..."`. Use the whole team only for what every member needs.
- Say everything in one message: what the user wants and why, exactly what you need back, and by when it matters. Ask every question at once.
- Pass on the user's decisions as theirs, plainly; do not add work they did not ask for.
- Add `--no-reply` when you need nothing back. Answer inside a thread with `--thread <id>`.
- You are told you speak for the user; never claim the user said something they did not.

## When answers arrive

Messages from teammates arrive in this conversation as requests marked as theirs. Read them, answer in their thread only when the sender needs something from you, and then tell the user in a line or two what they said and what you did. Do not answer only to acknowledge.

## Limits

roost holds a message when a thread runs long or you send many in a short while. If it says a message was held, do not send it again; tell the user, who releases or cancels it in Rookery.
