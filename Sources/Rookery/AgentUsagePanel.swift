import RookeryCore
import SwiftUI

/// The code agent accounts' plan limits in the sidebar, drawn as a launch webcast draws a rocket's
/// propellant: a thin gauge per limit draining as it is used, with what is left and the countdown to its
/// reset on segment displays, and when the limits are read next.
struct AgentUsagePanel: View {
    private static let digitHeight: CGFloat = 9
    private static let rowHeight: CGFloat = 14
    /// Below this much left, under half a percent, a limit counts as used up.
    private static let exhaustedFraction = 0.005
    /// How faint a used-up limit's name, gauge and share left grow, its countdown kept clear.
    private static let exhaustedOpacity = 0.4
    /// How strongly a running-out limit's row is washed red.
    private static let criticalWashOpacity = 0.16
    /// How far the red wash reaches past the row, so it frames the row without moving it.
    private static let criticalWashInset: CGFloat = 6
    /// Room for "100%", so the gauges line up.
    private static let percentWidth: CGFloat = 32
    /// The widest countdown, which sets the countdown column's width.
    private static let widestCountdown = "T-88:88"
    /// How old the limits may get before they show as stale.
    private static let staleAge: TimeInterval = 900

    let monitor: AgentUsageMonitor

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 9) {
                header(at: context.date)
                ForEach(monitor.listAccountGroups) { group in
                    accountBlock(group, at: context.date)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func header(at date: Date) -> some View {
        HStack(spacing: 6) {
            Text("Propellant")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StageColors.secondaryText)
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            Button(action: monitor.requestRefresh) {
                HStack(spacing: 3) {
                    SpinningSymbol(
                        icon: .refresh,
                        isSpinning: monitor.isRefreshing
                    )
                    Text(Self.nextRefreshText(monitor.nextRefreshAt, isRefreshing: monitor.isRefreshing, at: date))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(StageColors.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Read the limits now")
        }
    }

    private func accountBlock(_ group: AgentAccountGroup, at date: Date) -> some View {
        let usage = group.usage
        let error = group.error
        let isDefaultMarked = group.includesDefault && monitor.listShownAccounts.count > 1
        let isStale = usage.map { date.timeIntervalSince($0.fetchedAt) > Self.staleAge } ?? false
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(group.harness.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        if let plan = usage?.plan {
                            InfoTag(plan.capitalized)
                        }
                    }
                    HStack(spacing: 4) {
                        if let signedInAs = usage?.signedInAs {
                            Text(signedInAs)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if isDefaultMarked {
                            RookeryIconView(.play)
                            Text("default")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(StageColors.secondaryText)
                    .help(group.listAccounts.map { $0.configDirectory ?? "Default directory" }.joined(separator: ", "))
                }
                Spacer(minLength: 4)
                statusBadge(hasUsage: usage != nil, isStale: isStale, error: error)
            }
            if let usage {
                ForEach(usage.listLimits) { limit in
                    limitRow(limit, at: date)
                }
            }
        }
        .opacity(isStale || (usage == nil && error != nil) ? 0.55 : 1)
    }

    private func statusBadge(hasUsage: Bool, isStale: Bool, error: String?) -> some View {
        let (text, color): (String, Color) = if error != nil && !hasUsage || error != nil && isStale {
            ("No signal", .red)
        } else if isStale {
            ("Stale", .orange)
        } else if hasUsage {
            ("Live", .green)
        } else {
            ("Acquiring", .secondary)
        }
        return HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(StageColors.secondaryText)
        }
        .help(error ?? text)
    }

    private func limitRow(_ limit: AgentLimit, at date: Date) -> some View {
        let isReset = limit.resetsAt.map { $0 <= date } ?? false
        let remainingFraction = isReset ? 1 : limit.remainingFraction
        let isCritical = !isReset && PropellantGauge.isCritical(remainingFraction: remainingFraction, severity: limit.severity)
        let isExhausted = !isReset && remainingFraction <= Self.exhaustedFraction
        let spentOpacity = isExhausted ? Self.exhaustedOpacity : 1
        return HStack(spacing: 6) {
            Text(limit.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StageColors.secondaryText)
                .lineLimit(1)
                .frame(width: 34, alignment: .leading)
                .opacity(spentOpacity)
            PropellantGauge(remainingFraction: remainingFraction, severity: isReset ? .normal : limit.severity)
                .opacity(spentOpacity)
            Text("\(Int((remainingFraction * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(StageColors.secondaryText)
                .frame(width: Self.percentWidth, alignment: .trailing)
                .opacity(spentOpacity)
            SevenSegmentDisplay(
                text: Self.countdownText(until: isReset ? nil : limit.resetsAt, from: date),
                digitHeight: Self.digitHeight,
                color: StageColors.clockSegment
            )
            .frame(width: SevenSegmentDisplay.width(of: Self.widestCountdown, digitHeight: Self.digitHeight), alignment: .trailing)
        }
        .frame(height: Self.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.red.opacity(isCritical ? Self.criticalWashOpacity : 0))
                .padding(.horizontal, -Self.criticalWashInset)
                .padding(.vertical, -2)
        }
        .animation(.easeInOut(duration: 0.3), value: isCritical)
        .animation(.easeInOut(duration: 0.3), value: isExhausted)
        .help("\(limit.title): \(Int(limit.remainingFraction * 100))% left" + (limit.resetsAt.map { ", resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
    }

    /// The countdown to a reset, as "T-04:23" within a day and "T-1d12" beyond.
    private static func countdownText(until resetsAt: Date?, from date: Date) -> String {
        guard let resetsAt else {
            return "T-----"
        }
        let minutes = max(Int(resetsAt.timeIntervalSince(date) / 60), 0)
        let hours = minutes / 60
        if hours < 24 {
            return String(format: "T-%02d:%02d", hours, minutes % 60)
        }
        return String(format: "T-%dd%02d", hours / 24, hours % 24)
    }

    private static func nextRefreshText(_ nextRefreshAt: Date?, isRefreshing: Bool, at date: Date) -> String {
        guard !isRefreshing, let nextRefreshAt else {
            return "Syncing"
        }
        let minutes = max(Int(ceil(nextRefreshAt.timeIntervalSince(date) / 60)), 1)
        return "Next in \(minutes)m"
    }
}

/// A propellant gauge: a thin tank drained from the right as the limit is used, with marks at each
/// quarter, turning amber when a quarter is left and red at the last tenth or when the harness warns.
private struct PropellantGauge: View {
    private static let height: CGFloat = 5
    private static let listMarks: [CGFloat] = [0.25, 0.5, 0.75]
    private static let lowFraction = 0.25
    private static let criticalFraction = 0.1

    let remainingFraction: Double
    let severity: AgentLimitSeverity

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(StageColors.groove)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(fillColor.gradient)
                    .frame(width: proxy.size.width * remainingFraction)
                ForEach(Self.listMarks, id: \.self) { mark in
                    Rectangle()
                        .fill(StageColors.sidebar.opacity(0.9))
                        .frame(width: 1)
                        .offset(x: proxy.size.width * mark)
                }
            }
        }
        .frame(height: Self.height)
        .animation(.easeInOut(duration: 0.6), value: remainingFraction)
    }

    /// Whether a limit is running out: its last tenth left, or the harness says so.
    static func isCritical(remainingFraction: Double, severity: AgentLimitSeverity) -> Bool {
        remainingFraction <= criticalFraction || severity == .critical
    }

    private var fillColor: Color {
        if Self.isCritical(remainingFraction: remainingFraction, severity: severity) {
            return .red
        }
        if remainingFraction <= Self.lowFraction || severity == .warning {
            return .orange
        }
        return .primary.opacity(0.85)
    }
}
