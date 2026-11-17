import http.client
import json
import tempfile
import threading
import unittest
from pathlib import Path
from websockets.sync.client import ClientConnection, connect
from roost.__main__ import ServerCli
from roost.accounts import Account
from roost.config import ServerConfig
from roost.errors import ConfigError, ValidationError
from roost.http import RoostServer
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
