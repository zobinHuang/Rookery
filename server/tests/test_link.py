import http.client
import json
import tempfile
import threading
import unittest
from pathlib import Path
from websockets.exceptions import ConnectionClosed, InvalidStatus
from websockets.sync.client import ClientConnection, connect
from roost.config import ServerConfig
from roost.http import RoostServer
from roost.errors import ValidationError
from roost.resources import ResourceRef
from roost.store import SessionStore


class LinkTest(unittest.TestCase):
    """The live link: rooks and desktops holding a WebSocket to roost."""

    TEST_TOKEN = "test-token"
    TEST_TIMEOUT_SECONDS = 5
    TEST_AGENT = "s-1"

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
        self.server.link.listen()
        for target in (self.server.serve_forever, self.server.link.serve_forever):
            thread = threading.Thread(target=target, daemon=True)
            thread.start()
            self.addCleanup(thread.join, self.TEST_TIMEOUT_SECONDS)
        self.addCleanup(self.server.resources.database.close)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.server.events.record([{
            "actor": {"kind": "agent", "id": self.TEST_AGENT},
            "verb": "started",
            "detail": {"name": "studio/api", "rook_name": "studio"},
        }])

    def open_link(self, map_hello: dict[str, object], token: str = TEST_TOKEN) -> ClientConnection:
        connection = connect(
            f"ws://127.0.0.1:{self.server.link.bound_port()}/v1/link",
            additional_headers={"Authorization": f"Bearer {token}"},
            open_timeout=self.TEST_TIMEOUT_SECONDS,
        )
        self.addCleanup(connection.close)
        connection.send(json.dumps({"type": "hello", **map_hello}))
        self.assertEqual(self.receive(connection)["type"], "welcome")
        return connection

    def receive(self, connection: ClientConnection, kind: str | None = None) -> dict[str, object]:
        while True:
            map_message = json.loads(connection.recv(timeout=self.TEST_TIMEOUT_SECONDS))
            if kind is None or map_message["type"] == kind:
                return map_message

    def receive_event(self, connection: ClientConnection, verb: str) -> dict[str, object]:
        while True:
            map_event = self.receive(connection, "event")["event"]
            if map_event["verb"] == verb:
                return map_event

    def test_a_wrong_token_is_turned_away(self) -> None:
        with self.assertRaises(InvalidStatus):
            connect(
                f"ws://127.0.0.1:{self.server.link.bound_port()}/v1/link",
                additional_headers={"Authorization": "Bearer nope"},
                open_timeout=self.TEST_TIMEOUT_SECONDS,
            )

    def test_healthz_names_the_link_port(self) -> None:
        connection = http.client.HTTPConnection("127.0.0.1", self.server.bound_port(), timeout=5)
        connection.request("GET", "/v1/healthz")
        self.assertEqual(json.loads(connection.getresponse().read())["link_port"], self.server.link.bound_port())
        connection.close()

    def test_a_desktop_sees_events_after_the_one_it_names(self) -> None:
        desktop = self.open_link({"role": "desktop", "after": 0})
        self.assertEqual(self.receive_event(desktop, "started")["actor"]["id"], self.TEST_AGENT)
        self.server.events.record([{
            "actor": {"kind": "agent", "id": self.TEST_AGENT},
            "verb": "state",
            "detail": {"state": "working"},
        }])
        self.assertEqual(self.receive_event(desktop, "state")["detail"]["state"], "working")

    def test_a_rook_is_online_while_connected(self) -> None:
        desktop = self.open_link({"role": "desktop", "after": 0})
        rook = self.open_link({"role": "rook", "rook": "studio", "machine": {"os": "Darwin"}})
        self.receive_event(desktop, "connected")
        self.assertTrue(self.server.resources.get(ResourceRef("rook", "studio")).map_attributes["online"])
        rook.close()
        self.receive_event(desktop, "disconnected")
        self.assertFalse(self.server.resources.get(ResourceRef("rook", "studio")).map_attributes["online"])

    def test_a_prompt_from_a_desktop_reaches_the_rook_and_its_outcome_is_logged(self) -> None:
        rook = self.open_link({"role": "rook", "rook": "studio"})
        desktop = self.open_link({"role": "desktop", "after": 0})
        desktop.send(json.dumps({"type": "send", "ref": "c1", "to": self.TEST_AGENT, "text": "run the tests"}))
        sent = self.receive(desktop, "sent")
        self.assertEqual(sent["ref"], "c1")
        delivery = self.receive(rook, "deliver")["delivery"]
        self.assertEqual(delivery["text"], "run the tests")
        self.assertEqual(delivery["sender"], {"kind": "person", "id": "user"})
        rook.send(json.dumps({"type": "delivery", "id": delivery["id"], "status": "delivered", "reason": "typed"}))
        self.assertEqual(self.receive_event(desktop, "delivered")["detail"]["delivery"], delivery["id"])
        self.assertEqual(self.server.deliveries.get(delivery["id"]).status, "delivered")

    def test_a_delivery_waits_for_its_rook_to_connect(self) -> None:
        delivery = self.server.link.send_to_agent(ResourceRef("person", "user"), self.TEST_AGENT, "hello")
        rook = self.open_link({"role": "rook", "rook": "studio"})
        self.assertEqual(self.receive(rook, "deliver")["delivery"]["id"], delivery.id)

    def test_an_interrupt_and_an_approval_reach_the_agents_rook_with_their_kind(self) -> None:
        person = ResourceRef("person", "user")
        interrupt = self.server.link.send_to_agent(person, self.TEST_AGENT, "", kind="interrupt")
        approval = self.server.link.send_to_agent(person, self.TEST_AGENT, "", kind="approve", map_options={"choice": "once"})
        rook = self.open_link({"role": "rook", "rook": "studio"})
        list_delivered = [self.receive(rook, "deliver")["delivery"] for _ in range(2)]
        self.assertEqual([delivery["kind"] for delivery in list_delivered], ["interrupt", "approve"])
        self.assertEqual(list_delivered[1]["options"], {"choice": "once"})
        self.assertEqual({interrupt.id, approval.id}, {delivery["id"] for delivery in list_delivered})

    def test_an_approval_needs_a_choice_and_an_unknown_kind_is_refused(self) -> None:
        person = ResourceRef("person", "user")
        with self.assertRaises(ValidationError):
            self.server.link.send_to_agent(person, self.TEST_AGENT, "", kind="approve", map_options={"choice": "always"})
        with self.assertRaises(ValidationError):
            self.server.link.send_to_agent(person, self.TEST_AGENT, "", kind="reboot")

    def test_a_new_session_goes_to_its_rook_and_is_logged_against_it(self) -> None:
        self.server.events.record([{"actor": {"kind": "rook", "id": "studio"}, "verb": "connected"}])
        person = ResourceRef("person", "user")
        with self.assertRaises(ValidationError):
            self.server.link.spawn_on_rook(person, "studio", "go", {"cwd": "relative/path"})
        spawn = self.server.link.spawn_on_rook(person, "studio", "fix the flaky test", {"cwd": "/src/api"})
        rook = self.open_link({"role": "rook", "rook": "studio"})
        delivered = self.receive(rook, "deliver")["delivery"]
        self.assertEqual(delivered["id"], spawn.id)
        self.assertEqual(delivered["options"]["cwd"], "/src/api")
        self.assertEqual(delivered["options"]["harness"], "claude")
        self.assertTrue(delivered["options"]["launch"].startswith("l-"))
        rook.send(json.dumps({"type": "delivery", "id": spawn.id, "status": "delivered", "reason": "started"}))
        desktop = self.open_link({"role": "desktop", "after": 0})
        event = self.receive_event(desktop, "delivered")
        self.assertEqual(event["object"], {"kind": "rook", "id": "studio"})

    def test_an_agent_messages_another_through_its_rook(self) -> None:
        self.server.events.record([{
            "actor": {"kind": "agent", "id": "s-2"},
            "verb": "started",
            "detail": {"name": "studio/web", "rook_name": "studio"},
        }])
        self.server.catalog.create("team", {"id": "web", "name": "Web"})
        self.server.roster.join("web", self.TEST_AGENT, "the api", None)
        self.server.roster.join("web", "s-2", "the pages", None)
        rook = self.open_link({"role": "rook", "rook": "studio"})
        rook.send(json.dumps({
            "type": "send",
            "ref": "m1",
            "to": "s-2",
            "text": "the api is up",
            "as": {"kind": "agent", "id": self.TEST_AGENT},
        }))
        self.assertEqual(self.receive(rook, "deliver")["delivery"]["sender"]["id"], self.TEST_AGENT)
        list_relations = self.server.resources.relations(ResourceRef("agent", self.TEST_AGENT))
        self.assertIn("messaged", [relation.verb for relation in list_relations])

    def test_a_rook_cannot_send_as_another_rooks_agent(self) -> None:
        rook = self.open_link({"role": "rook", "rook": "laptop"})
        rook.send(json.dumps({
            "type": "send",
            "ref": "m1",
            "to": self.TEST_AGENT,
            "text": "hi",
            "as": {"kind": "agent", "id": self.TEST_AGENT},
        }))
        self.assertEqual(self.receive(rook, "error")["status"], 400)

    def test_a_rook_sends_its_events(self) -> None:
        rook = self.open_link({"role": "rook", "rook": "studio"})
        rook.send(json.dumps({
            "type": "events",
            "ref": "e1",
            "events": [{"actor": {"kind": "agent", "id": self.TEST_AGENT}, "verb": "state", "detail": {"state": "done"}}],
        }))
        self.assertEqual(self.receive(rook, "recorded")["count"], 1)
        agent = self.server.resources.get(ResourceRef("agent", self.TEST_AGENT))
        self.assertEqual(agent.map_attributes["state"], "done")

    def test_a_second_connection_takes_over_the_rook(self) -> None:
        first = self.open_link({"role": "rook", "rook": "studio"})
        self.open_link({"role": "rook", "rook": "studio"})
        with self.assertRaises(ConnectionClosed):
            first.recv(timeout=self.TEST_TIMEOUT_SECONDS)
        self.assertEqual(self.server.link.online_rooks(), ["studio"])


if __name__ == "__main__":
    unittest.main()
