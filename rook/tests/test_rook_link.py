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
from roost.resources import ResourceRef

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
        self.list_pressed: list[str] = []
        self.list_opened: list[tuple[str, str]] = []
        self.is_pane_running = False

    def press(self, agent_pane: object, key: str) -> None:
        self.list_pressed.append(key)

    def open_window(self, tmux_socket: str | None, cwd: str, command: str) -> str:
        self.list_opened.append((cwd, command))
        return "%9"

    def type(self, agent_pane: object, buffer_name: str, text: str) -> None:
        self.list_typed.append(text)

    def runs_program(self, agent_pane: object) -> bool:
        return self.is_pane_running

    def current_path(self, agent_pane: object) -> str:
        return "/src/api"


class AgentInPaneTest(RookHomeTest):
    """A session started in a tmux pane, as its SessionStart hook records it."""

    def start_session(self, session_id: str = SESSION, pane: str = "%1") -> None:
        with mock.patch.dict(os.environ, {"TMUX": f"{TMUX_SOCKET},1,0", "TMUX_PANE": pane}):
            rook_client.AgentPane.record(session_id, "claude")
        rook_client.AgentStateMemo.is_new(session_id, "idle")

    def delivery(
        self,
        delivery_id: str,
        text: str,
        sender: dict[str, str] | None = None,
        kind: str = "prompt",
        options: dict[str, object] | None = None,
    ) -> dict[str, object]:
        return {
            "id": delivery_id,
            "agent_id": "" if kind == "spawn" else SESSION,
            "text": text,
            "sender": sender or {"kind": "person", "id": "user"},
            "created_at": f"2026-11-16T00:00:0{len(delivery_id) % 10}.000+00:00",
            "kind": kind,
            "options": options or {},
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

    def test_a_team_message_names_its_thread_and_how_to_answer_it(self) -> None:
        self.start_session()
        self.desk.accept(self.delivery(
            "d-1",
            "v2 is tagged",
            {"kind": "agent", "id": "s-9"},
            options={"thread": "t-1", "team": "api", "sender_title": "API server"},
        ))
        self.desk.accept(self.delivery("d-22", "done", {"kind": "agent", "id": "s-9"}, options={"thread": "t-1", "no_reply": True}))
        self.desk.process(accepts_prompts=True)
        typed = self.typer.list_typed[0]
        self.assertIn('Message from agent s-9 ("API server") to team api, through rook (thread t-1)', typed)
        self.assertIn('rook message s-9 --thread t-1 "..."', typed)
        self.assertIn('rook team send api --thread t-1 "..."', typed)
        self.assertIn("No answer wanted", rook_link.DeliveryDesk.framed(self.delivery(
            "d-22",
            "done",
            {"kind": "agent", "id": "s-9"},
            options={"thread": "t-1", "no_reply": True},
        )))

    def test_a_message_from_raven_says_it_speaks_for_the_user(self) -> None:
        typed = rook_link.DeliveryDesk.framed(self.delivery(
            "d-1",
            "is v2 tagged?",
            {"kind": "agent", "id": "raven-1"},
            options={"thread": "t-1", "sender_title": "Release check", "sender_rook": "rookery"},
        ))
        self.assertIn(
            "Message from Raven, the user's assistant in Rookery, speaking for the user (agent raven-1 (\"Release check\")), through rook",
            typed,
        )
        self.assertIn('rook message raven-1 --thread t-1 "..."', typed)

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

    def test_an_interrupt_presses_escape_only_while_the_agent_works(self) -> None:
        self.start_session()
        rook_client.AgentStateMemo.is_new(SESSION, "working")
        self.desk.accept(self.delivery("d-1", "", kind="interrupt"))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_pressed, ["Escape"])
        rook_client.AgentStateMemo.is_new(SESSION, "idle")
        self.desk.accept(self.delivery("d-22", "", kind="interrupt"))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_pressed, ["Escape"])
        self.assertIn("nothing to interrupt", self.outcome("d-22")["reason"])

    def fake_playbook_tool(self, exit_code: int) -> Path:
        """A rook-playbook that records its arguments and the tmux server it was pointed at."""
        tool = self.home / ".local" / "bin" / "rook-playbook"
        tool.parent.mkdir(parents=True, exist_ok=True)
        record = self.home / "playbook-call.txt"
        tool.write_text(
            f'#!/bin/sh\nprintf "%s\\n" "$TMUX" "$@" > "{record}"\necho "no such playbook" >&2\nexit {exit_code}\n',
            encoding="utf-8",
        )
        tool.chmod(0o755)
        patcher = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        patcher.start()
        self.addCleanup(patcher.stop)
        return record

    def process_until_finished(self, delivery_id: str) -> dict[str, object]:
        deadline = time.time() + 5
        while time.time() < deadline:
            self.desk.process(accepts_prompts=True)
            outcome = self.outcome(delivery_id)
            if outcome["status"] != "waiting":
                return outcome
            time.sleep(0.05)
        self.fail("the playbook never finished loading")

    def test_a_playbook_loads_into_the_agents_pane_then_types_what_it_carries(self) -> None:
        record = self.fake_playbook_tool(0)
        self.start_session()
        self.desk.accept(self.delivery("d-1", "", kind="playbook", options={"playbook": "review"}))
        self.desk.accept(self.delivery("d-22", "review the diff again", kind="playbook", options={"playbook": "review"}))
        self.desk.process(accepts_prompts=True)
        self.assertIn("loading playbook review", self.outcome("d-1")["reason"])
        self.assertEqual(self.process_until_finished("d-1")["status"], "delivered")
        self.assertEqual(
            record.read_text(encoding="utf-8").split("\n")[:11],
            [f"{TMUX_SOCKET},0,0", "install", "review", "--agent", "claude", "--project", "/src/api", "--pane", "%1", "--quiet", ""],
        )
        self.assertEqual(self.process_until_finished("d-22")["status"], "delivered")
        self.assertEqual(self.typer.list_typed, ["review the diff again"])

    def test_a_playbook_that_cannot_load_fails_with_its_reason_and_types_nothing(self) -> None:
        self.fake_playbook_tool(1)
        self.start_session()
        self.desk.accept(self.delivery("d-1", "go on", kind="playbook", options={"playbook": "nope"}))
        outcome = self.process_until_finished("d-1")
        self.assertEqual(outcome["status"], "failed")
        self.assertIn("no such playbook", outcome["reason"])
        self.assertEqual(self.typer.list_typed, [])

    def test_an_approval_answers_only_a_waiting_claude_code(self) -> None:
        self.start_session()
        rook_client.AgentStateMemo.is_new(SESSION, "working")
        self.desk.accept(self.delivery("d-1", "", kind="approve", options={"choice": "once"}))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.outcome("d-1")["status"], "failed")
        self.assertEqual(self.typer.list_pressed, [])
        rook_client.AgentStateMemo.is_new(SESSION, "needs_approval")
        self.desk.accept(self.delivery("d-22", "", kind="approve", options={"choice": "once"}))
        self.desk.accept(self.delivery("d-333", "", kind="approve", options={"choice": "deny"}))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_pressed, ["1", "Escape"])
        self.assertEqual(self.outcome("d-22")["status"], "delivered")

    def test_an_approval_is_not_guessed_for_another_harness(self) -> None:
        with mock.patch.dict(os.environ, {"TMUX": f"{TMUX_SOCKET},1,0", "TMUX_PANE": "%1"}):
            rook_client.AgentPane.record(SESSION, "codex")
        rook_client.AgentStateMemo.is_new(SESSION, "needs_approval")
        self.desk.accept(self.delivery("d-1", "", kind="approve", options={"choice": "once"}))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_pressed, [])
        self.assertIn("Claude Code only", self.outcome("d-1")["reason"])

    def test_a_new_session_opens_a_window_running_its_harness_with_the_prompt(self) -> None:
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, True)
        fresh = os.path.join(directory, "1119-glm", "work")
        self.desk.accept(self.delivery("d-1", "fix the flaky test", kind="spawn", options={"cwd": directory, "harness": "claude"}))
        self.desk.accept(self.delivery("d-22", "", kind="spawn", options={"cwd": "/no-such-root-dir/x", "harness": "claude"}))
        self.desk.accept(self.delivery("d-333", "", kind="spawn", options={"cwd": fresh, "harness": "claude"}))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_opened, [(directory, "claude 'fix the flaky test'"), (fresh, "claude")])
        self.assertEqual(self.outcome("d-1")["status"], "delivered")
        self.assertEqual(self.outcome("d-22")["status"], "failed")
        self.assertIn("cannot create", self.outcome("d-22")["reason"])
        self.assertTrue(os.path.isdir(fresh))
        self.assertIn("created for it", self.outcome("d-333")["reason"])

    def test_a_launch_names_itself_and_installs_its_playbook_first(self) -> None:
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, True)
        self.desk.accept(self.delivery(
            "d-1",
            "",
            kind="spawn",
            options={"cwd": directory, "harness": "claude", "launch": "l-1", "playbook": "review"},
        ))
        self.desk.process(accepts_prompts=True)
        [(opened_in, command)] = self.typer.list_opened
        self.assertEqual(opened_in, directory)
        install, _, start = command.partition("; ")
        self.assertIn("rook-playbook install review --launch l-1 --agent claude --project .", install)
        self.assertEqual(start, "ROOK_LAUNCH=l-1 claude")

    def test_an_ended_session_cannot_be_reached(self) -> None:
        self.start_session()
        rook_client.AgentStateMemo.forget(SESSION)
        self.desk.accept(self.delivery("d-1", "hello"))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.outcome("d-1")["status"], "failed")

    def test_a_session_whose_state_went_unrecorded_is_reached_while_its_pane_runs_it(self) -> None:
        self.start_session()
        rook_client.AgentStateMemo.forget(SESSION)
        self.typer.is_pane_running = True
        self.desk.accept(self.delivery("d-1", "hello"))
        self.desk.process(accepts_prompts=True)
        self.assertEqual(self.typer.list_typed, ["hello"])
        self.assertEqual(self.outcome("d-1")["status"], "delivered")


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

    def test_a_pane_tells_a_program_from_its_shell(self) -> None:
        agent_pane = rook_client.AgentPane(session_id=SESSION, harness="claude", tmux_socket=self.socket, pane=self.pane)
        self.assertTrue(rook_link.PaneTyper().runs_program(agent_pane))
        gone_pane = rook_client.AgentPane(session_id=SESSION, harness="claude", tmux_socket=self.socket, pane="%99")
        self.assertFalse(rook_link.PaneTyper().runs_program(gone_pane))

    def test_a_key_is_pressed_in_the_pane(self) -> None:
        agent_pane = rook_client.AgentPane(session_id=SESSION, harness="claude", tmux_socket=self.socket, pane=self.pane)
        rook_link.PaneTyper().press(agent_pane, "x")
        time.sleep(0.3)
        screen = subprocess.run(
            [*self.tmux, "capture-pane", "-p", "-t", self.pane],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        self.assertIn("x", screen)

    def test_a_window_is_opened_and_its_command_run(self) -> None:
        pane = rook_link.PaneTyper().open_window(self.socket, self._tmp, "echo rook-opened-$((40+2))")
        time.sleep(0.8)
        screen = subprocess.run(
            [*self.tmux, "capture-pane", "-p", "-t", pane],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        self.assertIn("rook-opened-42", screen)

    def test_a_gone_pane_fails(self) -> None:
        agent_pane = rook_client.AgentPane(session_id=SESSION, harness="claude", tmux_socket=self.socket, pane="%99")
        with self.assertRaises(rook_link.RookLinkError):
            rook_link.PaneTyper().type(agent_pane, "rook-d-1", "hello")


class RookLinkTest(QueueAndSendTest):
    """rook-link against a roost of the test's own."""

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
        self.wait_for(lambda: server.resources.exists(agent_ref), "the agent to reach roost")
        self.wait_for(lambda: server.link.online_rooks() == ["studio"], "the rook to come online")
        delivery = server.link.send_to_agent(ResourceRef("person", "user"), SESSION, "run the tests")
        self.wait_for(lambda: server.deliveries.get(delivery.id).status == "delivered", "the delivery")
        self.assertEqual(typer.list_typed, ["run the tests"])


if __name__ == "__main__":
    unittest.main()
