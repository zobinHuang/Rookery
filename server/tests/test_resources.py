import tempfile
import threading
import unittest
from pathlib import Path
from rookd.database import Database
from rookd.errors import NotFoundError, ValidationError
from rookd.events import AgentStates, EventLog
from rookd.resources import Resource, ResourceQuery, ResourceRef, ResourceStore

AGENT = {"kind": "agent", "id": "s-1"}


def started(agent_id: str = "s-1", **map_detail: object) -> dict[str, object]:
    return {
        "actor": {"kind": "agent", "id": agent_id},
        "verb": "started",
        "detail": {"name": "studio/api", "harness": "claude", "cwd": "/srv/api", **map_detail},
    }


class EventLogTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.resources = ResourceStore(Database(Path(self._tmp.name)))
        self.addCleanup(self.resources.database.close)
        self.events = EventLog(self.resources)

    def agent(self, agent_id: str = "s-1") -> dict[str, object]:
        return self.resources.get(ResourceRef("agent", agent_id)).as_payload()

    def test_a_started_agent_is_idle_with_its_details(self) -> None:
        self.events.record([started(machine={"hostname": "studio"})])
        agent = self.agent()
        self.assertEqual(agent["name"], "studio/api")
        self.assertEqual(agent["attributes"]["state"], AgentStates.IDLE)
        self.assertEqual(agent["attributes"]["harness"], "claude")
        self.assertEqual(agent["attributes"]["machine"], {"hostname": "studio"})

    def test_states_follow_the_agent_through_to_its_end(self) -> None:
        self.events.record([started(), {"actor": AGENT, "verb": "state", "detail": {"state": "working"}}])
        self.assertEqual(self.agent()["attributes"]["state"], "working")
        self.events.record([{"actor": AGENT, "verb": "ended"}])
        attributes = self.agent()["attributes"]
        self.assertEqual(attributes["state"], AgentStates.ENDED)
        self.assertIsNotNone(attributes["closed_at"])

    def test_an_agent_first_heard_of_mid_session_is_created(self) -> None:
        self.events.record([{"actor": AGENT, "verb": "state", "detail": {"state": "thinking"}}])
        self.assertEqual(self.agent()["attributes"]["state"], "thinking")

    def test_a_bad_event_rolls_back_its_whole_batch(self) -> None:
        with self.assertRaises(ValidationError):
            self.events.record([started(), {"actor": AGENT, "verb": "state", "detail": {"state": "asleep"}}])
        with self.assertRaises(NotFoundError):
            self.agent()
        self.assertEqual(self.events.latest(10), [])

    def test_a_skill_named_by_an_agent_is_discovered_and_its_uses_counted(self) -> None:
        use = {"actor": AGENT, "verb": "uses", "object": {"kind": "skill", "name": "review"}}
        self.events.record([started(), use, use])
        skill = self.resources.get(ResourceRef("skill", "review"))
        self.assertTrue(skill.map_attributes["discovered"])
        list_relations = self.resources.relations(ResourceRef("agent", "s-1"))
        self.assertEqual([(r.verb, r.target.id, r.count) for r in list_relations], [("uses", "review", 2)])

    def test_a_skill_named_again_is_found_by_its_name(self) -> None:
        self.resources.put(Resource(kind="skill", id="github-com-acme-skills-review", name="review"))
        self.events.record([{"actor": AGENT, "verb": "uses", "object": {"kind": "skill", "name": "review"}}])
        list_ids = [r.target.id for r in self.resources.relations(ResourceRef("agent", "s-1"))]
        self.assertEqual(list_ids, ["github-com-acme-skills-review"])

    def test_memory_an_agent_writes_keeps_its_latest_text(self) -> None:
        for text in ("first", "second"):
            self.events.record([{
                "actor": AGENT,
                "verb": "wrote",
                "object": {"kind": "memory", "id": "m-1", "name": "pagination quirks"},
                "detail": {"text": text, "path": "/home/dev/.claude/projects/p/memory/pagination.md"},
            }])
        memory = self.resources.get(ResourceRef("memory", "m-1"))
        self.assertEqual(memory.map_attributes["text"], "second")
        self.assertEqual(memory.origin, ResourceRef("agent", "s-1"))

    def test_a_subagent_hangs_off_the_agent_that_spawned_it(self) -> None:
        self.events.record([started(), started("s-1~explore", parent="s-1")])
        child = self.resources.get(ResourceRef("agent", "s-1~explore"))
        self.assertEqual(child.origin, ResourceRef("agent", "s-1"))
        list_edges = [(r.source.id, r.verb, r.target.id) for r in self.resources.relations()]
        self.assertIn(("s-1", "spawned", "s-1~explore"), list_edges)

    def test_the_most_recently_used_come_first(self) -> None:
        self.events.record([
            {"actor": AGENT, "verb": "uses", "object": {"kind": "skill", "name": "old"}, "at": "2026-11-15T10:00:00Z"},
            {"actor": AGENT, "verb": "uses", "object": {"kind": "skill", "name": "new"}, "at": "2026-11-15T11:00:00Z"},
        ])
        list_names = [r.name for r in self.resources.query(ResourceQuery(kind="skill"))]
        self.assertEqual(list_names, ["new", "old"])

    def test_deleting_a_resource_drops_its_relations(self) -> None:
        self.events.record([{"actor": AGENT, "verb": "uses", "object": {"kind": "skill", "name": "review"}}])
        self.resources.delete(ResourceRef("skill", "review"))
        self.assertEqual(self.resources.relations(), [])

    def test_sequence_numbers_only_grow_and_resume_a_reader(self) -> None:
        self.events.record([started(), {"actor": AGENT, "verb": "state", "detail": {"state": "working"}}])
        list_all = self.events.after(0)
        self.assertEqual([event.seq for event in list_all], sorted({event.seq for event in list_all}))
        self.assertEqual([event.verb for event in self.events.after(list_all[0].seq)], ["state"])

    def test_a_waiting_reader_gets_the_next_event(self) -> None:
        list_received: list[str] = []
        waiter = threading.Thread(target=lambda: list_received.extend(e.verb for e in self.events.wait_after(0, 5)))
        waiter.start()
        self.events.record([started()])
        waiter.join(5)
        self.assertEqual(list_received, ["started"])

    def test_waiting_with_nothing_new_times_out_empty(self) -> None:
        self.assertEqual(self.events.wait_after(0, 0.05), [])


if __name__ == "__main__":
    unittest.main()
