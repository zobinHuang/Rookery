# Mail and calendars

Rookery reads the user's mail and calendars through the Mac's own Mail and Calendar, so any account the Mac holds (Gmail, Google Workspace, Outlook.com, Microsoft 365 and Exchange, iCloud, IMAP) is reachable at once, with no app registered anywhere and nothing sent to roost. Code agents reach them through `rookery-mail`, an MCP server; Raven is the only one that does by default.

## How it is read

- **Mail.** Mail's library, `~/Library/Mail/V<n>`, is read in place and read-only: the index database `MailData/Envelope Index` for each message's account, folder, sender, recipients, subject, dates, flags and opening (`MailLibrary`, `MailLibrarySearch`), and each message's `.emlx` file for its text (`MimeMessage`). A message's file is at `<account id>/<folder>.mbox/.../<store>/Data/<digits>/Messages/<id>.emlx`, the digits those of its id over a thousand, last first; a `.partial.emlx` lacks attachments or long parts not yet downloaded. Gmail keeps every message in All Mail and marks the inbox, starred and the rest as labels (the `labels` table), so a message's folder is the first of its mailbox and labels that applies. Junk and trash are left out of searches unless asked for. The schema is Mail's own and undocumented; `rookeryctl mail probe` reports what this Mac's looks like.
- **Accounts.** Mail's scripting names each account's id (which names its directory and its mailboxes' URLs), name and addresses (`MailScripting`), read again every five minutes.
- **Calendars.** EventKit, with full access: every calendar of every account, events between two moments, copies of one meeting on several calendars merged by their shared id (`CalendarLibrary`).

Rookery holds every permission itself: Full Disk Access for Mail's library (granted by the user in System Settings), Calendars, and control of Mail (asked for the first time). `rookery-mail` holds none: it forwards each call to the running app over the control socket (`ControlRequest.mailTool`).

## The tools

`list_accounts`, `search_mail`, `read_mail`, `read_thread` and `list_events` read. `propose_draft`, `propose_event`, `propose_event_change`, `propose_event_removal` and `propose_open_event` only check what they are given and return a proposal, which Raven shows as a card; once the user approves it, Rookery carries it out itself (`MailService.carryOut`): a draft opens in Mail, from the account named, for the user to read and send; an event is added, changed or removed through EventKit, this occurrence only for a recurring one; an invitation opens in Calendar for the user to answer. No tool sends mail, and no agent holds a tool that changes anything. EventKit cannot invite attendees or answer invitations, which is why those go through Mail and Calendar.

Settings, under Mail and Calendars, shows whether Rookery can read Mail's library and the calendars, with a way to grant each, whether Mail is running (new mail arrives only while it is), and every account: whether Raven may read it, and whether it is personal or work. Accounts the user holds back in `mail-accounts.json` in the data directory (`MailAccountSettings`: mail by address, calendars by account name) are not seen by any tool.

## Checking it

    .build/debug/rookeryctl mail probe                         # access, the library's shape, the accounts, the calendars
    .build/debug/rookeryctl mail list_accounts
    .build/debug/rookeryctl mail search_mail '{"folder":"inbox","unread_only":true}'
    .build/debug/rookeryctl mail list_events '{"start":"2026-11-17","end":"2026-11-24"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | .build/debug/rookery-mail

These read the user's own mail; when checking a change, print counts rather than subjects and text.
