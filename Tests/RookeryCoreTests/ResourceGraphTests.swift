import Foundation
import RookeryCore
import Testing

struct ResourceGraphTests {
    private static let agent = FleetRef(kind: "agent", id: "s-1")
    private static let skill = FleetRef(kind: "skill", id: "review")

    private func graph() -> ResourceGraph {
        var graph = ResourceGraph()
        graph.load(
            kinds: [FleetKind(name: "agent", title: "Agent", pluralTitle: "Agents")],
            resources: [
                FleetResource(kind: "agent", id: "s-1", name: "studio/api", mapAttributes: [:], lastUsedAt: "1"),
                FleetResource(kind: "skill", id: "review", name: "review", mapAttributes: [:], lastUsedAt: "1"),
            ],
            relations: [],
            recentEvents: [],
            lastSeq: 5
        )
        return graph
    }

    @Test func theLogNamesEachResourceByItsKindAndItsOwnName() {
        var graph = ResourceGraph()
        graph.load(
            kinds: [FleetKind(name: "agent", title: "Agent", pluralTitle: "Agents")],
            resources: [
                FleetResource(kind: "agent", id: "s-1", name: "studio/api", mapAttributes: ["title": .string("hi raven, what can you do?")], lastUsedAt: "1"),
            ],
            relations: [],
            recentEvents: [],
            lastSeq: 5
        )
        #expect(graph.logLabel(of: Self.agent) == "Agent [studio/api]")
        #expect(graph.logLabel(of: FleetRef(kind: "agent", id: "s-1~sub")) == "Agent [studio/api › subagent]")
        #expect(graph.logLabel(of: FleetRef(kind: "skill", id: "humanize")) == "Skill [humanize]")
        #expect(graph.logLabel(of: FleetRef(kind: "person", id: "me")) == "You")
        graph.put(FleetResource(kind: "agent", id: "r-1", name: "rookery/raven", mapAttributes: ["rook_name": .string("rookery"), "title": .string("Tomorrow's schedule")], lastUsedAt: "2"))
        #expect(graph.logLabel(of: FleetRef(kind: "agent", id: "r-1")) == "Raven [Tomorrow's schedule]")
    }

    @Test func drawsAndCountsRelationsAndMarksUse() {
        var graph = graph()

        #expect(graph.apply(FleetEvent(seq: 6, at: "2", actor: Self.agent, verb: "uses", object: Self.skill)).isEmpty)
        _ = graph.apply(FleetEvent(seq: 7, at: "3", actor: Self.agent, verb: "uses", object: Self.skill))

        let relation = graph.listRelations(touching: Self.skill)
        #expect(relation.map(\.count) == [2])
        #expect(graph.resource(Self.skill)?.lastUsedAt == "3")
        #expect(graph.listRecentEvents.map(\.seq) == [6, 7])
    }

    @Test func fetchesWhatItCannotTellAndForgetsWhatWasDeleted() {
        var graph = graph()
        let memory = FleetRef(kind: "memory", id: "m-1")

        #expect(graph.apply(FleetEvent(seq: 6, at: "2", actor: Self.agent, verb: "wrote", object: memory)) == [memory])
        _ = graph.apply(FleetEvent(seq: 7, at: "3", actor: FleetRef(kind: "person", id: "user"), verb: "deleted", object: Self.skill))

        #expect(graph.resource(Self.skill) == nil)
        #expect(graph.listRelations(touching: memory).count == 1)
        #expect(graph.name(of: FleetRef(kind: "person", id: "user")) == "you")
    }

    @Test func keepsOnlyTheLatestEvents() {
        var graph = graph()
        for seq in 6..<(6 + ResourceGraph.recentEventLimit + 10) {
            _ = graph.apply(FleetEvent(seq: seq, at: "2", actor: Self.agent, verb: "state", mapDetail: ["state": .string("working")]))
        }

        #expect(graph.listRecentEvents.count == ResourceGraph.recentEventLimit)
        #expect(graph.resource(Self.agent)?.mapAttributes["state"] == .string("working"))
    }
}
