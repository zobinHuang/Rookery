import AppKit
import RookeryCore
import SwiftUI

/// What the Rookmaster console shows above its panel: the board, or one kind's list.
enum RookmasterTab: Hashable {
    case board
    case kind(String)
    case hosts
}

/// What the panel at the bottom of the Rookmaster console shows.
enum RookmasterPanelTab: Hashable {
    case raven
    case log
}

/// The console over everything roost manages: the board of resources and the relations between them, a
/// list per kind to read and change them, and the log of what happened, live.
struct RookmasterView: View {
    private static let tabAnimation = Animation.spring(response: 0.3, dampingFraction: 0.88)
    /// The kinds the console leaves to the sidebar.
    static let setHiddenKinds: Set<String> = [AgentFleet.rookKind]

    let fleetModel: FleetModel
    let logClock: LogClock
    let onOpenAgent: (String) -> Void
    let onClose: () -> Void

    @Namespace private var tabNamespace

    private var memory: PageMemory {
        fleetModel.pageMemory
    }

    /// The teams the conversation open in Raven's panel directs, which its links reach while it is in
    /// them.
    private var listDirectedTeams: [FleetRef] {
        guard let conversationId = fleetModel.raven.openConversationId else {
            return []
        }
        return fleetModel.raven.teams(of: conversationId).map { FleetRef(kind: AgentFleet.teamKind, id: $0.id) }
    }

    private var listKinds: [FleetKind] {
        fleetModel.graph.listKinds.filter { !Self.setHiddenKinds.contains($0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            ZStack {
                switch memory.rookmasterTab {
                case .board:
                    RookmasterBoard(fleetModel: fleetModel, listKinds: listKinds) { ref in
                        open(ref)
                    }
                    .transition(.opacity)
                case .kind(AgentFleet.teamKind):
                    RookmasterTeamsView(fleetModel: fleetModel, selectedRef: Bindable(memory).rookmasterSelectedRef)
                        .transition(.opacity)
                case .kind(let kind):
                    RookmasterKindList(fleetModel: fleetModel, kind: kind, selectedRef: Bindable(memory).rookmasterSelectedRef) { ref in
                        open(ref)
                    }
                    .id(kind)
                    .transition(.opacity)
                case .hosts:
                    RookmasterHostsView(fleetModel: fleetModel)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Self.tabAnimation, value: memory.rookmasterTab)
            RookmasterPanel(fleetModel: fleetModel, clock: logClock)
        }
        .overlayPreferenceValue(CardAnchorsKey.self) { mapAnchors in
            if memory.rookmasterTab == .board {
                RavenLinksOverlay(
                    links: fleetModel.ravenLinks,
                    conversationId: fleetModel.raven.openConversationId,
                    listHeldRefs: listDirectedTeams,
                    mapAnchors: mapAnchors
                )
            }
        }
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
        .overlay {
            if fleetModel.hosts.isLaunchFormShown {
                LaunchForm(fleetModel: fleetModel)
                    .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: fleetModel.hosts.isLaunchFormShown)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RookeryIconView(.crown, scale: 2)
            Text("Rookmaster")
                .font(.system(size: 18, weight: .bold))
            tabs
            Spacer(minLength: 8)
            if fleetModel.connection != .online {
                RookeryLabel(connectionText, icon: .offline)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Button(action: onClose) {
                RookeryIconView(.close)
                    .foregroundStyle(StageColors.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(StageColors.tile, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            tabButton(.board, title: "Board", symbol: .board)
            ForEach(listKinds) { kind in
                tabButton(.kind(kind.name), title: kind.pluralTitle, symbol: RookeryIcon.kind(kind.name))
            }
            tabButton(.hosts, title: "Hosts", symbol: .machine)
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(StageColors.segmentGroove)
                .strokeBorder(StageColors.segmentGrooveBorder)
        }
    }

    private func tabButton(_ target: RookmasterTab, title: String, symbol: RookeryIcon) -> some View {
        let isSelected = memory.rookmasterTab == target
        let heldCount = target == .kind(AgentFleet.teamKind) ? fleetModel.listHeldEvents.count : 0
        return Button {
            withAnimation(Self.tabAnimation) {
                memory.rookmasterTab = target
            }
        } label: {
            HStack(spacing: 5) {
                RookeryLabel(title, icon: symbol)
                if heldCount > 0 {
                    Text("\(heldCount)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                        .help("\(heldCount) messages held for you")
                }
            }
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.selectedSegmentText) : AnyShapeStyle(StageColors.secondaryText))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(StageColors.selectedSegment)
                            .matchedGeometryEffect(id: "tab", in: tabNamespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var connectionText: String {
        switch fleetModel.connection {
        case .notConfigured: "Not connected to roost"
        case .connecting: "Connecting…"
        case .online: ""
        case .offline(let reason): reason
        }
    }

    /// Show a resource: an agent's page, or another kind's list with it selected.
    private func open(_ ref: FleetRef) {
        if ref.kind == AgentFleet.agentKind {
            onOpenAgent(ref.id)
            return
        }
        withAnimation(Self.tabAnimation) {
            memory.rookmasterSelectedRef = ref
            memory.rookmasterTab = .kind(ref.kind)
        }
    }
}

/// How the console draws each kind and verb.
enum RookmasterStyle {
    static func tint(of kind: String) -> Color {
        switch kind {
        case "agent": agentTint
        case "skill": .blue
        case "playbook": .purple
        case "memory": .pink
        case "rook": .teal
        case "person": .green
        default: .gray
        }
    }

    /// The crows' yellow, darkened to gold where it would be read on a light background.
    private static let agentTint = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 1)
            : NSColor(srgbRed: 0.6, green: 0.43, blue: 0, alpha: 1)
    })

    /// Whether a verb tells of something that went wrong, the one thing the log marks in color.
    static func isFailure(_ verb: String) -> Bool {
        listFailureVerbs.contains(verb)
    }

    private static let listFailureVerbs = ["undelivered", "deleted", "disconnected"]

    static func tint(ofVerb verb: String) -> Color {
        switch verb {
        case "uses", "mounts": .blue
        case "follows": .purple
        case "wrote", "updated", "created": .pink
        case "spawned": agentTint
        case "messaged", "delivered": .green
        case _ where isFailure(verb): .red
        case "depends_on": .indigo
        default: .secondary
        }
    }

    /// How long ago a timestamp was, briefly.
    static func age(of timestamp: String, now: Date) -> String {
        guard let date = FleetTimestamp.date(from: timestamp) else {
            return ""
        }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

/// The panel at the bottom of the Rookmaster console, after an editor's: the log of the latest events,
/// newest at the bottom, live, with a filter; and Raven beside it in a tab of its own. Folds down to its
/// title bar.
struct RookmasterPanel: View {
    /// The panel's height before the user sets one, and the bounds the user may drag it between.
    static let defaultHeight: CGFloat = 340
    private static let minimumHeight: CGFloat = 140
    private static let maximumHeight: CGFloat = 900
    private static let handleHeight: CGFloat = 7
    private static let foldAnimation = Animation.spring(response: 0.3, dampingFraction: 0.9)

    let fleetModel: FleetModel
    let clock: LogClock

    @Namespace private var tabNamespace
    /// The height when the drag under way began.
    @State private var dragStartHeight: CGFloat?
    @State private var isHandleHovered = false

    private var memory: PageMemory {
        fleetModel.pageMemory
    }

    private var graph: ResourceGraph {
        fleetModel.graph
    }

    private var listShown: [FleetEvent] {
        let query = memory.logFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return graph.listRecentEvents.filter { event in
            event.seq > memory.logClearedThroughSeq && (query.isEmpty || line(of: event).lowercased().contains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
                .overlay {
                    if memory.isPanelExpanded {
                        resizeHandle
                    }
                }
            titleBar
            if memory.isPanelExpanded {
                Rectangle()
                    .fill(StageColors.separator)
                    .frame(height: 1)
                HStack(spacing: 0) {
                    Group {
                        switch memory.panelTab {
                        case .log:
                            rows
                        case .raven:
                            RavenPanel(fleetModel: fleetModel)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: memory.panelHeight)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(StageColors.sidebar)
        .background {
            Button("Show or Hide Raven", action: toggleFromShortcut)
                .keyboardShortcut("j", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(Self.foldAnimation, value: memory.isPanelExpanded)
    }

    /// ⌘J: fold the panel away, or open it on Raven.
    private func toggleFromShortcut() {
        withAnimation(Self.foldAnimation) {
            if memory.isPanelExpanded {
                memory.isPanelExpanded = false
            } else {
                memory.panelTab = .raven
                memory.isPanelExpanded = true
            }
        }
    }

    /// A strip along the panel's top edge that drags its height, lit while the pointer is on it.
    private var resizeHandle: some View {
        Rectangle()
            .fill(isHandleHovered || dragStartHeight != nil ? AnyShapeStyle(Color.accentColor.opacity(0.5)) : AnyShapeStyle(StageColor.clear))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .frame(height: Self.handleHeight)
            .contentShape(Rectangle())
            .onHover { isInside in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHandleHovered = isInside
                }
                if isInside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? memory.panelHeight
                        dragStartHeight = start
                        memory.panelHeight = min(max(start - value.translation.height, Self.minimumHeight), Self.maximumHeight)
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                    }
            )
            .help("Drag to change the panel's height")
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Button {
                memory.isPanelExpanded.toggle()
            } label: {
                RookeryIconView(.chevronRight)
                    .rotationEffect(.degrees(memory.isPanelExpanded ? 90 : 0))
                    .foregroundStyle(StageColors.secondaryText)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(memory.isPanelExpanded ? "Fold the panel (⌘J)" : "Open the panel (⌘J)")
            HStack(spacing: 2) {
                panelTab(.raven, title: "Raven", count: nil, isBusy: fleetModel.raven.isAnyRunning)
                panelTab(.log, title: "Log", count: listShown.count, isBusy: false)
            }
            .padding(2)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(StageColors.segmentGroove)
                    .strokeBorder(StageColors.segmentGrooveBorder)
            }
            Spacer(minLength: 8)
            if memory.isPanelExpanded && memory.panelTab == .log {
                HStack(spacing: 5) {
                    RookeryIconView(.filter)
                        .foregroundStyle(StageColors.secondaryText)
                    TextField("Filter", text: Bindable(memory).logFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 140)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(StageColors.groove, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button {
                    memory.logClearedThroughSeq = graph.lastSeq
                } label: {
                    RookeryIconView(.clear)
                        .foregroundStyle(StageColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Clear the log")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func panelTab(_ target: RookmasterPanelTab, title: String, count: Int?, isBusy: Bool) -> some View {
        let isSelected = memory.panelTab == target
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                memory.panelTab = target
                memory.isPanelExpanded = true
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .opacity(0.6)
                }
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.selectedSegmentText) : AnyShapeStyle(StageColors.secondaryText))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(StageColors.selectedSegment)
                        .matchedGeometryEffect(id: "panelTab", in: tabNamespace)
                }
            }
            .contentShape(Rectangle())
            .anchorPreference(key: CardAnchorsKey.self, value: .bounds) { anchor in
                target == .raven ? [RavenLinks.ravenRef: anchor] : [:]
            }
        }
        .buttonStyle(.plain)
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(listShown, id: \.seq) { event in
                    row(event)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
        .modifier(RememberedScroll(
            key: "rookmaster.log",
            memory: memory,
            followsEnd: true,
            isReady: true,
            endToken: graph.lastSeq
        ))
    }

    private func row(_ event: FleetEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time(of: event))
                .foregroundStyle(StageColors.tertiaryText)
            Text(graph.logLabel(of: event.actor))
                .fontWeight(.medium)
                .foregroundStyle(StageColors.primaryText)
                .lineLimit(1)
            Text(event.verb)
                .foregroundStyle(RookmasterStyle.isFailure(event.verb) ? AnyShapeStyle(Color.red) : AnyShapeStyle(StageColors.secondaryText))
            if let object = event.object {
                Text(graph.logLabel(of: object))
                    .fontWeight(.medium)
                    .foregroundStyle(StageColors.primaryText)
                    .lineLimit(1)
            }
            Text(detail(of: event))
                .foregroundStyle(StageColors.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1)
    }

    private func time(of event: FleetEvent) -> String {
        guard let date = FleetTimestamp.date(from: event.at) else {
            return event.at
        }
        return date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
            timeZone: clock.timeZone,
            calendar: Calendar(identifier: .gregorian)
        ))
    }

    private func detail(of event: FleetEvent) -> String {
        for key in ["state", "title", "reason", "preview", "path"] {
            if let value = event.mapDetail[key]?.stringValue {
                return value.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }

    private func line(of event: FleetEvent) -> String {
        [graph.logLabel(of: event.actor), event.verb, event.object.map(graph.logLabel(of:)) ?? "", detail(of: event)].joined(separator: " ")
    }
}
