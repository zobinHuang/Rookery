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
            .buttonStyle(.borderedProminent)
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
                Text(fleetModel.graph.name(of: other))
                    .lineLimit(1)
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
