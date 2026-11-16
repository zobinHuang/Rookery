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
    /// The most steps of the conversation drawn; earlier ones are a click away.
    private static let shownEntryLimit = 400
    private static let shownDeliveryLimit = 3
    private static let bottomId = "bottom"

    let fleetModel: FleetModel
    let agentId: String
    let onClose: () -> Void

    @State private var reader = TranscriptReader()
    @State private var hasTranscript = true
    @State private var listDeliveries: [FleetDelivery] = []
    @State private var draft = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var isShowingAll = false
    @FocusState private var isComposerFocused: Bool

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
                .padding(4)
                .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(agent.name)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statePill(agent.state)
                }
                metadata(agent)
            }
            Spacer(minLength: 12)
            Button(action: onClose) {
                PixelIconView(.close)
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
                PixelLabel(agent.model.isEmpty ? agent.harness : "\(agent.harness) · \(agent.model)", icon: .chip)
            }
            if !agent.cwd.isEmpty {
                PixelLabel(agent.cwd.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~"), icon: .folder)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if !agent.gitBranch.isEmpty {
                PixelLabel(agent.gitBranch, icon: .branch)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(StageColors.secondaryText)
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Conversation

    private var conversation: some View {
        let listEntries = reader.listEntries
        let listShown = isShowingAll ? listEntries[...] : listEntries.suffix(Self.shownEntryLimit)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if listShown.count < listEntries.count {
                        Button("Show \(listEntries.count - listShown.count) Earlier Steps") {
                            isShowingAll = true
                        }
                        .buttonStyle(.link)
                        .frame(maxWidth: .infinity)
                    }
                    if listEntries.isEmpty {
                        emptyConversation
                    }
                    ForEach(listShown) { entry in
                        entryView(entry)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .textSelection(.enabled)
            }
            .onChange(of: listEntries.count) {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
        }
    }

    private var emptyConversation: some View {
        VStack(spacing: 8) {
            PixelIconView(hasTranscript ? .bubble : .offline, scale: 3)
                .foregroundStyle(StageColors.tertiaryText)
            Text(hasTranscript ? "Nothing said yet" : "roost has no transcript of this session")
                .font(.system(size: 13, weight: .semibold))
            if !hasTranscript {
                Text("Transcripts arrive once the agent's machine uploads them with rook connect.")
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func entryView(_ entry: TranscriptEntry) -> some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(entry.text)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .assistant:
            Text(Self.markdown(entry.text))
                .font(.system(size: 13))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PixelIconView(.tool)
                    .foregroundStyle(StageColors.tertiaryText)
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(StageColors.secondaryText)
                Text(entry.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StageColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: - Composer

    private func composer(_ agent: FleetAgent) -> some View {
        let isReachable = agent.state != .ended && fleetModel.fleet.isOnline(agent)
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(listDeliveries.prefix(Self.shownDeliveryLimit)) { delivery in
                deliveryLine(delivery)
            }
            if let sendError {
                PixelLabel(sendError, icon: .warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    isReachable ? "Message \(agent.name)" : composerHint(agent),
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...8)
                .focused($isComposerFocused)
                .disabled(!isReachable)
                .onKeyPress(.return, phases: .down) { keyPress in
                    guard !keyPress.modifiers.contains(.shift) else {
                        return .ignored
                    }
                    send(to: agent)
                    return .handled
                }
                Button {
                    send(to: agent)
                } label: {
                    Group {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            PixelIconView(.arrowUp)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(isEmpty || !isReachable ? Color.gray.opacity(0.5) : Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isEmpty || !isReachable || isSending)
                .help("Send (Return); Shift-Return for a new line")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isComposerFocused ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(StageColors.separator))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.2), value: listDeliveries)
    }

    private func composerHint(_ agent: FleetAgent) -> String {
        agent.state == .ended ? "This session has ended" : "\(agent.rookName) is offline"
    }

    private func deliveryLine(_ delivery: FleetDelivery) -> some View {
        let symbol: PixelIcon = switch delivery.status {
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
            PixelIconView(symbol)
                .foregroundStyle(tint)
            Text(delivery.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("· \(delivery.status.capitalized)\(delivery.reason.isEmpty ? "" : ": \(delivery.reason)")")
                .foregroundStyle(StageColors.secondaryText)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .transition(.opacity)
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
            } catch {
                sendError = FleetModel.describe(error)
            }
            isSending = false
        }
    }

    private var missing: some View {
        VStack(spacing: 10) {
            PixelIconView(.agent, scale: 3)
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
        isShowingAll = false
        while !Task.isCancelled {
            if let client = fleetModel.client() {
                await readTranscript(from: client)
                do {
                    listDeliveries = try await client.deliveries(to: agentId)
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

    private func readTranscript(from client: RoostClient) async {
        let sessionId = agentId.components(separatedBy: "~").first ?? agentId
        guard !agentId.contains("~") else {
            hasTranscript = false
            return
        }
        do {
            guard let chunk = try await client.transcript(of: sessionId, from: reader.byteCount) else {
                hasTranscript = false
                return
            }
            hasTranscript = true
            if chunk.total < reader.byteCount {
                reader = TranscriptReader()
                return
            }
            if !chunk.data.isEmpty {
                reader.append(chunk.data)
            }
        } catch {
            Self.logger.info("cannot read the transcript: \(FleetModel.describe(error), privacy: .public)")
        }
    }
}
