# Mail and calendar accounts

roost holds the owner's Gmail, Google Calendar, Outlook mail and Microsoft calendar accounts, so Rookery and Raven reach them from any Mac; rooks never do.

## How it is kept apart

- **Two tokens.** `roost token` is the fleet's, which every rook holds. `roost token --owner` is the owner's, which Rookery alone holds (in the keychain, as `roost-owner-token`) and writes into Raven's workspace. Only the owner's token reaches `/v1/providers`, `/v1/mail-accounts`, `/v1/mail` and `/v1/calendar`; the fleet's gets `403`.
- **Nothing in the event log.** Every rook reads the event log, so nothing of the owner's goes there; changes are told over the live link only to desktops that connected with the owner's token.
- **Sealed credentials.** Refresh tokens and app secrets are sealed with AES-GCM under the server's secrets key, which lives in its configuration (`~/.config/roost/config.json`), not in the data root beside the database. Each sealed value is bound to the row it belongs to.
- **Signed in on the Mac, kept on roost.** Rookery opens the provider's sign-in in the browser with PKCE, catches the code on a loopback port, and hands roost the code; roost exchanges it and keeps the refresh token. The Mac holds no mail credentials.
- **No sending.** roost asks to read and draft mail and to read and change calendar events, never to send mail.

## Setting up the apps

Each provider needs an app the owner registers once; its id (and Google's secret) goes into Rookery's settings, which keeps them on roost.

### Google

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project.
2. Enable the **Gmail API** and the **Google Calendar API** (APIs & Services, Library).
3. OAuth consent screen: user type **External**, so both personal Gmail and Workspace accounts can sign in; add the owner's addresses as test users; then **Publish app** to production without submitting it for verification. Sign-in then shows an "unverified app" warning, which the owner passes; a production app's refresh tokens do not expire after seven days, as a testing one's do.
4. Credentials, Create credentials, **OAuth client ID**, application type **Desktop app**. Its client id and client secret go into Rookery.

A Workspace whose admin restricts third-party apps needs the admin to allow this app's client id.

### Microsoft

1. In the [Azure portal](https://portal.azure.com/), App registrations, **New registration**.
2. Supported account types: **Accounts in any organizational directory and personal Microsoft accounts**.
3. Redirect URI: platform **Public client/native (mobile & desktop)**, `http://localhost`.
4. Authentication: allow public client flows.
5. API permissions, Microsoft Graph, delegated: `offline_access`, `openid`, `email`, `profile`, `User.Read`, `Mail.ReadWrite`, `Calendars.ReadWrite`.
6. The application (client) id goes into Rookery; there is no secret.

A work tenant that does not let users consent to apps needs its admin to grant consent once.

## Connecting

In Rookery's settings, under Mail and Calendar Accounts: save the owner token, save each app, then Google Account… or Microsoft Account… opens the sign-in. An account whose grant the provider withdrew shows "sign in again". Disconnect revokes roost's access where the provider allows it and forgets the account.
