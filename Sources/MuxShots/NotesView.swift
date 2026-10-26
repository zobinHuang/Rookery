import AppKit
import MuxShotsCore
import SwiftUI

/// The sidebar's quick notes: a button to start one, then the notes newest first as cards. A click edits a
/// note in place, the trash button or the context menu deletes it, and a note left blank goes away.
struct NotesView: View {
    private static let listAnimation = Animation.spring(response: 0.3, dampingFraction: 0.86)
    private static let hoverAnimation = Animation.easeOut(duration: 0.12)
    private static let cornerRadius: CGFloat = 10
    /// How many lines a note shows before it is cut short, until it is edited.
    private static let previewLineLimit = 8
    /// The row under a note's text, holding when it changed and, under the pointer, its buttons.
    private static let footerHeight: CGFloat = 20

    let notes: QuickNotes
    let model: StageModel
    let isCollapsed: Bool
    /// Take keyboard input and edit a note.
    let onBeginEditing: (NoteId) -> Void
    /// Give keyboard input back once a note is no longer edited.
    let onFinishEditing: () -> Void
    /// Widen the collapsed sidebar, so a note can be read or edited.
    let onExpand: () -> Void
    @State private var hoveredNoteId: NoteId?
    @State private var isNewNoteHovered = false

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
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
                Text("New Note")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isNewNoteHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(isNewNoteHovered ? StageColors.hoveredRow : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(StageColors.groove, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(Self.hoverAnimation) {
                isNewNoteHovered = isHovered
            }
        }
        .help("Write a new note")
    }

    private func noteCard(_ note: QuickNote) -> some View {
        let isHovered = hoveredNoteId == note.noteId
        return VStack(alignment: .leading, spacing: 3) {
            Text(note.text)
                .font(.system(size: 12))
                .lineLimit(Self.previewLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onBeginEditing(note.noteId)
                }
            HStack(spacing: 2) {
                Text(Self.modifiedText(note.modifiedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onBeginEditing(note.noteId)
                    }
                if isHovered {
                    cardButton("doc.on.doc", help: "Copy the note") {
                        copy(note)
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
        .onHover { isNowHovered in
            withAnimation(Self.hoverAnimation) {
                if isNowHovered {
                    hoveredNoteId = note.noteId
                } else if hoveredNoteId == note.noteId {
                    hoveredNoteId = nil
                }
            }
        }
        .contextMenu {
            Button("Edit") {
                onBeginEditing(note.noteId)
            }
            Button("Copy") {
                copy(note)
            }
            Divider()
            Button("Delete", role: .destructive) {
                notes.remove(note.noteId)
            }
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
                collapsedButton("note.text", help: note.text) {
                    onExpand()
                    onBeginEditing(note.noteId)
                }
                .transition(.opacity)
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
