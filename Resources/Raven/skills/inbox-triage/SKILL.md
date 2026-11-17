---
name: inbox-triage
description: Sort the user's recent mail across every account into what needs a reply, what needs action, what to read, and what to ignore. Use when the user asks what is in their inbox, what they missed, who is waiting on them, or to clean up their mail.
---

# Triage the inbox

1. `search_mail` with `folder: inbox` and `after` the time the user gave (since yesterday unless said), every account, up to 100.
2. Skim by sender, subject and snippet; read whole (`read_mail`) only what looks like it needs the user. Check `read_thread` before saying someone is waiting: the user may have answered already (a reply from one of their own addresses later in the thread).
3. Group, each line naming the account:
   - **Waiting on you**: a person asked a question or for something, and no reply from the user follows.
   - **To do**: deadlines, approvals, bills, forms.
   - **To read**: from people the user deals with, without an ask.
   - **Skip**: newsletters, notifications, marketing, by sender in one line each.
4. Offer to draft replies to the first group (`draft-reply`).
