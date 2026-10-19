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

    @Test func hidingRemembersTheFrameUntilShown() {
        var workspace = Workspace()
        workspace.adopt(Self.window(1), into: nil)
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        workspace.markHidden(WindowId(rawValue: 1), restoreFrame: frame)
        let listHiddenIds = workspace.listHiddenWindows.map(\.windowId.rawValue)
        let restoreFrame = workspace.markShown(WindowId(rawValue: 1))
        let secondRestoreFrame = workspace.markShown(WindowId(rawValue: 1))

        #expect(listHiddenIds == [1])
        #expect(restoreFrame == frame)
        #expect(secondRestoreFrame == nil)
        #expect(workspace.listHiddenWindows.isEmpty)
    }

    @Test func movingAHiddenWindowKeepsItsRestoreFrame() {
        var workspace = Workspace()
        workspace.adopt(Self.window(1), into: nil)
        let secondGroupId = workspace.adopt(Self.window(2), into: nil)
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        workspace.markHidden(WindowId(rawValue: 1), restoreFrame: frame)

        let window = workspace.listManagedWindows.first { $0.windowId.rawValue == 1 }
        if let window {
            workspace.adopt(window, into: secondGroupId)
        }

        #expect(workspace.group(containing: WindowId(rawValue: 1))?.groupId == secondGroupId)
        #expect(workspace.listHiddenWindows.first?.restoreFrame == frame)
    }

    @Test func savedWorkspaceWithoutRestoreFramesStillDecodes() throws {
        let json = """
            {"listGroups":[{"groupId":"g","name":"Paper","listMembers":[{"windowId":7,"title":"t",
            "application":{"processId":1,"bundleId":"com.example","name":"Example"}}]}]}
            """

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))

        #expect(workspace.listManagedWindows.first?.isHidden == false)
    }

    @Test func activatingAnUnknownGroupLeavesGroupMode() {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1), into: nil)

        workspace.activate(groupId)
        let activeAfterActivate = workspace.activeGroupId
        workspace.activate(GroupId(rawValue: "missing"))

        #expect(activeAfterActivate == groupId)
        #expect(workspace.activeGroupId == nil)
    }

    @Test func removingTheActiveGroupsLastMemberLeavesGroupMode() {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1), into: nil)
        workspace.activate(groupId)

        workspace.release(WindowId(rawValue: 1))

        #expect(workspace.activeGroupId == nil)
    }

    @Test func stackOrderPutsRecordedMembersFirstAndNewcomersAfter() {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1), into: nil)
        workspace.adopt(Self.window(2), into: groupId)
        workspace.adopt(Self.window(3), into: groupId)

        workspace.recordStack(of: groupId, frontToBack: [WindowId(rawValue: 3), WindowId(rawValue: 9), WindowId(rawValue: 1)])
        workspace.adopt(Self.window(4), into: groupId)

        let listOrder = workspace.listGroups[0].listMembersFrontToBack
        #expect(listOrder.map(\.windowId.rawValue) == [3, 1, 2, 4])
    }

    @Test func groupsAreFoundByNameOrPosition() {
        var workspace = Workspace()
        let paperId = workspace.adopt(Self.window(1), into: nil)
        workspace.rename(paperId, to: "Paper")
        let secondId = workspace.adopt(Self.window(2), into: nil)

        #expect(workspace.group(named: "paper")?.groupId == paperId)
        #expect(workspace.group(named: "2")?.groupId == secondId)
        #expect(workspace.group(named: "3") == nil)
    }

    @Test func workspaceSurvivesAJsonRoundTrip() throws {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1, title: "a"), into: nil)
        workspace.adopt(Self.window(2, title: "b"), into: groupId)
        workspace.activate(groupId)
        workspace.recordStack(of: groupId, frontToBack: [WindowId(rawValue: 2), WindowId(rawValue: 1)])

        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))

        #expect(decoded == workspace)
    }
}
