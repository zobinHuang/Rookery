---
name: draft-reply
description: Draft a reply to a message, or a new message, for the user to approve and then send from Mail. Use when the user asks to reply, answer, write to someone, follow up, or decline.
---

# Draft a reply

1. Read the message (`read_mail`) and its thread (`read_thread`), so the reply fits what was said.
2. Write it as the user would: their language, the thread's language and tone, short, answering every question asked; leave a placeholder in brackets for any fact you do not know rather than inventing it.
3. Propose it: `propose_draft` with `reply_to` set to the message's id, which sends it from the account the message came to, and the body. For a new message give `account` (the address to send from, chosen by who it is for: work to work), `to`, `subject` and `body`.
4. Tell the user in a line what the draft says and which account it goes from. It goes straight into Rookery's drafts, where they change and send it from Rookery's Mail page; nothing is sent by you.
