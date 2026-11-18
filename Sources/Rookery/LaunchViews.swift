import RookeryCore
import SwiftUI

/// What an agent begins with, as a workdir keeps it or a launch asks for it: its harness, the playbook and
/// skills installed first, who it is, and the teams it joins with a duty in each.
struct LaunchOptionsEditor: View {
    let fleetModel: FleetModel
    @Binding var workdir: Workdir

    private var listPlaybooks: [FleetResource] {
        fleetModel.graph.listResources(of: "playbook").sorted { $0.displayName < $1.displayName }
    }

    private var listSkills: [FleetResource] {
        fleetModel.graph.listResources(of: "skill")
            .filter { $0.mapAttributes["discovered"]?.boolValue != true }
            .sorted { $0.displayName < $1.displayName }
    }

    private var listTeams: [FleetResource] {
        fleetModel.graph.listResources(of: AgentFleet.teamKind).sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorSection(title: "Agent") {
                StageSegmentedControl(
                    selection: $workdir.harness,
                    listOptions: Workdir.listHarnesses,
                    title: { $0 == Workdir.harnessCodex ? "Codex" : "Claude Code" }
                )
            }
            EditorSection(title: "Playbook", hint: "installed into the directory before it starts") {
                Picker("Playbook", selection: $workdir.playbookId) {
                    Text("None").tag(String?.none)
                    ForEach(listPlaybooks, id: \.id) { playbook in
                        Text(playbook.displayName).tag(String?.some(playbook.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            EditorSection(title: "Skills", hint: "besides the playbook's") {
                skills
            }
            EditorSection(title: "Role", hint: "who it is to its teammates") {
                EditorField(text: $workdir.role, placeholder: "Owner of the CUDA profiler")
            }
            EditorSection(title: "Teams", hint: "it joins as it starts, each with its duty there") {
                teams
            }
        }
    }

    private var skills: some View {
        FlowRow(spacing: 6) {
            ForEach(listSkills, id: \.id) { skill in
                let isChosen = workdir.listSkillIds.contains(skill.id)
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        if isChosen {
                            workdir.listSkillIds.removeAll { $0 == skill.id }
                        } else {
                            workdir.listSkillIds.append(skill.id)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        RookeryIconView(isChosen ? .check : .plus)
                        Text(skill.displayName)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(isChosen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.secondaryText))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(isChosen ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(StageColors.tile), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(isChosen ? AnyShapeStyle(Color.accentColor.opacity(0.45)) : AnyShapeStyle(StageColors.separator))
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if listSkills.isEmpty {
                Text("roost holds no skills yet")
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.tertiaryText)
            }
        }
    }

    private var teams: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(workdir.listTeams.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    RookeryIconView(.agent)
                    Text(fleetModel.graph.resource(FleetRef(kind: AgentFleet.teamKind, id: workdir.listTeams[index].teamId))?.displayName ?? workdir.listTeams[index].teamId)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(minWidth: 90, alignment: .leading)
                    EditorField(text: $workdir.listTeams[index].duty, placeholder: "Its duty in the team")
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            _ = workdir.listTeams.remove(at: index)
                        }
                    } label: {
                        RookeryIconView(.close)
                            .foregroundStyle(StageColors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Leave this team out")
                }
            }
            let listOpen = listTeams.filter { team in !workdir.listTeams.contains { $0.teamId == team.id } }
            Menu {
                ForEach(listOpen, id: \.id) { team in
                    Button(team.displayName) {
                        withAnimation(.easeOut(duration: 0.12)) {
                            workdir.listTeams.append(LaunchTeam(teamId: team.id, duty: ""))
                        }
                    }
                }
            } label: {
                RookeryLabel(listTeams.isEmpty ? "No teams yet" : "Join a Team", icon: .plus, spacing: 4)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(listOpen.isEmpty)
        }
    }
}

/// A walk through the directories on a host over ssh, to choose one.
struct RemoteDirectoryBrowser: View {
    private static let listHeight: CGFloat = 200

    let hosts: HostsModel
    let alias: String
    let startPath: String
    let onChoose: (String) -> Void
    let onCancel: () -> Void

    @State private var directory: RemoteDirectory?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    if let parent = directory?.parent {
                        load(parent)
                    }
                } label: {
                    RookeryIconView(.arrowUp)
                }
                .buttonStyle(.plain)
                .disabled(directory?.parent == nil || isLoading)
                .help("Up one directory")
                Text(directory?.path ?? startPath)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(directory?.listDirectories ?? [], id: \.self) { name in
                        Button {
                            if let path = directory?.path {
                                load(path == "/" ? "/\(name)" : "\(path)/\(name)")
                            }
                        } label: {
                            HStack(spacing: 6) {
                                RookeryIconView(.folder)
                                    .foregroundStyle(StageColors.secondaryText)
                                Text(name)
                                    .foregroundStyle(name.hasPrefix(".") ? AnyShapeStyle(StageColors.tertiaryText) : AnyShapeStyle(StageColors.primaryText))
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: Self.listHeight)
            .background(StageColors.groove, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            if let error {
                RookeryLabel(error, icon: .warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Use This Directory") {
                    if let path = directory?.path {
                        onChoose(path)
                    }
                }
                .buttonStyle(StageButtonStyle(kind: .prominent))
                .disabled(directory == nil || isLoading)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.4))
        }
        .task {
            load(startPath)
        }
    }

    private func load(_ path: String) {
        isLoading = true
        Task {
            do {
                let listed = try await hosts.listDirectories(on: alias, in: path)
                withAnimation(.easeOut(duration: 0.12)) {
                    directory = listed
                }
                error = nil
            } catch {
                self.error = String(describing: error)
            }
            isLoading = false
        }
    }
}

/// The agents launched and not yet reported in: a spinner while each starts, and why one failed.
struct LaunchStatusList: View {
    let hosts: HostsModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(hosts.listLaunches) { launch in
                HStack(spacing: 8) {
                    switch launch.phase {
                    case .starting:
                        ProgressView()
                            .controlSize(.small)
                    case .failed:
                        RookeryIconView(.warning)
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        FittingText(launch.title, size: 12, weight: .semibold)
                        switch launch.phase {
                        case .starting:
                            Text("Starting on \(launch.rookName) in \(launch.cwd)")
                                .font(.system(size: 11))
                                .foregroundStyle(StageColors.secondaryText)
                                .lineLimit(2)
                        case .failed(let reason):
                            Text(reason)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            hosts.dismiss(launch.launchId)
                        }
                    } label: {
                        RookeryIconView(.close)
                            .foregroundStyle(StageColors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help(launch.phase == .starting ? "Stop following it" : "Dismiss")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(StageColors.separator)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: hosts.listLaunches)
    }
}

/// The form that starts a new agent: on which host, in which workdir or directory, beginning with what,
/// and with which first prompt, if any. It floats over the Rookmaster console.
struct LaunchForm: View {
    private static let width: CGFloat = 580
    private static let maximumHeight: CGFloat = 720
    private static let otherDirectory = "other"
    private static let hostPrefix = "host:"
    private static let rookPrefix = "rook:"

    let fleetModel: FleetModel

    @State private var target = ""
    @State private var workdirChoice = LaunchForm.otherDirectory
    @State private var draft = Workdir(name: "", path: "")
    /// The name of the new directory an agent started in a parent workdir gets.
    @State private var newDirectoryName = ""
    @State private var prompt = ""
    @State private var isBrowsing = false

    private var hosts: HostsModel {
        fleetModel.hosts
    }

    /// The places an agent can start: each ssh host, then each rook no ssh host runs, as `host:` and
    /// `rook:` keys.
    private var listTargets: [String] {
        hosts.listHosts.map { Self.hostPrefix + $0.alias } + hosts.listUnmatchedRooks.map { Self.rookPrefix + $0 }
    }

    private var alias: String? {
        target.hasPrefix(Self.hostPrefix) ? String(target.dropFirst(Self.hostPrefix.count)) : nil
    }

    private var rookName: String? {
        rookName(for: target)
    }

    /// The rook a place runs, by its key.
    private func rookName(for key: String) -> String? {
        if key.hasPrefix(Self.hostPrefix) {
            let alias = String(key.dropFirst(Self.hostPrefix.count))
            return hosts.listHosts.first { $0.alias == alias }.flatMap(hosts.rookName(of:))
        }
        return key.hasPrefix(Self.rookPrefix) ? String(key.dropFirst(Self.rookPrefix.count)) : nil
    }

    private var listWorkdirs: [Workdir] {
        alias.map { hosts.book.settings(of: $0).listWorkdirs } ?? []
    }

    /// Why the agent cannot start as the form stands, or nil when it can.
    private var blocker: String? {
        guard let rookName else {
            return "This host runs no rook; set one up in Hosts."
        }
        guard hosts.isOnline(rookName) else {
            return "\(rookName) is offline."
        }
        guard draft.path.hasPrefix("/") else {
            return "Choose a directory, an absolute path on the host."
        }
        if draft.isParent, newDirectoryName.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Name the new directory the agent gets in \(draft.name)."
        }
        return nil
    }

    /// The directory the agent starts in: the workdir's own, or for a parent the new one inside it.
    private var startDirectory: String {
        guard draft.isParent else {
            return draft.path
        }
        return draft.directory(
            forAgentNamed: newDirectoryName,
            on: .now,
            taken: rookName.map(hosts.takenDirectories(on:)) ?? []
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    RookeryIconView(.agent, scale: 1.5)
                    Text("New Agent")
                        .font(.system(size: 17, weight: .bold))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        place
                        LaunchOptionsEditor(fleetModel: fleetModel, workdir: $draft)
                        EditorSection(title: "First prompt", hint: "leave it empty to start the agent idle") {
                            EditorTextArea(text: $prompt, placeholder: "What it should do first; you or Raven can prompt it later.", minHeight: 70)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                Rectangle()
                    .fill(StageColors.separator)
                    .frame(height: 1)
                HStack(spacing: 10) {
                    if let blocker {
                        RookeryLabel(blocker, icon: .warning)
                            .font(.system(size: 11))
                            .foregroundStyle(StageColors.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Cancel", action: close)
                        .keyboardShortcut(.cancelAction)
                    Button("Start Agent", action: start)
                        .buttonStyle(StageButtonStyle(kind: .prominent))
                        .keyboardShortcut(.defaultAction)
                        .disabled(blocker != nil)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(width: Self.width)
            .frame(maxHeight: Self.maximumHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(StageColors.sidebar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(StageColors.separator)
            }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .onAppear(perform: prefill)
    }

    private var place: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorSection(title: "Host") {
                Picker("Host", selection: $target) {
                    ForEach(listTargets, id: \.self) { key in
                        Text(title(of: key)).tag(key)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: target) {
                    choose(listWorkdirs.first?.id ?? Self.otherDirectory)
                }
            }
            EditorSection(title: "Directory") {
                VStack(alignment: .leading, spacing: 8) {
                    if !listWorkdirs.isEmpty {
                        Picker("Workdir", selection: $workdirChoice) {
                            ForEach(listWorkdirs) { workdir in
                                Text("\(workdir.name)  \(workdir.path)").tag(workdir.id)
                            }
                            Divider()
                            Text("Another directory").tag(Self.otherDirectory)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: workdirChoice) {
                            choose(workdirChoice)
                        }
                    }
                    if draft.isParent, workdirChoice != Self.otherDirectory {
                        EditorField(text: $newDirectoryName, placeholder: "glm53flash")
                        RookeryLabel(
                            newDirectoryName.trimmingCharacters(in: .whitespaces).isEmpty
                                ? "A new directory \(draft.path.hasSuffix("/") ? draft.path : draft.path + "/")<MMDD-name>, made as the agent starts"
                                : startDirectory,
                            icon: .folder
                        )
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StageColors.secondaryText)
                    }
                    if workdirChoice == Self.otherDirectory {
                        HStack(spacing: 8) {
                            EditorField(text: $draft.path, placeholder: "/home/you/project")
                            if alias != nil {
                                Button("Browse…") {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        isBrowsing.toggle()
                                    }
                                }
                            }
                        }
                        if isBrowsing, let alias {
                            RemoteDirectoryBrowser(hosts: hosts, alias: alias, startPath: draft.path) { path in
                                draft.path = path
                                isBrowsing = false
                            } onCancel: {
                                isBrowsing = false
                            }
                            .transition(.opacity)
                        }
                    }
                }
            }
        }
    }

    private func title(of key: String) -> String {
        if key.hasPrefix(Self.rookPrefix) {
            let name = String(key.dropFirst(Self.rookPrefix.count))
            return "\(name), rook only\(hosts.isOnline(name) ? "" : ", offline")"
        }
        let alias = String(key.dropFirst(Self.hostPrefix.count))
        guard let host = hosts.listHosts.first(where: { $0.alias == alias }) else {
            return alias
        }
        guard let rookName = hosts.rookName(of: host) else {
            return "\(alias), no rook"
        }
        return hosts.isOnline(rookName) ? alias : "\(alias), offline"
    }

    private func prefill() {
        if let alias = hosts.launchFormAlias {
            target = Self.hostPrefix + alias
        } else {
            target = listTargets.first { rookName(for: $0).map(hosts.isOnline) == true } ?? listTargets.first ?? ""
        }
        choose(hosts.launchFormWorkdirId ?? listWorkdirs.first?.id ?? Self.otherDirectory)
    }

    /// Take a workdir's settings into the form, or start from none for another directory.
    private func choose(_ choice: String) {
        workdirChoice = choice
        isBrowsing = false
        if let workdir = listWorkdirs.first(where: { $0.id == choice }) {
            draft = workdir
        } else {
            draft = Workdir(name: "", path: "", harness: draft.harness)
        }
    }

    private func start() {
        guard blocker == nil, let rookName else {
            return
        }
        let request = LaunchRequest(
            rookName: rookName,
            cwd: startDirectory,
            harness: draft.harness,
            prompt: prompt,
            playbookId: draft.playbookId,
            listSkillIds: draft.listSkillIds,
            role: draft.role,
            listTeams: draft.listTeams
        )
        let name = draft.isParent
            ? Workdir.defaultName(of: startDirectory)
            : draft.name.isEmpty ? Workdir.defaultName(of: draft.path) : draft.name
        hosts.launch(request, title: "\(name) on \(alias ?? rookName)")
        close()
    }

    private func close() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            hosts.isLaunchFormShown = false
        }
    }
}
