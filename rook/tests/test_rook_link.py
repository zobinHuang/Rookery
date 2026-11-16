import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock
from rook.tests.test_rook_client import SESSION, QueueAndSendTest, RookHomeTest, rook_client
from rookd.resources import ResourceRef

REPO_ROOT = Path(__file__).resolve().parents[2]
LOADER = importlib.machinery.SourceFileLoader("rook_link", str(REPO_ROOT / "rook" / "bin" / "rook-link"))
SPEC = importlib.util.spec_from_loader("rook_link", LOADER)
rook_link = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(rook_link)

TMUX_SOCKET = "/tmp/rook-test.sock"


class RecordingTyper:
    """Stands in for tmux, keeping what would have been typed."""

    def __init__(self) -> None:
        self.list_typed: list[str] = []

    def type(self, agent_pane: object, buffer_name: str, text: str) -> None:
        self.list_typed.append(text)


class AgentInPaneTest(RookHomeTest):
    """A session started in a tmux pane, as its SessionStart hook records it."""

    def start_session(self, session_id: str = SESSION, pane: str = "%1") -> None:
        with mock.patch.dict(os.environ, {"TMUX": f"{TMUX_SOCKET},1,0", "TMUX_PANE": pane}):
            rook_client.AgentPane.record(session_id, "claude")
        rook_client.AgentStateMemo.is_new(session_id, "idle")

    def delivery(self, delivery_id: str, text: str, sender: dict[str, str] | None = None) -> dict[str, object]:
        return {
            "id": delivery_id,
            "agent_id": SESSION,
            "text": text,
            "sender": sender or {"kind": "person", "id": "user"},
            "created_at": f"2026-11-16T00:00:0{len(delivery_id) % 10}.000+00:00",
        }

    def outcome(self, delivery_id: str) -> dict[str, object]:
        return {report["id"]: report for report in self.desk.unreported()}[delivery_id]

    def setUp(self) -> None:
        super().setUp()
        self.typer = RecordingTyper()
        self.desk = rook_link.DeliveryDesk(self.typer)


class DeliveryDeskTest(AgentInPaneTest):
    def test_a_ready_agent_has_the_prompt_typed_in(self) -> None:
        self.start_session()
        self.desk.accept(self.delivery("d-1", "run the tests"))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_typed, ["run the tests"])
        self.assertEqual(self.outcome("d-1")["status"], "delivered")

    def test_a_busy_agent_gets_it_at_its_stop_hook(self) -> None:
        self.start_session()
        rook_client.AgentStateMemo.is_new(SESSION, "working")
        self.desk.accept(self.delivery("d-1", "also update the docs"))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_typed, [])
        self.assertEqual(self.outcome("d-1")["status"], "waiting")
        stdout = io.StringIO()
        payload = json.dumps({"session_id": SESSION, "hook_event_name": "Stop"})
        with mock.patch.object(sys, "stdin", io.StringIO(payload)), mock.patch.object(sys, "stdout", stdout):
            rook_client.RookClient.hook("claude")
        self.assertEqual(json.loads(stdout.getvalue()), {"decision": "block", "reason": "also update the docs"})
        self.assertEqual(rook_client.AgentStateMemo.current(SESSION), "thinking")
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.outcome("d-1")["status"], "delivered")
        self.assertEqual(self.typer.list_typed, [])

    def test_a_held_message_is_typed_once_the_agent_stops_without_taking_it(self) -> None:
        self.start_session()
        rook_client.AgentStateMemo.is_new(SESSION, "working")
        self.desk.accept(self.delivery("d-1", "hello"))
        self.desk.process(accepts_prompts=True)
        rook_client.AgentStateMemo.is_new(SESSION, "done")
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_typed, ["hello"])
        self.assertEqual(rook_client.Mailbox.take(SESSION), [])

    def test_two_prompts_wait_for_the_agent_to_take_the_first(self) -> None:
        self.start_session()
        self.desk.accept(self.delivery("d-1", "first"))
        self.desk.accept(self.delivery("d-22", "second"))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_typed, ["first"])
        time.sleep(0.01)
        rook_client.AgentStateMemo.is_new(SESSION, "thinking")
        self.desk.process(accepts_prompts=True)
        rook_client.AgentStateMemo.is_new(SESSION, "done")
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_typed, ["first", "second"])

    def test_a_message_from_an_agent_says_who_sent_it(self) -> None:
        self.start_session()
        self.desk.accept(self.delivery("d-1", "the api is up", {"kind": "agent", "id": "s-9"}))
        self.desk.process(accepts_prompts=True)
        self.assertIn("Message from agent s-9", self.typer.list_typed[0])
        self.assertIn('rook message s-9 "..."', self.typer.list_typed[0])

    def test_nothing_is_typed_when_prompts_are_off(self) -> None:
        self.start_session()
        self.desk.accept(self.delivery("d-1", "rm -rf"))
        self.desk.process(accepts_prompts=False)
        self.assertEqual(self.typer.list_typed, [])
        self.assertEqual(self.outcome("d-1")["status"], "failed")

    def test_a_pane_that_runs_another_session_is_left_alone(self) -> None:
        self.start_session()
        self.start_session(session_id="another-session")
        self.desk.accept(self.delivery("d-1", "hello"))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_typed, [])
        self.assertIn("another session", self.outcome("d-1")["reason"])

    def test_an_ended_session_cannot_be_reached(self) -> None:
        self.start_session()
        rook_client.AgentStateMemo.forget(SESSION)
        self.desk.accept(self.delivery("d-1", "hello"))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.outcome("d-1")["status"], "failed")


@unittest.skipUnless(shutil.which("tmux"), "needs tmux")
class PaneTyperTest(unittest.TestCase):
    """Typing into a pane of a tmux server of the test's own, never the user's."""

    def setUp(self) -> None:
        self._tmp = tempfile.mkdtemp(prefix="rk", dir="/tmp")
        self.addCleanup(shutil.rmtree, self._tmp, True)
        self.socket = os.path.join(self._tmp, "t.sock")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TMUX")}
        self.tmux = ["tmux", "-S", self.socket, "-f", "/dev/null"]
        subprocess.run([*self.tmux, "new-session", "-d", "-x", "120", "-y", "20", "cat"], check=True, env=environment)
        self.addCleanup(subprocess.run, [*self.tmux, "kill-server"], capture_output=True)
        self.pane = subprocess.run(
            [*self.tmux, "display-message", "-p", "#{pane_id}"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

    def test_text_is_pasted_and_submitted(self) -> None:
        agent_pane = rook_client.AgentPane(session_id=SESSION, harness="claude", tmux_socket=self.socket, pane=self.pane)
        rook_link.PaneTyper().type(agent_pane, "rook-d-1", "hello from rookery")
        time.sleep(0.3)
        screen = subprocess.run(
            [*self.tmux, "capture-pane", "-p", "-t", self.pane],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        self.assertGreaterEqual(screen.count("hello from rookery"), 2)

    def test_a_gone_pane_fails(self) -> None:
        agent_pane = rook_client.AgentPane(session_id=SESSION, harness="claude", tmux_socket=self.socket, pane="%99")
        with self.assertRaises(rook_link.RookLinkError):
            rook_link.PaneTyper().type(agent_pane, "rook-d-1", "hello")


class RookLinkTest(QueueAndSendTest):
    """rook-link against a rookd of the test's own."""

    def start_server(self):
        server = super().start_server()
        server.link.listen()
        thread = threading.Thread(target=server.link.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.link.shutdown)
        return server

    def wait_for(self, predicate, what: str) -> None:
        deadline = time.monotonic() + 5
        while not predicate():
            if time.monotonic() > deadline:
                self.fail(f"timed out waiting for {what}")
            time.sleep(0.05)

    def test_events_go_over_the_link_and_a_prompt_comes_back_typed(self) -> None:
        server = self.start_server()
        self.connect(server.bound_port())
        with mock.patch.dict(os.environ, {"TMUX": f"{TMUX_SOCKET},1,0", "TMUX_PANE": "%1"}):
            self.hook(self.payload("SessionStart", cwd=str(self.home)))
        typer = RecordingTyper()
        link = rook_link.RookLink(rook_link.DeliveryDesk(typer))
        thread = threading.Thread(target=link.run_once, args=(rook_client.Connection.load(),), daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(link.stop)
        agent_ref = ResourceRef("agent", SESSION)
        self.wait_for(lambda: server.resources.exists(agent_ref), "the agent to reach rookd")
        self.wait_for(lambda: server.link.online_rooks() == ["studio"], "the rook to come online")
        delivery = server.link.send_to_agent(ResourceRef("person", "user"), SESSION, "run the tests")
        self.wait_for(lambda: server.deliveries.get(delivery.id).status == "delivered", "the delivery")
        self.assertEqual(typer.list_typed, ["run the tests"])


if __name__ == "__main__":
    unittest.main()
