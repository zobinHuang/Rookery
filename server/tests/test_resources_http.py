import http.client
import json
import tempfile
import threading
import unittest
from pathlib import Path
from roost.config import ServerConfig
from roost.database import Database
from roost.http import RoostServer
from roost.playbooks import PlaybookIndex
from roost.resources import ResourceStore
from roost.skills import SkillIndex
from roost.store import SessionStore
from tests.test_skills import FakeResolver


class ResourceApiTest(unittest.TestCase):
    """The resource API a desktop reads and the event API rook writes, over HTTP."""

    TEST_TOKEN = "test-token"
    TEST_TIMEOUT_SECONDS = 5
    TEST_AGENT = {"kind": "agent", "id": "s-1"}

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        resources = ResourceStore(Database(root))
        self.addCleanup(resources.database.close)
        skills = SkillIndex(resources, FakeResolver())
        config = ServerConfig(
            data_root=root,
            host="127.0.0.1",
            port=0,
            token=self.TEST_TOKEN,
            max_body_bytes=1024 * 64,
            tls_cert=None,
            tls_key=None,
        )
        self.server = RoostServer(
            config=config,
            store=SessionStore(root),
            resources=resources,
            skills=skills,
            playbooks=PlaybookIndex(resources, skills),
        )
        self.port = self.server.bound_port()
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, self.TEST_TIMEOUT_SECONDS)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)

    def request(
        self,
        method: str,
        path: str,
        map_body: object = None,
        token: str | None = TEST_TOKEN,
    ) -> tuple[int, dict[str, object]]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=self.TEST_TIMEOUT_SECONDS)
        try:
            body = None if map_body is None else json.dumps(map_body).encode("utf-8")
            map_headers: dict[str, str] = {}
            if token is not None:
                map_headers["Authorization"] = f"Bearer {token}"
            if body is not None:
                map_headers["Content-Length"] = str(len(body))
            connection.request(method, path, body=body, headers=map_headers)
            response = connection.getresponse()
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
        finally:
            connection.close()

    def report(self, *list_events: dict[str, object]) -> list[dict[str, object]]:
        status, map_body = self.request("POST", "/v1/events", {"events": list(list_events)})
        self.assertEqual(status, 200, map_body)
        return map_body["events"]

    def upload(self, session_id: str, list_lines: list[dict[str, object]]) -> None:
        status, map_body = self.request("POST", f"/v1/sessions/{session_id}/begin", {"agent": "claude", "session_id": session_id})
        self.assertEqual(status, 200, map_body)
        body = "".join(json.dumps(line) + "\n" for line in list_lines).encode("utf-8")
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=self.TEST_TIMEOUT_SECONDS)
        try:
            connection.request(
                "PUT",
                f"/v1/sessions/{session_id}/data?offset={map_body['cursor']}",
                body=body,
                headers={"Authorization": f"Bearer {self.TEST_TOKEN}", "Content-Length": str(len(body))},
            )
            self.assertEqual(connection.getresponse().status, 200)
        finally:
            connection.close()

    def test_an_uploaded_transcript_names_its_agent(self) -> None:
        self.report({"actor": self.TEST_AGENT, "verb": "started", "detail": {"name": "studio/bash"}})
        self.upload("s-1", [
            {"type": "ai-title", "aiTitle": "Repo overview"},
            {"type": "user", "message": {"content": "hi"}},
            {"type": "custom-title", "customTitle": "G-Watch development"},
        ])
        _, agent = self.request("GET", "/v1/resources/agent/s-1")
        self.assertEqual(agent["attributes"]["title"], "G-Watch development")
        _, map_events = self.request("GET", "/v1/events?limit=1")
        self.assertEqual(map_events["events"][0]["verb"], "renamed")

    def test_an_agent_that_starts_after_its_transcript_takes_its_title(self) -> None:
        self.upload("s-1", [{"type": "ai-title", "aiTitle": "Repo overview"}])
        self.report({"actor": self.TEST_AGENT, "verb": "started", "detail": {"name": "studio/bash"}})
        _, agent = self.request("GET", "/v1/resources/agent/s-1")
        self.assertEqual(agent["attributes"]["title"], "Repo overview")

    def test_the_kinds_are_listed(self) -> None:
        status, map_body = self.request("GET", "/v1/kinds")
        self.assertEqual(status, 200)
        self.assertEqual([kind["name"] for kind in map_body["kinds"]], ["agent", "skill", "playbook", "memory", "rook"])

    def test_an_agent_reported_by_events_is_listed_with_its_relations(self) -> None:
        self.report(
            {"actor": self.TEST_AGENT, "verb": "started", "detail": {"name": "studio/api"}},
            {"actor": self.TEST_AGENT, "verb": "uses", "object": {"kind": "skill", "name": "review"}},
        )
        _, map_agents = self.request("GET", "/v1/resources?kind=agent")
        self.assertEqual([agent["name"] for agent in map_agents["resources"]], ["studio/api"])
        _, map_relations = self.request("GET", "/v1/relations?kind=agent&id=s-1")
        self.assertEqual([edge["verb"] for edge in map_relations["relations"]], ["uses"])

    def test_events_are_read_back_after_a_sequence_number(self) -> None:
        list_logged = self.report(
            {"actor": self.TEST_AGENT, "verb": "started"},
            {"actor": self.TEST_AGENT, "verb": "state", "detail": {"state": "working"}},
        )
        _, map_body = self.request("GET", f"/v1/events?after={list_logged[0]['seq']}")
        self.assertEqual([event["verb"] for event in map_body["events"]], ["state"])

    def test_a_memory_is_created_and_changed_by_whoever_the_request_names(self) -> None:
        status, created = self.request(
            "POST",
            "/v1/resources/memory",
            {"name": "pagination quirks", "attributes": {"text": "cursor"}, "actor": self.TEST_AGENT},
        )
        self.assertEqual(status, 201, created)
        status, updated = self.request(
            "PATCH",
            f"/v1/resources/memory/{created['id']}",
            {"attributes": {"text": "cursor, not offset"}},
        )
        self.assertEqual(status, 200, updated)
        self.assertEqual(updated["attributes"]["text"], "cursor, not offset")
        _, map_events = self.request("GET", "/v1/events")
        list_actors = [(event["actor"]["kind"], event["verb"]) for event in map_events["events"]]
        self.assertEqual(list_actors, [("agent", "created"), ("person", "updated")])

    def test_a_skill_goes_through_its_own_index(self) -> None:
        status, skill = self.request("POST", "/v1/resources/skill", {"source": "owner/repo@review"})
        self.assertEqual(status, 201, skill)
        self.assertEqual(skill["id"], "github-com-owner-repo-review")
        self.assertEqual(skill["attributes"]["versions"][0]["commit"], "a" * 40)

    def test_deleting_an_unknown_resource_is_not_found(self) -> None:
        status, _ = self.request("DELETE", "/v1/resources/memory/nothing-here")
        self.assertEqual(status, 404)

    def test_a_deleted_agent_stays_deleted(self) -> None:
        subagent = {"kind": "agent", "id": "s-1~helper"}
        self.report({"actor": subagent, "verb": "started", "detail": {"parent": "s-1"}})
        status, _ = self.request("DELETE", "/v1/resources/agent/s-1~helper")
        self.assertEqual(status, 200)
        status, _ = self.request("GET", "/v1/resources/agent/s-1~helper")
        self.assertEqual(status, 404)

    def test_every_route_needs_the_token(self) -> None:
        for path in ("/v1/kinds", "/v1/resources", "/v1/events", "/v1/relations"):
            with self.subTest(path=path):
                status, _ = self.request("GET", path, token=None)
                self.assertEqual(status, 401)

    def test_the_stream_sends_what_was_missed_and_then_what_happens(self) -> None:
        self.report({"actor": self.TEST_AGENT, "verb": "started"})
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=self.TEST_TIMEOUT_SECONDS)
        self.addCleanup(connection.close)
        connection.request(
            "GET",
            "/v1/events/stream?after=0",
            headers={"Authorization": f"Bearer {self.TEST_TOKEN}"},
        )
        response = connection.getresponse()
        self.assertEqual(response.getheader("Content-Type"), "text/event-stream")
        self.report({"actor": self.TEST_AGENT, "verb": "state", "detail": {"state": "working"}})
        list_verbs: list[str] = []
        while len(list_verbs) < 2:
            line = response.fp.readline().decode("utf-8").strip()
            if line.startswith("data: "):
                list_verbs.append(json.loads(line[len("data: "):])["verb"])
        self.assertEqual(list_verbs, ["started", "state"])


if __name__ == "__main__":
    unittest.main()
