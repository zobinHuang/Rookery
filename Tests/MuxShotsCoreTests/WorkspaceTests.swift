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

    @Test func onlyApplicationsWithEveryShownWindowHiddenCanBeHidden() {
        let terminal = RunningApplication(processId: 300, bundleId: "com.googlecode.iterm2", name: "iTerm2")
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1), into: nil)
        workspace.adopt(Self.window(2), into: groupId)
        workspace.adopt(ManagedWindow(windowId: WindowId(rawValue: 3), application: terminal, title: ""), into: groupId)
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        for rawId: UInt32 in [1, 2, 3] {
            workspace.markHidden(WindowId(rawValue: rawId), restoreFrame: frame)
        }
        let mapShown: [WindowId: Int32] = [
            WindowId(rawValue: 1): 200,
            WindowId(rawValue: 2): 200,
            WindowId(rawValue: 3): 300,
            WindowId(rawValue: 4): 300,
        ]

        let setAllHidden = workspace.processIdsShowingOnlyHiddenWindows(among: mapShown)
        workspace.markShown(WindowId(rawValue: 2))
        let setOneShown = workspace.processIdsShowingOnlyHiddenWindows(among: mapShown)

        #expect(setAllHidden == [200])
        #expect(setOneShown.isEmpty)
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

    @Test func activatingAGroupDisplacesOnlyTheGroupsItShares() {
        var workspace = Workspace()
        let laptopGroupId = workspace.adopt(Self.window(1), into: nil)
        let externalGroupId = workspace.adopt(Self.window(2), into: nil)
        let otherLaptopGroupId = workspace.adopt(Self.window(3), into: nil)

        workspace.activate(laptopGroupId, displacing: [])
        workspace.activate(externalGroupId, displacing: [])
        workspace.activate(otherLaptopGroupId, displacing: [laptopGroupId])

        #expect(workspace.setActiveGroupIds == [externalGroupId, otherLaptopGroupId])
        #expect(workspace.listActiveGroups.map(\.groupId) == [externalGroupId, otherLaptopGroupId])
    }

    @Test func activatingAnUnknownGroupChangesNothing() {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1), into: nil)
        workspace.activate(groupId, displacing: [])

        workspace.activate(GroupId(rawValue: "missing"), displacing: [groupId])
        let setAfterUnknown = workspace.setActiveGroupIds
        workspace.deactivateAll()

        #expect(setAfterUnknown == [groupId])
        #expect(workspace.setActiveGroupIds.isEmpty)
    }

    @Test func removingAnActiveGroupsLastMemberDeactivatesIt() {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1), into: nil)
        workspace.activate(groupId, displacing: [])

        workspace.release(WindowId(rawValue: 1))

        #expect(workspace.setActiveGroupIds.isEmpty)
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

    @Test func stagingKeepsTheFirstHomeUntilUnstaged() {
        var workspace = Workspace()
        workspace.adopt(Self.window(1), into: nil)
        let home = CGRect(x: 10, y: 10, width: 400, height: 300)

        workspace.markStaged(WindowId(rawValue: 1), homeFrame: home)
        workspace.markStaged(WindowId(rawValue: 1), homeFrame: CGRect(x: 0, y: 0, width: 1, height: 1))
        let listStagedIds = workspace.listStagedWindows.map(\.windowId.rawValue)
        let returnedHome = workspace.markUnstaged(WindowId(rawValue: 1))

        #expect(listStagedIds == [1])
        #expect(returnedHome == home)
        #expect(workspace.listStagedWindows.isEmpty)
    }

    @Test func bringingToFrontReordersOnlyThatGroup() {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1), into: nil)
        workspace.adopt(Self.window(2), into: groupId)
        workspace.adopt(Self.window(3), into: groupId)

        workspace.bringToFront(WindowId(rawValue: 3))
        workspace.bringToFront(WindowId(rawValue: 2))

        #expect(workspace.listGroups[0].listMembersFrontToBack.map(\.windowId.rawValue) == [2, 3, 1])
        #expect(workspace.listGroups[0].listMembers.map(\.windowId.rawValue) == [1, 2, 3])
    }

    @Test func windowNamesOverrideTitlesUntilCleared() {
        var workspace = Workspace()
        workspace.adopt(Self.window(1, title: "main.tex — paper"), into: nil)

        workspace.rename(window: WindowId(rawValue: 1), to: "  Draft  ")
        let renamed = workspace.listManagedWindows[0].displayName
        workspace.updateTitle(of: WindowId(rawValue: 1), to: "intro.tex — paper")
        let afterTitleChange = workspace.listManagedWindows[0].displayName
        workspace.rename(window: WindowId(rawValue: 1), to: " ")

        #expect(renamed == "Draft")
        #expect(afterTitleChange == "Draft")
        #expect(workspace.listManagedWindows[0].displayName == "intro.tex — paper")
    }

    @Test func untitledWindowsShowTheirApplication() {
        var workspace = Workspace()
        workspace.adopt(Self.window(1), into: nil)

        #expect(workspace.listManagedWindows[0].displayName == "Code")
    }

    @Test func groupsMoveBeforeATargetOrToTheEnd() {
        var workspace = Workspace()
        let firstId = workspace.adopt(Self.window(1), into: nil)
        let secondId = workspace.adopt(Self.window(2), into: nil)
        let thirdId = workspace.adopt(Self.window(3), into: nil)

        workspace.moveGroup(thirdId, before: firstId)
        let afterMoveToFront = workspace.listGroups.map(\.groupId)
        workspace.moveGroup(thirdId, before: nil)
        workspace.moveGroup(firstId, before: firstId)

        #expect(afterMoveToFront == [thirdId, firstId, secondId])
        #expect(workspace.listGroups.map(\.groupId) == [firstId, secondId, thirdId])
    }

    @Test func membersMoveWithinTheirGroupOnly() {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1), into: nil)
        workspace.adopt(Self.window(2), into: groupId)
        workspace.adopt(Self.window(3), into: groupId)
        workspace.adopt(Self.window(9), into: nil)

        workspace.moveMember(WindowId(rawValue: 3), before: WindowId(rawValue: 1))
        let afterMoveToFront = workspace.listGroups[0].listMembers.map(\.windowId.rawValue)
        workspace.moveMember(WindowId(rawValue: 3), before: nil)
        workspace.moveMember(WindowId(rawValue: 1), before: WindowId(rawValue: 9))

        #expect(afterMoveToFront == [3, 1, 2])
        #expect(workspace.listGroups[0].listMembers.map(\.windowId.rawValue) == [1, 2, 3])
    }

    @Test func workspaceSurvivesAJsonRoundTrip() throws {
        var workspace = Workspace()
        let groupId = workspace.adopt(Self.window(1, title: "a"), into: nil)
        workspace.adopt(Self.window(2, title: "b"), into: groupId)
        workspace.activate(groupId, displacing: [])
        workspace.recordStack(of: groupId, frontToBack: [WindowId(rawValue: 2), WindowId(rawValue: 1)])
        workspace.rename(window: WindowId(rawValue: 2), to: "Notes")

        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))

        #expect(decoded == workspace)
    }

    @Test func updatingATitleReportsWhetherItChanged() {
        var workspace = Workspace()
        workspace.adopt(Self.window(1, title: "Draft"), into: nil)

        let isSameTitleChanged = workspace.updateTitle(of: WindowId(rawValue: 1), to: "Draft")
        let isNewTitleChanged = workspace.updateTitle(of: WindowId(rawValue: 1), to: "Final")
        let isUnmanagedChanged = workspace.updateTitle(of: WindowId(rawValue: 2), to: "Elsewhere")

        #expect(!isSameTitleChanged)
        #expect(isNewTitleChanged)
        #expect(workspace.listManagedWindows.first?.title == "Final")
        #expect(!isUnmanagedChanged)
    }
}
