import Foundation
import MuxShotsControl
import MuxShotsCore
import MuxShotsPlatform
import Network
import os

/// Serves `muxctl` requests on the control socket.
final class ControlServer: Sendable {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "control")

    private let tracker: WindowTracker
    private let workspaceController: WorkspaceController
    private let stages: StageCoordinator
    private let mixerController: MixerController
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MuxShots.control.listener")

    /// Bind the control socket, replacing a stale one left by an earlier run.
    ///
    /// - Parameters:
    ///   - tracker: the source of observed window state
    ///   - workspaceController: the owner of the groups
    ///   - stages: the stages to open and close
    ///   - mixerController: the mixer to report and adjust
    init(
        tracker: WindowTracker,
        workspaceController: WorkspaceController,
        stages: StageCoordinator,
        mixerController: MixerController
    ) throws {
        let url = ControlSocket.url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: url.path)
        self.listener = try NWListener(using: parameters)
        self.tracker = tracker
        self.workspaceController = workspaceController
        self.stages = stages
        self.mixerController = mixerController
    }

    /// Start accepting connections.
    func start() {
        listener.newConnectionHandler = { [tracker, workspaceController, stages, mixerController] connection in
            let control = ControlConnection(accepted: connection)
            Task {
                await Self.serve(
                    control,
                    tracker: tracker,
                    workspaceController: workspaceController,
                    stages: stages,
                    mixerController: mixerController
                )
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Self.logger.error("control listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
    }

    /// Stop accepting connections and remove the socket.
    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(at: ControlSocket.url)
    }

    private static func serve(
        _ connection: ControlConnection,
        tracker: WindowTracker,
        workspaceController: WorkspaceController,
        stages: StageCoordinator,
        mixerController: MixerController
    ) async {
        defer { connection.cancel() }
        do {
            guard let request = try await connection.receive(ControlRequest.self) else {
                return
            }
            switch request {
            case .list:
                try await connection.send(ControlMessage.workspace(
                    listGroups: await workspaceController.workspace.listGroups,
                    setActiveGroupIds: await workspaceController.workspace.setActiveGroupIds,
                    listWindows: await tracker.listWindows()
                ))
            case .watch:
                let changes = await tracker.changes()
                try await connection.send(ControlMessage.workspace(
                    listGroups: await workspaceController.workspace.listGroups,
                    setActiveGroupIds: await workspaceController.workspace.setActiveGroupIds,
                    listWindows: await tracker.listWindows()
                ))
                for await change in changes {
                    try await connection.send(ControlMessage.change(change))
                }
            case .manage(let windowId, let groupNameOrPosition):
                guard let window = WindowServer.window(withId: windowId) else {
                    try await connection.send(ControlMessage.failure(message: "no window \(windowId)"))
                    return
                }
                var groupId: GroupId?
                if let groupNameOrPosition {
                    guard let group = await workspaceController.workspace.group(named: groupNameOrPosition) else {
                        try await connection.send(ControlMessage.failure(message: "no group \(groupNameOrPosition)"))
                        return
                    }
                    groupId = group.groupId
                }
                await workspaceController.adopt(windowId, processId: window.processId, into: groupId)
                try await connection.send(ControlMessage.done)
            case .release(let windowId):
                await workspaceController.release(windowId)
                try await connection.send(ControlMessage.done)
            case .act(let action, let windowId):
                do {
                    try await workspaceController.perform(action, on: windowId)
                    try await connection.send(ControlMessage.done)
                } catch let error as WindowActionError {
                    try await connection.send(ControlMessage.failure(message: error.description))
                }
            case .switchGroup(let nameOrPosition):
                let groupId: GroupId?
                if let nameOrPosition {
                    guard let group = await workspaceController.workspace.group(named: nameOrPosition) else {
                        try await connection.send(ControlMessage.failure(message: "no group \(nameOrPosition)"))
                        return
                    }
                    groupId = group.groupId
                } else {
                    groupId = nil
                }
                await workspaceController.switchTo(groupId)
                try await connection.send(ControlMessage.done)
            case .stage(let isOpen):
                await MainActor.run {
                    if isOpen {
                        stages.openOnCursorDisplay()
                    } else {
                        stages.closeAll()
                    }
                }
                try await connection.send(ControlMessage.done)
            case .mixer:
                try await connection.send(await mixerMessage(mixerController))
            case .mixerApply(.application(let bundleId), let settings):
                await mixerController.apply(settings, to: bundleId)
                try await connection.send(await mixerMessage(mixerController))
            case .mixerApply(.browserTab(let sessionId, let tabId), let settings):
                await mixerController.browserTabs.update(BrowserTabKey(sessionId: sessionId, tabId: tabId)) { $0 = settings }
                try await connection.send(await mixerMessage(mixerController))
            case .browserSession:
                await serveBrowser(connection, browserTabs: mixerController.browserTabs)
            }
        } catch {
            logger.info("control session ended: \(error)")
        }
    }

    /// Pass a browser extension's reports to the tab mixer and its commands back, until it disconnects.
    private static func serveBrowser(_ connection: ControlConnection, browserTabs: BrowserTabMixer) async {
        let session = await browserTabs.openSession()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await relayBrowserEvents(from: connection, to: browserTabs, sessionId: session.sessionId)
            }
            group.addTask {
                await relayBrowserCommands(session.commands, to: connection)
            }
            await group.next()
            group.cancelAll()
        }
        await browserTabs.closeSession(session.sessionId)
    }

    private static func relayBrowserEvents(
        from connection: ControlConnection,
        to browserTabs: BrowserTabMixer,
        sessionId: Int
    ) async {
        let decoder = BrowserWire.makeDecoder()
        do {
            while let event = try await connection.receive(BrowserEvent.self, decoder: decoder) {
                await browserTabs.receive(event, in: sessionId)
            }
        } catch {
            logger.info("browser session ended: \(error)")
        }
    }

    private static func relayBrowserCommands(_ commands: AsyncStream<BrowserCommand>, to connection: ControlConnection) async {
        let encoder = BrowserWire.makeEncoder()
        do {
            for await command in commands {
                try await connection.send(command, encoder: encoder)
            }
        } catch {
            logger.info("browser session ended: \(error)")
        }
    }

    @MainActor
    private static func mixerMessage(_ mixerController: MixerController) -> ControlMessage {
        let listTracks = mixerController.listTracks
        let mapLevels = Dictionary(uniqueKeysWithValues: listTracks.filter(\.isCapturing).map { track in
            let levels = mixerController.takeLevels(of: track.bundleId)
            return (track.bundleId, max(levels.left, levels.right))
        })
        let browserTabs = mixerController.browserTabs
        let listTabs = browserTabs.listTabs.map { browserTab in
            let levels = browserTabs.mapLevels[browserTab.key] ?? MixerLevels()
            return MixerTabStatus(
                sessionId: browserTab.key.sessionId,
                tab: browserTab.tab,
                settings: browserTabs.settings(of: browserTab.key),
                level: max(levels.left, levels.right)
            )
        }
        return .mixer(listTracks: listTracks, mapLevels: mapLevels, listTabs: listTabs)
    }
}
