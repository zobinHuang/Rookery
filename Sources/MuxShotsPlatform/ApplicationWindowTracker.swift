import ApplicationServices
import MuxShotsCore
import os

/// Tracks the managed windows of one application through Accessibility, on a thread of its own so that an
/// unresponsive application stalls only its own tracker.
final class ApplicationWindowTracker: @unchecked Sendable {
    // Every mutable property is touched only on `thread`.
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "tracker")
    private static let refreshDebounce: TimeInterval = 0.05
    private static let discoveryRetryInterval = Duration.seconds(30)
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
    private static let setServerListChangingNotifications: Set<String> = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
    ]

    let application: RunningApplication
    private let thread: RunLoopThread
    private let onSnapshot: @Sendable (ApplicationSnapshot) -> Void
    private let root: AccessibilityElement
    private var observer: AXObserver?
    private var isApplicationObserved = false
    private var isRefreshScheduled = false
    private var isServerListStale = true
    private var setManagedIds: Set<WindowId> = []
    private var mapElements: [WindowId: AccessibilityElement] = [:]
    private var setObservedIds: Set<WindowId> = []
    private var mapServerWindows: [WindowId: WindowServerWindow] = [:]
    private var mapLastProbeTimes: [WindowId: ContinuousClock.Instant] = [:]

    /// - Parameters:
    ///   - application: the application to track
    ///   - onSnapshot: receives the managed windows' state after every change, on the tracker's thread
    init(application: RunningApplication, onSnapshot: @escaping @Sendable (ApplicationSnapshot) -> Void) {
        self.application = application
        self.onSnapshot = onSnapshot
        self.root = AccessibilityElement.application(processId: application.processId)
        self.thread = RunLoopThread(name: "MuxShots.tracker.\(application.processId)")
    }

    /// Start observing the application.
    func start() {
        thread.startAndWait()
        thread.perform { [self] in
            createObserver()
        }
    }

    /// Stop observing and exit the tracker's thread.
    func stop() {
        thread.perform { [self] in
            removeObserver()
        }
        thread.shutdown()
    }

    /// Start tracking one of the application's windows.
    func manage(_ windowId: WindowId) {
        thread.perform { [self] in
            setManagedIds.insert(windowId)
            isServerListStale = true
            refresh()
        }
    }

    /// Stop tracking one of the application's windows.
    func release(_ windowId: WindowId) {
        thread.perform { [self] in
            setManagedIds.remove(windowId)
            if let element = mapElements.removeValue(forKey: windowId), setObservedIds.remove(windowId) != nil {
                unobserve(element, notifications: Self.listWindowNotifications)
            }
            mapLastProbeTimes[windowId] = nil
        }
    }

    /// Move and resize a managed window.
    ///
    /// - Parameters:
    ///   - windowId: the window
    ///   - frame: the frame in global screen coordinates, origin at the top-left of the main display
    func applyFrame(_ frame: CGRect, to windowId: WindowId) {
        thread.perform { [self] in
            guard let element = mapElements[windowId] else {
                return
            }
            let isEnhanced = (try? root.isEnhancedUserInterface()) == true
            if isEnhanced {
                try? root.applyEnhancedUserInterface(false)
            }
            do {
                try element.applyFrame(frame)
            } catch {
                Self.logger.error("cannot move window \(windowId.rawValue): \(error, privacy: .public)")
            }
            if isEnhanced {
                try? root.applyEnhancedUserInterface(true)
            }
        }
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

    private func unobserve(_ element: AccessibilityElement, notifications listNotifications: [String]) {
        guard let observer else {
            return
        }
        for notification in listNotifications {
            AXObserverRemoveNotification(observer, element.element, notification as CFString)
        }
    }

    private func handle(notification: String) {
        if Self.setServerListChangingNotifications.contains(notification) {
            isServerListStale = true
        }
        guard !isRefreshScheduled else {
            return
        }
        isRefreshScheduled = true
        thread.perform(after: Self.refreshDebounce) { [self] in
            isRefreshScheduled = false
            refresh()
        }
    }

    private func updateServerWindows(_ listServerWindows: [WindowServerWindow]) {
        mapServerWindows = Dictionary(uniqueKeysWithValues: listServerWindows.map { ($0.windowId, $0) })
        isServerListStale = false
    }

    private func refresh() {
        guard !setManagedIds.isEmpty else {
            return
        }
        if isServerListStale {
            updateServerWindows(WindowServer.listWindows().filter { $0.processId == application.processId })
        }
        if !isApplicationObserved {
            isApplicationObserved = observe(root, notifications: Self.listApplicationNotifications)
        }
        for element in (try? root.windows()) ?? [] {
            if let windowId = try? element.windowId(), setManagedIds.contains(windowId) {
                mapElements[windowId] = element
            }
        }

        publishSnapshot()
        if discoverMissingWindows() {
            publishSnapshot()
        }
    }

    /// Report every managed window the tracker can see, and those that have closed.
    private func publishSnapshot() {
        let listClosedIds = setManagedIds.filter { mapServerWindows[$0] == nil }
        for windowId in listClosedIds {
            setManagedIds.remove(windowId)
            mapElements[windowId] = nil
            setObservedIds.remove(windowId)
            mapLastProbeTimes[windowId] = nil
        }

        var listWindows: [WindowRecord] = []
        for (windowId, element) in mapElements {
            do {
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
        onSnapshot(ApplicationSnapshot(
            application: application,
            listWindows: listWindows,
            listClosedIds: Array(listClosedIds)
        ))
    }

    /// Look up managed windows that `kAXWindowsAttribute` does not list, as happens for windows on other Spaces.
    ///
    /// - Returns: whether any window was found
    private func discoverMissingWindows() -> Bool {
        let now = ContinuousClock.now
        let setTargetIds = setManagedIds.filter { windowId in
            guard
                mapElements[windowId] == nil,
                mapServerWindows[windowId]?.isOrderedIn == true
            else {
                return false
            }
            guard let lastProbeTime = mapLastProbeTimes[windowId] else {
                return true
            }
            return now - lastProbeTime >= Self.discoveryRetryInterval
        }
        guard !setTargetIds.isEmpty else {
            return false
        }
        for windowId in setTargetIds {
            mapLastProbeTimes[windowId] = now
        }
        let mapFound = AccessibilityElement.discoverWindows(
            processId: application.processId,
            setTargetIds: setTargetIds
        )
        Self.logger.info("""
            discovery for \(self.application.name, privacy: .public): found \(mapFound.count) of \(setTargetIds.count) \
            in \(ContinuousClock.now - now, privacy: .public)
            """)
        mapElements.merge(mapFound) { _, found in found }
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
