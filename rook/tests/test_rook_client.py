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

from roost.config import ServerConfig  # noqa: E402
from roost.http import RoostServer  # noqa: E402
from roost.resources import ResourceRef  # noqa: E402
from roost.store import SessionMeta, SessionStore  # noqa: E402

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

    def test_a_state_carries_the_sessions_title(self) -> None:
        transcript = self.home / "session.jsonl"
        transcript.write_text("\n".join(json.dumps(line) for line in [
            {"type": "ai-title", "aiTitle": "Repo overview"},
            {"type": "user", "message": {"content": "hi"}},
            {"type": "custom-title", "customTitle": "G-Watch development"},
            {"type": "ai-title", "aiTitle": "Later guess"},
        ]) + "\n")
        [event] = self.events("Stop", transcript_path=str(transcript))
        self.assertEqual(event["detail"]["title"], "G-Watch development")

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

    def test_a_harness_helper_without_an_agent_type_is_not_a_subagent(self) -> None:
        self.assertEqual(self.events("SubagentStop", agent_id="a3c52ad0"), [])

    def test_a_payload_without_a_session_says_nothing(self) -> None:
        self.assertEqual(rook_client.HookEventMapper("claude", {"hook_event_name": "Stop"}).events(), [])


class EntrypointTest(RookHomeTest):
    """Which Claude Code sessions rook reports, by how they were started."""

    def test_a_session_another_program_started_is_left_out(self) -> None:
        payload = json.dumps({"session_id": SESSION, "hook_event_name": "SessionStart"})
        with mock.patch.dict(os.environ, {"CLAUDE_CODE_ENTRYPOINT": "raft"}), \
                mock.patch.object(sys, "stdin", io.StringIO(payload)):
            self.assertEqual(rook_client.RookClient.hook("claude"), 0)
        path = rook_client.RookPaths.queue_file()
        self.assertFalse(path.exists() and path.read_text().strip())

    def test_a_terminal_session_and_an_unknown_one_are_reported(self) -> None:
        with mock.patch.dict(os.environ, {"CLAUDE_CODE_ENTRYPOINT": "cli"}):
            self.assertTrue(rook_client.RookClient.reports_session("claude"))
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CLAUDE_CODE_ENTRYPOINT", None)
            self.assertTrue(rook_client.RookClient.reports_session("claude"))

    def test_a_transcript_says_how_its_session_was_started(self) -> None:
        transcript = self.home / "session.jsonl"
        transcript.write_text(json.dumps({"type": "user", "entrypoint": "raft"}) + "\n")
        self.assertFalse(rook_client.RookClient.reports_session("claude", str(transcript)))
        rook_client.RookConfig.update({"entrypoints": ["cli", "raft"]})
        self.assertTrue(rook_client.RookClient.reports_session("claude", str(transcript)))


class TranscriptLinesTest(unittest.TestCase):
    def test_a_transcript_reads_as_turns_and_tool_calls(self) -> None:
        raw = "\n".join(json.dumps(line) for line in [
            {"type": "user", "message": {"content": "fix the login test"}},
            {"type": "assistant", "message": {"content": [
                {"type": "thinking", "thinking": "hmm"},
                {"type": "text", "text": "Looking."},
                {"type": "tool_use", "name": "Bash", "input": {"command": "npm test"}},
            ]}},
            {"type": "response_item", "payload": {"type": "function_call", "name": "shell", "arguments": "{\"command\": [\"rg\", \"x\"]}"}},
        ]).encode()
        self.assertEqual(
            rook_client.TranscriptLines.readable(raw),
            ["[user] fix the login test", "[assistant] Looking.", "[tool Bash] npm test", "[tool shell] rg x"],
        )


class PlaybookEventsTest(unittest.TestCase):
    def test_a_loaded_playbook_is_followed_and_its_skills_mounted(self) -> None:
        map_resolved = {"id": "backend-review", "skills": [{"skill_id": "review"}, {"skill_id": "lint"}]}
        list_events = rook_client.PlaybookEvents.of(SESSION, map_resolved)
        self.assertEqual(
            [(event["verb"], event["object"]["id"]) for event in list_events],
            [("follows", "backend-review"), ("mounts", "review"), ("mounts", "lint")],
        )


class QueueAndSendTest(RookHomeTest):
    TEST_TOKEN = "test-token"

    def start_server(self) -> RoostServer:
        root = self.home / "roost"
        config = ServerConfig(
            data_root=root,
            host="127.0.0.1",
            port=0,
            token=self.TEST_TOKEN,
            max_body_bytes=1024 * 1024,
            tls_cert=None,
            tls_key=None,
        )
        server = RoostServer(config=config, store=SessionStore(root))
        self.addCleanup(server.resources.database.close)
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
        self.hook(self.payload("SessionStart", cwd=str(self.home)))
        self.hook(self.payload("PreToolUse", tool_name="Bash", tool_input={}))
        self.hook(self.payload("PostToolUse", tool_name="Bash", tool_input={}))
        self.hook(self.payload("PreToolUse", tool_name="Bash", tool_input={}))
        self.assertEqual([json.loads(line)["verb"] for line in self.queued()], ["started", "state"])

    def test_a_session_first_seen_partway_is_started_with_its_name(self) -> None:
        self.hook(self.payload("UserPromptSubmit"))
        list_events = [json.loads(line) for line in self.queued()]
        self.assertEqual([event["verb"] for event in list_events], ["started", "state"])
        self.assertEqual(list_events[0]["detail"]["name"], "studio")
        self.hook(self.payload("Stop"))
        self.assertEqual([json.loads(line)["verb"] for line in self.queued()][2:], ["state"])

    def test_queued_events_reach_roost(self) -> None:
        server = self.start_server()
        self.connect(server.bound_port())
        self.hook(self.payload("SessionStart", cwd=str(self.home)))
        self.assertTrue(self.spawned)
        self.assertEqual(rook_client.RookClient.flush(), 0)
        agent = server.resources.get(ResourceRef("agent", SESSION))
        self.assertEqual(agent.name, "studio")
        self.assertEqual(self.queued(), [])

    def test_events_wait_while_roost_is_away_and_go_once_it_is_back(self) -> None:
        self.connect(1)
        self.hook(self.payload("SessionStart", cwd=str(self.home)))
        self.hook(self.payload("UserPromptSubmit"))
        self.assertEqual(rook_client.RookClient.flush(), 1)
        server = self.start_server()
        self.connect(server.bound_port())
        self.assertEqual(rook_client.RookClient.flush(), 0)
        agent = server.resources.get(ResourceRef("agent", SESSION))
        self.assertEqual(agent.map_attributes["state"], "thinking")



class AgentCommandsTest(QueueAndSendTest):
    """`rook agent` against a roost of the test's own."""

    def setUp(self) -> None:
        super().setUp()
        self.server = self.start_server()
        self.connect(self.server.bound_port())

    def report(self, list_events: list[dict[str, object]]) -> None:
        self.server.events.record(list_events)

    def run_client(self, list_argv: list[str]) -> str:
        stdout = io.StringIO()
        with mock.patch.object(sys, "stdout", stdout):
            self.assertEqual(rook_client.main(list_argv), 0)
        return stdout.getvalue()

    def start_agent(self, agent_id: str, state: str, at: str, detail: dict[str, object] | None = None) -> None:
        actor = {"kind": "agent", "id": agent_id}
        self.report([
            {"actor": actor, "verb": "started", "at": at, "detail": {"name": f"studio/{agent_id}", "rook_name": "studio", **(detail or {})}},
            {"actor": actor, "verb": "state", "at": at, "detail": {"state": state}},
        ])

    def test_status_lists_those_needing_a_person_first_and_leaves_ended_ones_out(self) -> None:
        self.report([{"actor": {"kind": "rook", "id": "studio"}, "verb": "connected"}])
        self.start_agent("busy", "working", "2026-11-16T10:00:00.000+00:00", {"cwd": "/src/payments", "git_branch": "main"})
        self.start_agent("asking", "needs_approval", "2026-11-16T09:00:00.000+00:00")
        self.start_agent("gone", "ended", "2026-11-16T11:00:00.000+00:00")
        self.start_agent("busy~helper", "working", "2026-11-16T10:30:00.000+00:00", {"parent": "busy"})
        list_rows = json.loads(self.run_client(["agent", "status", "--json"]))
        self.assertEqual([row["id"] for row in list_rows], ["asking", "busy"])
        self.assertTrue(list_rows[0]["needs_person"])
        self.assertEqual(list_rows[1]["project"], "payments")
        self.assertEqual(list_rows[1]["subagents"], 1)
        self.assertTrue(list_rows[1]["rook_online"])
        list_all = json.loads(self.run_client(["agent", "status", "--all", "--json"]))
        self.assertIn("gone", [row["id"] for row in list_all])

    def test_tail_reads_only_the_end_of_a_long_transcript(self) -> None:
        self.server.store.begin(SessionMeta.from_request(session_id="agent-helper", map_body={"agent": "claude"}))
        list_lines = [
            json.dumps({"type": "user", "message": {"role": "user", "content": f"step {index}"}})
            for index in range(5000)
        ]
        self.server.store.append("agent-helper", 0, ("\n".join(list_lines) + "\n").encode(), do_reset=False)
        with mock.patch.object(rook_client.AgentCommands, "AGENT_TAIL_BYTES", 2000):
            output = self.run_client(["agent", "tail", "busy~helper", "--steps", "3"])
        self.assertEqual(output.splitlines(), ["[user] step 4997", "[user] step 4998", "[user] step 4999"])


    def test_a_proposal_names_the_agent_and_sends_nothing(self) -> None:
        self.start_agent("busy", "working", "2026-11-16T10:00:00.000+00:00", {"title": "Payments"})
        output = self.run_client(["propose", "message", "busy", "run", "the", "tests"])
        proposal = json.loads(output.splitlines()[0])["proposal"]
        self.assertEqual(proposal["agent_title"], "Payments")
        self.assertEqual(proposal["text"], "run the tests")
        self.assertTrue(proposal["id"].startswith("p-"))
        self.assertEqual(self.server.deliveries.list_recent(agent_id="busy", limit=10), [])

    def test_an_approval_is_proposed_only_while_the_agent_waits_on_one(self) -> None:
        self.start_agent("busy", "working", "2026-11-16T10:00:00.000+00:00")
        stderr = io.StringIO()
        with mock.patch.object(sys, "stderr", stderr):
            self.assertEqual(rook_client.main(["propose", "approve", "busy", "--choice", "once"]), 1)
        self.assertIn("not waiting for an approval", stderr.getvalue())
        self.start_agent("asking", "needs_approval", "2026-11-16T10:00:00.000+00:00")
        proposal = json.loads(self.run_client(["propose", "approve", "asking", "--choice", "deny"]).splitlines()[0])["proposal"]
        self.assertEqual((proposal["action"], proposal["choice"]), ("approve", "deny"))

    def test_a_new_session_is_proposed_on_an_online_rook(self) -> None:
        self.report([{"actor": {"kind": "rook", "id": "studio"}, "verb": "connected"}])
        output = self.run_client(["propose", "spawn", "studio", "--cwd", "/src/api", "fix", "the", "flaky", "test"])
        proposal = json.loads(output.splitlines()[0])["proposal"]
        self.assertEqual(proposal["rook"], "studio")
        self.assertEqual(proposal["cwd"], "/src/api")
        self.assertEqual(proposal["text"], "fix the flaky test")
        self.report([{"actor": {"kind": "rook", "id": "studio"}, "verb": "disconnected"}])
        stderr = io.StringIO()
        with mock.patch.object(sys, "stderr", stderr):
            self.assertEqual(rook_client.main(["propose", "spawn", "studio", "--cwd", "/src/api"]), 1)
        self.assertIn("offline", stderr.getvalue())

    def test_an_ended_agent_takes_no_proposal(self) -> None:
        self.start_agent("gone", "ended", "2026-11-16T10:00:00.000+00:00")
        stderr = io.StringIO()
        with mock.patch.object(sys, "stderr", stderr):
            self.assertEqual(rook_client.main(["propose", "message", "gone", "hello"]), 1)
        self.assertIn("has ended", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()


class TeamCommandsTest(QueueAndSendTest):
    """Teams as an agent sees them through rook: told at its start, told of changes, and messaging them."""

    report = AgentCommandsTest.report
    run_client = AgentCommandsTest.run_client
    start_agent = AgentCommandsTest.start_agent

    def setUp(self) -> None:
        super().setUp()
        self.server = self.start_server()
        self.connect(self.server.bound_port())
        for agent_id in ("a", "b", "c"):
            self.start_agent(agent_id, "idle", "2026-11-17T10:00:00.000+00:00", {"title": f"agent {agent_id}"})
        self.server.catalog.create("team", {"id": "api", "name": "API", "attributes": {"goal": "ship v2"}})
        self.server.roster.join("api", "a", "server", None)
        self.server.roster.join("api", "b", "tests", None)
        patcher = mock.patch.object(rook_client.AgentPane, "session_here", return_value="a")
        patcher.start()
        self.addCleanup(patcher.stop)

    def hook_output(self, payload: dict[str, object]) -> dict[str, object] | None:
        stdout = io.StringIO()
        with mock.patch.object(sys, "stdout", stdout):
            self.hook(payload)
        return json.loads(stdout.getvalue()) if stdout.getvalue() else None

    def test_a_starting_session_is_told_its_teams_and_teammates(self) -> None:
        output = self.hook_output({"session_id": "a", "hook_event_name": "SessionStart"})
        context = output["hookSpecificOutput"]["additionalContext"]
        self.assertIn("Team API (id api), goal: ship v2", context)
        self.assertIn("- you, agent a", context)
        self.assertIn("duty here: tests", context)
        self.assertIn("rook team send", context)

    def test_a_session_in_no_team_is_told_nothing(self) -> None:
        self.assertIsNone(self.hook_output({"session_id": "c", "hook_event_name": "SessionStart"}))

    def test_a_launched_session_joins_its_teams_before_it_is_told_them(self) -> None:
        self.report([{"actor": {"kind": "rook", "id": "studio"}, "verb": "connected"}])
        self.server.link.spawn_on_rook(
            ResourceRef("person", "user"),
            "studio",
            "",
            {"cwd": "/src", "launch": "l-new", "teams": [{"team": "api", "duty": "docs"}]},
        )
        with mock.patch.dict(os.environ, {"ROOK_LAUNCH": "l-new"}):
            output = self.hook_output({"session_id": "d", "hook_event_name": "SessionStart"})
        self.assertIn("- you, agent d", output["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(self.server.roster.members_of(self.server.roster.teams()[0])["d"]["duty"], "docs")

    def test_a_prompt_is_told_what_changed_in_its_teams(self) -> None:
        self.hook_output({"session_id": "a", "hook_event_name": "SessionStart"})
        self.server.roster.join("api", "c", "docs", None)
        self.server.roster.leave("api", "b", None)
        with mock.patch.object(rook_client.TeamBriefing, "BRIEFING_CHECK_SECONDS", 0):
            output = self.hook_output({"session_id": "a", "hook_event_name": "UserPromptSubmit"})
            context = output["hookSpecificOutput"]["additionalContext"]
            self.assertIn("agent c joined as: docs", context)
            self.assertIn("agent b left", context)
            self.assertIsNone(self.hook_output({"session_id": "a", "hook_event_name": "UserPromptSubmit"}))

    def test_an_answer_and_a_team_message_carry_their_thread(self) -> None:
        first = self.run_client(["message", "b", "does", "the", "schema", "hold?"]).split()
        thread = first[first.index("thread") + 1]
        self.run_client(["message", "b", "--thread", thread, "--no-reply", "never", "mind"])
        list_sent = self.server.deliveries.list_recent(agent_id="b", limit=10)
        self.assertEqual({delivery.map_options["thread"] for delivery in list_sent}, {thread})
        self.assertTrue(list_sent[0].map_options["no_reply"])
        self.run_client(["team", "send", "api", "v2", "is", "tagged"])
        self.assertEqual(self.server.deliveries.list_recent(agent_id="b", limit=10)[0].map_options["team"], "api")
        inbox = self.run_client(["inbox"])
        self.assertIn("to b", inbox)
        self.assertIn("v2 is tagged", inbox)

    def test_role_and_focus_go_on_the_agents_card(self) -> None:
        self.run_client(["me", "role", "API", "owner"])
        self.run_client(["me", "focus", "auth", "tokens"])
        map_attributes = self.server.resources.get(ResourceRef("agent", "a")).map_attributes
        self.assertEqual((map_attributes["role"], map_attributes["focus"]), ("API owner", "auth tokens"))
        self.assertIn("role: API owner", self.run_client(["me"]))
        self.assertIn("now: auth tokens", self.run_client(["team", "roster", "api"]))

