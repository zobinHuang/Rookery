import RookeryCore
import SwiftUI

/// A request as the box hands it to Raven: the words, the resources they name, and for each person named
/// the address the user chose for them, by the person's id; a person with none chosen goes with all of
/// theirs.
struct RavenRequest {
    let text: String
    let listMentions: [FleetRef]
    let mapAddresses: [String: String]

    /// What a request names, in lines a code agent reads under it: each resource by its kind, name and id,
    /// and each person by their mention, with the address the user chose or every one of theirs.
    ///
    /// - Parameters:
    ///   - listMentions: the resources named, a resource named twice listed once
    ///   - listPeople: the people named
    ///   - mapAddresses: the address chosen for each person, by the person's id
    ///   - graph: roost's resources, which name them
    /// - Returns: the lines, a blank line before each part; none when nothing is named
    static func mentionLines(
        listMentions: [FleetRef],
        listPeople: [Person],
        mapAddresses: [String: String],
        graph: ResourceGraph
    ) -> [String] {
        var listLines: [String] = []
        let listUnique = listMentions.reduce(into: [FleetRef]()) { list, ref in
            if !list.contains(ref) {
                list.append(ref)
            }
        }
        if !listUnique.isEmpty {
            listLines.append("")
            listLines.append("The request names these resources:")
            for ref in listUnique {
                listLines.append("- \(ref.kind) \"\(graph.name(of: ref))\" (id \(ref.id))")
            }
        }
        if !listPeople.isEmpty {
            listLines.append("")
            listLines.append("The request names these people, by their mention; write to them and invite them at these addresses:")
            for person in listPeople {
                if let chosen = mapAddresses[person.id] {
                    let listOthers = person.listAddresses.filter { $0 != chosen }
                    let others = listOthers.isEmpty ? "" : " (their other addresses: \(listOthers.joined(separator: ", ")))"
                    listLines.append("- \(person.mentionToken) is \(person.name): the user chose \(chosen); use that address\(others)")
                } else {
                    let addresses = person.listAddresses.isEmpty ? "no address known" : person.listAddresses.joined(separator: ", ")
                    listLines.append("- \(person.mentionToken) is \(person.name): \(addresses)")
                }
            }
        }
        return listLines
    }
}

/// The box to ask Raven in, wherever Raven is asked: plain words, people and roost's resources named with
/// @ and chosen from suggestions floating over the box, the arrows, Tab and Return working them. Choosing
/// a person with several addresses turns the suggestions into their addresses, to pick one or go with
/// none; the people named show over the box with their marks and the address chosen.
struct RavenComposer: View {
    let fleetModel: FleetModel
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let isBusy: Bool
    var fontSize: CGFloat = 12
    /// Stops the work under way, while busy; nil where nothing can be stopped.
    var onStop: (() -> Void)?
    /// Sends the request.
    let onSend: (RavenRequest) -> Void
    var isFocused: FocusState<Bool>.Binding
    /// Takes a key the suggestions do not, before the box does, as the launcher's Escape.
    var onKey: ((ComposerKey) -> Bool)?

    @State private var listMentions: [FleetRef] = []
    /// The address chosen for each person named, by the person's id.
    @State private var mapAddresses: [String: String] = [:]
    /// The person whose address is being chosen, the suggestions their addresses meanwhile.
    @State private var choosingPerson: Person?
    /// A person just picked, with the text picking them left, whose address is chosen once the box shows it.
    @State private var pickedPerson: Person?
    @State private var pickedText: String?
    @State private var highlightedIndex = 0

    private var listSuggestions: [MentionTarget] {
        fleetModel.mentionTargets(in: text)
    }

    /// How many rows the suggestions show: a person's addresses and None, or the mention targets.
    private var rowCount: Int {
        choosingPerson.map { $0.listAddresses.count + 1 } ?? listSuggestions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottomLeading) {
                    if let choosingPerson {
                        addressList(of: choosingPerson)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 4)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    } else if !listSuggestions.isEmpty {
                        suggestions
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 4)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: listSuggestions.map(\.id))
                .animation(.easeOut(duration: 0.15), value: choosingPerson?.id)
            let listNamedPeople = fleetModel.people.book.people(mentionedIn: text)
            if !listNamedPeople.isEmpty {
                FlowRow(spacing: 5) {
                    ForEach(listNamedPeople) { person in
                        HStack(spacing: 5) {
                            PersonMark(person: person, size: 16)
                            Text(person.name)
                                .font(.system(size: 11, weight: .semibold))
                            if let address = mapAddresses[person.id] {
                                Text(address)
                                    .font(.system(size: 11))
                                    .foregroundStyle(StageColors.secondaryText)
                            }
                        }
                        .padding(.leading, 2)
                        .padding(.trailing, 8)
                        .padding(.vertical, 2)
                        .background(StageColors.segmentGroove, in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(StageColors.segmentGrooveBorder)
                        }
                        .help(mapAddresses[person.id] ?? person.listAddresses.joined(separator: ", "))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            AgentComposer(
                text: $text,
                placeholder: placeholder,
                isEnabled: isEnabled,
                isBusy: isBusy,
                fontSize: fontSize,
                onStop: onStop,
                onSend: send,
                onKey: takeKey,
                isFocused: isFocused
            )
            .onChange(of: text) { _, newText in
                highlightedIndex = 0
                choosingPerson = newText == pickedText ? pickedPerson : nil
                pickedPerson = nil
                pickedText = nil
            }
        }
    }

    private var suggestions: some View {
        listBox {
            ForEach(Array(listSuggestions.enumerated()), id: \.element.id) { index, target in
                row(isHighlighted: index == highlightedIndex) {
                    pick(target)
                } content: {
                    switch target {
                    case .person(let person):
                        PersonMark(person: person, size: 18)
                            .frame(width: 16)
                        Text(person.name)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(person.listAddresses.count > 1 ? "\(person.listAddresses.count) addresses" : person.listAddresses.first ?? "person")
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
            }
        }
    }

    /// A person's addresses to choose from, None first.
    private func addressList(of person: Person) -> some View {
        listBox {
            HStack(spacing: 6) {
                PersonMark(person: person, size: 16)
                Text("Which address for \(person.name)?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StageColors.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
            row(isHighlighted: highlightedIndex == 0) {
                chooseAddress(nil)
            } content: {
                RookeryIconView(.mail)
                    .frame(width: 16)
                Text("Any of their addresses")
                Spacer(minLength: 4)
            }
            ForEach(Array(person.listAddresses.enumerated()), id: \.offset) { index, address in
                row(isHighlighted: highlightedIndex == index + 1) {
                    chooseAddress(address)
                } content: {
                    Color.clear
                        .frame(width: 16)
                    Text(address)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
            }
        }
    }

    private func listBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            content()
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

    private func row<Content: View>(isHighlighted: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content()
            }
            .font(.system(size: 12))
            .foregroundStyle(isHighlighted ? AnyShapeStyle(StageColors.selectedSegmentText) : AnyShapeStyle(StageColors.primaryText))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(StageColors.selectedSegment)
                        .strokeBorder(StageColors.contrastActiveBorder)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The keys that work the suggestions while they show; the rest go to the caller first.
    private func takeKey(_ key: ComposerKey) -> Bool {
        let isShowing = choosingPerson != nil || !listSuggestions.isEmpty
        switch key {
        case .up where isShowing:
            return moveHighlight(by: -1)
        case .down where isShowing:
            return moveHighlight(by: 1)
        case .tab where isShowing, .send where isShowing:
            return pickHighlighted()
        case .escape where choosingPerson != nil:
            chooseAddress(nil)
            return true
        default:
            return onKey?(key) ?? false
        }
    }

    private func moveHighlight(by step: Int) -> Bool {
        guard rowCount > 0 else {
            return false
        }
        highlightedIndex = (highlightedIndex + step + rowCount) % rowCount
        return true
    }

    private func pickHighlighted() -> Bool {
        if let choosingPerson {
            chooseAddress(highlightedIndex == 0 ? nil : choosingPerson.listAddresses[highlightedIndex - 1])
            return true
        }
        guard listSuggestions.indices.contains(highlightedIndex) else {
            return false
        }
        pick(listSuggestions[highlightedIndex])
        return true
    }

    private func pick(_ target: MentionTarget) {
        switch target {
        case .person(let person):
            let completed = Mentions.complete(text, with: person)
            mapAddresses[person.id] = nil
            if person.listAddresses.count > 1 {
                pickedPerson = person
                pickedText = completed
            }
            text = completed
        case .resource(let resource):
            text = Mentions.complete(text, with: resource)
            listMentions.append(FleetRef(kind: resource.kind, id: resource.id))
        }
        isFocused.wrappedValue = true
    }

    /// Settle the address of the person being chosen for: one of theirs, or nil for any.
    private func chooseAddress(_ address: String?) {
        if let person = choosingPerson {
            mapAddresses[person.id] = address
        }
        choosingPerson = nil
        highlightedIndex = 0
        isFocused.wrappedValue = true
    }

    /// Send the request with the resources it still names and the addresses of the people it still names,
    /// and forget them for the next.
    private func send() {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isBusy else {
            return
        }
        let listNamed = listMentions.filter { ref in
            fleetModel.graph.resource(ref).map { request.contains(Mentions.token(for: $0)) } ?? false
        }
        let setNamedPeople = Set(fleetModel.people.book.people(mentionedIn: request).map(\.id))
        onSend(RavenRequest(text: request, listMentions: listNamed, mapAddresses: mapAddresses.filter { setNamedPeople.contains($0.key) }))
        listMentions = []
        mapAddresses = [:]
        isFocused.wrappedValue = true
    }
}
