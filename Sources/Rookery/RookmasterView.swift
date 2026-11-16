import AppKit
import RookeryCore
import SwiftUI

/// What the Rookmaster console shows above its log: the board, or one kind's list.
enum RookmasterTab: Hashable {
    case board
    case kind(String)
}

/// The console over everything rookd manages: the board of resources and the relations between them, a
/// list per kind to read and change them, and the log of what happened, live.
struct RookmasterView: View {
    private static let tabAnimation = Animation.spring(response: 0.3, dampingFraction: 0.88)
    /// The kinds the console leaves to the sidebar.
    static let setHiddenKinds: Set<String> = [AgentFleet.rookKind]

    let fleetModel: FleetModel
    let onOpenAgent: (String) -> Void
    let onClose: () -> Void

    @State private var tab = RookmasterTab.board
    @State private var selectedRef: FleetRef?
    @Namespace private var tabNamespace

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
                switch tab {
                case .board:
                    RookmasterBoard(fleetModel: fleetModel, listKinds: listKinds) { ref in
                        open(ref)
                    }
                    .transition(.opacity)
                case .kind(let kind):
                    RookmasterKindList(fleetModel: fleetModel, kind: kind, selectedRef: $selectedRef) { ref in
                        open(ref)
                    }
                    .id(kind)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Self.tabAnimation, value: tab)
            RookmasterLog(graph: fleetModel.graph)
        }
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "crown.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.yellow.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("Rookmaster")
                .font(.system(size: 18, weight: .bold))
            tabs
            Spacer(minLength: 8)
            if fleetModel.connection != .online {
                Label(connectionText, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
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
            tabButton(.board, title: "Board", symbol: "point.3.connected.trianglepath.dotted")
            ForEach(listKinds) { kind in
                tabButton(.kind(kind.name), title: kind.pluralTitle, symbol: RookmasterStyle.symbol(of: kind.name))
            }
        }
        .padding(3)
        .background(StageColors.groove, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func tabButton(_ target: RookmasterTab, title: String, symbol: String) -> some View {
        let isSelected = tab == target
        return Button {
            withAnimation(Self.tabAnimation) {
                tab = target
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.secondaryText))
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
        case .notConfigured: "Not connected to rookd"
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
            selectedRef = ref
            tab = .kind(ref.kind)
        }
    }
}

/// How the console draws each kind and verb.
enum RookmasterStyle {
    static func symbol(of kind: String) -> String {
        switch kind {
        case "agent": "bird"
        case "skill": "wrench.adjustable"
        case "playbook": "book.closed"
        case "memory": "brain"
        case "rook": "desktopcomputer"
        case "person": "person.fill"
        default: "cube"
        }
    }

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

    static func tint(ofVerb verb: String) -> Color {
        switch verb {
        case "uses", "mounts": .blue
        case "follows": .purple
        case "wrote", "updated", "created": .pink
        case "spawned": agentTint
        case "messaged", "delivered": .green
        case "undelivered", "deleted", "disconnected": .red
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

/// The console's log, after an editor's output panel: the latest events, newest at the bottom, live, with
/// a filter; folds down to its title bar.
struct RookmasterLog: View {
    private static let expandedHeight: CGFloat = 190
    private static let bottomId = "bottom"

    let graph: ResourceGraph

    @State private var isExpanded = true
    @State private var filter = ""
    @State private var clearedThroughSeq = 0

    private var listShown: [FleetEvent] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return graph.listRecentEvents.filter { event in
            event.seq > clearedThroughSeq && (query.isEmpty || line(of: event).lowercased().contains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            titleBar
            if isExpanded {
                rows
                    .frame(height: Self.expandedHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(StageColors.sidebar)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isExpanded)
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Log")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(listShown.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(StageColors.groove, in: Capsule())
                }
                .foregroundStyle(StageColors.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if isExpanded {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 10))
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 140)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(StageColors.groove, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button {
                    clearedThroughSeq = graph.lastSeq
                } label: {
                    Image(systemName: "clear")
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Clear the log")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(listShown, id: \.seq) { event in
                        row(event)
                            .transition(.opacity)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .textSelection(.enabled)
            }
            .onChange(of: graph.lastSeq) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
        }
    }

    private func row(_ event: FleetEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time(of: event))
                .foregroundStyle(StageColors.tertiaryText)
            Text(graph.name(of: event.actor))
                .foregroundStyle(RookmasterStyle.tint(of: event.actor.kind))
                .lineLimit(1)
            Text(event.verb)
                .foregroundStyle(RookmasterStyle.tint(ofVerb: event.verb))
            if let object = event.object {
                Text(graph.name(of: object))
                    .foregroundStyle(RookmasterStyle.tint(of: object.kind))
                    .lineLimit(1)
            }
            Text(detail(of: event))
                .foregroundStyle(StageColors.secondaryText)
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
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    private func detail(of event: FleetEvent) -> String {
        for key in ["state", "reason", "preview", "path"] {
            if let value = event.mapDetail[key]?.stringValue {
                return value.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }

    private func line(of event: FleetEvent) -> String {
        [graph.name(of: event.actor), event.verb, event.object.map(graph.name(of:)) ?? "", detail(of: event)].joined(separator: " ")
    }
}
