import RookeryCore
import SwiftUI

/// The stage's right sidebar: the day's calendar, the unread mail, and the mixer, one tab each. Folds to a
/// strip of the three icons, each with what it most needs to say: the next event's time, the unread count,
/// whether the mixer holds any sound.
struct RightSidebarView: View {
    private static let tabAnimation = Animation.spring(response: 0.3, dampingFraction: 0.88)

    let model: StageModel
    @Bindable var preferences: Preferences
    let mixer: MixerController
    let fleetModel: FleetModel
    let actions: StageActions

    @Namespace private var tabNamespace

    private var personal: PersonalDataModel {
        fleetModel.personal
    }

    var body: some View {
        Group {
            if model.isRightSidebarCollapsed {
                strip
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    header
                    Rectangle()
                        .fill(StageColors.separator)
                        .frame(height: 1)
                    ZStack(alignment: .top) {
                        switch model.rightSidebarTab {
                        case .calendar:
                            TodayCalendarView(personal: personal, onOpenPage: { actions.showPage(.calendar) }, onOpenSettings: { actions.showPage(.settings) })
                                .transition(.opacity)
                        case .mail:
                            UnreadMailView(personal: personal, onOpenMessage: openMessage, onOpenPage: { actions.showPage(.mail) }, onOpenSettings: { actions.showPage(.settings) })
                                .transition(.opacity)
                        case .mixer:
                            mixerTab
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                }
                .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity)
        .background(StageColors.sidebar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(StageColors.separator)
                .frame(width: 1)
        }
        .animation(Self.tabAnimation, value: model.rightSidebarTab)
        .onAppear {
            if model.isVisible {
                personal.begin()
            }
        }
        .onChange(of: model.isVisible) { _, isVisible in
            if isVisible {
                personal.begin()
            } else {
                personal.end()
            }
        }
    }

    // MARK: - Header and strip

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(RightSidebarTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(3)
            .background(StageColors.groove, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Spacer(minLength: 0)
            Button(action: actions.toggleRightSidebar) {
                RookeryIconView(.sidebarRight)
                    .foregroundStyle(StageColors.secondaryText)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Fold the right sidebar")
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func tabButton(_ tab: RightSidebarTab) -> some View {
        let isSelected = model.rightSidebarTab == tab
        return Button {
            withAnimation(Self.tabAnimation) {
                actions.showRightSidebarTab(tab)
            }
        } label: {
            HStack(spacing: 4) {
                RookeryIconView(tab.symbol)
                Text(tab.title)
                    .font(.system(size: 11.5, weight: .semibold))
                if tab == .mail, personal.unreadTotal > 0 {
                    Text(Self.count(personal.unreadTotal))
                        .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(StageColors.secondaryText)
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.secondaryText))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(StageColors.selectedSegment)
                        .matchedGeometryEffect(id: "rightTab", in: tabNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }

    /// The folded sidebar: a button that opens it, then each tab's icon with its badge.
    private var strip: some View {
        VStack(spacing: 14) {
            Button(action: actions.toggleRightSidebar) {
                RookeryIconView(.sidebarRight)
                    .foregroundStyle(StageColors.secondaryText)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Show the right sidebar")
            .padding(.top, 14)
            ForEach(RightSidebarTab.allCases, id: \.self) { tab in
                Button {
                    actions.showRightSidebarTab(tab)
                } label: {
                    VStack(spacing: 3) {
                        RookeryIconView(tab.symbol)
                            .foregroundStyle(StageColors.secondaryText)
                            .frame(width: 30, height: 26)
                            .overlay(alignment: .topTrailing) {
                                badge(of: tab)
                                    .offset(x: 6, y: -5)
                            }
                        if tab == .calendar, let next = personal.nextEvent, Calendar.current.isDateInToday(next.startsAt) {
                            Text(next.startsAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(next.startsAt <= personal.now ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.secondaryText))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(stripHelp(of: tab))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func badge(of tab: RightSidebarTab) -> some View {
        switch tab {
        case .mail where personal.unreadTotal > 0:
            Text(Self.count(personal.unreadTotal))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor, in: Capsule())
                .fixedSize()
        case .mixer where mixer.listTracks.contains(where: \.isCapturing):
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
        default:
            EmptyView()
        }
    }

    private func stripHelp(of tab: RightSidebarTab) -> String {
        switch tab {
        case .calendar:
            personal.nextEvent.map { "Next: \($0.title), \($0.startsAt.formatted(date: .omitted, time: .shortened))" } ?? "Today"
        case .mail:
            "\(personal.unreadTotal) unread"
        case .mixer:
            "Mixer"
        }
    }

    /// A count as a badge shows it: as it is up to 999, then in thousands.
    static func count(_ value: Int) -> String {
        value < 1000 ? "\(value)" : "\(value / 1000)k"
    }

    // MARK: - Tabs

    @ViewBuilder
    private var mixerTab: some View {
        if preferences.isMixerEnabled {
            ScrollView {
                MixerView(mixer: mixer, isCollapsed: false)
                    .padding(.vertical, 6)
            }
        } else {
            SidebarNotice(
                icon: .mixer,
                title: "The mixer is off",
                text: "Turn it on to set each app's and each browser tab's volume, balance and sound.",
                actionTitle: "Turn On"
            ) {
                preferences.isMixerEnabled = true
            }
        }
    }

    private func openMessage(_ message: MailMessageSummary) {
        fleetModel.pageMemory.selectedMailId = message.id
        actions.open(.mail)
    }
}

/// A short note filling a sidebar tab that has nothing to show yet, with a way forward.
struct SidebarNotice: View {
    let icon: RookeryIcon
    let title: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            RookeryIconView(icon, scale: 2)
                .foregroundStyle(StageColors.tertiaryText)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(StageColors.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
}

/// A color for each mail account: the accounts Mail holds take the colors in the order of their addresses,
/// so no two share one while there are fewer accounts than colors; an address not yet known takes the next.
@MainActor
enum AccountColor {
    private static let listColors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .red]
    private static var listKnown: [String] = []

    /// Know the accounts Mail holds, which fixes their colors.
    static func know(_ listAddresses: [String]) {
        let listSorted = Set(listAddresses.map { $0.lowercased() }).sorted()
        if listSorted != listKnown.filter(listSorted.contains) || listKnown.count != listSorted.count {
            listKnown = listSorted
        }
    }

    static func of(_ address: String) -> Color {
        let key = address.lowercased()
        if !listKnown.contains(key) {
            listKnown.append(key)
        }
        return listColors[(listKnown.firstIndex(of: key) ?? 0) % listColors.count]
    }

    /// A calendar's color from its `#rrggbb`, or the accent color without one.
    nonisolated static func calendar(_ hex: String) -> Color {
        guard hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else {
            return .accentColor
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
