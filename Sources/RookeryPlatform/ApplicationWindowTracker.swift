import ApplicationServices
import os
import RookeryCore

/// Tracks the managed windows of one application through Accessibility, on a thread of its own so that an
/// unresponsive application stalls only its own tracker.
final class ApplicationWindowTracker: @unchecked Sendable {
    // Every mutable property is touched only on `thread`.
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "tracker")
    /// Coalesce bursts such as terminals changing their titles while output streams in.
    private static let refreshDebounce: TimeInterval = 0.25
    private static let discoveryRetryInterval = Duration.seconds(30)
    private static let discoverySliceSize: UInt64 = 10_000
    private static let frameTolerance: CGFloat = 2
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
    private static let setFocusNotifications: Set<String> = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
    ]
    private static let setServerListChangingNotifications: Set<String> = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]
    private static let setWindowStateNotifications: Set<String> = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    let application: RunningApplication
    private let thread: RunLoopThread
    private let onSnapshot: @Sendable (ApplicationSnapshot) -> Void
    private let onFocus: @Sendable (WindowId) -> Void
    private let root: AccessibilityElement
    private var observer: AXObserver?
    private var isApplicationObserved = false
    private var isRefreshScheduled = false
    private var isWindowRefreshScheduled = false
    private var isServerListStale = true
    private var setManagedIds: Set<WindowId> = []
    private var mapElements: [WindowId: AccessibilityElement] = [:]
    /// The managed windows whose own notifications reported a change since they were last read.
    private var setPendingWindowIds: Set<WindowId> = []
    private var setObservedIds: Set<WindowId> = []
    private var mapServerWindows: [WindowId: WindowServerWindow] = [:]
    private var mapLastProbeTimes: [WindowId: ContinuousClock.Instant] = [:]
    /// The next element identifier to probe while a discovery is running; nil when none is.
    private var discoveryCursor: UInt64?
    private var setDiscoveryTargetIds: Set<WindowId> = []
    private var discoveryStartTime = ContinuousClock.now

    /// - Parameters:
    ///   - application: the application to track
    ///   - onSnapshot: receives the managed windows' state after every change, on the tracker's thread
    ///   - onFocus: receives a managed window that the application has just focused, on the tracker's thread
    init(
        application: RunningApplication,
        onSnapshot: @escaping @Sendable (ApplicationSnapshot) -> Void,
        onFocus: @escaping @Sendable (WindowId) -> Void
    ) {
        self.application = application
        self.onSnapshot = onSnapshot
        self.onFocus = onFocus
        self.root = AccessibilityElement.application(processId: application.processId)
        self.thread = RunLoopThread(name: "Rookery.tracker.\(application.processId)")
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

    /// Move and resize a managed window, then read back where it ended up, since applications may
    /// constrain the frame.
    ///
    /// - Parameters:
    ///   - frame: the frame in global screen coordinates, origin at the top-left of the main display
    ///   - windowId: the window
    /// - Returns: the frame after the move, or nil if the window could not be moved
    func applyFrame(_ frame: CGRect, to windowId: WindowId) async -> CGRect? {
        let result = await thread.run { [self] () -> CGRect? in
            guard let element = mapElements[windowId] ?? listedElement(of: windowId) else {
                return nil
            }
            let isEnhanced = (try? root.isEnhancedUserInterface()) == true
            if isEnhanced {
                try? root.applyEnhancedUserInterface(false)
            }
            defer {
                if isEnhanced {
                    try? root.applyEnhancedUserInterface(true)
                }
            }
            do {
                try element.applyFrame(frame)
                var landedFrame = try element.frame()
                if !Self.isClose(landedFrame, to: frame) {
                    try element.applyFrame(frame)
                    landedFrame = try element.frame()
                }
                return landedFrame
            } catch let error as AccessibilityError where error.isInvalidElement {
                mapElements[windowId] = nil
                setObservedIds.remove(windowId)
                Self.logger.info("window \(windowId.rawValue) is gone from Accessibility")
                return nil
            } catch {
                Self.logger.error("cannot move window \(windowId.rawValue): \(error, privacy: .public)")
                return nil
            }
        }
        return result ?? nil
    }

    /// Where a managed window is, as Accessibility reports it. Unlike the window server's list, this is not
    /// skewed while a Space transition animates the window.
    func frame(of windowId: WindowId) async -> CGRect? {
        await thread.run { [self] in
            try? mapElements[windowId]?.frame()
        } ?? nil
    }

    /// The element of a managed window the tracker has lost, if the application lists it again, as it does
    /// once a window it ordered out comes back.
    private func listedElement(of windowId: WindowId) -> AccessibilityElement? {
        guard
            setManagedIds.contains(windowId),
            let element = ((try? root.windows()) ?? []).first(where: { (try? $0.windowId()) == windowId })
        else {
            return nil
        }
        mapElements[windowId] = element
        return element
    }

    /// Whether two frames match within the rounding applications apply.
    private static func isClose(_ lhs: CGRect, to rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= frameTolerance
            && abs(lhs.minY - rhs.minY) <= frameTolerance
            && abs(lhs.width - rhs.width) <= frameTolerance
            && abs(lhs.height - rhs.height) <= frameTolerance
    }

    /// Bring a managed window to the front, restoring it from the Dock first, and give it keyboard focus.
    ///
    /// - Returns: whether the window was raised
    func raise(_ windowId: WindowId) async -> Bool {
        await thread.run { [self] () -> Bool in
            guard let element = mapElements[windowId] ?? listedElement(of: windowId) else {
                return false
            }
            do {
                if try element.isMinimized() {
                    try element.applyMinimized(false)
                }
                try element.raise()
                try? root.focusWindow(element)
                return true
            } catch {
                Self.logger.error("cannot raise window \(windowId.rawValue): \(error, privacy: .public)")
                return false
            }
        } ?? false
    }

    /// Minimize a managed window to the Dock, or restore it from there where it was last placed.
    ///
    /// - Returns: whether the window took the request
    func applyMinimized(_ isMinimized: Bool, to windowId: WindowId) async -> Bool {
        await thread.run { [self] () -> Bool in
            guard let element = mapElements[windowId] ?? listedElement(of: windowId) else {
                return false
            }
            do {
                if try element.isMinimized() != isMinimized {
                    try element.applyMinimized(isMinimized)
                }
                return true
            } catch {
                Self.logger.error("cannot minimize window \(windowId.rawValue): \(error, privacy: .public)")
                return false
            }
        } ?? false
    }

    /// Whether a managed window is minimized to the Dock.
    func isMinimized(_ windowId: WindowId) async -> Bool {
        await thread.run { [self] in
            (try? mapElements[windowId]?.isMinimized()) == true
        } ?? false
    }

    /// Whether a managed window is in native full screen.
    func isFullscreen(_ windowId: WindowId) async -> Bool {
        await thread.run { [self] in
            (try? mapElements[windowId]?.isFullscreen()) == true
        } ?? false
    }

    /// Ask a managed window to leave native full screen; the transition finishes asynchronously.
    ///
    /// - Returns: whether the request was accepted
    func requestExitFullscreen(_ windowId: WindowId) async -> Bool {
        await thread.run { [self] in
            guard let element = mapElements[windowId] else {
                return false
            }
            return (try? element.applyFullscreen(false)) != nil
        } ?? false
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
        let error = AXObserverCreate(application.processId, { _, element, notification, context in
            guard let context else {
                return
            }
            Unmanaged<ApplicationWindowTracker>.fromOpaque(context)
                .takeUnretainedValue()
                .handle(notification: notification as String, element: element)
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

    /// The managed window the application has focused.
    func focusedWindowId() async -> WindowId? {
        await thread.run { [self] in
            focusedManagedWindowId()
        } ?? nil
    }

    private func focusedManagedWindowId() -> WindowId? {
        guard
            let windowId = try? root.focusedWindow()?.windowId(),
            setManagedIds.contains(windowId)
        else {
            return nil
        }
        return windowId
    }

    private func handle(notification: String, element: AXUIElement) {
        if Self.setFocusNotifications.contains(notification), let windowId = focusedManagedWindowId() {
            onFocus(windowId)
            return
        }
        if Self.setServerListChangingNotifications.contains(notification) {
            isServerListStale = true
            scheduleRefresh()
            return
        }
        guard
            Self.setWindowStateNotifications.contains(notification),
            let windowId = try? AccessibilityElement(element: element).windowId(),
            setManagedIds.contains(windowId)
        else {
            return
        }
        // A notification can come from an element inside the window, so the window is read through its own element.
        guard mapElements[windowId] != nil else {
            scheduleRefresh()
            return
        }
        setPendingWindowIds.insert(windowId)
        guard !isWindowRefreshScheduled else {
            return
        }
        isWindowRefreshScheduled = true
        thread.perform(after: Self.refreshDebounce) { [self] in
            isWindowRefreshScheduled = false
            refreshPendingWindows()
        }
    }

    private func scheduleRefresh() {
        guard !isRefreshScheduled else {
            return
        }
        isRefreshScheduled = true
        thread.perform(after: Self.refreshDebounce) { [self] in
            isRefreshScheduled = false
            refresh()
        }
    }

    /// Publish only the windows whose own notifications reported a change.
    private func refreshPendingWindows() {
        let setWindowIds = setPendingWindowIds
        setPendingWindowIds.removeAll(keepingCapacity: true)
        var listWindows: [WindowRecord] = []
        for windowId in setWindowIds where setManagedIds.contains(windowId) {
            guard let element = mapElements[windowId] else {
                continue
            }
            do {
                listWindows.append(try record(windowId: windowId, element: element))
            } catch let error as AccessibilityError where error.isInvalidElement {
                mapElements[windowId] = nil
                setObservedIds.remove(windowId)
            } catch {
                continue
            }
        }
        guard !listWindows.isEmpty else {
            return
        }
        onSnapshot(ApplicationSnapshot(application: application, listWindows: listWindows))
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
            updateServerWindows(
                WindowServer.listWindows(orderedWindowIds: setManagedIds)
                    .filter { $0.processId == application.processId }
            )
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
        discoverMissingWindows()
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

    /// Start looking up managed windows that `kAXWindowsAttribute` does not list, as happens for windows on
    /// other Spaces. The probe runs in slices queued behind other work, so window actions never wait long.
    private func discoverMissingWindows() {
        guard discoveryCursor == nil else {
            return
        }
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
            return
        }
        for windowId in setTargetIds {
            mapLastProbeTimes[windowId] = now
        }
        setDiscoveryTargetIds = setTargetIds
        discoveryCursor = AccessibilityElement.remoteElementIdRange.lowerBound
        discoveryStartTime = now
        thread.perform { [self] in
            continueDiscovery()
        }
    }

    private func continueDiscovery() {
        guard let cursor = discoveryCursor else {
            return
        }
        let setTargetIds = setDiscoveryTargetIds.filter { setManagedIds.contains($0) && mapElements[$0] == nil }
        let upperBound = min(cursor + Self.discoverySliceSize, AccessibilityElement.remoteElementIdRange.upperBound)
        let mapFound = setTargetIds.isEmpty ? [:] : AccessibilityElement.discoverWindows(
            processId: application.processId,
            setTargetIds: setTargetIds,
            in: cursor..<upperBound
        )
        mapElements.merge(mapFound) { _, found in found }
        if !mapFound.isEmpty {
            publishSnapshot()
        }
        let isFinished = setTargetIds.count == mapFound.count
            || upperBound == AccessibilityElement.remoteElementIdRange.upperBound
        guard isFinished else {
            discoveryCursor = upperBound
            thread.perform { [self] in
                continueDiscovery()
            }
            return
        }
        Self.logger.info("""
            discovery for \(self.application.name, privacy: .public): \(setTargetIds.count - mapFound.count) of \
            \(self.setDiscoveryTargetIds.count) not found after \(ContinuousClock.now - self.discoveryStartTime, privacy: .public)
            """)
        discoveryCursor = nil
        setDiscoveryTargetIds = []
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
