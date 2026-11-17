import base64
import http.client
import json
import tempfile
import threading
import unittest
from pathlib import Path
from websockets.sync.client import ClientConnection, connect
from roost.__main__ import ServerCli
from roost.accounts import Account, AccountStore
from roost.config import ServerConfig
from roost.database import Database
from roost.errors import ConfigError, ValidationError
from roost.http import RoostServer
from roost.oauth import AccountLogin, LoginRequiredError
from roost.store import SessionStore
from roost.vault import SecretVault


class OwnerTest(unittest.TestCase):
    """The owner's accounts: reached by the owner's token alone, their secrets sealed, kept out of the event
    log, and their changes told only to desktops holding the owner's token."""

    FLEET_TOKEN = "fleet-token"
    OWNER_TOKEN = "owner-token"
    TEST_TIMEOUT_SECONDS = 5

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        config = ServerConfig(
            data_root=root,
            host="127.0.0.1",
            port=0,
            token=self.FLEET_TOKEN,
            max_body_bytes=1024 * 64,
            tls_cert=None,
            tls_key=None,
            link_port=0,
            owner_token=self.OWNER_TOKEN,
            secrets_key=ServerConfig.generate_secrets_key(),
        )
        self.server = RoostServer(config=config, store=SessionStore(root))
        self.server.link.listen()
        for target in (self.server.serve_forever, self.server.link.serve_forever):
            thread = threading.Thread(target=target, daemon=True)
            thread.start()
            self.addCleanup(thread.join, self.TEST_TIMEOUT_SECONDS)
        self.addCleanup(self.server.resources.database.close)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, method: str, path: str, token: str, map_body: object = None) -> tuple[int, dict[str, object]]:
        connection = http.client.HTTPConnection("127.0.0.1", self.server.bound_port(), timeout=self.TEST_TIMEOUT_SECONDS)
        try:
            body = None if map_body is None else json.dumps(map_body).encode("utf-8")
            map_headers = {"Authorization": f"Bearer {token}"}
            if body is not None:
                map_headers["Content-Length"] = str(len(body))
            connection.request(method, path, body=body, headers=map_headers)
            response = connection.getresponse()
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
        finally:
            connection.close()

    def open_desktop(self, token: str) -> ClientConnection:
        connection = connect(
            f"ws://127.0.0.1:{self.server.link.bound_port()}/v1/link",
            additional_headers={"Authorization": f"Bearer {token}"},
            open_timeout=self.TEST_TIMEOUT_SECONDS,
        )
        self.addCleanup(connection.close)
        connection.send(json.dumps({"type": "hello", "role": "desktop"}))
        self.assertEqual(json.loads(connection.recv(timeout=self.TEST_TIMEOUT_SECONDS))["type"], "welcome")
        return connection

    def connect_account(self) -> Account:
        return self.server.accounts.connect(
            provider="google",
            kind=Account.KIND_PERSONAL,
            email="Me@Example.com",
            display_name="Me",
            list_scopes=["gmail.readonly"],
            refresh_token="refresh-secret",
        )

    def test_the_fleets_token_never_reaches_the_owners_data(self) -> None:
        self.connect_account()
        for path in ("/v1/providers", "/v1/mail-accounts", "/v1/mail/messages", "/v1/calendar/events"):
            status, _ = self.request("GET", path, self.FLEET_TOKEN)
            self.assertEqual(status, 403, path)
        status, _ = self.request("GET", "/v1/mail-accounts", "wrong")
        self.assertEqual(status, 401)

    def test_the_owners_token_reaches_the_fleet_too(self) -> None:
        status, map_body = self.request("GET", "/v1/kinds", self.OWNER_TOKEN)
        self.assertEqual(status, 200)
        self.assertIn("team", [kind["name"] for kind in map_body["kinds"]])

    def test_a_provider_apps_secret_is_kept_but_never_shown(self) -> None:
        status, map_app = self.request(
            "PUT",
            "/v1/providers/google",
            self.OWNER_TOKEN,
            {"client_id": "id.apps.googleusercontent.com", "client_secret": "s3cret"},
        )
        self.assertEqual((status, map_app["has_client_secret"]), (200, True))
        self.assertNotIn("s3cret", json.dumps(self.request("GET", "/v1/providers", self.OWNER_TOKEN)[1]))
        self.assertEqual(self.server.accounts.provider("google").client_secret, "s3cret")
        status, _ = self.request("PUT", "/v1/providers/yahoo", self.OWNER_TOKEN, {"client_id": "x"})
        self.assertEqual(status, 400)

    def test_an_account_is_listed_without_its_token_and_sealed_at_rest(self) -> None:
        account = self.connect_account()
        status, map_body = self.request("GET", "/v1/mail-accounts", self.OWNER_TOKEN)
        self.assertEqual(status, 200)
        self.assertEqual([listed["email"] for listed in map_body["accounts"]], ["me@example.com"])
        self.assertNotIn("refresh-secret", json.dumps(map_body))
        with self.server.resources.database.reading() as connection:
            stored = connection.execute("SELECT refresh_token FROM accounts").fetchone()["refresh_token"]
        self.assertNotIn("refresh-secret", stored)
        self.assertEqual(self.server.accounts.refresh_token(account.id), "refresh-secret")

    def test_signing_in_again_keeps_one_account_per_address(self) -> None:
        first = self.connect_account()
        self.server.accounts.note_status(first.id, Account.STATUS_NEEDS_LOGIN, "token revoked")
        again = self.connect_account()
        self.assertEqual(again.id, first.id)
        self.assertEqual((again.status, again.error), (Account.STATUS_CONNECTED, ""))
        with self.assertRaises(ValidationError):
            self.server.accounts.connect("google", "family", "a@b.c", "", [], "t")

    def test_removing_an_account_forgets_it(self) -> None:
        account = self.connect_account()
        status, _ = self.request("DELETE", f"/v1/mail-accounts/{account.id}", self.OWNER_TOKEN)
        self.assertEqual(status, 200)
        self.assertEqual(self.server.accounts.list(), [])

    def test_nothing_of_the_owners_goes_into_the_event_log(self) -> None:
        self.request("PUT", "/v1/providers/google", self.OWNER_TOKEN, {"client_id": "id"})
        self.connect_account()
        self.assertEqual(self.server.events.latest(10), [])

    def test_only_the_owners_desktops_hear_of_their_mail(self) -> None:
        owner = self.open_desktop(self.OWNER_TOKEN)
        fleet = self.open_desktop(self.FLEET_TOKEN)
        self.assertEqual(self.server.link.notify_owner({"type": "mail", "account": "a-1"}), 1)
        self.assertEqual(json.loads(owner.recv(timeout=self.TEST_TIMEOUT_SECONDS))["type"], "mail")
        with self.assertRaises(TimeoutError):
            fleet.recv(timeout=0.3)


class VaultTest(unittest.TestCase):
    def test_a_sealed_secret_opens_only_for_its_purpose_and_key(self) -> None:
        vault = SecretVault(ServerConfig(
            data_root=Path("."), host="", port=0, token="t", max_body_bytes=0, tls_cert=None, tls_key=None,
            secrets_key=ServerConfig.generate_secrets_key(),
        ).secrets_key_bytes())
        sealed = vault.seal("hunter2", "account:a-1:refresh_token")
        self.assertEqual(vault.open(sealed, "account:a-1:refresh_token"), "hunter2")
        with self.assertRaises(ConfigError):
            vault.open(sealed, "account:a-2:refresh_token")
        other = SecretVault(bytes(32))
        with self.assertRaises(ConfigError):
            other.open(sealed, "account:a-1:refresh_token")


class InitTest(unittest.TestCase):
    def test_init_keeps_the_tokens_and_adds_what_an_older_configuration_lacks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({"data_root": directory, "token": "old-fleet"}))
            cli = ServerCli(path)
            cli.run_init(data_root=Path(directory), host="127.0.0.1", port=8787, tls_cert=None, tls_key=None)
            config = ServerConfig.from_file(path)
            self.assertEqual(config.token, "old-fleet")
            self.assertTrue(config.owner_token)
            self.assertEqual(len(config.secrets_key_bytes()), 32)
            cli.run_init(data_root=Path(directory), host="127.0.0.1", port=8787, tls_cert=None, tls_key=None)
            again = ServerConfig.from_file(path)
            self.assertEqual((again.owner_token, again.secrets_key), (config.owner_token, config.secrets_key))


if __name__ == "__main__":
    unittest.main()


class FakeProvider:
    """A provider's token and profile endpoints, answering from what the test set."""

    def __init__(self) -> None:
        self.list_requests: list[tuple[str, str, dict[str, str] | None]] = []
        self.map_answers: dict[str, list[tuple[int, dict[str, object]]]] = {}

    def answer(self, url_part: str, status: int, map_body: dict[str, object]) -> None:
        self.map_answers.setdefault(url_part, []).append((status, map_body))

    def request(self, method, url, map_form=None, bearer=None):
        self.list_requests.append((method, url, map_form))
        for url_part, list_queue in self.map_answers.items():
            if url_part in url and list_queue:
                return list_queue.pop(0) if len(list_queue) > 1 else list_queue[0]
        return 404, {}


class AccountLoginTest(unittest.TestCase):
    """Signing in to an account with a code Rookery got, and keeping its access fresh."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        database = Database(Path(self._tmp.name))
        self.addCleanup(database.close)
        self.accounts = AccountStore(database, SecretVault(bytes(range(32))))
        self.accounts.put_provider("google", "cid", "csecret")
        self.accounts.put_provider("microsoft", "mid", "")
        self.provider = FakeProvider()
        self.now = 1000.0
        self.login = AccountLogin(self.accounts, self.provider, clock=lambda: self.now)

    def sign_in_google(self, map_profile: dict[str, object] | None = None) -> Account:
        self.provider.answer("oauth2.googleapis.com/token", 200, {"access_token": "at-1", "refresh_token": "rt-1", "expires_in": 3600})
        self.provider.answer("userinfo", 200, map_profile or {"email": "me@gmail.com", "name": "Me"})
        return self.login.connect("google", "code", "verifier", "http://127.0.0.1:5000/callback")

    def test_the_sign_in_page_asks_for_no_mail_sending(self) -> None:
        url = self.login.authorize_url("google", "http://127.0.0.1:5000/callback", "challenge", "state")
        self.assertIn("client_id=cid", url)
        self.assertIn("access_type=offline", url)
        self.assertIn("gmail.compose", url)
        self.assertNotIn("gmail.send", url)
        with self.assertRaises(ValidationError):
            self.login.authorize_url("google", "https://evil.example/callback", "challenge", "state")

    def test_a_code_becomes_an_account_whose_token_stays_on_roost(self) -> None:
        account = self.sign_in_google()
        self.assertEqual((account.email, account.kind, account.status), ("me@gmail.com", "personal", "connected"))
        self.assertEqual(self.accounts.refresh_token(account.id), "rt-1")
        _, url, map_form = self.provider.list_requests[0]
        self.assertEqual((map_form["code_verifier"], map_form["client_secret"]), ("verifier", "csecret"))
        self.assertEqual(self.login.access_token(account.id), "at-1")

    def test_a_workspace_account_is_a_work_one(self) -> None:
        self.assertEqual(self.sign_in_google({"email": "me@corp.com", "hd": "corp.com"}).kind, "work")

    def test_a_microsoft_personal_account_is_told_by_its_tenant(self) -> None:
        claims = base64_claims({"tid": "9188040d-6c67-4c5b-b112-36a304b66dad"})
        self.provider.answer("oauth2/v2.0/token", 200, {"access_token": "at", "refresh_token": "rt", "id_token": claims})
        self.provider.answer("graph.microsoft.com/v1.0/me", 200, {"mail": None, "userPrincipalName": "me@outlook.com", "displayName": "Me"})
        account = self.login.connect("microsoft", "code", "verifier", "http://localhost:5000")
        self.assertEqual((account.email, account.kind), ("me@outlook.com", "personal"))
        self.assertNotIn("client_secret", self.provider.list_requests[0][2])

    def test_access_is_renewed_before_it_expires_and_a_rotated_token_kept(self) -> None:
        account = self.sign_in_google()
        self.now += 3600 - 60
        self.provider.map_answers["oauth2.googleapis.com/token"] = [(200, {"access_token": "at-2", "refresh_token": "rt-2", "expires_in": 3600})]
        self.assertEqual(self.login.access_token(account.id), "at-2")
        self.assertEqual(self.accounts.refresh_token(account.id), "rt-2")

    def test_a_revoked_grant_asks_the_owner_to_sign_in_again(self) -> None:
        account = self.sign_in_google()
        self.now += 7200
        self.provider.map_answers["oauth2.googleapis.com/token"] = [(400, {"error": "invalid_grant", "error_description": "Token has been expired or revoked."})]
        with self.assertRaises(LoginRequiredError):
            self.login.access_token(account.id)
        self.assertEqual(self.accounts.get(account.id).status, "needs_login")

    def test_disconnecting_revokes_and_forgets(self) -> None:
        account = self.sign_in_google()
        self.provider.answer("oauth2.googleapis.com/revoke", 200, {})
        self.login.disconnect(account.id)
        self.assertEqual(self.accounts.list(), [])
        self.assertIn(("POST", "https://oauth2.googleapis.com/revoke", {"token": "rt-1"}), self.provider.list_requests)


def base64_claims(map_claims: dict[str, object]) -> str:
    body = base64.urlsafe_b64encode(json.dumps(map_claims).encode()).decode().rstrip("=")
    return f"header.{body}.signature"
