import RookeryCore
import SwiftUI

/// The box to ask Raven in, wherever Raven is asked: plain words, people and roost's resources named with
/// @ and chosen from suggestions floating over the box, the arrows, Tab and Return working them; the
/// people named shown over the box with their marks. Sending hands over the request and the resources it
/// still names.
struct RavenComposer: View {
    let fleetModel: FleetModel
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let isBusy: Bool
    let onStop: () -> Void
    /// Sends the request, with the resources it names.
    let onSend: (String, [FleetRef]) -> Void
    var isFocused: FocusState<Bool>.Binding

    @State private var listMentions: [FleetRef] = []
    @State private var highlightedIndex = 0

    private var listSuggestions: [MentionTarget] {
        fleetModel.mentionTargets(in: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottomLeading) {
                    if !listSuggestions.isEmpty {
                        suggestions
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 4)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: listSuggestions.map(\.id))
            let listNamedPeople = fleetModel.people.book.people(mentionedIn: text)
            if !listNamedPeople.isEmpty {
                FlowRow(spacing: 5) {
                    ForEach(listNamedPeople) { person in
                        HStack(spacing: 5) {
                            PersonMark(person: person, size: 16)
                            Text(person.name)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.leading, 2)
                        .padding(.trailing, 8)
                        .padding(.vertical, 2)
                        .background(StageColors.segmentGroove, in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(StageColors.segmentGrooveBorder)
                        }
                        .help(person.listAddresses.joined(separator: ", "))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            AgentComposer(
                text: $text,
                placeholder: placeholder,
                isEnabled: isEnabled,
                isBusy: isBusy,
                fontSize: 12,
                onStop: onStop,
                onSend: send,
                onKey: takeSuggestionKey,
                isFocused: isFocused
            )
            .onChange(of: text) {
                highlightedIndex = 0
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(listSuggestions.enumerated()), id: \.element.id) { index, target in
                Button {
                    pick(target)
                } label: {
                    HStack(spacing: 8) {
                        switch target {
                        case .person(let person):
                            PersonMark(person: person, size: 18)
                                .frame(width: 16)
                            Text(person.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(person.listAddresses.first ?? "person")
                                .opacity(0.6)
                                .lineLimit(1)
                        case .resource(let resource):
                            RookeryIconView(RookeryIcon.kind(resource.kind))
                                .frame(width: 16)
                            Text(resource.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(resource.kind)
                                .opacity(0.6)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(index == highlightedIndex ? AnyShapeStyle(StageColors.selectedSegmentText) : AnyShapeStyle(StageColors.primaryText))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        if index == highlightedIndex {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(StageColors.selectedSegment)
                                .strokeBorder(StageColors.contrastActiveBorder)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StageColors.window)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(StageColors.card)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StageColors.separator)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    /// The keys that work the suggestions while they show.
    private func takeSuggestionKey(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .upArrow:
            return moveHighlight(by: -1)
        case .downArrow:
            return moveHighlight(by: 1)
        case .tab:
            return pickHighlighted()
        case .return where !listSuggestions.isEmpty:
            return pickHighlighted()
        default:
            return .ignored
        }
    }

    private func moveHighlight(by step: Int) -> KeyPress.Result {
        guard !listSuggestions.isEmpty else {
            return .ignored
        }
        highlightedIndex = (highlightedIndex + step + listSuggestions.count) % listSuggestions.count
        return .handled
    }

    private func pickHighlighted() -> KeyPress.Result {
        guard listSuggestions.indices.contains(highlightedIndex) else {
            return .ignored
        }
        pick(listSuggestions[highlightedIndex])
        return .handled
    }

    private func pick(_ target: MentionTarget) {
        switch target {
        case .person(let person):
            text = Mentions.complete(text, with: person)
        case .resource(let resource):
            text = Mentions.complete(text, with: resource)
            listMentions.append(FleetRef(kind: resource.kind, id: resource.id))
        }
        isFocused.wrappedValue = true
    }

    /// Send the request with the resources it still names, and empty the box.
    private func send() {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isBusy else {
            return
        }
        let listNamed = listMentions.filter { ref in
            fleetModel.graph.resource(ref).map { request.contains(Mentions.token(for: $0)) } ?? false
        }
        onSend(request, listNamed)
        listMentions = []
        isFocused.wrappedValue = true
    }
}
