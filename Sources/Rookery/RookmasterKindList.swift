import RookeryCore
import SwiftUI

/// One kind's resources in the Rookmaster console: a searchable list, and beside it the selected one's
/// fields, its relations and, for the kinds the console edits, its name and attributes to change or the
/// resource to remove. Skills and playbooks keep their own shape and are changed through rook.
struct RookmasterKindList: View {
    private static let listWidth: CGFloat = 300
    /// The kinds whose resources the console edits as a name and attributes.
    private static let setReadOnlyKinds: Set<String> = ["skill", "playbook", "agent"]

    let fleetModel: FleetModel
    let kind: String
    @Binding var selectedRef: FleetRef?
    let onOpen: (FleetRef) -> Void

    @State private var query = ""

    private var listResources: [FleetResource] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        return fleetModel.graph.listResources(of: kind).filter { resource in
            trimmed.isEmpty || "\(resource.name) \(resource.id)".lowercased().contains(trimmed)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: Self.listWidth)
            Rectangle()
                .fill(StageColors.separator)
                .frame(width: 1)
            Group {
                if let selectedRef, selectedRef.kind == kind, let resource = fleetModel.graph.resource(selectedRef) {
                    ResourceInspector(
                        fleetModel: fleetModel,
                        resource: resource,
                        isEditable: !Self.setReadOnlyKinds.contains(kind),
                        onOpen: onOpen,
                        onDeleted: { self.selectedRef = nil }
                    )
                    .id(selectedRef)
                } else {
                    VStack(spacing: 8) {
                        PixelIconView(PixelIcon.kind(kind), scale: 3)
                            .foregroundStyle(StageColors.tertiaryText)
                        Text(listResources.isEmpty ? "Nothing here yet" : "Choose one to see it")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StageColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                PixelIconView(.search)
                    .foregroundStyle(StageColors.secondaryText)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(StageColors.groove, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(listResources, id: \.id) { resource in
                        row(resource)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private func row(_ resource: FleetResource) -> some View {
        let ref = FleetRef(kind: resource.kind, id: resource.id)
        let isSelected = selectedRef == ref
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedRef = ref
            }
        } label: {
            HStack(spacing: 8) {
                if let agent = fleetModel.fleet.mapAgents[resource.id], resource.kind == AgentFleet.agentKind {
                    CrowView(state: agent.state, size: 24)
                } else {
                    PixelIconView(PixelIcon.kind(resource.kind))
                        .foregroundStyle(RookmasterStyle.tint(of: resource.kind))
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(resource.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(resource.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StageColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text(RookmasterStyle.age(of: resource.lastUsedAt, now: .now))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(StageColors.tertiaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(StageColor.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One resource's fields and relations, and its name and attributes to edit when its kind allows.
private struct ResourceInspector: View {
    let fleetModel: FleetModel
    let resource: FleetResource
    let isEditable: Bool
    let onOpen: (FleetRef) -> Void
    let onDeleted: () -> Void

    @State private var nameDraft = ""
    @State private var attributesDraft = ""
    @State private var error: String?
    @State private var isSaving = false
    @State private var isConfirmingDelete = false

    private var ref: FleetRef {
        FleetRef(kind: resource.kind, id: resource.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    PixelIconView(PixelIcon.kind(resource.kind))
                        .foregroundStyle(RookmasterStyle.tint(of: resource.kind))
                    if isEditable {
                        TextField("Name", text: $nameDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 18, weight: .bold))
                    } else {
                        Text(resource.name)
                            .font(.system(size: 18, weight: .bold))
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    if resource.kind == AgentFleet.agentKind {
                        Button("Open Agent") {
                            onOpen(ref)
                        }
                    }
                }
                Text("\(resource.kind) · \(resource.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StageColors.secondaryText)
                    .textSelection(.enabled)
                relations
                attributes
                if let error {
                    PixelLabel(error, icon: .warning)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                if isEditable {
                    HStack {
                        Button("Delete…", role: .destructive) {
                            isConfirmingDelete = true
                        }
                        Spacer()
                        Button("Revert") {
                            load()
                        }
                        .disabled(!isChanged)
                        Button {
                            save()
                        } label: {
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
                } else if resource.kind != AgentFleet.agentKind {
                    Text("Change \(resource.kind)s with rook \(resource.kind) on a machine, or ask the maintenance agent.")
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.secondaryText)
                }
            }
            .padding(24)
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete \(resource.name)?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                delete()
            }
        } message: {
            Text("roost removes it and its relations. This can't be undone.")
        }
    }

    private var relations: some View {
        let listRelations = fleetModel.graph.listRelations(touching: ref).sorted { $0.lastAt > $1.lastAt }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Relations")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StageColors.secondaryText)
            if listRelations.isEmpty {
                Text("None yet")
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.tertiaryText)
            }
            ForEach(listRelations) { relation in
                let other = relation.source == ref ? relation.target : relation.source
                let isOutgoing = relation.source == ref
                Button {
                    onOpen(other)
                } label: {
                    HStack(spacing: 6) {
                        PixelIconView(isOutgoing ? .arrowRight : .arrowLeft)
                            .foregroundStyle(StageColors.tertiaryText)
                        Text(relation.verb)
                            .foregroundStyle(RookmasterStyle.tint(ofVerb: relation.verb))
                        PixelIconView(PixelIcon.kind(other.kind))
                            .foregroundStyle(RookmasterStyle.tint(of: other.kind))
                        Text(fleetModel.graph.name(of: other))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(relation.count)× · \(RookmasterStyle.age(of: relation.lastAt, now: .now))")
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
    }

    private var attributes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attributes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StageColors.secondaryText)
            if isEditable {
                TextEditor(text: $attributesDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 180)
                    .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text(Self.pretty(resource.mapAttributes))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var isChanged: Bool {
        nameDraft != resource.name || attributesDraft != Self.pretty(resource.mapAttributes)
    }

    private func load() {
        nameDraft = resource.name
        attributesDraft = Self.pretty(resource.mapAttributes)
        error = nil
    }

    private func save() {
        let mapAttributes: [String: JSONValue]
        do {
            mapAttributes = try JSONDecoder().decode([String: JSONValue].self, from: Data(attributesDraft.utf8))
        } catch {
            self.error = "The attributes are not a JSON object."
            return
        }
        isSaving = true
        Task {
            do {
                try await fleetModel.update(ref, name: nameDraft == resource.name ? nil : nameDraft, attributes: mapAttributes)
                error = nil
            } catch {
                self.error = FleetModel.describe(error)
            }
            isSaving = false
        }
    }

    private func delete() {
        Task {
            do {
                try await fleetModel.delete(ref)
                onDeleted()
            } catch {
                self.error = FleetModel.describe(error)
            }
        }
    }

    private static func pretty(_ mapAttributes: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(mapAttributes) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
