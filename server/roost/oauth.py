import base64
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from roost.accounts import Account, AccountStore, ProviderApp
from roost.errors import RoostError, ValidationError


class ProviderError(RoostError):
    """A mail and calendar provider refused or could not be reached."""

    ERROR_HTTP_STATUS = 502


class LoginRequiredError(ProviderError):
    """The provider no longer honours an account's refresh token: the owner must sign in again."""

    ERROR_HTTP_STATUS = 409


@dataclass(frozen=True)
class ProviderEndpoints:
    """Where a provider signs a user in and hands out tokens, and what roost asks it for."""

    authorize_url: str
    token_url: str
    revoke_url: str
    profile_url: str
    list_scopes: tuple[str, ...]
    map_extra_authorize: tuple[tuple[str, str], ...]

    GOOGLE_WORKSPACE_CLAIM = "hd"
    """The tenant Microsoft gives every personal account."""
    MICROSOFT_CONSUMER_TENANT = "9188040d-6c67-4c5b-b112-36a304b66dad"

    @classmethod
    def of(cls, provider: str) -> "ProviderEndpoints":
        """A provider's endpoints and scopes. roost reads and drafts mail and reads and changes calendar
        events; it never asks to send mail.

        Raises:
            ValidationError: if the provider is unknown
        """
        if provider == ProviderApp.PROVIDER_GOOGLE:
            return cls(
                authorize_url="https://accounts.google.com/o/oauth2/v2/auth",
                token_url="https://oauth2.googleapis.com/token",
                revoke_url="https://oauth2.googleapis.com/revoke",
                profile_url="https://openidconnect.googleapis.com/v1/userinfo",
                list_scopes=(
                    "openid",
                    "email",
                    "profile",
                    "https://www.googleapis.com/auth/gmail.readonly",
                    "https://www.googleapis.com/auth/gmail.compose",
                    "https://www.googleapis.com/auth/calendar.readonly",
                    "https://www.googleapis.com/auth/calendar.events",
                ),
                map_extra_authorize=(("access_type", "offline"), ("prompt", "consent")),
            )
        if provider == ProviderApp.PROVIDER_MICROSOFT:
            return cls(
                authorize_url="https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
                token_url="https://login.microsoftonline.com/common/oauth2/v2.0/token",
                revoke_url="",
                profile_url="https://graph.microsoft.com/v1.0/me",
                list_scopes=(
                    "openid",
                    "email",
                    "profile",
                    "offline_access",
                    "User.Read",
                    "Mail.ReadWrite",
                    "Calendars.ReadWrite",
                ),
                map_extra_authorize=(("prompt", "select_account"),),
            )
        raise ValidationError(f"unknown provider: {provider!r}")


class HttpTransport:
    """How roost speaks to the providers: one HTTPS request, its JSON answer. Tests put a fake in its place."""

    TRANSPORT_TIMEOUT_SECONDS = 30

    def request(
        self,
        method: str,
        url: str,
        map_form: dict[str, str] | None = None,
        bearer: str | None = None,
    ) -> tuple[int, dict[str, object]]:
        """Send one request.

        Args:
            method: the HTTP method
            url: where to
            map_form: a form body, or None for none
            bearer: an access token to present, or None

        Returns:
            the status and the decoded JSON answer, empty when it has none

        Raises:
            ProviderError: if the provider cannot be reached
        """
        data = urllib.parse.urlencode(map_form).encode("utf-8") if map_form is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        if bearer:
            request.add_header("Authorization", f"Bearer {bearer}")
        if data is not None:
            request.add_header("Content-Type", "application/x-www-form-urlencoded")
        try:
            with urllib.request.urlopen(request, timeout=self.TRANSPORT_TIMEOUT_SECONDS) as response:
                return response.status, self._decode(response.read())
        except urllib.error.HTTPError as err:
            return err.code, self._decode(err.read())
        except (urllib.error.URLError, OSError) as err:
            raise ProviderError(f"cannot reach {urllib.parse.urlsplit(url).netloc}: {err}") from err

    @staticmethod
    def _decode(raw: bytes) -> dict[str, object]:
        try:
            map_body = json.loads(raw) if raw else {}
        except ValueError:
            return {}
        return map_body if isinstance(map_body, dict) else {}


class AccountLogin:
    """Signing roost in to the owner's accounts and keeping their access fresh. Rookery signs the owner in
    on the Mac, in the browser, with the app the owner registered and PKCE, and hands roost the code; roost
    alone exchanges it, so the account's refresh token never leaves roost. Access tokens are kept in memory
    until shortly before they expire."""

    LOGIN_EXPIRY_MARGIN_SECONDS = 120
    LOGIN_DEFAULT_LIFETIME_SECONDS = 3600.0
    LOGIN_INVALID_GRANT = "invalid_grant"

    def __init__(
        self,
        accounts: AccountStore,
        transport: HttpTransport | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._accounts = accounts
        self._transport = transport or HttpTransport()
        self._clock = clock
        self._lock = threading.Lock()
        self._map_access: dict[str, tuple[str, float]] = {}

    def authorize_url(self, provider: str, redirect_uri: str, code_challenge: str, state: str) -> str:
        """Where the owner's browser goes to sign in, for Rookery to open.

        Args:
            provider: `google` or `microsoft`
            redirect_uri: the loopback address Rookery listens on
            code_challenge: the PKCE challenge, S256
            state: what Rookery checks comes back

        Raises:
            ValidationError: if the provider is unknown or an argument missing
            NotFoundError: if no app is set up for the provider
        """
        if not redirect_uri.startswith(("http://127.0.0.1", "http://localhost")):
            raise ValidationError("the sign-in comes back to Rookery on this Mac, at a loopback address")
        if not code_challenge or not state:
            raise ValidationError("a sign-in needs a PKCE challenge and a state")
        app = self._accounts.provider(provider)
        endpoints = ProviderEndpoints.of(provider)
        map_query = {
            "client_id": app.client_id,
            "response_type": "code",
            "redirect_uri": redirect_uri,
            "scope": " ".join(endpoints.list_scopes),
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
            "state": state,
            **dict(endpoints.map_extra_authorize),
        }
        return endpoints.authorize_url + "?" + urllib.parse.urlencode(map_query)

    def connect(self, provider: str, code: str, code_verifier: str, redirect_uri: str, kind: str = "") -> Account:
        """Exchange the code the owner's sign-in returned for tokens, and keep the account.

        Args:
            provider: `google` or `microsoft`
            code: the authorization code
            code_verifier: the PKCE verifier the challenge came from
            redirect_uri: the loopback address the sign-in returned to
            kind: `personal` or `work`; empty to tell from the account itself

        Returns:
            the account, connected

        Raises:
            ProviderError: if the provider refuses the code or cannot be reached
            ValidationError: if an argument is unusable
        """
        if not code or not code_verifier:
            raise ValidationError("a sign-in needs its code and PKCE verifier")
        app = self._accounts.provider(provider)
        endpoints = ProviderEndpoints.of(provider)
        map_form = {
            "client_id": app.client_id,
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": code_verifier,
            "redirect_uri": redirect_uri,
        }
        if app.client_secret:
            map_form["client_secret"] = app.client_secret
        status, map_tokens = self._transport.request("POST", endpoints.token_url, map_form)
        if status != 200 or not map_tokens.get("access_token"):
            raise ProviderError(f"{provider} refused the sign-in: {self._reason(map_tokens)}")
        access_token = str(map_tokens["access_token"])
        status, map_profile = self._transport.request("GET", endpoints.profile_url, bearer=access_token)
        if status != 200:
            raise ProviderError(f"{provider} would not say whose account it is: {self._reason(map_profile)}")
        email = str(
            map_profile.get("email")
            or map_profile.get("mail")
            or map_profile.get("userPrincipalName")
            or ""
        )
        display_name = str(map_profile.get("name") or map_profile.get("displayName") or "")
        account = self._accounts.connect(
            provider=provider,
            kind=kind or self._kind_of(provider, map_profile, str(map_tokens.get("id_token") or "")),
            email=email,
            display_name=display_name,
            list_scopes=str(map_tokens.get("scope") or " ".join(endpoints.list_scopes)).split(),
            refresh_token=str(map_tokens.get("refresh_token") or ""),
        )
        self._remember(account.id, access_token, map_tokens)
        return account

    def access_token(self, account_id: str) -> str:
        """A fresh access token for an account, renewed with its refresh token when the one held is about to
        expire; a provider that no longer honours the refresh token marks the account as needing the owner
        to sign in again.

        Raises:
            LoginRequiredError: if the owner must sign in again
            ProviderError: if the provider cannot be reached or fails otherwise
            NotFoundError: if there is no such account
        """
        with self._lock:
            held = self._map_access.get(account_id)
        if held is not None and held[1] - self.LOGIN_EXPIRY_MARGIN_SECONDS > self._clock():
            return held[0]
        account = self._accounts.get(account_id)
        app = self._accounts.provider(account.provider)
        map_form = {
            "client_id": app.client_id,
            "grant_type": "refresh_token",
            "refresh_token": self._accounts.refresh_token(account_id),
        }
        if app.client_secret:
            map_form["client_secret"] = app.client_secret
        status, map_tokens = self._transport.request(
            "POST",
            ProviderEndpoints.of(account.provider).token_url,
            map_form,
        )
        if status != 200 or not map_tokens.get("access_token"):
            reason = self._reason(map_tokens)
            if map_tokens.get("error") == self.LOGIN_INVALID_GRANT:
                self._accounts.note_status(account_id, Account.STATUS_NEEDS_LOGIN, reason)
                raise LoginRequiredError(f"{account.email} needs signing in again: {reason}")
            self._accounts.note_status(account_id, Account.STATUS_FAILING, reason)
            raise ProviderError(f"{account.provider} would not renew access to {account.email}: {reason}")
        if map_tokens.get("refresh_token"):
            self._accounts.replace_refresh_token(account_id, str(map_tokens["refresh_token"]))
        if account.status != Account.STATUS_CONNECTED:
            self._accounts.note_status(account_id, Account.STATUS_CONNECTED)
        return self._remember(account_id, str(map_tokens["access_token"]), map_tokens)

    def disconnect(self, account_id: str) -> Account:
        """Revoke roost's access to an account where the provider allows it, and forget the account.

        Raises:
            NotFoundError: if there is no such account
        """
        account = self._accounts.get(account_id)
        endpoints = ProviderEndpoints.of(account.provider)
        if endpoints.revoke_url:
            try:
                self._transport.request(
                    "POST",
                    endpoints.revoke_url,
                    {"token": self._accounts.refresh_token(account_id)},
                )
            except ProviderError:
                pass
        with self._lock:
            self._map_access.pop(account_id, None)
        return self._accounts.remove(account_id)

    def _remember(self, account_id: str, access_token: str, map_tokens: dict[str, object]) -> str:
        try:
            lifetime = float(map_tokens.get("expires_in") or self.LOGIN_DEFAULT_LIFETIME_SECONDS)
        except (TypeError, ValueError):
            lifetime = self.LOGIN_DEFAULT_LIFETIME_SECONDS
        with self._lock:
            self._map_access[account_id] = (access_token, self._clock() + lifetime)
        return access_token

    @staticmethod
    def _kind_of(provider: str, map_profile: dict[str, object], id_token: str) -> str:
        if provider == ProviderApp.PROVIDER_GOOGLE:
            is_workspace = bool(map_profile.get(ProviderEndpoints.GOOGLE_WORKSPACE_CLAIM))
            return Account.KIND_WORK if is_workspace else Account.KIND_PERSONAL
        is_consumer = AccountLogin._claims_of(id_token).get("tid") == ProviderEndpoints.MICROSOFT_CONSUMER_TENANT
        return Account.KIND_PERSONAL if is_consumer else Account.KIND_WORK

    @staticmethod
    def _claims_of(id_token: str) -> dict[str, object]:
        """An ID token's claims, read without checking its signature: it came straight from the provider's
        token endpoint over TLS, and is used only to tell a personal account from a work one."""
        list_parts = id_token.split(".")
        if len(list_parts) != 3:
            return {}
        payload = list_parts[1] + "=" * (-len(list_parts[1]) % 4)
        try:
            map_claims = json.loads(base64.urlsafe_b64decode(payload))
        except ValueError:
            return {}
        return map_claims if isinstance(map_claims, dict) else {}

    @staticmethod
    def _reason(map_body: dict[str, object]) -> str:
        return str(map_body.get("error_description") or map_body.get("error") or "no reason given")
