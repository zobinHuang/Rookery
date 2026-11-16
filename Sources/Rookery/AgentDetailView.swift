import AppKit
import os
import RookeryCore
import RookeryPlatform
import SwiftUI

/// The content area's page for one agent: its crow and where it runs, its conversation as roost stored
/// it, and a box to prompt it, with what became of each prompt. Reads the transcript's new bytes and the
/// prompts' outcomes every couple of seconds while it shows.
struct AgentDetailView: View {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "agents")
    private static let pollInterval: Duration = .seconds(2)
    /// How much of a transcript's end is read when the page opens; the rest is a click away.
    private static let openingTailBytes = 3 * 1024 * 1024
    private static let shownDeliveryLimit = 3
    /// How long a prompt's outcome stays above the box once it is known.
    private static let deliveredLinger: TimeInterval = 4
    private static let failedLinger: TimeInterval = 10
    private static let bottomId = "bottom"

    let fleetModel: FleetModel
    let agentId: String
    let onClose: () -> Void

    @State private var reader = TranscriptReader()
    @State private var hasTranscript = true
    @State private var listDeliveries: [FleetDelivery] = []
    /// When each prompt was first seen settled; those settled before the page opened count as long ago.
    @State private var mapSettledAt: [String: Date] = [:]
    @State private var setDismissedDeliveries: Set<String> = []
    @State private var now = Date()
    @State private var draft = ""
    @State private var isSending = false
    @State private var sendError: String?
    @FocusState private var isComposerFocused: Bool

    /// The session the transcript is read from.
    private var transcriptSessionId: String {
        FleetAgent.transcriptSessionId(of: agentId)
    }

    private var agent: FleetAgent? {
        fleetModel.fleet.mapAgents[agentId]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let agent {
                header(agent)
                Rectangle()
                    .fill(StageColors.separator)
                    .frame(height: 1)
                conversation
                composer(agent)
            } else {
                missing
            }
        }
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
        .task(id: agentId) {
            await follow()
        }
    }

    // MARK: - Header

    private func header(_ agent: FleetAgent) -> some View {
        HStack(alignment: .center, spacing: 16) {
            CrowView(state: agent.state, size: .large)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(reader.title ?? agent.displayName)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statePill(agent.state)
                }
                if reader.title != nil || !agent.title.isEmpty {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StageColors.secondaryText)
                }
                metadata(agent)
            }
            Spacer(minLength: 12)
            Button(action: onClose) {
                RookeryIconView(.close)
                    .foregroundStyle(StageColors.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(StageColors.tile, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func statePill(_ state: AgentState) -> some View {
        Text(state.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(stateTint(state))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateTint(state).opacity(0.14), in: Capsule())
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: state)
    }

    private func stateTint(_ state: AgentState) -> Color {
        if state.needsAttention {
            return .orange
        }
        switch state {
        case .thinking, .working, .compacting: return .accentColor
        case .done: return .green
        default: return .secondary
        }
    }

    private func metadata(_ agent: FleetAgent) -> some View {
        let isOnline = fleetModel.fleet.isOnline(agent)
        return HStack(spacing: 14) {
            if !agent.rookName.isEmpty {
                Label {
                    Text(agent.rookName)
                } icon: {
                    Circle()
                        .fill(isOnline ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                }
                .help(isOnline ? "\(agent.rookName) is online" : "\(agent.rookName) is offline")
            }
            if !agent.harness.isEmpty {
                RookeryLabel(agent.harness, icon: .chip)
                if !agent.model.isEmpty {
                    InfoTag(agent.model)
                }
            }
            if !agent.cwd.isEmpty {
                RookeryLabel(agent.cwd.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~"), icon: .folder)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if !agent.gitBranch.isEmpty {
                RookeryLabel(agent.gitBranch, icon: .branch)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(StageColors.secondaryText)
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Conversation

    private var conversation: some View {
        TranscriptView(reader: reader, agentId: agentId, memory: fleetModel.pageMemory, hasTranscript: hasTranscript) {
            fleetModel.transcripts.forget(agentId)
            reader = TranscriptReader()
        }
        .id(agentId)
    }

    // MARK: - Composer

    private func composer(_ agent: FleetAgent) -> some View {
        let isReachable = agent.state != .ended && fleetModel.fleet.isOnline(agent)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(listShownDeliveries) { delivery in
                deliveryLine(delivery)
            }
            if let sendError {
                HStack(spacing: 6) {
                    RookeryLabel(sendError, icon: .warning)
                        .foregroundStyle(.orange)
                    dismissButton {
                        self.sendError = nil
                    }
                }
                .font(.system(size: 11))
                .transition(.opacity)
            }
            AgentComposer(
                text: $draft,
                placeholder: isReachable ? "Message \(agent.displayName)" : composerHint(agent),
                isEnabled: isReachable,
                isBusy: isSending,
                onSend: { send(to: agent) },
                isFocused: $isComposerFocused
            )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.25), value: listShownDeliveries)
        .animation(.easeOut(duration: 0.2), value: sendError)
        .onChange(of: draft) {
            sendError = nil
        }
    }

    /// The prompts on their way, and those whose outcome came in a moment ago and was not dismissed.
    private var listShownDeliveries: [FleetDelivery] {
        let listShown = listDeliveries.filter { delivery in
            guard !setDismissedDeliveries.contains(delivery.id) else {
                return false
            }
            guard delivery.isSettled else {
                return true
            }
            let linger = delivery.isFailed ? Self.failedLinger : Self.deliveredLinger
            return now.timeIntervalSince(mapSettledAt[delivery.id] ?? .distantPast) < linger
        }
        return Array(listShown.prefix(Self.shownDeliveryLimit))
    }

    /// Note when each prompt's outcome first showed up.
    private func noteOutcomes(isOpening: Bool) {
        now = Date()
        for delivery in listDeliveries where delivery.isSettled && mapSettledAt[delivery.id] == nil {
            mapSettledAt[delivery.id] = isOpening ? .distantPast : now
        }
    }

    private func dismissButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RookeryIconView(.close)
                .foregroundStyle(StageColors.tertiaryText)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }

    private func composerHint(_ agent: FleetAgent) -> String {
        agent.state == .ended ? "This session has ended" : "\(agent.rookName) is offline"
    }

    private func deliveryLine(_ delivery: FleetDelivery) -> some View {
        let symbol: RookeryIcon = switch delivery.status {
        case "delivered": .check
        case "failed", "expired": .failed
        case "waiting": .hourglass
        default: .send
        }
        let tint: Color = switch delivery.status {
        case "delivered": .green
        case "failed", "expired": .red
        case "waiting": .orange
        default: .secondary
        }
        return HStack(spacing: 6) {
            RookeryIconView(symbol)
                .foregroundStyle(tint)
            Text(delivery.text)
                .lineLimit(1)
                .truncationMode(.tail)
            InfoTag(delivery.status.capitalized, tint: tint)
            Text(delivery.reason)
                .foregroundStyle(StageColors.secondaryText)
                .lineLimit(1)
            if delivery.isSettled {
                dismissButton {
                    setDismissedDeliveries.insert(delivery.id)
                }
            }
        }
        .font(.system(size: 11))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func send(to agent: FleetAgent) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else {
            return
        }
        isSending = true
        sendError = nil
        Task {
            do {
                let delivery = try await fleetModel.send(text, to: agent.id)
                draft = ""
                listDeliveries.insert(delivery, at: 0)
                noteOutcomes(isOpening: false)
            } catch {
                sendError = FleetModel.describe(error)
            }
            isSending = false
        }
    }

    private var missing: some View {
        VStack(spacing: 10) {
            RookeryIconView(.agent, scale: 3)
                .foregroundStyle(StageColors.tertiaryText)
            Text("This agent is gone from roost")
                .font(.system(size: 14, weight: .semibold))
            Button("Close", action: onClose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Following

    /// Read the transcript's new bytes and the prompts' outcomes until the page goes away.
    private func follow() async {
        reader = TranscriptReader()
        hasTranscript = true
        listDeliveries = []
        mapSettledAt = [:]
        var isOpening = true
        if let cached = await fleetModel.transcripts.reader(for: agentId) {
            reader = cached
        } else if let client = fleetModel.client() {
            await startAtTail(from: client)
        }
        while !Task.isCancelled {
            if let client = fleetModel.client() {
                await readTranscript(from: client)
                do {
                    listDeliveries = try await client.deliveries(to: agentId)
                    noteOutcomes(isOpening: isOpening)
                    isOpening = false
                } catch {
                    Self.logger.info("cannot read deliveries: \(FleetModel.describe(error), privacy: .public)")
                }
            }
            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                return
            }
        }
    }

    /// Begin reading at the transcript's last stretch, so the latest of a long conversation shows at once.
    private func startAtTail(from client: RoostClient) async {
        do {
            guard let probe = try await client.transcript(of: transcriptSessionId, from: 0, limit: 1) else {
                return
            }
            if probe.total > Self.openingTailBytes {
                reader = TranscriptReader(startOffset: probe.total - Self.openingTailBytes)
            }
        } catch {
            Self.logger.info("cannot read the transcript: \(FleetModel.describe(error), privacy: .public)")
        }
    }

    /// Read what the transcript grew by since the last read, all of it, a chunk at a time; start over when
    /// the agent rewrote it.
    private func readTranscript(from client: RoostClient) async {
        do {
            while !Task.isCancelled {
                guard let chunk = try await client.transcript(of: transcriptSessionId, from: reader.nextOffset) else {
                    hasTranscript = false
                    return
                }
                hasTranscript = true
                if chunk.total < reader.nextOffset {
                    fleetModel.transcripts.forget(agentId)
                    reader = TranscriptReader()
                    continue
                }
                guard !chunk.data.isEmpty else {
                    return
                }
                reader.append(chunk.data)
                fleetModel.transcripts.append(chunk.data, after: reader, for: agentId)
                if reader.nextOffset >= chunk.total {
                    return
                }
            }
        } catch {
            Self.logger.info("cannot read the transcript: \(FleetModel.describe(error), privacy: .public)")
        }
    }
}
