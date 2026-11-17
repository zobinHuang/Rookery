import Foundation
import RookeryCore
import Testing

struct HostsTests {
    private static let config = """
        # personal
        Host b300 b300-alias
            HostName 10.0.0.3
            User zobin
            Port 2222

        Host *.internal !bastion
            User ops

        Host marsrover
          HostName=marsrover.stream
          User root
          User someone-else

        Match host foo
            User nobody

        Include conf.d/*
        Host *
            ServerAliveInterval 30
        """

    @Test func readsConcreteHostsWithTheFirstValueOfEachKeyword() {
        let listHosts = SSHConfig.hosts(in: Self.config) { pattern in
            pattern == "conf.d/*" ? "Host lab\n  HostName lab.example.com\n  Port 22\n" : nil
        }
        #expect(listHosts.map(\.alias) == ["b300", "b300-alias", "marsrover", "lab"])
        #expect(listHosts[0] == SSHHost(alias: "b300", hostName: "10.0.0.3", user: "zobin", port: 2222))
        #expect(listHosts[2].user == "root")
        #expect(listHosts[2].hostName == "marsrover.stream")
        #expect(listHosts[3].port == nil)
        #expect(listHosts[0].address == "zobin@10.0.0.3:2222")
    }

    @Test func aHostRunsTheRookChosenForItOrOneNamedAsIt() {
        var book = HostBook()
        let host = SSHHost(alias: "b300", hostName: "alibaba-b300-0.example.com")
        #expect(book.rookName(of: host, among: ["alibaba-b300-0"]) == "alibaba-b300-0")
        #expect(book.rookName(of: SSHHost(alias: "lab"), among: ["lab"]) == "lab")
        #expect(book.rookName(of: SSHHost(alias: "lab"), among: []) == nil)
        book.assignRook("studio", to: "b300")
        #expect(book.rookName(of: host, among: ["alibaba-b300-0"]) == "studio")
        book.assignRook("", to: "b300")
        #expect(book.rookName(of: host, among: ["alibaba-b300-0"]) == "alibaba-b300-0")
    }

    @Test func workdirsAreAddedReplacedAndRemovedByTheirId() {
        var book = HostBook()
        var workdir = Workdir(name: "G-Watch", path: "/home/zobin/gwatch")
        book.put(workdir, on: "b300")
        workdir.role = "kernel profiler"
        book.put(workdir, on: "b300")
        #expect(book.settings(of: "b300").listWorkdirs == [workdir])
        book.removeWorkdir(workdir.id, from: "b300")
        #expect(book.settings(of: "b300").listWorkdirs.isEmpty)
        #expect(Workdir.defaultName(of: "/home/zobin/gwatch/") == "gwatch")
    }

    @Test func aLaunchCarriesWhatTheAgentBeginsWith() {
        let workdir = Workdir(
            name: "G-Watch",
            path: "/src/gwatch",
            playbookId: "review",
            listSkillIds: ["cuda"],
            role: " tester ",
            listTeams: [LaunchTeam(teamId: "gw", duty: "tests")]
        )
        let request = LaunchRequest(workdir: workdir, rookName: "b300", prompt: "")
        let mapBody = request.body
        #expect(mapBody["kind"] == .string("spawn"))
        #expect(mapBody["rook"] == .string("b300"))
        guard case .object(let mapOptions) = mapBody["options"] else {
            Issue.record("no options")
            return
        }
        #expect(mapOptions["launch"] == .string(request.launchId))
        #expect(mapOptions["playbook"] == .string("review"))
        #expect(mapOptions["role"] == .string("tester"))
        #expect(mapOptions["teams"] == .array([.object(["team": .string("gw"), "duty": .string("tests")])]))
        #expect(request.launchId.hasPrefix("l-"))
    }

    @Test func aProbeReadsWhatItsCommandPrintedPastAGreeting() {
        let probe = HostProbe.parse("Welcome to b300\ntmux=yes\nclaude=yes\ncodex=no\nrook=yes\nrook_name=alibaba-b300-0\nconnected=yes\n")
        #expect(probe == HostProbe(hasTmux: true, hasClaude: true, hasCodex: false, hasRook: true, isConnected: true, rookName: "alibaba-b300-0"))
        #expect(HostProbe.parse("") == HostProbe())
    }

    @Test func aListingKeepsItsDirectoriesVisibleOnesFirst() {
        let directory = RemoteDirectory.parse("/home/zobin\n.cache/\nnotes.txt\nRookery/\napi/\n")
        #expect(directory.path == "/home/zobin")
        #expect(directory.listDirectories == ["api", "Rookery", ".cache"])
        #expect(directory.parent == "/home")
        #expect(RemoteDirectory.parse("/\n").parent == nil)
    }
}
