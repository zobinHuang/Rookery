import json
import secrets
import sqlite3
from dataclasses import dataclass, field
from roost.database import Database
from roost.errors import NotFoundError, ValidationError
from roost.resources import ResourceStore
from roost.vault import SecretVault


@dataclass
class ProviderApp:
    """The app the owner registered with a mail and calendar provider, through which roost signs in to
    their accounts: Google's OAuth client, or Microsoft's app registration."""

    PROVIDER_GOOGLE = "google"
    PROVIDER_MICROSOFT = "microsoft"
    SET_PROVIDERS = frozenset({PROVIDER_GOOGLE, PROVIDER_MICROSOFT})

    provider: str
    client_id: str
    client_secret: str = ""
    updated_at: str = ""

    def as_payload(self) -> dict[str, object]:
        """Render the app as JSON, its secret left out.

        Returns:
            the provider, the client id, and whether a secret is kept
        """
        return {
            "provider": self.provider,
            "client_id": self.client_id,
            "has_client_secret": bool(self.client_secret),
            "updated_at": self.updated_at,
        }


@dataclass
class Account:
    """One of the owner's mail and calendar accounts: which provider, whether personal or a work one, the
    address, how it stands, and how far its sync has come. Its refresh token stays sealed in the database
    and never leaves roost."""

    KIND_PERSONAL = "personal"
    KIND_WORK = "work"
    SET_KINDS = frozenset({KIND_PERSONAL, KIND_WORK})
    STATUS_CONNECTED = "connected"
    STATUS_NEEDS_LOGIN = "needs_login"
    STATUS_FAILING = "failing"

    id: str
    provider: str
    kind: str
    email: str
    display_name: str
    list_scopes: list[str]
    status: str
    error: str = ""
    created_at: str = ""
    updated_at: str = ""
    synced_at: str = ""
    map_sync_state: dict[str, object] = field(default_factory=dict)

    def as_payload(self) -> dict[str, object]:
        """Render the account as JSON, its credentials left out.

        Returns:
            a mapping of every field but the refresh token
        """
        return {
            "id": self.id,
            "provider": self.provider,
            "kind": self.kind,
            "email": self.email,
            "display_name": self.display_name,
            "scopes": self.list_scopes,
            "status": self.status,
            "error": self.error,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "synced_at": self.synced_at,
        }


class AccountStore:
    """The owner's provider apps and accounts, in the database, their secrets sealed by the vault. Nothing here
    goes into the event log, which every rook reads; only the owner's token reaches it."""

    ACCOUNT_ID_PREFIX = "a-"
    ACCOUNT_ID_BYTES = 9
    ACCOUNT_FIELD_MAX_CHARS = 500

    def __init__(self, database: Database, vault: SecretVault) -> None:
        self._database = database
        self._vault = vault

    def put_provider(self, provider: str, client_id: str, client_secret: str) -> ProviderApp:
        """Keep the app registered with a provider, replacing the one kept.

        Args:
            provider: `google` or `microsoft`
            client_id: the app's client id
            client_secret: its secret, or empty for an app that has none, as a Microsoft public client

        Returns:
            the app as kept

        Raises:
            ValidationError: if the provider is unknown or the client id empty or too long
        """
        self._check_provider(provider)
        client_id = client_id.strip()
        if not client_id or len(client_id) > self.ACCOUNT_FIELD_MAX_CHARS:
            raise ValidationError("a provider app needs a client id")
        at = ResourceStore.now_timestamp()
        sealed = ""
        if client_secret.strip():
            sealed = self._vault.seal(client_secret.strip(), self._secret_purpose(provider))
        with self._database.transaction() as connection:
            connection.execute(
                """
                INSERT INTO provider_apps (provider, client_id, client_secret, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT (provider) DO UPDATE SET
                    client_id = excluded.client_id, client_secret = excluded.client_secret,
                    updated_at = excluded.updated_at
                """,
                (provider, client_id, sealed, at),
            )
        return self.provider(provider)

    def provider(self, provider: str) -> ProviderApp:
        """The app registered with a provider, its secret opened.

        Raises:
            ValidationError: if the provider is unknown
            NotFoundError: if no app is kept for it
        """
        self._check_provider(provider)
        with self._database.reading() as connection:
            row = connection.execute("SELECT * FROM provider_apps WHERE provider = ?", (provider,)).fetchone()
        if row is None:
            raise NotFoundError(f"no {provider} app is set up")
        client_secret = ""
        if row["client_secret"]:
            client_secret = self._vault.open(row["client_secret"], self._secret_purpose(provider))
        return ProviderApp(
            provider=row["provider"],
            client_id=row["client_id"],
            client_secret=client_secret,
            updated_at=row["updated_at"],
        )

    def providers(self) -> list[ProviderApp]:
        """Every app kept, by provider."""
        list_apps: list[ProviderApp] = []
        for provider in sorted(ProviderApp.SET_PROVIDERS):
            try:
                list_apps.append(self.provider(provider))
            except NotFoundError:
                continue
        return list_apps

    def connect(
        self,
        provider: str,
        kind: str,
        email: str,
        display_name: str,
        list_scopes: list[str],
        refresh_token: str,
    ) -> Account:
        """Keep an account roost signed in to, or the new credentials of one it had: an address is one account
        per provider, and signing in again replaces its token and clears its failure.

        Args:
            provider: `google` or `microsoft`
            kind: `personal` or `work`
            email: its address
            display_name: the name on it
            list_scopes: what roost may do with it
            refresh_token: the token roost renews its access with

        Returns:
            the account

        Raises:
            ValidationError: if the provider, the kind, the address or the token is unusable
        """
        self._check_provider(provider)
        if kind not in Account.SET_KINDS:
            raise ValidationError(f"an account is personal or work, not {kind!r}")
        email = email.strip().lower()
        if "@" not in email or len(email) > self.ACCOUNT_FIELD_MAX_CHARS:
            raise ValidationError("an account needs its address")
        if not refresh_token:
            raise ValidationError("the provider gave no refresh token; sign in again and allow offline access")
        at = ResourceStore.now_timestamp()
        with self._database.transaction() as connection:
            row = connection.execute(
                "SELECT id FROM accounts WHERE provider = ? AND email = ?",
                (provider, email),
            ).fetchone()
            account_id = (
                row["id"] if row is not None else self.ACCOUNT_ID_PREFIX + secrets.token_urlsafe(self.ACCOUNT_ID_BYTES)
            )
            connection.execute(
                """
                INSERT INTO accounts
                    (id, provider, kind, email, display_name, scopes, refresh_token, status, error, created_at,
                     updated_at, synced_at, sync_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, '', ?, ?, '', '{}')
                ON CONFLICT (id) DO UPDATE SET
                    kind = excluded.kind, display_name = excluded.display_name, scopes = excluded.scopes,
                    refresh_token = excluded.refresh_token, status = excluded.status, error = '',
                    updated_at = excluded.updated_at
                """,
                (
                    account_id,
                    provider,
                    kind,
                    email,
                    display_name.strip()[: self.ACCOUNT_FIELD_MAX_CHARS],
                    json.dumps(list_scopes),
                    self._vault.seal(refresh_token, self._token_purpose(account_id)),
                    Account.STATUS_CONNECTED,
                    at,
                    at,
                ),
            )
        return self.get(account_id)

    def get(self, account_id: str) -> Account:
        """One account.

        Raises:
            NotFoundError: if there is no such account
        """
        with self._database.reading() as connection:
            row = connection.execute("SELECT * FROM accounts WHERE id = ?", (account_id,)).fetchone()
        if row is None:
            raise NotFoundError(f"no such account: {account_id}")
        return self._account_of(row)

    def list(self) -> list[Account]:
        """Every account, by address."""
        with self._database.reading() as connection:
            list_rows = connection.execute("SELECT * FROM accounts ORDER BY email, provider").fetchall()
        return [self._account_of(row) for row in list_rows]

    def refresh_token(self, account_id: str) -> str:
        """An account's refresh token, opened, for renewing its access.

        Raises:
            NotFoundError: if there is no such account
        """
        with self._database.reading() as connection:
            row = connection.execute("SELECT refresh_token FROM accounts WHERE id = ?", (account_id,)).fetchone()
        if row is None:
            raise NotFoundError(f"no such account: {account_id}")
        return self._vault.open(row["refresh_token"], self._token_purpose(account_id))

    def replace_refresh_token(self, account_id: str, refresh_token: str) -> None:
        """Keep the refresh token a provider rotated to."""
        with self._database.transaction() as connection:
            connection.execute(
                "UPDATE accounts SET refresh_token = ?, updated_at = ? WHERE id = ?",
                (
                    self._vault.seal(refresh_token, self._token_purpose(account_id)),
                    ResourceStore.now_timestamp(),
                    account_id,
                ),
            )

    def note_status(self, account_id: str, status: str, error: str = "") -> None:
        """Record how an account stands: connected, needing the owner to sign in again, or failing."""
        with self._database.transaction() as connection:
            connection.execute(
                "UPDATE accounts SET status = ?, error = ?, updated_at = ? WHERE id = ?",
                (status, error[: self.ACCOUNT_FIELD_MAX_CHARS], ResourceStore.now_timestamp(), account_id),
            )

    def note_synced(self, account_id: str, map_sync_state: dict[str, object]) -> None:
        """Record how far an account's sync has come, and when."""
        with self._database.transaction() as connection:
            connection.execute(
                "UPDATE accounts SET sync_state = ?, synced_at = ? WHERE id = ?",
                (json.dumps(map_sync_state), ResourceStore.now_timestamp(), account_id),
            )

    def remove(self, account_id: str) -> Account:
        """Forget an account and its credentials.

        Returns:
            the account as it was

        Raises:
            NotFoundError: if there is no such account
        """
        account = self.get(account_id)
        with self._database.transaction() as connection:
            connection.execute("DELETE FROM accounts WHERE id = ?", (account_id,))
        return account

    @staticmethod
    def _check_provider(provider: str) -> None:
        if provider not in ProviderApp.SET_PROVIDERS:
            raise ValidationError(f"unknown provider: {provider!r}")

    @staticmethod
    def _secret_purpose(provider: str) -> str:
        return f"provider:{provider}:client_secret"

    @staticmethod
    def _token_purpose(account_id: str) -> str:
        return f"account:{account_id}:refresh_token"

    @staticmethod
    def _account_of(row: sqlite3.Row) -> Account:
        return Account(
            id=row["id"],
            provider=row["provider"],
            kind=row["kind"],
            email=row["email"],
            display_name=row["display_name"],
            list_scopes=json.loads(row["scopes"]),
            status=row["status"],
            error=row["error"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            synced_at=row["synced_at"],
            map_sync_state=json.loads(row["sync_state"]),
        )
