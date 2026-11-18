import AppKit
import RookeryCore
import SwiftUI

/// A titled block of a resource's editor.
struct EditorSection<Content: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StageColors.secondaryText)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.tertiaryText)
                }
            }
            content
        }
    }
}

/// A box of text to edit in place, in the console's tile, with what to write in it while it is empty.
struct EditorTextArea: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 80
    var isMonospaced = false

    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13, design: isMonospaced ? .monospaced : .default))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .focused($isFocused)
            .padding(8)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(StageColors.tertiaryText)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(StageColors.separator))
            }
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// A one-line field in the console's tile.
struct EditorField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(StageColors.separator)
            }
    }
}

/// An editor's buttons: delete at the leading edge, revert and save at the trailing.
struct EditorActions: View {
    let isChanged: Bool
    let isSaving: Bool
    let onDelete: () -> Void
    let onRevert: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack {
            Button("Delete…", role: .destructive, action: onDelete)
            Spacer()
            Button("Revert", action: onRevert)
                .disabled(!isChanged || isSaving)
            Button(action: onSave) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(StageButtonStyle(kind: .prominent))
            .disabled(!isChanged || isSaving)
            .keyboardShortcut("s", modifiers: .command)
        }
    }
}

/// The relations touching a resource, each a click away from its other end.
struct RelationsList: View {
    let fleetModel: FleetModel
    let ref: FleetRef
    let onOpen: (FleetRef) -> Void

    var body: some View {
        let listRelations = fleetModel.graph.listRelations(touching: ref).sorted { $0.lastAt > $1.lastAt }
        EditorSection(title: "Relations") {
            if listRelations.isEmpty {
                Text("None yet")
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.tertiaryText)
            }
            ForEach(listRelations) { relation in
                row(relation)
            }
        }
    }

    private func row(_ relation: FleetRelation) -> some View {
        let other = relation.source == ref ? relation.target : relation.source
        return Button {
            onOpen(other)
        } label: {
            HStack(spacing: 6) {
                RookeryIconView(relation.source == ref ? .arrowRight : .arrowLeft)
                    .foregroundStyle(StageColors.tertiaryText)
                Text(relation.verb)
                    .foregroundStyle(RookmasterStyle.tint(ofVerb: relation.verb))
                RookeryIconView(RookeryIcon.kind(other.kind))
                FittingText(fleetModel.graph.name(of: other), size: 12)
                Spacer(minLength: 0)
                Text("\(relation.count)×")
                    .monospacedDigit()
                    .foregroundStyle(StageColors.tertiaryText)
                Text(RookmasterStyle.age(of: relation.lastAt, now: .now))
                    .foregroundStyle(StageColors.tertiaryText)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What an editor needs to do its work on roost and report how it went.
@MainActor
struct EditorWork {
    let fleetModel: FleetModel
    let ref: FleetRef

    /// Save fields of the resource, reporting a failure.
    func save(_ mapBody: [String: JSONValue], isSaving: Binding<Bool>, error failure: Binding<String?>) {
        isSaving.wrappedValue = true
        Task {
            do {
                try await fleetModel.update(ref, body: mapBody)
                failure.wrappedValue = nil
            } catch {
                failure.wrappedValue = FleetModel.describe(error)
            }
            isSaving.wrappedValue = false
        }
    }

    /// Remove the resource, calling back once roost has.
    func delete(error failure: Binding<String?>, onDeleted: @escaping () -> Void) {
        Task {
            do {
                try await fleetModel.delete(ref)
                onDeleted()
            } catch {
                failure.wrappedValue = FleetModel.describe(error)
            }
        }
    }
}

// MARK: - Skill

/// A skill roost tracks: where it lives and which version, what it is for, the playbooks that load it and
/// the agents that used it. Its name, description and tracked ref can be changed, its version refreshed,
/// and it can be removed.
struct SkillEditor: View {
    let fleetModel: FleetModel
    let resource: FleetResource
    let onOpen: (FleetRef) -> Void
    let onDeleted: () -> Void

    @State private var nameDraft = ""
    @State private var descriptionDraft = ""
    @State private var refDraft = ""
    @State private var isSaving = false
    @State private var isRefreshing = false
    @State private var isConfirmingDelete = false
    @State private var error: String?

    private var ref: FleetRef {
        FleetRef(kind: resource.kind, id: resource.id)
    }

    private var attributes: [String: JSONValue] {
        resource.mapAttributes
    }

    private var isChanged: Bool {
        nameDraft != resource.name
            || descriptionDraft != (attributes["description"]?.stringValue ?? "")
            || refDraft != (attributes["default_ref"]?.stringValue ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleRow
                source
                EditorSection(title: "Description", hint: "when an agent should use it") {
                    EditorTextArea(text: $descriptionDraft, placeholder: "Review a pull request for security issues before merging.", minHeight: 70)
                }
                pinnedBy
                RelationsList(fleetModel: fleetModel, ref: ref, onOpen: onOpen)
                if let error {
                    RookeryLabel(error, icon: .warning)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                EditorActions(
                    isChanged: isChanged,
                    isSaving: isSaving,
                    onDelete: { isConfirmingDelete = true },
                    onRevert: load,
                    onSave: save
                )
            }
            .padding(24)
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete \(resource.name)?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                EditorWork(fleetModel: fleetModel, ref: ref).delete(error: $error, onDeleted: onDeleted)
            }
        } message: {
            Text("roost stops tracking it, and playbooks that load it lose it. This can't be undone.")
        }
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            RookeryIconView(.skill, scale: 1.5)
            TextField("Name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .bold))
            if attributes["discovered"]?.boolValue == true {
                InfoTag("seen in use", tint: .orange)
                    .help("An agent used a skill of this name, but no repository is registered for it")
            }
        }
    }

    private var source: some View {
        let listVersions: [JSONValue] = if case .array(let list) = attributes["versions"] { list } else { [] }
        let latest = listVersions.last
        return VStack(alignment: .leading, spacing: 8) {
            if let repoUrl = attributes["repo_url"]?.stringValue {
                factRow("Repository") {
                    if let url = URL(string: repoUrl), url.scheme?.hasPrefix("http") == true {
                        Link(repoUrl, destination: url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(repoUrl)
                            .textSelection(.enabled)
                    }
                }
            }
            if let path = attributes["skill_path"]?.stringValue {
                factRow("Path") {
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if attributes["repo_url"] != nil {
                factRow("Tracks") {
                    TextField("main", text: $refDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 200)
                    Spacer(minLength: 0)
                    if let commit = latest?["commit"]?.stringValue {
                        InfoTag(String(commit.prefix(10)))
                            .help("The commit roost last resolved it to")
                    }
                    if let resolvedAt = latest?["resolved_at"]?.stringValue {
                        Text(RookmasterStyle.age(of: resolvedAt, now: .now))
                            .font(.system(size: 11))
                            .foregroundStyle(StageColors.tertiaryText)
                    }
                    Button {
                        refresh()
                    } label: {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            RookeryLabel("Refresh", icon: .refresh, spacing: 4)
                        }
                    }
                    .controlSize(.small)
                    .disabled(isRefreshing)
                    .help("Resolve the tracked ref again and record what the repository has now")
                }
            }
        }
        .padding(12)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func factRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(StageColors.secondaryText)
                .frame(width: 80, alignment: .leading)
            content()
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private var pinnedBy: some View {
        let listPlaybooks = fleetModel.graph.listResources(of: "playbook").filter { playbook in
            PlaybookPin.pins(of: playbook).contains { $0.skillId == resource.id }
        }
        if !listPlaybooks.isEmpty {
            EditorSection(title: "Loaded by") {
                HStack(spacing: 6) {
                    ForEach(listPlaybooks, id: \.id) { playbook in
                        Button {
                            onOpen(FleetRef(kind: "playbook", id: playbook.id))
                        } label: {
                            RookeryLabel(playbook.name, icon: .playbook, spacing: 4)
                                .font(.system(size: 12))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(StageColors.tile, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func load() {
        nameDraft = resource.name
        descriptionDraft = attributes["description"]?.stringValue ?? ""
        refDraft = attributes["default_ref"]?.stringValue ?? ""
        error = nil
    }

    private func save() {
        var mapBody: [String: JSONValue] = [
            "name": .string(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
            "description": .string(descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        if !refDraft.isEmpty {
            mapBody["default_ref"] = .string(refDraft.trimmingCharacters(in: .whitespaces))
        }
        EditorWork(fleetModel: fleetModel, ref: ref).save(mapBody, isSaving: $isSaving, error: $error)
    }

    private func refresh() {
        isRefreshing = true
        Task {
            do {
                try await fleetModel.refreshSkill(resource.id)
                error = nil
            } catch {
                self.error = FleetModel.describe(error)
            }
            isRefreshing = false
        }
    }
}

// MARK: - Playbook

/// A playbook: what kind of problem it is for, its steps, and the skills it loads. A step names a skill it
/// uses with `@`; saving pins every skill the steps name, beside those added by hand.
struct PlaybookEditor: View {
    let fleetModel: FleetModel
    let resource: FleetResource
    let onOpen: (FleetRef) -> Void
    let onDeleted: () -> Void

    @State private var nameDraft = ""
    @State private var descriptionDraft = ""
    @State private var promptDraft = ""
    @State private var listPinsDraft: [PlaybookPin] = []
    @State private var isSaving = false
    @State private var isConfirmingDelete = false
    @State private var error: String?

    private var ref: FleetRef {
        FleetRef(kind: resource.kind, id: resource.id)
    }

    private var listSkills: [FleetResource] {
        fleetModel.graph.listResources(of: "skill").filter { $0.mapAttributes["discovered"]?.boolValue != true }
    }

    /// The pins as they would be saved: those held, then the skills the steps newly name.
    private var listPinsToSave: [PlaybookPin] {
        PlaybookSteps.pins(listPinsDraft, adding: PlaybookSteps.skillIds(namedIn: promptDraft, among: listSkills))
    }

    private var isChanged: Bool {
        nameDraft != resource.name
            || descriptionDraft != (resource.mapAttributes["description"]?.stringValue ?? "")
            || promptDraft != (resource.mapAttributes["prompt"]?.stringValue ?? "")
            || listPinsToSave != PlaybookPin.pins(of: resource)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    RookeryIconView(.playbook, scale: 1.5)
                    TextField("Name", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .bold))
                }
                EditorSection(title: "For", hint: "when an agent should follow it") {
                    EditorField(text: $descriptionDraft, placeholder: "Shipping a backend feature that changes the schema")
                }
                EditorSection(title: "Steps", hint: "one a line; name a skill with @ where a step uses it") {
                    EditorTextArea(
                        text: $promptDraft,
                        placeholder: "1. Read the issue and the code it touches.\n2. Write the migration with @db-migrations.\n3. Review the change with @review before opening the pull request.",
                        minHeight: 200
                    )
                }
                skills
                RelationsList(fleetModel: fleetModel, ref: ref, onOpen: onOpen)
                if let error {
                    RookeryLabel(error, icon: .warning)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                EditorActions(
                    isChanged: isChanged,
                    isSaving: isSaving,
                    onDelete: { isConfirmingDelete = true },
                    onRevert: load,
                    onSave: save
                )
            }
            .padding(24)
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete \(resource.name)?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                EditorWork(fleetModel: fleetModel, ref: ref).delete(error: $error, onDeleted: onDeleted)
            }
        } message: {
            Text("Agents can no longer load it. This can't be undone.")
        }
    }

    private var skills: some View {
        let listUnpinned = listSkills.filter { skill in !listPinsToSave.contains { $0.skillId == skill.id } }
        let setNamed = Set(PlaybookSteps.skillIds(namedIn: promptDraft, among: listSkills))
        return EditorSection(title: "Skills", hint: "loaded with the playbook") {
            FlowRow(spacing: 6) {
                ForEach(listPinsToSave) { pin in
                    pinChip(pin, isNamedInSteps: setNamed.contains(pin.skillId))
                }
                Menu {
                    ForEach(listUnpinned, id: \.id) { skill in
                        Button(skill.name) {
                            listPinsDraft.append(PlaybookPin(skillId: skill.id))
                        }
                    }
                } label: {
                    RookeryLabel("Add Skill", icon: .plus, spacing: 4)
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(listUnpinned.isEmpty)
            }
        }
    }

    private func pinChip(_ pin: PlaybookPin, isNamedInSteps: Bool) -> some View {
        let name = fleetModel.graph.resource(FleetRef(kind: "skill", id: pin.skillId))?.name ?? pin.skillId
        return HStack(spacing: 5) {
            Button {
                onOpen(FleetRef(kind: "skill", id: pin.skillId))
            } label: {
                RookeryLabel(name, icon: .skill, spacing: 4)
            }
            .buttonStyle(.plain)
            if pin.pin != PlaybookPin.latest {
                InfoTag(pin.pin)
            }
            if isNamedInSteps {
                InfoTag("in steps", tint: .accentColor)
                    .help("A step names it with @, so saving keeps it")
            } else {
                Button {
                    listPinsDraft.removeAll { $0.skillId == pin.skillId }
                } label: {
                    RookeryIconView(.close)
                        .foregroundStyle(StageColors.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Stop loading it")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(StageColors.tile, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(StageColors.separator)
        }
    }

    private func load() {
        nameDraft = resource.name
        descriptionDraft = resource.mapAttributes["description"]?.stringValue ?? ""
        promptDraft = resource.mapAttributes["prompt"]?.stringValue ?? ""
        listPinsDraft = PlaybookPin.pins(of: resource)
        error = nil
    }

    private func save() {
        let mapBody: [String: JSONValue] = [
            "name": .string(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
            "description": .string(descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
            "prompt": .string(promptDraft),
            "skills": .array(listPinsToSave.map(\.payload)),
        ]
        listPinsDraft = listPinsToSave
        EditorWork(fleetModel: fleetModel, ref: ref).save(mapBody, isSaving: $isSaving, error: $error)
    }
}

// MARK: - Memory

/// A memory an agent wrote down: what it says and which project it is about.
struct MemoryEditor: View {
    let fleetModel: FleetModel
    let resource: FleetResource
    let onOpen: (FleetRef) -> Void
    let onDeleted: () -> Void

    @State private var nameDraft = ""
    @State private var projectDraft = ""
    @State private var textDraft = ""
    @State private var isSaving = false
    @State private var isConfirmingDelete = false
    @State private var error: String?

    private var ref: FleetRef {
        FleetRef(kind: resource.kind, id: resource.id)
    }

    private var isChanged: Bool {
        nameDraft != resource.name
            || projectDraft != (resource.mapAttributes["project"]?.stringValue ?? "")
            || textDraft != (resource.mapAttributes["text"]?.stringValue ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    RookeryIconView(.memory, scale: 1.5)
                    TextField("Name", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .bold))
                }
                EditorSection(title: "Project") {
                    EditorField(text: $projectDraft, placeholder: "the project it is about")
                }
                EditorSection(title: "What to remember") {
                    EditorTextArea(text: $textDraft, placeholder: "Refunds over $500 need a second approver.", minHeight: 180)
                }
                if let path = resource.mapAttributes["path"]?.stringValue {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StageColors.tertiaryText)
                        .textSelection(.enabled)
                }
                RelationsList(fleetModel: fleetModel, ref: ref, onOpen: onOpen)
                if let error {
                    RookeryLabel(error, icon: .warning)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                EditorActions(
                    isChanged: isChanged,
                    isSaving: isSaving,
                    onDelete: { isConfirmingDelete = true },
                    onRevert: load,
                    onSave: save
                )
            }
            .padding(24)
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete \(resource.name)?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                EditorWork(fleetModel: fleetModel, ref: ref).delete(error: $error, onDeleted: onDeleted)
            }
        } message: {
            Text("roost forgets it and its relations. This can't be undone.")
        }
    }

    private func load() {
        nameDraft = resource.name
        projectDraft = resource.mapAttributes["project"]?.stringValue ?? ""
        textDraft = resource.mapAttributes["text"]?.stringValue ?? ""
        error = nil
    }

    private func save() {
        let mapBody: [String: JSONValue] = [
            "name": .string(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
            "attributes": .object([
                "project": .string(projectDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
                "text": .string(textDraft),
            ]),
        ]
        EditorWork(fleetModel: fleetModel, ref: ref).save(mapBody, isSaving: $isSaving, error: $error)
    }
}

/// Views laid out left to right, wrapping onto a new line where the width runs out.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    /// Whether each line sits at the trailing edge rather than the leading one.
    var isTrailing = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let listLines = lines(of: subviews, within: maxWidth)
        let widest = listLines.map(\.width).max() ?? 0
        let height = listLines.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, listLines.count - 1))
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(of: subviews, within: bounds.width) {
            var x = isTrailing ? bounds.maxX - line.width : bounds.minX
            for (index, size) in zip(line.listIndices, line.listSizes) {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    /// The subviews laid out in lines that fit a width, each no wider than the width itself.
    private func lines(of subviews: Subviews, within maxWidth: CGFloat) -> [FlowLine] {
        var listLines: [FlowLine] = []
        var current = FlowLine()
        for index in subviews.indices {
            let natural = subviews[index].sizeThatFits(.unspecified)
            let size = CGSize(width: min(natural.width, maxWidth), height: natural.height)
            if !current.listIndices.isEmpty, current.width + spacing + size.width > maxWidth {
                listLines.append(current)
                current = FlowLine()
            }
            current.width += (current.listIndices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.listIndices.append(index)
            current.listSizes.append(size)
        }
        if !current.listIndices.isEmpty {
            listLines.append(current)
        }
        return listLines
    }
}

/// One line of a `FlowRow`: which subviews it holds, at what sizes, and how wide and tall it is.
struct FlowLine {
    var listIndices: [Int] = []
    var listSizes: [CGSize] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
}

// MARK: - Agent

/// An agent as roost holds it: its crow and title, where it runs, its session, what it touched, and any
/// other facts roost keeps about it, each laid out as a fact rather than as data.
struct AgentInspector: View {
    /// The attributes the page lays out itself; any other shows under Other.
    private static let setShownAttributes: Set<String> = [
        "state", "title", "harness", "rook_name", "tab", "machine", "cwd", "git_branch", "model",
        "opened_at", "closed_at", "transcript_path",
    ]

    let fleetModel: FleetModel
    let resource: FleetResource
    let onOpen: (FleetRef) -> Void

    private var ref: FleetRef {
        FleetRef(kind: resource.kind, id: resource.id)
    }

    private var attributes: [String: JSONValue] {
        resource.mapAttributes
    }

    private var agent: FleetAgent? {
        fleetModel.fleet.mapAgents[resource.id]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                FactCard(title: "Where it runs") {
                    machineFacts
                }
                FactCard(title: "Session") {
                    sessionFacts
                }
                RelationsList(fleetModel: fleetModel, ref: ref, onOpen: onOpen)
                otherFacts
            }
            .padding(24)
        }
    }

    private var header: some View {
        let state = agent?.state ?? AgentState(rawValue: attributes["state"]?.stringValue ?? "") ?? .ended
        let isOnline = agent.map { fleetModel.fleet.isOnline($0) } ?? false
        return HStack(alignment: .center, spacing: 14) {
            CrowView(state: state, size: .large)
            VStack(alignment: .leading, spacing: 6) {
                FittingText(resource.displayName, size: 20, weight: .bold)
                    .textSelection(.enabled)
                HStack(spacing: 5) {
                    InfoTag(state.title, tint: state.needsAttention ? .orange : nil)
                    if state != .ended {
                        InfoTag(isOnline ? "online" : "offline", tint: isOnline ? .green : .orange)
                    }
                    if let harness = attributes["harness"]?.stringValue {
                        InfoTag(harness)
                    }
                    if let model = attributes["model"]?.stringValue {
                        InfoTag(model)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                onOpen(ref)
            } label: {
                RookeryLabel("Open Agent", icon: .arrowRight, spacing: 4)
            }
            .buttonStyle(StageButtonStyle(kind: .prominent))
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var machineFacts: some View {
        let machine = attributes["machine"]
        if let rookName = attributes["rook_name"]?.stringValue {
            FactRow(title: "Rook", icon: .link) {
                Text(rookName)
                if let tab = attributes["tab"]?.stringValue, !tab.isEmpty {
                    InfoTag("window \(tab)")
                }
            }
        }
        if let hostname = machine?["hostname"]?.stringValue {
            FactRow(title: "Hostname", icon: .chip) {
                Text(hostname)
                    .help("The name the machine's own system goes by, which may differ from its rook's name")
                ForEach([machine?["os"]?.stringValue, machine?["arch"]?.stringValue, machine?["user"]?.stringValue].compactMap { $0 }, id: \.self) { fact in
                    InfoTag(fact)
                }
            }
        }
        if let cwd = attributes["cwd"]?.stringValue, !cwd.isEmpty {
            FactRow(title: "Directory", icon: .folder) {
                Text(cwd)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let branch = attributes["git_branch"]?.stringValue, !branch.isEmpty {
            FactRow(title: "Branch", icon: .branch) {
                Text(branch)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var sessionFacts: some View {
        FactRow(title: "Session", icon: .terminal) {
            Text(resource.id)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        }
        if let openedAt = attributes["opened_at"]?.stringValue {
            FactRow(title: "Opened", icon: .clock) {
                Text(Self.moment(openedAt))
                Text("\(RookmasterStyle.age(of: openedAt, now: .now)) ago")
                    .foregroundStyle(StageColors.tertiaryText)
            }
        }
        if let closedAt = attributes["closed_at"]?.stringValue {
            FactRow(title: "Closed", icon: .clock) {
                Text(Self.moment(closedAt))
                Text("\(RookmasterStyle.age(of: closedAt, now: .now)) ago")
                    .foregroundStyle(StageColors.tertiaryText)
            }
        }
        FactRow(title: "Last active", icon: .clock) {
            Text(Self.moment(resource.lastUsedAt))
            Text("\(RookmasterStyle.age(of: resource.lastUsedAt, now: .now)) ago")
                .foregroundStyle(StageColors.tertiaryText)
        }
        if let path = attributes["transcript_path"]?.stringValue {
            FactRow(title: "Transcript", icon: .book) {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StageColors.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var otherFacts: some View {
        let listKeys = attributes.keys.filter { key in
            !Self.setShownAttributes.contains(key) && attributes[key].map(FactValue.text(of:))?.isEmpty == false
        }.sorted()
        if !listKeys.isEmpty {
            FactCard(title: "Other") {
                ForEach(listKeys, id: \.self) { key in
                    FactRow(title: FactValue.title(of: key), icon: nil) {
                        Text(attributes[key].map(FactValue.text(of:)) ?? "")
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// A timestamp as a date and time on this Mac's clock.
    private static func moment(_ timestamp: String) -> String {
        guard let date = FleetTimestamp.date(from: timestamp) else {
            return timestamp
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A titled card of facts, one a row.
struct FactCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StageColors.secondaryText)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(StageColors.separator)
            }
        }
    }
}

/// One fact: what it is, with an icon, and its value beside it.
struct FactRow<Content: View>: View {
    let title: String
    let icon: RookeryIcon?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 6) {
                if let icon {
                    RookeryIconView(icon)
                        .foregroundStyle(StageColors.tertiaryText)
                }
                Text(title)
                    .foregroundStyle(StageColors.secondaryText)
            }
            .frame(width: FactValue.titleWidth, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                content
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }
}

/// How a fact roost keeps reads to a person: its key in words, its value as text.
enum FactValue {
    /// The width of a fact's title column, so the values line up.
    static let titleWidth: CGFloat = 96

    /// A key such as `git_branch` as "Git branch".
    static func title(of key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A value as text: a string as it is, a number or flag in words, a list or object as its parts.
    static func text(of value: JSONValue) -> String {
        switch value {
        case .null:
            return ""
        case .string(let string):
            return string
        case .number(let number):
            return number.formatted()
        case .bool(let flag):
            return flag ? "yes" : "no"
        case .array(let listValues):
            return listValues.map(text(of:)).filter { !$0.isEmpty }.joined(separator: ", ")
        case .object(let mapValues):
            return mapValues.keys.sorted().compactMap { key in
                let part = mapValues[key].map(text(of:)) ?? ""
                return part.isEmpty ? nil : "\(title(of: key)): \(part)"
            }.joined(separator: "\n")
        }
    }
}
