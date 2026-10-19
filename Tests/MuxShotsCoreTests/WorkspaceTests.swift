import Foundation
import MuxShotsCore
import Testing

struct WorkspaceTests {
    static let code = RunningApplication(processId: 200, bundleId: "com.microsoft.VSCode", name: "Code")

    static func window(_ rawId: UInt32, title: String = "") -> ManagedWindow {
        ManagedWindow(windowId: WindowId(rawValue: rawId), application: Self.code, title: title)
    }

    @Test func adoptingIntoNoGroupCreatesNumberedGroups() {
        var workspace = Workspace()
        workspace.adopt(Self.window(1), into: nil)
        workspace.adopt(Self.window(2), into: nil)

        #expect(workspace.listGroups.map(\.name) == ["Group 1", "Group 2"])
        #expect(workspace.isManaged(WindowId(rawValue: 1)))
    }

    @Test func adoptingIntoAGroupAppendsInJoinOrder() {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1), into: nil)
        workspace.adopt(Self.window(3), into: groupId)
        workspace.adopt(Self.window(2), into: groupId)

        #expect(workspace.listGroups.count == 1)
        #expect(workspace.listGroups[0].listMembers.map(\.windowId.rawValue) == [1, 3, 2])
    }

    @Test func adoptingAManagedWindowMovesItAndDropsTheEmptiedGroup() {
        var workspace = Workspace()
        workspace.adopt(Self.window(1), into: nil)
        let secondGroupId = workspace.adopt(Self.window(2), into: nil)

        workspace.adopt(Self.window(1), into: secondGroupId)

        #expect(workspace.listGroups.count == 1)
        #expect(workspace.group(containing: WindowId(rawValue: 1))?.groupId == secondGroupId)
    }

    @Test func releasingTheLastMemberRemovesTheGroupAndFreesItsName() {
        var workspace = Workspace()
        workspace.adopt(Self.window(1), into: nil)
        workspace.adopt(Self.window(2), into: nil)

        let wasManaged = workspace.release(WindowId(rawValue: 1))
        let wasManagedAgain = workspace.release(WindowId(rawValue: 1))
        #expect(wasManaged)
        #expect(!wasManagedAgain)
        workspace.adopt(Self.window(3), into: nil)

        #expect(workspace.listGroups.map(\.name) == ["Group 2", "Group 1"])
    }

    @Test func renameIgnoresBlankNames() {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1), into: nil)

        workspace.rename(groupId, to: "  Paper  ")
        workspace.rename(groupId, to: "   ")

        #expect(workspace.listGroups[0].name == "Paper")
    }

    @Test func titleUpdatesReachTheMember() {
        var workspace = Workspace()
        workspace.adopt(Self.window(1, title: "old"), into: nil)

        workspace.updateTitle(of: WindowId(rawValue: 1), to: "new")

        #expect(workspace.listManagedWindows.map(\.title) == ["new"])
    }

    @Test func workspaceSurvivesAJsonRoundTrip() throws {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1, title: "a"), into: nil)
        workspace.adopt(Self.window(2, title: "b"), into: groupId)

        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))

        #expect(decoded == workspace)
    }
}
