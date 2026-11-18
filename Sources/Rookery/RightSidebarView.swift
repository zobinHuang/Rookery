import RookeryCore
import SwiftUI

/// The stage's right strip: a button for the calendar, the mail and the mixer, each opening its page in
/// the content area and lit while it shows, with what it most needs to say: the next event's time, the
/// unread count, whether the mixer holds any sound.
struct RightSidebarView: View {
    let model: StageModel
    let mixer: MixerController
    let fleetModel: FleetModel
    let actions: StageActions

    private var personal: PersonalDataModel {
        fleetModel.personal
    }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(RightSidebarTab.allCases, id: \.self) { tab in
                button(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StageColors.sidebar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(StageColors.separator)
                .frame(width: 1)
        }
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

    private func button(_ tab: RightSidebarTab) -> some View {
        let isShown = model.shownPage == tab.page
        return Button {
            if isShown {
                actions.closePage()
            } else {
                actions.showPage(tab.page)
            }
        } label: {
            VStack(spacing: 3) {
                RookeryIconView(tab.symbol)
                    .foregroundStyle(isShown ? AnyShapeStyle(StageColors.selectedSegmentText) : AnyShapeStyle(StageColors.secondaryText))
                    .frame(width: 30, height: 26)
                    .background {
                        if isShown {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(StageColors.selectedSegment)
                        }
                    }
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
            .animation(.easeOut(duration: 0.15), value: isShown)
        }
        .buttonStyle(.plain)
        .help(stripHelp(of: tab))
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
