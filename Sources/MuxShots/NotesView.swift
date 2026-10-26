import AppKit
import MuxShotsCore
import SwiftUI

/// The sidebar's quick notes: a button to start one, then the notes as cards in the user's order, which a
/// drag rearranges. A click edits a note in place, the trash button or the context menu deletes it, and a
/// note left blank goes away. A tab dropped on a note links the note to it, and on the button starts a
/// note linked to it; a click on a linked note goes to the tab instead, and its pencil button edits it.
struct NotesView: View {
    private static let listAnimation = Animation.spring(response: 0.3, dampingFraction: 0.86)
    private static let hoverAnimation = Animation.easeOut(duration: 0.12)
    private static let cornerRadius: CGFloat = 10
    /// How many lines a note shows before it is cut short, until it is edited.
    private static let previewLineLimit = 8
    /// The row under a note's text, holding when it changed and, under the pointer, its buttons.
    private static let footerHeight: CGFloat = 20
    /// How faint a note being dragged stays in its old place.
    private static let draggedOpacity = 0.4
    /// How faint a link to a tab that has closed is.
    private static let closedLinkOpacity = 0.55
    private static let linkHeight: CGFloat = 22
    private static let linkIconSize: CGFloat = 14
    /// How strongly a note or the button lights up while a tab is over it.
    private static let tabTargetFillOpacity = 0.1

    let notes: QuickNotes
    let model: StageModel
    let isCollapsed: Bool
    /// Take keyboard input and edit a note.
    let onBeginEditing: (NoteId) -> Void
    /// Give keyboard input back once a note is no longer edited.
    let onFinishEditing: () -> Void
    /// Widen the collapsed sidebar, so a note can be read or edited.
    let onExpand: () -> Void
    /// A note started being dragged to reorder the notes.
    let onDragBegan: (NoteId) -> Void
    /// Link a note to a dragged tab, or start a new note linked to it with nil.
    let onLinkTab: (NoteId?, WindowId) -> NoteId?
    /// Go to the tab a note leads to.
    let onOpenLink: (NoteLink) -> Void
    @State private var hoveredNoteId: NoteId?
    @State private var isNewNoteHovered = false
    /// The note a dragged tab is over, which it would link to.
    @State private var tabTargetNoteId: NoteId?
    /// Whether a dragged tab is over the button, which would start a note linked to it.
    @State private var isTabOverNewNote = false

    var body: some View {
        Group {
            if isCollapsed {
                collapsedList
            } else {
                expandedList
            }
        }
        .animation(Self.listAnimation, value: notes.listNotes.map(\.noteId))
    }

    private var expandedList: some View {
        VStack(spacing: 6) {
            newNoteButton
            ForEach(notes.listNotes) { note in
                Group {
                    if model.editingNoteId == note.noteId {
                        NoteEditor(initialText: note.text) { text in
                            notes.update(note.noteId, text: text)
                            onFinishEditing()
                        }
                    } else {
                        noteCard(note)
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.96))
                ))
            }
            if model.isNoteOverSidebarEnd {
                InsertionMark(isVertical: false)
            }
            if notes.listNotes.isEmpty {
                Text("Jot down anything you want at hand. Notes are kept until you delete them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var newNoteButton: some View {
        Button(action: startNewNote) {
            HStack(spacing: 7) {
                Image(systemName: isTabOverNewNote ? "link" : "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(isTabOverNewNote ? "New Note for This Tab" : "New Note")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(newNoteStyle)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(newNoteFill)
            }
            .overlay {
                if isTabOverNewNote {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                } else {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(StageColors.groove, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(Self.hoverAnimation) {
                isNewNoteHovered = isHovered
            }
        }
        .help("Write a new note, or drop a tab here for a note that leads to it")
        .dropDestination(for: String.self) { listTexts, _ in
            guard case .window(let windowId) = listTexts.first.flatMap(StagePayload.init) else {
                return false
            }
            model.clearDragState()
            if let noteId = onLinkTab(nil, windowId) {
                onBeginEditing(noteId)
            }
            return true
        } isTargeted: { isTargeted in
            withAnimation(Self.hoverAnimation) {
                isTabOverNewNote = isTargeted && model.isDraggingTab
            }
        }
    }

    private var newNoteStyle: AnyShapeStyle {
        if isTabOverNewNote {
            return AnyShapeStyle(Color.accentColor)
        }
        return isNewNoteHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var newNoteFill: Color {
        if isTabOverNewNote {
            return Color.accentColor.opacity(Self.tabTargetFillOpacity)
        }
        return isNewNoteHovered ? StageColors.hoveredRow : Color.clear
    }

    private func noteCard(_ note: QuickNote) -> some View {
        let isHovered = hoveredNoteId == note.noteId
        let isTabTarget = tabTargetNoteId == note.noteId
        return VStack(alignment: .leading, spacing: 5) {
            if let link = note.link {
                linkLabel(link)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        open(note)
                    }
            }
            if !note.text.isEmpty {
                Text(note.text)
                    .font(.system(size: 12))
                    .lineLimit(Self.previewLineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        open(note)
                    }
            }
            HStack(spacing: 2) {
                Text(isTabTarget ? "Drop to link this note to the tab" : Self.modifiedText(note.modifiedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(isTabTarget ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        open(note)
                    }
                if isHovered && !isTabTarget {
                    if note.link != nil {
                        cardButton("pencil", help: "Edit the note") {
                            onBeginEditing(note.noteId)
                        }
                    }
                    if !note.text.isEmpty {
                        cardButton("doc.on.doc", help: "Copy the note") {
                            copy(note)
                        }
                    }
                    cardButton("trash", help: "Delete the note") {
                        notes.remove(note.noteId)
                    }
                }
            }
            .frame(height: Self.footerHeight)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(StageColors.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(isHovered ? StageColors.hoveredRow : Color.clear)
                .allowsHitTesting(false)
        }
        .overlay {
            if isTabTarget {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(Self.tabTargetFillOpacity))
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .opacity(model.draggingNoteId == note.noteId ? Self.draggedOpacity : 1)
        .overlay(alignment: .top) {
            if model.noteInsertBeforeId == note.noteId && model.draggingNoteId != note.noteId {
                InsertionMark(isVertical: false)
                    .offset(y: -4)
            }
        }
        .onHover { isNowHovered in
            withAnimation(Self.hoverAnimation) {
                if isNowHovered {
                    hoveredNoteId = note.noteId
                } else if hoveredNoteId == note.noteId {
                    hoveredNoteId = nil
                }
            }
        }
        .help(note.link.map(linkHelp) ?? "")
        .contextMenu {
            if let link = note.link {
                Button("Go to Tab") {
                    onOpenLink(link)
                }
            }
            Button("Edit") {
                onBeginEditing(note.noteId)
            }
            Button("Copy") {
                copy(note)
            }
            .disabled(note.text.isEmpty)
            if note.link != nil {
                Button("Remove Link") {
                    notes.link(note.noteId, to: nil)
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                notes.remove(note.noteId)
            }
        }
        .onDrag {
            onDragBegan(note.noteId)
            return NSItemProvider(object: StagePayload.note(note.noteId).text as NSString)
        } preview: {
            Text(note.text.isEmpty ? note.link?.name ?? "" : note.text)
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(width: StageModel.sidebarWidth - 40, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: .rect(cornerRadius: Self.cornerRadius))
        }
        .dropDestination(for: String.self) { listTexts, _ in
            switch listTexts.first.flatMap(StagePayload.init) {
            case .note(let draggedNoteId):
                model.clearDragState()
                notes.move(draggedNoteId, before: note.noteId)
                return true
            case .window(let windowId):
                model.clearDragState()
                return onLinkTab(note.noteId, windowId) != nil
            case .group, nil:
                return false
            }
        } isTargeted: { isTargeted in
            if model.isDraggingTab {
                withAnimation(Self.hoverAnimation) {
                    if isTargeted {
                        tabTargetNoteId = note.noteId
                    } else if tabTargetNoteId == note.noteId {
                        tabTargetNoteId = nil
                    }
                }
                return
            }
            guard model.draggingNoteId != nil else {
                return
            }
            if isTargeted {
                model.noteInsertBeforeId = note.noteId
            } else if model.noteInsertBeforeId == note.noteId {
                model.noteInsertBeforeId = nil
            }
        }
    }

    /// The tab a note leads to: its application, its name now or, once it has closed, its name then.
    private func linkLabel(_ link: NoteLink) -> some View {
        let liveName = model.mapLinkedWindowNames[link.windowId]
        return HStack(spacing: 6) {
            linkIcon(link)
                .frame(width: Self.linkIconSize, height: Self.linkIconSize)
            Text(liveName ?? link.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(liveName == nil)
            Spacer(minLength: 0)
            Image(systemName: liveName == nil ? "xmark" : "arrow.up.forward")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: Self.linkHeight)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(StageColors.idleTab)
        }
        .opacity(liveName == nil ? Self.closedLinkOpacity : 1)
    }

    @ViewBuilder
    private func linkIcon(_ link: NoteLink) -> some View {
        if let icon = ApplicationIcon.icon(forBundleId: link.bundleId) {
            Image(nsImage: icon)
                .resizable()
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: 10))
        }
    }

    private func linkHelp(_ link: NoteLink) -> String {
        model.mapLinkedWindowNames[link.windowId] == nil
            ? "The tab has closed; click to go to its group"
            : "Click to go to the tab"
    }

    /// A click on a note: go to its tab, or edit a note that leads nowhere.
    private func open(_ note: QuickNote) {
        if let link = note.link {
            onOpenLink(link)
        } else {
            onBeginEditing(note.noteId)
        }
    }

    private func cardButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.footerHeight, height: Self.footerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .transition(.opacity)
    }

    private func copy(_ note: QuickNote) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
    }

    /// In the collapsed sidebar: a button to start a note and one per note, which widen the sidebar.
    private var collapsedList: some View {
        VStack(spacing: 4) {
            collapsedButton("square.and.pencil", help: "Write a new note") {
                onExpand()
                startNewNote()
            }
            ForEach(notes.listNotes) { note in
                if let link = note.link {
                    collapsedLinkButton(note, link: link)
                        .transition(.opacity)
                } else {
                    collapsedButton("note.text", help: note.text) {
                        onExpand()
                        onBeginEditing(note.noteId)
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func collapsedButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StageColors.card)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// In the collapsed sidebar, a linked note's button: its tab's application, going to the tab.
    private func collapsedLinkButton(_ note: QuickNote, link: NoteLink) -> some View {
        Button {
            onOpenLink(link)
        } label: {
            linkIcon(link)
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
                .opacity(model.mapLinkedWindowNames[link.windowId] == nil ? Self.closedLinkOpacity : 1)
                .frame(width: 38, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StageColors.card)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(note.text.isEmpty ? model.mapLinkedWindowNames[link.windowId] ?? link.name : note.text)
    }

    private func startNewNote() {
        onBeginEditing(notes.add())
    }

    /// When a note last changed: the time today, else the date.
    private static func modifiedText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A note being written, the caret after its text: return saves, option-return starts a new line, escape puts the text back, and
/// leaving the field, or the sidebar switching away from the notes, saves.
struct NoteEditor: View {
    private static let maxLineCount = 14

    let initialText: String
    let onFinish: (String) -> Void
    @State private var text = ""
    @State private var isFinished = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Note", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...Self.maxLineCount)
                .focused($isFocused)
            Text("↩ Save    ⌥↩ New line    ⎋ Cancel")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StageColors.selectedSegment)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
        }
        .onAppear {
            text = initialText
            isFocused = true
            if !initialText.isEmpty {
                Task { @MainActor in
                    NSApp.sendAction(#selector(NSResponder.moveToEndOfDocument(_:)), to: nil, from: nil)
                }
            }
        }
        .onSubmit {
            finish(with: text)
        }
        .onExitCommand {
            finish(with: initialText)
        }
        .onChange(of: isFocused) { _, isNowFocused in
            if !isNowFocused {
                finish(with: text)
            }
        }
        .onDisappear {
            finish(with: text)
        }
    }

    private func finish(with finalText: String) {
        guard !isFinished else {
            return
        }
        isFinished = true
        onFinish(finalText)
    }
}
