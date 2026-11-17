import AppKit
import Observation
import os
import RookeryCore
import RookeryPlatform

/// One row the launcher offers: an application, opened, or brought forward on its stage when Rookery
/// manages its windows; a page of Rookery's; the text typed, asked of Raven; or a conversation with Raven,
/// to ask on in.
enum LauncherItem: Identifiable {
    case application(InstalledApplication, groupName: String?)
    case page(SwitcherEntry)
    case askRaven(String)
    case conversation(RavenConversation)

    var id: String {
        switch self {
        case .application(let application, _): "app:\(application.id)"
        case .page(let entry): "page:\(entry.id)"
        case .askRaven: "ask"
        case .conversation(let conversation): "conversation:\(conversation.id)"
        }
    }
}

/// What the launcher shows: what is typed, the rows it finds, the one chosen, the conversation the next
/// request goes to, and the conversation it shows once Raven is asked.
@MainActor
@Observable
final class LauncherModel {
    var isVisible = false
    var query = ""
    var listItems: [LauncherItem] = []
    var selectedIndex = 0
    /// The conversation a request goes to, as a tag before what is typed; nil to begin one.
    var targetConversationId: String?
    /// The conversation the launcher shows in place of its rows once Raven is asked; nil for the rows.
    var shownConversationId: String?
    /// Changes with every request sent, to bring the conversation's end into view.
    var sendToken = 0
    var problem: String?
    /// The theme the user chose for Rookery; nil to follow the system.
    var chosenTheme: Theme?
}

/// The launcher, opened with ⌘Space: a box to find an application or one of Rookery's pages and open it,
/// or to ask Raven, with the latest conversations with Raven under it to ask on in; once Raven is asked it
/// shows the conversation, Raven's answer coming in, in place of the rows.
@MainActor
final class LauncherController {
    nonisolated private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "launcher")
    /// The most rows of each kind shown for a query.
    private static let applicationLimit = 6
    private static let pageLimit = 3
    private static let conversationLimit = 4
    /// The conversations shown before anything is typed.
    private static let recentConversationLimit = 8
    /// How long the list of applications is kept before it is read again.
    private static let catalogLifetime: TimeInterval = 60
    /// How much each earlier opening of an application raises it among matches as good, up to a limit.
    private static let useBoost = 12
    private static let useBoostLimit = 120
    private static let usesKey = "launcherUses"
    static let panelSize = CGSize(width: 680, height: 600)
    /// How far below the top of the screen the launcher's box sits, as a share of the screen's height.
    private static let topShare: CGFloat = 0.2
    /// How long the blur behind the launcher takes to come and go.
    private static let backdropFade: TimeInterval = 0.18

    let model = LauncherModel()
    private let panel: LauncherPanel
    /// The blur over everything behind the launcher, on its display, which closes it when clicked.
    private let backdrop: NSPanel
    let fleetModel: FleetModel
    private let workspaceController: WorkspaceController
    private let preferences: Preferences
    private var listApplications: [InstalledApplication] = []
    private var catalogReadAt: Date?
    private var catalogTask: Task<Void, Never>?
    private var mapUses: [String: Int]
    private var resignObserver: (any NSObjectProtocol)?

    init(fleetModel: FleetModel, workspaceController: WorkspaceController, preferences: Preferences) {
        self.fleetModel = fleetModel
        self.workspaceController = workspaceController
        self.preferences = preferences
        mapUses = UserDefaults.standard.dictionary(forKey: Self.usesKey) as? [String: Int] ?? [:]
        panel = LauncherPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backdrop = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        backdrop.isOpaque = false
        backdrop.backgroundColor = .clear
        backdrop.hasShadow = false
        backdrop.level = .popUpMenu
        backdrop.alphaValue = 0
        backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let blur = LauncherBackdropView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        backdrop.contentView = blur
        panel.contentView = LauncherView.makeHostingView(controller: self)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    func stop() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        catalogTask?.cancel()
        panel.orderOut(nil)
        backdrop.orderOut(nil)
    }

    /// Open the launcher on the display under the pointer, or close it if it is open.
    func toggle() {
        model.isVisible ? hide() : show()
    }

    func show() {
        fleetModel.raven.loadIfNeeded()
        refreshCatalogIfStale()
        model.chosenTheme = preferences.theme
        panel.appearance = preferences.theme.map { NSAppearance(named: $0.appearanceName) } ?? nil
        model.query = ""
        model.problem = nil
        model.targetConversationId = nil
        model.shownConversationId = nil
        search()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(
                x: visible.midX - Self.panelSize.width / 2,
                y: visible.maxY - visible.height * Self.topShare - Self.panelSize.height
            ))
        }
        if let screen {
            backdrop.setFrame(screen.frame, display: false)
            (backdrop.contentView as? LauncherBackdropView)?.onClick = { [weak self] in
                self?.hide()
            }
            backdrop.alphaValue = 0
            backdrop.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.backdropFade
                backdrop.animator().alphaValue = 1
            }
        }
        panel.makeKeyAndOrderFront(nil)
        model.isVisible = true
    }

    func hide() {
        guard model.isVisible else {
            return
        }
        model.isVisible = false
        panel.orderOut(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.backdropFade
            backdrop.animator().alphaValue = 0
        } completionHandler: { [backdrop] in
            MainActor.assumeIsolated {
                if backdrop.alphaValue == 0 {
                    backdrop.orderOut(nil)
                }
            }
        }
    }

    // MARK: - Finding

    /// Find the rows for what is typed: the latest conversations when nothing is; else the applications,
    /// the pages, asking Raven, and the conversations it matches, each kind best first.
    func search() {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let listConversations = fleetModel.raven.conversations.listConversations
        guard !query.isEmpty else {
            model.listItems = listConversations.prefix(Self.recentConversationLimit).map { .conversation($0) }
            model.selectedIndex = 0
            return
        }
        var listItems: [LauncherItem] = []
        if model.targetConversationId == nil {
            let listApplicationMatches = listApplications.compactMap { application -> (InstalledApplication, Int)? in
                let score = max(
                    LauncherMatch.score(of: query, in: application.name) ?? 0,
                    LauncherMatch.score(of: query, in: application.alternateName) ?? 0
                )
                guard score > 0 else {
                    return nil
                }
                return (application, score + min((mapUses[application.id] ?? 0) * Self.useBoost, Self.useBoostLimit))
            }
            listItems += listApplicationMatches
                .sorted { $0.1 > $1.1 }
                .prefix(Self.applicationLimit)
                .map { .application($0.0, groupName: groupName(of: $0.0)) }
            let listPageMatches = workspaceController.pageEntries().compactMap { entry -> (SwitcherEntry, Int)? in
                LauncherMatch.score(of: query, in: entry.title).map { (entry, $0) }
            }
            listItems += listPageMatches.sorted { $0.1 > $1.1 }.prefix(Self.pageLimit).map { .page($0.0) }
        }
        listItems.append(.askRaven(query))
        if model.targetConversationId == nil {
            let listConversationMatches = listConversations.compactMap { conversation -> (RavenConversation, Int)? in
                LauncherMatch.score(of: query, in: conversation.title).map { (conversation, $0) }
            }
            listItems += listConversationMatches.sorted { $0.1 > $1.1 }.prefix(Self.conversationLimit).map { .conversation($0.0) }
        }
        model.listItems = listItems
        model.selectedIndex = 0
    }

    /// The group Rookery shows an application's windows in, if it manages any.
    private func groupName(of application: InstalledApplication) -> String? {
        guard let bundleId = application.bundleId else {
            return nil
        }
        return workspaceController.workspace.listGroups.first { group in
            group.listMembers.contains { $0.application.bundleId == bundleId }
        }?.name
    }

    private func refreshCatalogIfStale() {
        if let catalogReadAt, Date.now.timeIntervalSince(catalogReadAt) < Self.catalogLifetime {
            return
        }
        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            let listApplications = await Task.detached(priority: .userInitiated) {
                InstalledApplication.scan()
            }.value
            guard let self, !Task.isCancelled else {
                return
            }
            self.listApplications = listApplications
            catalogReadAt = .now
            if model.isVisible {
                search()
            }
        }
    }

    // MARK: - Choosing

    /// Move the chosen row up or down, wrapping around.
    func moveSelection(by step: Int) {
        let count = model.listItems.count
        guard count > 0 else {
            return
        }
        model.selectedIndex = ((model.selectedIndex + step) % count + count) % count
    }

    /// Act on the chosen row, or with the command key ask Raven whatever is chosen.
    func choose(isAskingRaven: Bool = false) {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.shownConversationId != nil || isAskingRaven {
            ask(query)
            return
        }
        guard model.listItems.indices.contains(model.selectedIndex) else {
            return
        }
        choose(model.listItems[model.selectedIndex])
    }

    func choose(_ item: LauncherItem) {
        switch item {
        case .application(let application, _):
            open(application)
        case .page(let entry):
            if let page = StagePage(switcherId: entry.id) {
                workspaceController.onOpenPage(page)
            }
            hide()
        case .askRaven(let text):
            ask(text)
        case .conversation(let conversation):
            let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
            model.targetConversationId = conversation.id
            if query.isEmpty {
                model.shownConversationId = conversation.id
                model.listItems = []
            } else {
                ask(query)
            }
        }
    }

    /// Leave the conversation a request would go to, and the one shown, for the rows again.
    func dropTarget() {
        model.targetConversationId = nil
        model.shownConversationId = nil
        search()
    }

    /// Begin a new conversation from the one shown.
    func startNewConversation() {
        model.targetConversationId = nil
        model.shownConversationId = nil
        model.query = ""
        search()
    }

    /// Show the conversation shown in the Rookmaster console's Raven panel.
    func openInRookmaster() {
        guard let conversationId = model.shownConversationId ?? model.targetConversationId else {
            return
        }
        fleetModel.raven.openConversationId = conversationId
        fleetModel.pageMemory.panelTab = .raven
        fleetModel.pageMemory.isPanelExpanded = true
        workspaceController.onOpenPage(.rookmaster)
        hide()
    }

    /// Ask Raven what is typed, in the conversation chosen or a new one, and show the conversation.
    private func ask(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        let raven = fleetModel.raven
        guard fleetModel.client() != nil else {
            model.problem = "Raven needs Rookery to follow a roost; connect one in the settings."
            return
        }
        guard !raven.isRunning(model.targetConversationId) else {
            model.problem = "Raven is still answering in this conversation."
            return
        }
        guard let conversationId = raven.ask(text, mentioning: [], in: model.targetConversationId) else {
            model.problem = "Raven could not take the request."
            return
        }
        model.problem = nil
        model.targetConversationId = conversationId
        model.shownConversationId = conversationId
        model.listItems = []
        model.query = ""
        model.sendToken += 1
    }

    /// Open an application, or bring its window forward on its stage when Rookery manages one.
    private func open(_ application: InstalledApplication) {
        mapUses[application.id, default: 0] += 1
        UserDefaults.standard.set(mapUses, forKey: Self.usesKey)
        hide()
        if
            let bundleId = application.bundleId,
            let group = workspaceController.workspace.listGroups.first(where: { group in
                group.listMembers.contains { $0.application.bundleId == bundleId }
            }),
            let window = group.listMembersFrontToBack.first(where: { $0.application.bundleId == bundleId })
        {
            Task { [workspaceController] in
                await workspaceController.switchTo(group.groupId, bringingToFront: window.windowId)
            }
            return
        }
        NSWorkspace.shared.openApplication(at: application.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Self.logger.error("cannot open \(application.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The launcher's window: a panel that takes the keyboard without bringing Rookery forward, as Spotlight
/// does, so the application the user works in stays in front.
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

/// The blur behind the launcher, with a faint shade over it, closing the launcher when clicked.
final class LauncherBackdropView: NSVisualEffectView {
    private static let shadeAlpha: CGFloat = 0.12

    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let shade = CALayer()
        shade.backgroundColor = NSColor.black.withAlphaComponent(Self.shadeAlpha).cgColor
        shade.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(shade)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.last?.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

