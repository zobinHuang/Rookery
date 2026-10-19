import ApplicationServices
import MuxShotsCore
import os

/// Tracks one application's windows through Accessibility, on a thread of its own so that an unresponsive
/// application stalls only its own tracker.
final class ApplicationWindowTracker: @unchecked Sendable {
    // Every mutable property is touched only on `thread`.
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "tracker")
    private static let refreshDebounce: TimeInterval = 0.05
    private static let listApplicationNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]
    private static let listWindowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    let application: RunningApplication
    private let thread: RunLoopThread
    private let onSnapshot: @Sendable (ApplicationSnapshot) -> Void
    private let root: AccessibilityElement
    private var observer: AXObserver?
    private var isApplicationObserved = false
    private var isRefreshScheduled = false
    private var isServerListStale = false
    private var mapElements: [WindowId: AccessibilityElement] = [:]
    private var setObservedIds: Set<WindowId> = []
    private var mapServerWindows: [WindowId: WindowServerWindow] = [:]
    /// Window-server windows that are not windows MuxShots manages, so they are never probed again.
    private var setUnmanagedIds: Set<WindowId> = []

    /// - Parameters:
    ///   - application: the application to track
    ///   - onSnapshot: receives the application's complete window set after every change, on the tracker's thread
    init(application: RunningApplication, onSnapshot: @escaping @Sendable (ApplicationSnapshot) -> Void) {
        self.application = application
        self.onSnapshot = onSnapshot
        self.root = AccessibilityElement.application(processId: application.processId)
        self.thread = RunLoopThread(name: "MuxShots.tracker.\(application.processId)")
    }

    /// Start observing the application and take a first snapshot.
    func start() {
        thread.startAndWait()
        thread.perform { [self] in
            createObserver()
            refresh()
        }
    }

    /// Stop observing and exit the tracker's thread.
    func stop() {
        thread.perform { [self] in
            removeObserver()
        }
        thread.shutdown()
    }

    /// Refresh against the window server's current list of this application's windows.
    func reconcile(listServerWindows: [WindowServerWindow]) {
        thread.perform { [self] in
            updateServerWindows(listServerWindows)
            refresh()
        }
    }

    private func createObserver() {
        var created: AXObserver?
        let error = AXObserverCreate(application.processId, { _, _, notification, context in
            guard let context else {
                return
            }
            Unmanaged<ApplicationWindowTracker>.fromOpaque(context)
                .takeUnretainedValue()
                .handle(notification: notification as String)
        }, &created)
        guard error == .success, let created else {
            return
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    private func removeObserver() {
        guard let observer else {
            return
        }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    /// Register for a set of notifications on one element.
    ///
    /// - Returns: whether every registration succeeded or was already in place
    private func observe(_ element: AccessibilityElement, notifications listNotifications: [String]) -> Bool {
        guard let observer else {
            return false
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var isComplete = true
        for notification in listNotifications {
            let error = AXObserverAddNotification(observer, element.element, notification as CFString, context)
            if error != .success && error != .notificationAlreadyRegistered {
                isComplete = false
            }
        }
        return isComplete
    }

    private func handle(notification: String) {
        if notification == kAXWindowCreatedNotification {
            isServerListStale = true
        }
        guard !isRefreshScheduled else {
            return
        }
        isRefreshScheduled = true
        thread.perform(after: Self.refreshDebounce) { [self] in
            isRefreshScheduled = false
            if isServerListStale {
                isServerListStale = false
                updateServerWindows(WindowServer.listWindows().filter { $0.processId == application.processId })
            }
            refresh()
        }
    }

    private func updateServerWindows(_ listServerWindows: [WindowServerWindow]) {
        mapServerWindows = Dictionary(uniqueKeysWithValues: listServerWindows.map { ($0.windowId, $0) })
    }

    private func refresh() {
        if !isApplicationObserved {
            isApplicationObserved = observe(root, notifications: Self.listApplicationNotifications)
        }

        guard let listListed = try? root.windows() else {
            return
        }
        for element in listListed {
            if let windowId = try? element.windowId() {
                mapElements[windowId] = element
            }
        }
        publishSnapshot()
        if discoverUnlistedWindows() {
            publishSnapshot()
        }
    }

    private func publishSnapshot() {
        var listWindows: [WindowRecord] = []
        for (windowId, element) in mapElements {
            do {
                guard try element.isWindow else {
                    mapElements[windowId] = nil
                    continue
                }
                listWindows.append(try record(windowId: windowId, element: element))
                if !setObservedIds.contains(windowId) && observe(element, notifications: Self.listWindowNotifications) {
                    setObservedIds.insert(windowId)
                }
            } catch let error as AccessibilityError where error.isInvalidElement {
                mapElements[windowId] = nil
                setObservedIds.remove(windowId)
            } catch {
                continue
            }
        }
        onSnapshot(ApplicationSnapshot(application: application, listWindows: listWindows))
    }

    /// Look up windows that are shown on another Space, which `kAXWindowsAttribute` does not list;
    /// each identifier is probed once.
    ///
    /// - Returns: whether any window was found
    private func discoverUnlistedWindows() -> Bool {
        setUnmanagedIds.formIntersection(mapServerWindows.keys)
        let listUnlisted = mapServerWindows.values.filter { window in
            window.isOrderedIn
                && mapElements[window.windowId] == nil
                && !setUnmanagedIds.contains(window.windowId)
        }
        guard !listUnlisted.isEmpty else {
            return false
        }
        let setCurrentSpaceIds = WindowServer.currentSpaceIds()
        let setTargetIds = Set(listUnlisted.map(\.windowId).filter { windowId in
            WindowServer.spaceIds(ofWindow: windowId).isDisjoint(with: setCurrentSpaceIds)
        })
        guard !setTargetIds.isEmpty else {
            return false
        }
        let startTime = ContinuousClock.now
        let mapFound = AccessibilityElement.discoverWindows(
            processId: application.processId,
            setTargetIds: setTargetIds
        )
        Self.logger.info("""
            discovery for \(self.application.name, privacy: .public): found \(mapFound.count) of \(setTargetIds.count) \
            in \(ContinuousClock.now - startTime, privacy: .public), targets \(setTargetIds.map(\.rawValue).sorted(), privacy: .public)
            """)
        mapElements.merge(mapFound) { _, found in found }
        setUnmanagedIds.formUnion(setTargetIds.subtracting(mapFound.keys))
        return !mapFound.isEmpty
    }

    private func record(windowId: WindowId, element: AccessibilityElement) throws -> WindowRecord {
        WindowRecord(
            windowId: windowId,
            application: application,
            title: try element.title(),
            frame: try element.frame(),
            isMinimized: try element.isMinimized(),
            isFullscreen: try element.isFullscreen(),
            isOnScreen: mapServerWindows[windowId]?.isOnScreen ?? false
        )
    }
}
