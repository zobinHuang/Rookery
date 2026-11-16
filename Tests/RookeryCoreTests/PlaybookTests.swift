import RookeryCore
import Testing

struct PlaybookTests {
    private let listSkills = [
        FleetResource(kind: "skill", id: "github-com-team-skills-review", name: "review", mapAttributes: [:], lastUsedAt: ""),
        FleetResource(kind: "skill", id: "db-migrations", name: "DB migrations", mapAttributes: [:], lastUsedAt: ""),
    ]

    @Test func readsPinsInEitherForm() {
        let playbook = FleetResource(
            kind: "playbook",
            id: "p",
            name: "p",
            mapAttributes: ["skills": .array([.string("a"), .object(["skill_id": .string("b"), "pin": .string("v2")])])],
            lastUsedAt: ""
        )

        #expect(PlaybookPin.pins(of: playbook) == [PlaybookPin(skillId: "a"), PlaybookPin(skillId: "b", pin: "v2")])
        #expect(PlaybookPin(skillId: "a").payload == .string("a"))
    }

    @Test func pinsTheSkillsItsStepsName() {
        let prompt = "1. Plan the change.\n2. Write the migration with @DB-migrations.\n3. Review it with @review, then @review again."

        let listIds = PlaybookSteps.skillIds(namedIn: prompt, among: listSkills)

        #expect(listIds == ["db-migrations", "github-com-team-skills-review"])
        #expect(PlaybookSteps.pins([PlaybookPin(skillId: "db-migrations", pin: "v1")], adding: listIds).map(\.skillId)
            == ["db-migrations", "github-com-team-skills-review"])
    }
}
