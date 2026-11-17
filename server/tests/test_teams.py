import http.client
import json
import tempfile
import threading
import unittest
from pathlib import Path
from roost.config import ServerConfig
from roost.errors import NotFoundError, ValidationError
from roost.http import RoostServer
from roost.messages import Delivery
from roost.resources import ResourceRef
from roost.store import SessionStore


class TeamTest(unittest.TestCase):
    """Teams: who is in them with what duty, how their agents message one another, and the backstop that
    holds a message for the user when agents go too far."""

    TEST_TOKEN = "test-token"
    TEST_TIMEOUT_SECONDS = 5
    PERSON = ResourceRef("person", "user")

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
        self.addCleanup(thread.join, self.TEST_TIMEOUT_SECONDS)
        self.addCleanup(self.server.resources.database.close)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        for agent_id, rook_name in (("a", "studio"), ("b", "studio"), ("c", "laptop"), ("raven", "rookery")):
            self.start(agent_id, rook_name)
        self.server.catalog.create("team", {"id": "api", "name": "API", "attributes": {"goal": "ship v2"}})
        self.server.roster.join("api", "a", "server", None)
        self.server.roster.join("api", "b", "tests", None)

    def start(self, agent_id: str, rook_name: str, map_detail: dict[str, object] | None = None) -> None:
        self.server.events.record([{
            "actor": {"kind": "agent", "id": agent_id},
            "verb": "started",
            "detail": {"name": agent_id, "rook_name": rook_name, **(map_detail or {})},
        }])

    def request(self, method: str, path: str, map_body: object = None) -> tuple[int, dict[str, object]]:
        connection = http.client.HTTPConnection("127.0.0.1", self.server.bound_port(), timeout=self.TEST_TIMEOUT_SECONDS)
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

    def send(self, sender: str, to: str, text: str = "hi", **map_options: object) -> Delivery:
        return self.server.link.send_to_agent(ResourceRef("agent", sender), to, text, map_options=map_options)

    def test_an_agent_may_be_in_several_teams_each_with_its_duty(self) -> None:
        self.server.catalog.create("team", {"id": "web", "name": "Web"})
        self.server.roster.join("web", "a", "review", None)
        status, map_body = self.request("GET", "/v1/teams?agent=a")
        self.assertEqual(status, 200)
        map_duties = {
            team["id"]: [member["duty"] for member in team["members"] if member["id"] == "a"]
            for team in map_body["teams"]
        }
        self.assertEqual(map_duties, {"api": ["server"], "web": ["review"]})

    def test_a_card_carries_who_the_agent_is_and_what_it_does_now(self) -> None:
        self.request("PATCH", "/v1/resources/agent/a", {"attributes": {"role": "API owner", "focus": "auth"}})
        status, map_team = self.request("GET", "/v1/teams/api")
        self.assertEqual(status, 200)
        map_card = next(member for member in map_team["members"] if member["id"] == "a")
        self.assertEqual((map_card["role"], map_card["focus"], map_card["duty"]), ("API owner", "auth", "server"))

    def test_members_join_and_leave_over_http(self) -> None:
        status, map_team = self.request("POST", "/v1/teams/api/members", {"agent": "c", "duty": "docs"})
        self.assertEqual(status, 200)
        self.assertIn("c", [member["id"] for member in map_team["members"]])
        status, map_team = self.request("DELETE", "/v1/teams/api/members/c")
        self.assertEqual(status, 200)
        self.assertNotIn("c", [member["id"] for member in map_team["members"]])
        status, _ = self.request("DELETE", "/v1/teams/api/members/c")
        self.assertEqual(status, 404)

    def test_rookerys_own_agents_join_a_team_the_user_puts_them_in(self) -> None:
        status, map_team = self.request("POST", "/v1/teams/api/members", {"agent": "raven", "duty": "directs the team"})
        self.assertEqual(status, 200)
        map_card = next(member for member in map_team["members"] if member["id"] == "raven")
        self.assertEqual((map_card["rook_name"], map_card["duty"]), ("rookery", "directs the team"))

    def test_an_agent_messages_only_its_teammates(self) -> None:
        self.assertEqual(self.send("a", "b").status, Delivery.STATUS_PENDING)
        with self.assertRaises(ValidationError):
            self.send("a", "c")

    def test_a_person_messages_anyone(self) -> None:
        self.assertEqual(self.server.link.send_to_agent(self.PERSON, "c", "hi").status, Delivery.STATUS_PENDING)

    def test_rookerys_own_agents_message_only_the_teams_they_are_in(self) -> None:
        with self.assertRaises(ValidationError):
            self.send("raven", "a")
        with self.assertRaises(ValidationError):
            self.server.link.send_to_team(ResourceRef("agent", "raven"), "api", "status?")
        self.server.roster.join("api", "raven", "directs the team", None)
        self.assertEqual(self.send("raven", "a").status, Delivery.STATUS_PENDING)
        with self.assertRaises(ValidationError):
            self.send("raven", "c")

    def test_rookery_reads_and_reports_the_messages_for_its_own_agents(self) -> None:
        self.server.roster.join("api", "raven", "directs the team", None)
        question = self.send("raven", "a", "is v2 tagged?")
        answer = self.send("a", "raven", "yes", thread=question.map_options["thread"])
        status, map_body = self.request("GET", "/v1/messages?rook=rookery")
        self.assertEqual(status, 200)
        self.assertEqual([message["id"] for message in map_body["messages"]], [answer.id])
        status, map_delivery = self.request("POST", f"/v1/messages/{answer.id}/report", {"status": "delivered"})
        self.assertEqual((status, map_delivery["status"]), (200, Delivery.STATUS_DELIVERED))
        status, map_body = self.request("GET", "/v1/messages?rook=rookery")
        self.assertEqual(map_body["messages"], [])
        status, _ = self.request("POST", f"/v1/messages/{question.id}/report", {"status": "delivered"})
        self.assertEqual(status, 404)

    def test_an_answer_carries_on_its_thread(self) -> None:
        first = self.send("a", "b", "does the schema hold?")
        answer = self.send("b", "a", "it does", thread=first.map_options["thread"], no_reply=True)
        self.assertEqual(answer.map_options["thread"], first.map_options["thread"])
        self.assertEqual((first.map_options["hop"], answer.map_options["hop"]), (1, 2))
        self.assertTrue(answer.map_options["no_reply"])

    def test_a_team_message_reaches_every_other_member_once(self) -> None:
        self.server.roster.join("api", "c", "docs", None)
        status, map_body = self.request(
            "POST",
            "/v1/messages",
            {"team": "api", "text": "v2 is tagged", "actor": {"kind": "agent", "id": "a"}},
        )
        self.assertEqual(status, 201)
        list_messages = map_body["messages"]
        self.assertEqual(sorted(message["agent_id"] for message in list_messages), ["b", "c"])
        self.assertEqual(len({message["options"]["thread"] for message in list_messages}), 1)
        self.assertEqual({message["options"]["team"] for message in list_messages}, {"api"})

    def test_an_agent_messages_no_team_it_is_not_in(self) -> None:
        with self.assertRaises(ValidationError):
            self.server.link.send_to_team(ResourceRef("agent", "c"), "api", "hi")

    def test_a_thread_past_its_limit_is_held_until_released(self) -> None:
        self.server.catalog.update("team", "api", {"attributes": {"limits": {"thread_hops": 2}}})
        first = self.send("a", "b")
        thread = first.map_options["thread"]
        self.send("b", "a", thread=thread)
        held = self.send("a", "b", thread=thread)
        self.assertEqual(held.status, Delivery.STATUS_HELD)
        self.assertIn("thread", held.map_detail["reason"])
        status, map_released = self.request("POST", f"/v1/messages/{held.id}/release")
        self.assertEqual((status, map_released["status"]), (200, Delivery.STATUS_PENDING))
        self.assertEqual(self.send("b", "a", thread=thread).status, Delivery.STATUS_PENDING)

    def test_an_agent_that_sends_too_much_is_held_and_may_be_cancelled(self) -> None:
        self.server.catalog.update("team", "api", {"attributes": {"limits": {"sends_per_window": 2}}})
        self.send("a", "b")
        self.send("a", "b")
        held = self.send("a", "b")
        self.assertEqual(held.status, Delivery.STATUS_HELD)
        status, map_cancelled = self.request("POST", f"/v1/messages/{held.id}/cancel")
        self.assertEqual((status, map_cancelled["status"]), (200, Delivery.STATUS_CANCELLED))
        status, _ = self.request("POST", f"/v1/messages/{held.id}/release")
        self.assertEqual(status, 400)

    def test_a_launched_agent_takes_its_role_and_teams_as_it_starts(self) -> None:
        self.server.events.record([{"actor": {"kind": "rook", "id": "laptop"}, "verb": "connected"}])
        spawn = self.server.link.spawn_on_rook(
            self.PERSON,
            "laptop",
            "",
            {"cwd": "/src/api", "role": "load tester", "teams": [{"team": "api", "duty": "benchmarks"}]},
        )
        self.start("d", "laptop", {"launch": spawn.map_options["launch"]})
        agent = self.server.resources.get(ResourceRef("agent", "d"))
        self.assertEqual(agent.map_attributes["role"], "load tester")
        self.assertEqual(agent.map_attributes["role_source"], "launch")
        self.assertEqual(agent.map_attributes["launch"], spawn.map_options["launch"])
        list_teams = self.server.roster.teams_of("d")
        self.assertEqual([team.id for team in list_teams], ["api"])
        self.assertEqual(self.server.roster.members_of(list_teams[0])["d"]["duty"], "benchmarks")

    def test_a_launch_resolves_what_it_installs(self) -> None:
        self.server.events.record([{"actor": {"kind": "rook", "id": "laptop"}, "verb": "connected"}])
        spawn = self.server.link.spawn_on_rook(self.PERSON, "laptop", "", {"cwd": "/src", "launch": "l-one"})
        self.assertEqual(spawn.map_options["launch"], "l-one")
        status, map_resolved = self.request("GET", "/v1/launches/l-one/resolve")
        self.assertEqual((status, map_resolved["id"], map_resolved["skills"]), (200, "", []))
        status, _ = self.request("GET", "/v1/launches/l-none/resolve")
        self.assertEqual(status, 404)

    def test_a_message_names_its_sender_and_lists_by_sender(self) -> None:
        self.request("PATCH", "/v1/resources/agent/a", {"attributes": {"title": "API server"}})
        delivery = self.send("a", "b")
        self.assertEqual(delivery.map_options["sender_title"], "API server")
        self.send("b", "a")
        status, map_body = self.request("GET", "/v1/messages?sender=a")
        self.assertEqual((status, [message["id"] for message in map_body["messages"]]), (200, [delivery.id]))

    def test_a_launch_names_only_teams_and_skills_that_exist(self) -> None:
        self.server.events.record([{"actor": {"kind": "rook", "id": "laptop"}, "verb": "connected"}])
        with self.assertRaises(NotFoundError):
            self.server.link.spawn_on_rook(self.PERSON, "laptop", "", {"cwd": "/src", "teams": [{"team": "nope"}]})
        with self.assertRaises(NotFoundError):
            self.server.link.spawn_on_rook(self.PERSON, "laptop", "", {"cwd": "/src", "skills": ["nope"]})


if __name__ == "__main__":
    unittest.main()
