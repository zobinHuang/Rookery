import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "server"))

from rookd.config import ServerConfig  # noqa: E402
from rookd.http import RookdServer  # noqa: E402
from rookd.resources import ResourceRef  # noqa: E402
from rookd.store import SessionStore  # noqa: E402

LOADER = importlib.machinery.SourceFileLoader("rook_client", str(REPO_ROOT / "rook" / "bin" / "rook-client"))
SPEC = importlib.util.spec_from_loader("rook_client", LOADER)
rook_client = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(rook_client)

SESSION = "a07f54b5-e80e-467c-a551-073b8b330911"


class RookHomeTest(unittest.TestCase):
    """A fake home for rook's configuration and state, outside tmux."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name)
        patcher = mock.patch.dict(os.environ, {
            "XDG_CONFIG_HOME": str(self.home / "config"),
            "XDG_STATE_HOME": str(self.home / "state"),
        })
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("TMUX_PANE", None)
        (self.home / "config" / "rook").mkdir(parents=True)
        (self.home / "config" / "rook" / "config.json").write_text(json.dumps({"name": "studio"}))

    def payload(self, hook: str, **map_fields: object) -> dict[str, object]:
        return {"session_id": SESSION, "hook_event_name": hook, **map_fields}

    def events(self, hook: str, harness: str = "claude", **map_fields: object) -> list[dict[str, object]]:
        return rook_client.HookEventMapper(harness, self.payload(hook, **map_fields)).events()


class HookEventMapperTest(RookHomeTest):
    def test_a_session_start_names_the_agent_after_the_rook(self) -> None:
        [event] = self.events("SessionStart", cwd=str(self.home))
        self.assertEqual(event["verb"], "started")
        self.assertEqual(event["actor"], {"kind": "agent", "id": SESSION})
        self.assertEqual(event["detail"]["name"], "studio")
        self.assertEqual(event["detail"]["harness"], "claude")

    def test_using_a_skill_is_working_and_uses_it(self) -> None:
        list_events = self.events("PreToolUse", tool_name="Skill", tool_input={"skill": "review"})
        self.assertEqual([event["verb"] for event in list_events], ["state", "uses"])
        self.assertEqual(list_events[1]["object"], {"kind": "skill", "name": "review"})

    def test_writing_memory_reports_its_text_and_name(self) -> None:
        path = self.home / ".claude" / "projects" / "-srv-api" / "memory" / "pagination.md"
        path.parent.mkdir(parents=True)
        path.write_text("---\nname: pagination quirks\n---\nuse cursors\n")
        list_events = self.events("PostToolUse", tool_name="Write", tool_input={"file_path": str(path)})
        memory = list_events[1]
        self.assertEqual(memory["verb"], "wrote")
        self.assertEqual(memory["object"]["name"], "pagination quirks")
        self.assertIn("use cursors", memory["detail"]["text"])
        self.assertEqual(memory["detail"]["project"], "-srv-api")

    def test_editing_a_skill_updates_it(self) -> None:
        list_events = self.events(
            "PostToolUse",
            tool_name="Edit",
            tool_input={"file_path": "/srv/api/.claude/skills/release-notes/SKILL.md"},
        )
        self.assertEqual(list_events[1]["verb"], "updated")
        self.assertEqual(list_events[1]["object"], {"kind": "skill", "name": "release-notes"})

    def test_states_from_notifications_and_failures(self) -> None:
        cases = [
            ("Notification", {"notification_type": "permission_prompt"}, "needs_approval"),
            ("Notification", {"notification_type": "elicitation_dialog"}, "needs_input"),
            ("StopFailure", {"error": "Claude usage limit reached"}, "rate_limited"),
            ("StopFailure", {"error": "overloaded"}, "error"),
            ("PreCompact", {}, "compacting"),
            ("Stop", {}, "done"),
        ]
        for hook, map_fields, state in cases:
            with self.subTest(hook=hook, state=state):
                [event] = self.events(hook, **map_fields)
                self.assertEqual(event["detail"]["state"], state)

    def test_codex_asks_for_approval_with_its_own_event(self) -> None:
        [event] = self.events("PermissionRequest", harness="codex")
        self.assertEqual(event["detail"]["state"], "needs_approval")

    def test_a_subagent_that_stops_is_started_under_its_parent_and_ended(self) -> None:
        list_events = self.events("SubagentStop", agent_id="explore-1", agent_type="Explore")
        self.assertEqual([event["verb"] for event in list_events], ["started", "ended"])
        self.assertEqual(list_events[0]["actor"]["id"], f"{SESSION}~explore-1")
        self.assertEqual(list_events[0]["detail"]["parent"], SESSION)

    def test_a_payload_without_a_session_says_nothing(self) -> None:
        self.assertEqual(rook_client.HookEventMapper("claude", {"hook_event_name": "Stop"}).events(), [])


class QueueAndSendTest(RookHomeTest):
    TEST_TOKEN = "test-token"

    def start_server(self) -> RookdServer:
        root = self.home / "rookd"
        config = ServerConfig(
            data_root=root,
            host="127.0.0.1",
            port=0,
            token=self.TEST_TOKEN,
            max_body_bytes=1024 * 1024,
            tls_cert=None,
            tls_key=None,
        )
        server = RookdServer(config=config, store=SessionStore(root))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)
        return server

    def connect(self, port: int) -> None:
        (self.home / "config" / "rook" / "connect.json").write_text(json.dumps({
            "base_url": f"http://127.0.0.1:{port}",
            "token": self.TEST_TOKEN,
        }))

    def hook(self, payload: dict[str, object]) -> None:
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(payload))), \
                mock.patch.object(rook_client.RookClient, "start_sender") as start_sender:
            self.assertEqual(rook_client.RookClient.hook("claude"), 0)
        self.spawned = start_sender.called

    def queued(self) -> list[str]:
        path = rook_client.RookPaths.queue_file()
        return path.read_text().splitlines() if path.exists() else []

    def test_a_state_repeated_by_every_tool_call_is_queued_once(self) -> None:
        self.hook(self.payload("PreToolUse", tool_name="Bash", tool_input={}))
        self.hook(self.payload("PostToolUse", tool_name="Bash", tool_input={}))
        self.hook(self.payload("PreToolUse", tool_name="Bash", tool_input={}))
        self.assertEqual(len(self.queued()), 1)

    def test_queued_events_reach_rookd(self) -> None:
        server = self.start_server()
        self.connect(server.bound_port())
        self.hook(self.payload("SessionStart", cwd=str(self.home)))
        self.assertTrue(self.spawned)
        self.assertEqual(rook_client.RookClient.flush(), 0)
        agent = server.resources.get(ResourceRef("agent", SESSION))
        self.assertEqual(agent.name, "studio")
        self.assertEqual(self.queued(), [])

    def test_events_wait_while_rookd_is_away_and_go_once_it_is_back(self) -> None:
        self.connect(1)
        self.hook(self.payload("SessionStart", cwd=str(self.home)))
        self.hook(self.payload("UserPromptSubmit"))
        self.assertEqual(rook_client.RookClient.flush(), 1)
        server = self.start_server()
        self.connect(server.bound_port())
        self.assertEqual(rook_client.RookClient.flush(), 0)
        agent = server.resources.get(ResourceRef("agent", SESSION))
        self.assertEqual(agent.map_attributes["state"], "thinking")


if __name__ == "__main__":
    unittest.main()
