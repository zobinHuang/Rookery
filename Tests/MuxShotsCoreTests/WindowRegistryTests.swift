import CoreGraphics
import MuxShotsCore
import Testing

struct WindowRegistryTests {
    static let chrome = RunningApplication(processId: 100, bundleId: "com.google.Chrome", name: "Google Chrome")
    static let code = RunningApplication(processId: 200, bundleId: "com.microsoft.VSCode", name: "Code")

    static func window(_ rawId: UInt32, of application: RunningApplication, title: String = "") -> WindowRecord {
        WindowRecord(
            windowId: WindowId(rawValue: rawId),
            application: application,
            title: title,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            isFullscreen: false,
            isOnScreen: true
        )
    }

    @Test func firstSnapshotAddsEveryWindow() {
        var registry = WindowRegistry()
        let listChanges = registry.apply(ApplicationSnapshot(
            application: Self.chrome,
            listWindows: [Self.window(1, of: Self.chrome), Self.window(2, of: Self.chrome)]
        ))

        #expect(listChanges == [
            .added(window: Self.window(1, of: Self.chrome)),
            .added(window: Self.window(2, of: Self.chrome)),
        ])
        #expect(registry.listWindows.count == 2)
    }

    @Test func snapshotReportsOnlyWhatChanged() {
        var registry = WindowRegistry()
        _ = registry.apply(ApplicationSnapshot(
            application: Self.chrome,
            listWindows: [Self.window(1, of: Self.chrome), Self.window(2, of: Self.chrome)]
        ))

        let listChanges = registry.apply(ApplicationSnapshot(
            application: Self.chrome,
            listWindows: [Self.window(2, of: Self.chrome, title: "Inbox"), Self.window(3, of: Self.chrome)]
        ))

        #expect(listChanges == [
            .removed(windowId: WindowId(rawValue: 1)),
            .updated(window: Self.window(2, of: Self.chrome, title: "Inbox")),
            .added(window: Self.window(3, of: Self.chrome)),
        ])
    }

    @Test func snapshotLeavesOtherApplicationsAlone() {
        var registry = WindowRegistry()
        _ = registry.apply(ApplicationSnapshot(application: Self.chrome, listWindows: [Self.window(1, of: Self.chrome)]))
        _ = registry.apply(ApplicationSnapshot(application: Self.code, listWindows: [Self.window(2, of: Self.code)]))

        let listChanges = registry.apply(ApplicationSnapshot(application: Self.chrome, listWindows: []))

        #expect(listChanges == [.removed(windowId: WindowId(rawValue: 1))])
        #expect(registry.window(withId: WindowId(rawValue: 2)) != nil)
    }

    @Test func removingAnApplicationRemovesItsWindows() {
        var registry = WindowRegistry()
        _ = registry.apply(ApplicationSnapshot(
            application: Self.code,
            listWindows: [Self.window(5, of: Self.code), Self.window(4, of: Self.code)]
        ))

        let listChanges = registry.removeApplication(processId: Self.code.processId)

        #expect(listChanges == [.removed(windowId: WindowId(rawValue: 4)), .removed(windowId: WindowId(rawValue: 5))])
        #expect(registry.listWindows.isEmpty)
    }

    @Test func windowsAreOrderedByApplicationThenId() {
        var registry = WindowRegistry()
        _ = registry.apply(ApplicationSnapshot(
            application: Self.chrome,
            listWindows: [Self.window(9, of: Self.chrome), Self.window(3, of: Self.chrome)]
        ))
        _ = registry.apply(ApplicationSnapshot(application: Self.code, listWindows: [Self.window(7, of: Self.code)]))

        #expect(registry.listWindows.map(\.windowId.rawValue) == [7, 3, 9])
    }
}
