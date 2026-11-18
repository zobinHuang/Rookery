import tempfile
import unittest
from pathlib import Path
from roost.catalog import ResourceCatalog
from roost.database import Database
from roost.events import EventLog
from roost.playbooks import PlaybookIndex
from roost.resources import ResourceRef, ResourceStore
from roost.skills import SkillIndex, SkillRecord
from tests.test_skills import FakeResolver


class SkillIdentityTest(unittest.TestCase):
    """A skill an agent used by name and the skill registered from its repository are one skill, and a
    playbook's pinned skills are its edges, so the board draws agent, playbook and skill joined up."""

    REPO_SOURCE = "https://github.com/org/skills/tree/main/skills/pdf"

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.resources = ResourceStore(Database(Path(self._tmp.name)))
        self.addCleanup(self.resources.database.close)
        self.events = EventLog(self.resources)
        self.skills = SkillIndex(self.resources, FakeResolver())
        self.playbooks = PlaybookIndex(self.resources, self.skills)
        self.catalog = ResourceCatalog(self.resources, self.events, self.skills, self.playbooks)

    def use(self, agent_id: str, skill_name: str) -> None:
        self.events.record([{"actor": {"kind": "agent", "id": agent_id}, "verb": "uses", "object": {"kind": "skill", "name": skill_name}}])

    def edges(self, verb: str) -> set[tuple[str, str]]:
        return {(relation.source.id, relation.target.id) for relation in self.resources.relations() if relation.verb == verb}

    def test_a_name_matches_the_registered_name_or_the_last_part_of_its_path_a_plugin_prefix_aside(self) -> None:
        self.assertTrue(SkillRecord.answers_to("pdf", "PDF tools", "skills/pdf"))
        self.assertTrue(SkillRecord.answers_to("docs:pdf", "pdf", ""))
        self.assertFalse(SkillRecord.answers_to("pdfs", "pdf", "skills/pdf"))

    def test_a_skill_used_before_it_was_registered_is_folded_into_it_with_its_edges(self) -> None:
        self.use("s-1", "pdf")
        self.assertIn(("s-1", "pdf"), self.edges("uses"))
        record = self.skills.register({"source": self.REPO_SOURCE})
        self.assertIn(("s-1", record.id), self.edges("uses"))
        self.assertFalse(self.resources.exists(ResourceRef(kind="skill", id="pdf")))

    def test_a_skill_used_after_it_was_registered_lands_on_it_whatever_its_namespace(self) -> None:
        record = self.skills.register({"source": self.REPO_SOURCE})
        self.use("s-2", "docs:pdf")
        self.assertEqual(self.edges("uses"), {("s-2", record.id)})

    def test_a_playbook_depends_on_the_skills_it_pins_and_no_longer_on_those_it_drops(self) -> None:
        pdf = self.skills.register({"source": self.REPO_SOURCE})
        review = self.skills.register({"source": "https://github.com/org/skills/tree/main/skills/review"})
        self.catalog.create("playbook", {"name": "Ship docs", "skills": [pdf.id, review.id]})
        self.assertEqual(self.edges("depends_on"), {("ship-docs", pdf.id), ("ship-docs", review.id)})
        self.catalog.update("playbook", "ship-docs", {"skills": [review.id]})
        self.assertEqual(self.edges("depends_on"), {("ship-docs", review.id)})

    def test_a_starting_server_draws_the_edges_of_playbooks_made_before_it_drew_any(self) -> None:
        pdf = self.skills.register({"source": self.REPO_SOURCE})
        self.playbooks.create({"name": "Ship docs", "skills": [pdf.id]})
        self.assertEqual(self.edges("depends_on"), set())
        self.catalog.link_every_playbook()
        self.assertEqual(self.edges("depends_on"), {("ship-docs", pdf.id)})
