import http.client
import json
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock
from roost.config import ServerConfig
from roost.credentials import GitCredentialStore
from roost.database import Database
from roost.errors import NotFoundError, ValidationError
from roost.http import RoostServer
from roost.skills import GitRefResolver
from roost.store import SessionStore


class GitCredentialStoreTest(unittest.TestCase):
    """Tokens for git hosts: kept by host, shown only by their last characters, handed to git through its
    environment, and matched to a repository by its host over https alone."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        database = Database(Path(self._tmp.name))
        self.addCleanup(database.close)
        self.store = GitCredentialStore(database)

    def test_a_token_is_kept_by_its_host_and_replaced_in_place(self) -> None:
        self.store.put("https://GitHub.com/org/repo", "", "ghp_first1234")
        self.store.put("github.com", "", "ghp_second5678")
        [credential] = self.store.list_all()
        self.assertEqual((credential.host, credential.username, credential.token), ("github.com", "x-access-token", "ghp_second5678"))
        self.assertEqual(credential.as_listing()["token_hint"], "…5678")
        self.assertNotIn("token", credential.as_listing())

    def test_a_host_other_than_github_takes_the_usual_user_name_and_a_port(self) -> None:
        credential = self.store.put("git.example.com:8443", "", "glpat-abc")
        self.assertEqual((credential.host, credential.username), ("git.example.com:8443", "oauth2"))
        self.assertEqual(self.store.for_repo("https://git.example.com:8443/team/skills.git").token, "glpat-abc")

    def test_only_a_repository_over_https_on_the_host_matches(self) -> None:
        self.store.put("github.com", "", "ghp_token")
        self.assertIsNotNone(self.store.for_repo("https://github.com/org/private"))
        self.assertIsNone(self.store.for_repo("git@github.com:org/private.git"))
        self.assertIsNone(self.store.for_repo("https://gitlab.com/org/private"))

    def test_unusable_hosts_and_tokens_are_refused_and_a_missing_one_is_not_found(self) -> None:
        with self.assertRaises(ValidationError):
            self.store.put("not a host", "", "token")
        with self.assertRaises(ValidationError):
            self.store.put("github.com", "", "two words")
        with self.assertRaises(NotFoundError):
            self.store.remove("github.com")

    def test_git_takes_the_token_from_its_environment_not_its_command_line(self) -> None:
        credential = self.store.put("github.com", "", "ghp_secret")
        list_command = ["git", *GitCredentialStore.git_options(), "credential", "fill"]
        self.assertFalse(any("ghp_secret" in argument for argument in list_command))
        completed = subprocess.run(
            list_command,
            input="protocol=https\nhost=github.com\n\n",
            capture_output=True,
            text=True,
            env={"PATH": os.environ["PATH"], "HOME": self._tmp.name, "GIT_TERMINAL_PROMPT": "0", **GitCredentialStore.git_environment(credential)},
            check=True,
        )
        self.assertIn("username=x-access-token", completed.stdout)
        self.assertIn("password=ghp_secret", completed.stdout)

    def test_the_resolver_hands_git_the_token_for_a_private_repository(self) -> None:
        self.store.put("github.com", "", "ghp_secret")
        resolver = GitRefResolver(credentials=self.store)
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="ref: refs/heads/main\tHEAD\n", stderr="")
        with mock.patch("roost.skills.subprocess.run", return_value=completed) as run:
            self.assertEqual(resolver.default_branch("https://github.com/org/private"), "main")
        list_arguments = run.call_args.args[0]
        self.assertIn("credential.helper=", list_arguments)
        self.assertNotIn("ghp_secret", " ".join(list_arguments))
        self.assertEqual(run.call_args.kwargs["env"][GitCredentialStore.CREDENTIAL_PASSWORD_ENV], "ghp_secret")


class GitCredentialRoutesTest(unittest.TestCase):
    """The credential routes: a listing that never shows a token, and the whole token only for the host of
    a repository a rook is about to fetch from."""

    TEST_TOKEN = "test-token"

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        config = ServerConfig(
            data_root=root,
            host="127.0.0.1",
            port=0,
            token=self.TEST_TOKEN,
            max_body_bytes=1024 * 64,
            tls_cert=None,
            tls_key=None,
            link_port=0,
        )
        self.server = RoostServer(config=config, store=SessionStore(root))
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(self.server.resources.database.close)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, method: str, path: str, map_body: object = None) -> tuple[int, dict[str, object]]:
        connection = http.client.HTTPConnection("127.0.0.1", self.server.bound_port(), timeout=5)
        try:
            body = None if map_body is None else json.dumps(map_body).encode("utf-8")
            map_headers = {"Authorization": f"Bearer {self.TEST_TOKEN}"}
            if body is not None:
                map_headers["Content-Length"] = str(len(body))
            connection.request(method, path, body=body, headers=map_headers)
            response = connection.getresponse()
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
        finally:
            connection.close()

    def test_a_token_is_registered_listed_without_itself_matched_and_removed(self) -> None:
        status, map_listing = self.request("PUT", "/v1/credentials/github.com", {"token": "ghp_secret1234"})
        self.assertEqual((status, map_listing["token_hint"]), (200, "…1234"))
        status, map_body = self.request("GET", "/v1/credentials")
        self.assertEqual(status, 200)
        self.assertNotIn("ghp_secret1234", json.dumps(map_body))
        status, map_secret = self.request("GET", "/v1/credentials/match?repo=https%3A%2F%2Fgithub.com%2Forg%2Fprivate")
        self.assertEqual((status, map_secret["token"]), (200, "ghp_secret1234"))
        status, _ = self.request("GET", "/v1/credentials/match?repo=git%40github.com%3Aorg%2Fprivate.git")
        self.assertEqual(status, 404)
        status, _ = self.request("DELETE", "/v1/credentials/github.com")
        self.assertEqual(status, 200)
        status, map_body = self.request("GET", "/v1/credentials")
        self.assertEqual(map_body["credentials"], [])
