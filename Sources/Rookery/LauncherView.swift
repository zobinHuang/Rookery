import AppKit
import RookeryCore
import RookeryPlatform
import SwiftUI

/// The launcher: its box, with the conversation a request goes to as a tag before it, and under it either
/// the rows it finds, each kind under its heading and the chosen one in the theme turned over, or, once
/// Raven is asked, the conversation with Raven's answer coming in.
struct LauncherView: View {
    private static let appearAnimation = Animation.spring(response: 0.26, dampingFraction: 0.86)
    private static let width: CGFloat = 640
    private static let rowsMaxHeight: CGFloat = 400
    private static let conversationHeight: CGFloat = 430
    private static let iconSize: CGFloat = 28
    private static let cornerRadius: CGFloat = 20
    private static let fieldHeight: CGFloat = 58
    /// Where the mentions offered start, under the text typed.
    private static let mentionInset: CGFloat = 46
    private static let mentionWidth: CGFloat = 380

    let controller: LauncherController
    @FocusState private var isFieldFocused: Bool

    private var model: LauncherModel {
        controller.model
    }

    /// An AppKit view hosting the launcher.
    static func makeHostingView(controller: LauncherController) -> NSView {
        let view = NSHostingView(rootView: LauncherView(controller: controller))
        view.sizingOptions = []
        return view
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if let problem = model.problem {
                RookeryLabel(problem, icon: .warning)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
            if let conversationId = model.shownConversationId {
                separator
                RavenThreadView(fleetModel: controller.fleetModel, conversationId: conversationId, sendToken: model.sendToken)
                    .id(conversationId)
                    .frame(height: Self.conversationHeight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !model.listItems.isEmpty {
                separator
                rows
                    .transition(.opacity)
            }
        }
        .frame(width: Self.width)
        .background(StageColors.window, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(StageColors.segmentGrooveBorder)
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
        .overlay(alignment: .topLeading) {
            if !model.listMentionTargets.isEmpty {
                mentionList
                    .padding(.leading, Self.mentionInset)
                    .padding(.top, Self.fieldHeight - 4)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.listMentionTargets.map(\.id))
        .scaleEffect(model.isVisible ? 1 : 0.96, anchor: .top)
        .opacity(model.isVisible ? 1 : 0)
        .animation(Self.appearAnimation, value: model.isVisible)
        .animation(Self.appearAnimation, value: model.shownConversationId)
        .animation(.easeOut(duration: 0.15), value: model.listItems.map(\.id))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 20)
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
        .environment(\.chosenTheme, model.chosenTheme)
        .environment(\.people, controller.fleetModel.people)
        .onChange(of: model.isVisible) { _, isVisible in
            if isVisible {
                isFieldFocused = true
            }
        }
        .onChange(of: model.query) {
            controller.updateMentions()
            if model.shownConversationId == nil {
                controller.search()
            }
        }
    }

    // MARK: - The box

    private var field: some View {
        HStack(spacing: 10) {
            RookeryIconView(model.targetConversationId == nil ? .search : .bubble, scale: 1.4)
                .foregroundStyle(StageColors.secondaryText)
            if let targetId = model.targetConversationId, let conversation = controller.fleetModel.raven.conversations.conversation(targetId) {
                HStack(spacing: 4) {
                    RookeryIconView(.bubble)
                    Text(conversation.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StageColors.selectedSegmentText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(StageColors.selectedSegment, in: Capsule())
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .help("Asking in this conversation; ⌫ on an empty box to leave it")
                .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
            }
            TextField(placeholder, text: Bindable(model).query, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .lineLimit(1...6)
                .focused($isFieldFocused)
                .onKeyPress(phases: .down, action: take)
            if model.shownConversationId != nil {
                Button("New") {
                    controller.startNewConversation()
                }
                .controlSize(.small)
                .help("Begin a new conversation with Raven")
                Button {
                    controller.openInRookmaster()
                } label: {
                    RookeryIconView(.expand)
                }
                .controlSize(.small)
                .help("Open this conversation in Rookmaster")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: Self.fieldHeight)
        .animation(Self.appearAnimation, value: model.targetConversationId)
    }

    private var placeholder: String {
        if model.shownConversationId != nil {
            return "Ask a follow-up…"
        }
        if model.targetConversationId != nil {
            return "Ask in this conversation…"
        }
        return "Search apps or ask Raven…"
    }

    private var separator: some View {
        Rectangle()
            .fill(StageColors.separator)
            .frame(height: 1)
    }

    /// The box's keys: the arrows move among the rows, Return chooses and ⌘Return asks Raven, ⇧Return or
    /// ⌃J start a new line, Escape closes, and Delete on an empty box leaves the conversation chosen; none
    /// while an input method composes.
    private func take(_ keyPress: KeyPress) -> KeyPress.Result {
        guard !AgentComposer.isComposing else {
            return .ignored
        }
        if AgentComposer.insertsNewline(keyPress) {
            AgentComposer.insertNewline()
            return .handled
        }
        if !model.listMentionTargets.isEmpty {
            switch keyPress.key {
            case .downArrow:
                controller.moveMention(by: 1)
                return .handled
            case .upArrow:
                controller.moveMention(by: -1)
                return .handled
            case .return, .tab:
                if model.listMentionTargets.indices.contains(model.mentionIndex) {
                    controller.pickMention(model.listMentionTargets[model.mentionIndex])
                }
                return .handled
            default:
                break
            }
        }
        switch keyPress.key {
        case .downArrow where model.shownConversationId == nil:
            controller.moveSelection(by: 1)
        case .upArrow where model.shownConversationId == nil:
            controller.moveSelection(by: -1)
        case .return:
            controller.choose(isAskingRaven: keyPress.modifiers.contains(.command))
        case .escape:
            controller.hide()
        case .delete where model.query.isEmpty && model.targetConversationId != nil:
            controller.dropTarget()
        default:
            return .ignored
        }
        return .handled
    }

    // MARK: - Mentions

    /// The people and resources the `@` being typed could name, floating under the box over whatever
    /// the launcher shows, the chosen one in the theme turned over.
    private var mentionList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.listMentionTargets.enumerated()), id: \.element.id) { index, target in
                let isSelected = index == model.mentionIndex
                Button {
                    controller.pickMention(target)
                } label: {
                    HStack(spacing: 9) {
                        switch target {
                        case .person(let person):
                            PersonMark(person: person, size: 20)
                            Text(person.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(person.listAddresses.first ?? "")
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .opacity(0.7)
                        case .resource(let resource):
                            RookeryIconView(RookeryIcon.kind(resource.kind))
                                .frame(width: 20)
                            Text(resource.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(resource.kind.capitalized)
                                .font(.system(size: 11))
                                .opacity(0.7)
                        }
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.selectedSegmentText) : AnyShapeStyle(StageColors.primaryText))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(StageColors.selectedSegment)
                                .strokeBorder(StageColors.contrastActiveBorder)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .frame(width: Self.mentionWidth)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StageColors.window)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(StageColors.card)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(StageColors.segmentGrooveBorder)
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }

    // MARK: - Rows

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.listItems.enumerated()), id: \.element.id) { index, item in
                        if let heading = heading(at: index) {
                            Text(heading)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(StageColors.tertiaryText)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 2 : 10)
                                .padding(.bottom, 3)
                        }
                        row(item, isSelected: index == model.selectedIndex)
                            .id(item.id)
                            .onTapGesture {
                                model.selectedIndex = index
                                controller.choose(item)
                            }
                            .onHover { isInside in
                                if isInside {
                                    model.selectedIndex = index
                                }
                            }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: Self.rowsMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.selectedIndex) { _, index in
                if model.listItems.indices.contains(index) {
                    proxy.scrollTo(model.listItems[index].id)
                }
            }
        }
    }

    /// The heading over a row that begins a kind of rows.
    private func heading(at index: Int) -> String? {
        let kind = Self.kind(of: model.listItems[index])
        guard index == 0 || Self.kind(of: model.listItems[index - 1]) != kind else {
            return nil
        }
        switch model.listItems[index] {
        case .application: return "Applications"
        case .page: return "Rookery"
        case .askRaven: return "Raven"
        case .conversation: return model.query.isEmpty ? "Recent Conversations" : "Conversations"
        }
    }

    private static func kind(of item: LauncherItem) -> Int {
        switch item {
        case .application: 0
        case .page: 1
        case .askRaven: 2
        case .conversation: 3
        }
    }

    private func row(_ item: LauncherItem, isSelected: Bool) -> some View {
        HStack(spacing: 11) {
            icon(of: item, isSelected: isSelected)
                .frame(width: Self.iconSize, height: Self.iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(of: item))
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.selectedSegmentText) : AnyShapeStyle(StageColors.primaryText))
                if let subtitle = subtitle(of: item) {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.selectedSegmentText.opacity(0.7)) : AnyShapeStyle(StageColors.secondaryText))
                }
            }
            Spacer(minLength: 8)
            accessory(of: item, isSelected: isSelected)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(StageColors.selectedSegment)
                    .strokeBorder(StageColors.contrastActiveBorder)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func icon(of item: LauncherItem, isSelected: Bool) -> some View {
        let ink = isSelected ? AnyShapeStyle(StageColors.selectedSegmentText) : AnyShapeStyle(StageColors.secondaryText)
        switch item {
        case .application(let application, _):
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                .resizable()
        case .page(let entry):
            RookeryIconView(entry.symbolName ?? .window, scale: 1.5)
                .foregroundStyle(ink)
        case .askRaven:
            RavenView(isWorking: false)
                .scaleEffect(Self.iconSize / CrowSize.regular.rawValue)
        case .conversation(let conversation):
            RavenView(isWorking: controller.fleetModel.raven.isRunning(conversation.id))
                .scaleEffect(Self.iconSize / CrowSize.regular.rawValue)
        }
    }

    private func title(of item: LauncherItem) -> String {
        switch item {
        case .application(let application, _): application.name
        case .page(let entry): entry.title
        case .askRaven: "Ask Raven"
        case .conversation(let conversation): conversation.title
        }
    }

    private func subtitle(of item: LauncherItem) -> String? {
        switch item {
        case .application(let application, _):
            application.alternateName.isEmpty ? nil : application.alternateName
        case .page(let entry):
            entry.subtitle.isEmpty ? nil : entry.subtitle
        case .askRaven(let text):
            text
        case .conversation(let conversation):
            "\(conversation.lastAt.formatted(.relative(presentation: .named))), \(conversation.turnCount == 1 ? "1 request" : "\(conversation.turnCount) requests")"
        }
    }

    @ViewBuilder
    private func accessory(of item: LauncherItem, isSelected: Bool) -> some View {
        switch item {
        case .application(_, let groupName?):
            tag(groupName, isSelected: isSelected)
        case .page:
            tag("Rookery", isSelected: isSelected)
        case .askRaven, .conversation:
            if isSelected {
                Text(Self.keyHint(of: item, query: model.query))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StageColors.selectedSegmentText.opacity(0.7))
            }
        default:
            EmptyView()
        }
    }

    private static func keyHint(of item: LauncherItem, query: String) -> String {
        if case .conversation = item, query.trimmingCharacters(in: .whitespaces).isEmpty {
            return "↩ to ask in it"
        }
        return "↩"
    }

    private func tag(_ text: String, isSelected: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.selectedSegmentText.opacity(0.85)) : AnyShapeStyle(StageColors.secondaryText))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(isSelected ? AnyShapeStyle(StageColors.selectedSegmentText.opacity(0.16)) : AnyShapeStyle(StageColors.segmentGroove), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(isSelected ? AnyShapeStyle(StageColor.clear) : AnyShapeStyle(StageColors.segmentGrooveBorder))
            }
    }
}
