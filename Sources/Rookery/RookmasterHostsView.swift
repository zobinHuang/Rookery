import RookeryCore
import SwiftUI

/// The hosts this Mac reaches over ssh, in the Rookmaster console: a list of them with the rook each runs,
/// and beside it the chosen one: its address, its rook and what it has for agents, rook's setup where it
/// has none, and the workdirs the user starts agents in there.
struct RookmasterHostsView: View {
    private static let listWidth: CGFloat = 280

    let fleetModel: FleetModel

    @State private var selectedAlias: String?

    private var hosts: HostsModel {
        fleetModel.hosts
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: Self.listWidth)
            Rectangle()
                .fill(StageColors.separator)
                .frame(width: 1)
            Group {
                if let selectedAlias, let host = hosts.listHosts.first(where: { $0.alias == selectedAlias }) {
                    HostDetail(fleetModel: fleetModel, host: host)
                        .id(host.alias)
                } else {
                    VStack(spacing: 8) {
                        RookeryIconView(.machine, scale: 3)
                            .foregroundStyle(StageColors.tertiaryText)
                        Text(hosts.listHosts.isEmpty ? "~/.ssh/config names no host" : "Choose a host to see it")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StageColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            hosts.reloadHosts()
            if selectedAlias == nil {
                selectedAlias = hosts.listHosts.first?.alias
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("From ~/.ssh/config")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StageColors.tertiaryText)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        hosts.reloadHosts()
                    }
                } label: {
                    RookeryIconView(.refresh)
                        .foregroundStyle(StageColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Read the ssh configuration again")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(hosts.listHosts) { host in
                        row(host)
                    }
                    if !hosts.listUnmatchedRooks.isEmpty {
                        Text("Rooks no host here runs")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(StageColors.tertiaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(hosts.listUnmatchedRooks, id: \.self) { rookName in
                            unmatchedRow(rookName)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .modifier(RememberedScroll(key: "rookmaster.hosts", memory: fleetModel.pageMemory))
        }
    }

    private func row(_ host: SSHHost) -> some View {
        let isSelected = selectedAlias == host.alias
        let rookName = hosts.rookName(of: host)
        let agentCount = rookName.map(runningAgents(on:)) ?? 0
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedAlias = host.alias
            }
        } label: {
            HStack(spacing: 8) {
                RookeryIconView(.machine)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    FittingText(host.alias, size: 12, weight: .semibold)
                    Text(host.address)
                        .font(.system(size: 10))
                        .foregroundStyle(StageColors.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if agentCount > 0 {
                    InfoTag("\(agentCount) running")
                }
                HostStatusDot(state: status(of: rookName))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func unmatchedRow(_ rookName: String) -> some View {
        HStack(spacing: 8) {
            RookeryIconView(.machine)
                .frame(width: 24)
                .opacity(0.6)
            FittingText(rookName, size: 12, weight: .medium)
            Spacer(minLength: 4)
            HostStatusDot(state: status(of: rookName))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .help("roost knows this rook, but no host in ~/.ssh/config runs it; agents can still start there")
    }

    private func status(of rookName: String?) -> HostStatusDot.State {
        guard let rookName else {
            return .none
        }
        return hosts.isOnline(rookName) ? .online : .offline
    }

    private func runningAgents(on rookName: String) -> Int {
        fleetModel.fleet.listSessions.filter { $0.rookName == rookName && $0.state != .ended }.count
    }
}

/// Whether a host's rook is online, offline, or not set up, as a dot.
struct HostStatusDot: View {
    enum State {
        case online
        case offline
        case none
    }

    let state: State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(help)
    }

    private var color: Color {
        switch state {
        case .online: .green
        case .offline: .orange
        case .none: Color.secondary.opacity(0.45)
        }
    }

    private var help: String {
        switch state {
        case .online: "rook is online"
        case .offline: "rook is offline"
        case .none: "no rook set up"
        }
    }
}

/// One host: where it is, its rook and what the last check found, setting rook up, and its workdirs.
private struct HostDetail: View {
    let fleetModel: FleetModel
    let host: SSHHost

    @State private var editingWorkdir: Workdir?
    @State private var installName = ""
    @State private var isConfirmingInstall = false
    @State private var workdirToRemove: Workdir?

    private var hosts: HostsModel {
        fleetModel.hosts
    }

    private var rookName: String? {
        hosts.rookName(of: host)
    }

    private var listWorkdirs: [Workdir] {
        hosts.book.settings(of: host.alias).listWorkdirs
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                rookCard
                workdirs
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            installName = host.alias
        }
        .confirmationDialog(
            "Install rook on \(host.alias)?",
            isPresented: $isConfirmingInstall,
            titleVisibility: .visible
        ) {
            Button("Install") {
                hosts.installRook(on: host.alias, name: installName.trimmingCharacters(in: .whitespaces))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This runs rook's setup on \(host.alias) over ssh: it installs rook into ~/.local, adds its hooks to Claude Code and Codex there, starts its link as a user service, and connects it to the roost Rookery follows.")
        }
        .confirmationDialog(
            "Remove the workdir \(workdirToRemove?.name ?? "")?",
            isPresented: Binding(get: { workdirToRemove != nil }, set: { if !$0 { workdirToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let workdirToRemove {
                    withAnimation(.easeOut(duration: 0.15)) {
                        hosts.removeWorkdir(workdirToRemove.id, from: host.alias)
                    }
                }
            }
        } message: {
            Text("Only Rookery forgets it; nothing on the host changes.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RookeryIconView(.machine, scale: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias)
                    .font(.system(size: 18, weight: .bold))
                Text(host.address)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(StageColors.secondaryText)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    hosts.openLaunchForm(alias: host.alias)
                }
            } label: {
                RookeryLabel("New Agent", icon: .plus, spacing: 5)
            }
            .buttonStyle(StageButtonStyle(kind: .prominent))
            .disabled(rookName.map(hosts.isOnline) != true)
        }
    }

    private var rookCard: some View {
        FactCard(title: "Rook") {
            FactRow(title: "Runs", icon: .machine) {
                Picker("Rook", selection: Binding(
                    get: { hosts.book.settings(of: host.alias).rookName ?? "" },
                    set: { hosts.assignRook($0, to: host.alias) }
                )) {
                    Text(matchedTitle).tag("")
                    ForEach(hosts.setRookNames.sorted().filter { $0 != AgentFleet.rookeryRookName }, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let rookName {
                    InfoTag(hosts.isOnline(rookName) ? "online" : "offline", tint: hosts.isOnline(rookName) ? .green : .orange)
                }
            }
            FactRow(title: "Check", icon: .search) {
                checkResult
            }
            if rookName == nil || hosts.mapInstalls[host.alias] != nil {
                FactRow(title: "Set up", icon: .gear) {
                    install
                }
            }
        }
    }

    private var matchedTitle: String {
        let matched = HostBook().rookName(of: host, among: hosts.setRookNames)
        return matched.map { "\($0), by name" } ?? "None found by name"
    }

    @ViewBuilder
    private var checkResult: some View {
        switch hosts.mapChecks[host.alias] {
        case .none:
            Button("Check Host") {
                hosts.check(host.alias)
            }
            .controlSize(.small)
            Text("ssh in and see what it has for agents")
                .foregroundStyle(StageColors.tertiaryText)
        case .running:
            ProgressView()
                .controlSize(.small)
            Text("Connecting…")
                .foregroundStyle(StageColors.secondaryText)
        case .passed(let probe):
            FlowRow(spacing: 5) {
                probeTag("tmux", probe.hasTmux)
                probeTag("claude", probe.hasClaude)
                probeTag("codex", probe.hasCodex)
                probeTag(probe.rookName.map { "rook \($0)" } ?? "rook", probe.hasRook)
                probeTag("connected", probe.isConnected)
                Button {
                    hosts.check(host.alias)
                } label: {
                    RookeryIconView(.refresh)
                        .foregroundStyle(StageColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Check again")
            }
        case .failed(let reason):
            Text(reason)
                .foregroundStyle(.orange)
                .lineLimit(4)
                .textSelection(.enabled)
            Button("Retry") {
                hosts.check(host.alias)
            }
            .controlSize(.small)
        }
    }

    private func probeTag(_ title: String, _ isPresent: Bool) -> some View {
        InfoTag(title, tint: isPresent ? .green : .orange)
            .opacity(isPresent ? 1 : 0.8)
            .help(isPresent ? "\(title): found" : "\(title): not found")
    }

    @ViewBuilder
    private var install: some View {
        switch hosts.mapInstalls[host.alias] {
        case .running:
            ProgressView()
                .controlSize(.small)
            Text("Installing rook on \(host.alias)…")
                .foregroundStyle(StageColors.secondaryText)
        case .finished:
            RookeryLabel("Installed and connected", icon: .check)
                .foregroundStyle(.green)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
                    .lineLimit(8)
                    .textSelection(.enabled)
                installControls
            }
        case .none:
            installControls
        }
    }

    private var installControls: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $installName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .help("The name this host's agents go by")
            Button("Install rook…") {
                isConfirmingInstall = true
            }
            .controlSize(.small)
            .disabled(installName.trimmingCharacters(in: .whitespaces).isEmpty || fleetModel.connection == .notConfigured)
        }
    }

    private var workdirs: some View {
        EditorSection(title: "Workdirs", hint: "where you start agents on this host") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(listWorkdirs) { workdir in
                    if editingWorkdir?.id == workdir.id {
                        editor
                    } else {
                        workdirCard(workdir)
                    }
                }
                if let editingWorkdir, !listWorkdirs.contains(where: { $0.id == editingWorkdir.id }) {
                    editor
                } else if editingWorkdir == nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            editingWorkdir = Workdir(name: "", path: "")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            RookeryIconView(.plus)
                            Text("Add Workdir")
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                LaunchStatusList(hosts: hosts)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if editingWorkdir != nil {
            WorkdirEditor(
                fleetModel: fleetModel,
                alias: host.alias,
                workdir: Binding(get: { editingWorkdir ?? Workdir(name: "", path: "") }, set: { editingWorkdir = $0 })
            ) { saved in
                withAnimation(.easeOut(duration: 0.15)) {
                    hosts.put(saved, on: host.alias)
                    editingWorkdir = nil
                }
            } onCancel: {
                withAnimation(.easeOut(duration: 0.15)) {
                    editingWorkdir = nil
                }
            }
            .transition(.opacity)
        }
    }

    private func workdirCard(_ workdir: Workdir) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RookeryIconView(.folder)
                .foregroundStyle(StageColors.secondaryText)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(workdir.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(workdir.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StageColors.secondaryText)
                    .textSelection(.enabled)
                FlowRow(spacing: 5) {
                    if workdir.isParent {
                        InfoTag("a new directory per agent")
                    }
                    InfoTag(workdir.harness == Workdir.harnessCodex ? "Codex" : "Claude Code")
                    if let playbookId = workdir.playbookId {
                        InfoTag(fleetModel.graph.resource(FleetRef(kind: "playbook", id: playbookId))?.displayName ?? playbookId, tint: .purple)
                    }
                    if !workdir.listSkillIds.isEmpty {
                        InfoTag(workdir.listSkillIds.count == 1 ? "1 skill" : "\(workdir.listSkillIds.count) skills", tint: .blue)
                    }
                    ForEach(workdir.listTeams, id: \.self) { team in
                        InfoTag(fleetModel.graph.resource(FleetRef(kind: AgentFleet.teamKind, id: team.teamId))?.displayName ?? team.teamId, tint: .teal)
                    }
                }
                if !workdir.role.isEmpty {
                    Text(workdir.role)
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.secondaryText)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        hosts.openLaunchForm(alias: host.alias, workdirId: workdir.id)
                    }
                } label: {
                    RookeryLabel("Start", icon: .play, spacing: 4)
                }
                .controlSize(.small)
                .disabled(rookName.map(hosts.isOnline) != true)
                Menu {
                    Button("Edit") {
                        withAnimation(.easeOut(duration: 0.15)) {
                            editingWorkdir = workdir
                        }
                    }
                    Button("Remove…", role: .destructive) {
                        workdirToRemove = workdir
                    }
                } label: {
                    RookeryIconView(.ellipsis)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(12)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StageColors.separator)
        }
    }
}

/// A workdir being added or changed: its name and directory, and what an agent started there begins with.
private struct WorkdirEditor: View {
    let fleetModel: FleetModel
    let alias: String
    @Binding var workdir: Workdir
    let onSave: (Workdir) -> Void
    let onCancel: () -> Void

    @State private var isBrowsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorSection(title: "Directory", hint: "an absolute path on \(alias)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        EditorField(text: $workdir.path, placeholder: "/home/you/project")
                        Button("Browse…") {
                            withAnimation(.easeOut(duration: 0.15)) {
                                isBrowsing.toggle()
                            }
                        }
                    }
                    if isBrowsing {
                        RemoteDirectoryBrowser(hosts: fleetModel.hosts, alias: alias, startPath: workdir.path) { path in
                            workdir.path = path
                            if workdir.name.isEmpty {
                                workdir.name = Workdir.defaultName(of: path)
                            }
                            isBrowsing = false
                        } onCancel: {
                            isBrowsing = false
                        }
                        .transition(.opacity)
                    }
                }
            }
            EditorSection(title: "Name") {
                EditorField(text: $workdir.name, placeholder: Workdir.defaultName(of: workdir.path).isEmpty ? "G-Watch" : Workdir.defaultName(of: workdir.path))
            }
            Toggle(isOn: $workdir.isParent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("A parent directory")
                        .font(.system(size: 12, weight: .medium))
                    Text("Each agent started here gets a new directory of its own inside, named <MMDD-name>, which its rook makes as it starts.")
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            LaunchOptionsEditor(fleetModel: fleetModel, workdir: $workdir)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    var saved = workdir
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    if saved.name.isEmpty {
                        saved.name = Workdir.defaultName(of: saved.path)
                    }
                    saved.path = saved.path.trimmingCharacters(in: .whitespaces)
                    saved.role = saved.role.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(saved)
                }
                .buttonStyle(StageButtonStyle(kind: .prominent))
                .disabled(!workdir.path.trimmingCharacters(in: .whitespaces).hasPrefix("/"))
            }
        }
        .padding(14)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45))
        }
    }
}
