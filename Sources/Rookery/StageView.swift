import AppKit
import RookeryCore
import SwiftUI

/// What the stage view asks of its controller.
@MainActor
protocol StageActions: AnyObject {
    func selectGroup(_ groupId: GroupId)
    func selectTab(_ windowId: WindowId)
    func releaseWindow(_ windowId: WindowId)
    /// Move a window to a group, or to a new group with nil.
    func moveWindow(_ windowId: WindowId, to groupId: GroupId?)
    func renameGroup(_ groupId: GroupId, to name: String)
    func renameWindow(_ windowId: WindowId, to name: String)
    /// Take keyboard input for a name being edited.
    func beginEditing()
    /// Give keyboard input back to the stage's front window, unless it has gone elsewhere already.
    func endEditing()
    func tabDragBegan()
    func groupDragBegan(_ groupId: GroupId)
    /// A drag came over a drop target on the stage, from this stage or any other: its feedback is cleared once
    /// the mouse is released, wherever the drag ends.
    func dragEntered()
    /// Move a group to just before another, or to the end with nil.
    func moveGroup(_ groupId: GroupId, before targetGroupId: GroupId?)
    /// Move a tab to just before another tab, or to the end with nil.
    func moveTab(_ windowId: WindowId, before targetWindowId: WindowId?)
    func toggleSidebar()
    /// Hide the right strip of icons, or show it again.
    func toggleRightSidebar()
    /// Switch between the light and the dark theme, keeping the contrast.
    func toggleTheme()
    /// Fill the display with the stage, or go back to its earlier frame.
    func toggleMaximize()
    func exitStage()
    /// Open another Rookery window.
    func newStage()
    /// Show a page in the content area, or close it if it shows.
    func showPage(_ page: StagePage)
    /// Show a page in the content area, leaving it there if it shows already.
    func open(_ page: StagePage)
    /// Close the page shown in the content area and bring its front window back.
    func closePage()
    /// The user is dragging the stage by its sidebar header, towards another display.
    func moveStageChanged()
    func moveStageEnded()
}

/// The stage: groups down the left, the active group's windows as tabs along the top, and the content
/// area the front window is laid over.
struct StageView: View {
    private static let zoneAnimation = Animation.spring(response: 0.28, dampingFraction: 0.82)
    private static let sidebarAnimation = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// The most of the sidebar's height the videos shown in it may take, leaving the rest to the groups or
    /// the mixer.
    private static let pictureHeightShare: CGFloat = 0.45
    nonisolated private static let tabBarSpace = "tabBar"
    /// How wide the fade is at an edge of the tabs with more beyond it, and how far they must reach past the
    /// edge for it to show.
    private static let tabFadeWidth: CGFloat = 28
    nonisolated private static let tabFadeThreshold: CGFloat = 2
    /// The most of the sidebar the Windows section takes above the agents, and with the agents folded.
    private static let windowsShare: CGFloat = 0.45
    private static let windowsAloneShare: CGFloat = 0.8
    /// A tab's height, from the content's top edge, which it stands on.
    static let tabHeight: CGFloat = 34
    /// The tabs' distance from the content's sides, clear of its rounded corners.
    static let tabBarInset: CGFloat = 12
    private static let tabScrollAnimation = Animation.easeOut(duration: 0.22)

    let model: StageModel
    let preferences: Preferences
    let shortcutRecorder: ShortcutRecorder
    let mixer: MixerController
    let agentUsage: AgentUsageMonitor
    let fleetModel: FleetModel
    unowned let actions: any StageActions
    @State private var hoveredGroupId: GroupId?
    @State private var sidebarHeight: CGFloat = 0
    /// The height of the area the groups or the mixer scroll in, which their empty space fills.
    @State private var listViewportHeight: CGFloat = 0
    /// How tall the groups' rows are together, which the Windows section takes up to its share.
    @State private var groupsContentHeight: CGFloat = 0
    @State private var isWindowsFolded = false
    @State private var isAgentsFolded = false
    /// The width the tabs scroll in.
    @State private var tabBarWidth: CGFloat = 0
    /// Whether tabs lie beyond the leading or the trailing edge of the width they scroll in. Only these are
    /// kept, not the scroll offset, so scrolling does not rebuild the stage.
    @State private var hasTabsBefore = false
    @State private var hasTabsAfter = false

    /// An AppKit view hosting the stage.
    static func makeHostingView(
        model: StageModel,
        preferences: Preferences,
        shortcutRecorder: ShortcutRecorder,
        mixer: MixerController,
        agentUsage: AgentUsageMonitor,
        fleetModel: FleetModel,
        actions: any StageActions
    ) -> NSView {
        let view = NSHostingView(rootView: StageView(
            model: model,
            preferences: preferences,
            shortcutRecorder: shortcutRecorder,
            mixer: mixer,
            agentUsage: agentUsage,
            fleetModel: fleetModel,
            actions: actions
        ))
        view.sizingOptions = []
        return view
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            Footbar(listCities: model.listClockCities)
                .frame(height: StageModel.footbarHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StageColors.window)
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
        .environment(\.chosenTheme, model.shownTheme)
        .environment(\.people, fleetModel.people)
        .buttonStyle(StageButtonStyle())
        .onChange(of: fleetModel.pageMemory.requestedPage) { _, page in
            guard let page else {
                return
            }
            fleetModel.pageMemory.requestedPage = nil
            actions.showPage(page)
        }
        .opacity(model.isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.22), value: model.isVisible)
        .animation(Self.zoneAnimation, value: model.highlightedZone)
        .animation(Self.zoneAnimation, value: showsDropZones)
        .animation(Self.zoneAnimation, value: model.tabInsertBeforeId)
        .animation(Self.zoneAnimation, value: model.groupInsertBeforeId)
        .animation(Self.sidebarAnimation, value: model.isSidebarCollapsed)
        .animation(Self.sidebarAnimation, value: model.isRightSidebarCollapsed)
        .animation(.easeOut(duration: 0.18), value: model.switchingGroupId)
        .animation(Self.sidebarAnimation, value: showsTabBar)
    }

    /// The sidebars with the tabs and the content between them.
    private var stage: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: model.sidebarWidth)
            VStack(spacing: 0) {
                tabBar
                    .opacity(switchingGroupName == nil ? 1 : 0)
                    .overlay(alignment: .leading) {
                        if let switchingGroupName {
                            SwitchingTabs(groupName: switchingGroupName)
                                .transition(.opacity)
                        }
                    }
                    .frame(height: showsTabBar ? StageModel.tabBarHeight : (isPageFullBleed ? 0 : StageModel.contentInset))
                    .opacity(showsTabBar ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(showsTabBar)
                content
                    .overlay {
                        if let switchingGroupName, model.shownPage == nil {
                            VStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.regular)
                                Text("Bringing up \(switchingGroupName)…")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(StageColors.secondaryText)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .background(StageColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            .allowsHitTesting(false)
                        }
                    }
                    .padding(.bottom, isPageFullBleed ? 0 : StageModel.contentInset)
            }
            if !model.isRightSidebarCollapsed {
                RightSidebarView(
                    model: model,
                    mixer: mixer,
                    fleetModel: fleetModel,
                    actions: actions
                )
                .frame(width: model.rightSidebarWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The name of the group a switch is bringing forward, while it is under way and its tabs are not yet the
    /// ones shown.
    private var switchingGroupName: String? {
        guard let switchingGroupId = model.switchingGroupId else {
            return nil
        }
        return model.listGroups.first { $0.groupId == switchingGroupId && !$0.isActive }?.name
    }

    /// Whether a page of Rookery's own fills the content area edge to edge, between the sidebars, rather
    /// than sitting in the rounded frame a window is laid in: while one is shown and nothing is dragged.
    private var isPageFullBleed: Bool {
        model.shownPage != nil && !showsDropZones
    }

    /// Whether the tabs show above the content: not while a page of Rookery's own fills it, unless a window
    /// or tab is being dragged and may be dropped among them.
    private var showsTabBar: Bool {
        model.shownPage == nil || showsDropZones
    }

    /// What an agent's page's back button names: the console or the settings it was opened from; none for
    /// another agent's page, or a window.
    private static func loadingTitle(of page: StagePage) -> String {
        switch page {
        case .settings: "Opening Settings"
        case .calendar: "Opening Calendar"
        case .mail: "Opening Mail"
        case .mixer: "Opening Mixer"
        case .rookmaster: "Opening Rookmaster"
        case .agent: "Opening the agent"
        default: "Opening"
        }
    }

    // MARK: - Sidebar

    private var showsDropZones: Bool {
        model.isReceivingWindow || model.isDraggingTab
    }

    /// The Windows section's height: its groups', up to half the sidebar while the agents show under it.
    private var windowsListHeight: CGFloat {
        let content = max(groupsContentHeight, 1)
        guard !isAgentsFolded else {
            return min(content, max(sidebarHeight * Self.windowsAloneShare, 1))
        }
        return min(content, max(sidebarHeight * Self.windowsShare, 1))
    }

    /// A section's heading in the sidebar: its name and how many it holds, folding it away; a hairline in
    /// the collapsed sidebar.
    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int, isFolded: Binding<Bool>) -> some View {
        if model.isSidebarCollapsed {
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        } else {
            Button {
                withAnimation(Self.sidebarAnimation) {
                    isFolded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(StageColors.secondaryText)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(StageColors.tertiaryText)
                    }
                    Spacer(minLength: 0)
                    RookeryIconView(.chevronDown)
                        .foregroundStyle(StageColors.tertiaryText)
                        .rotationEffect(.degrees(isFolded.wrappedValue ? -90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFolded.wrappedValue ? "Show the \(title.lowercased())" : "Fold the \(title.lowercased()) away")
        }
    }

    /// The agent whose page the content area shows, if any.
    private var shownAgentId: String? {
        if case .agent(let agentId) = model.shownPage {
            return agentId
        }
        return nil
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            sidebarHeader
            sectionHeader("Windows", count: model.listGroups.count, isFolded: $isWindowsFolded)
            if !isWindowsFolded || showsDropZones {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.listGroups) { row in
                            groupRow(row)
                        }
                        if model.highlightedZone == .newGroup && !model.isSidebarCollapsed {
                            newGroupPlaceholder
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if model.isGroupOverSidebarEnd {
                            InsertionMark(isVertical: false)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        groupsContentHeight = height
                    }
                    .modifier(EmptySpaceTap(minHeight: listViewportHeight, action: finishEditingOnEmptySpace))
                }
                .frame(height: windowsListHeight)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    listViewportHeight = height
                }
                .transition(.opacity)
            }
            if showsDropZones {
                VStack(spacing: 6) {
                    dropZone(.newGroup, title: "New Group", symbol: .plus, tint: .accentColor)
                    if model.isDraggingManagedWindow || model.isDraggingTab {
                        dropZone(.release, title: "Release", symbol: .release, tint: .red)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if model.listGroups.isEmpty && !model.isSidebarCollapsed && !isWindowsFolded {
                Text("Drop a window on New Group to start a group.")
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            if !model.isSidebarCollapsed {
                Rectangle()
                    .fill(StageColors.separator)
                    .frame(height: 1)
                    .padding(.top, 6)
            }
            sectionHeader("Agents", count: fleetModel.fleet.listSessions.filter { $0.state != .ended }.count, isFolded: $isAgentsFolded)
            if !isAgentsFolded {
                AgentsSidebarView(
                    fleetModel: fleetModel,
                    isCollapsed: model.isSidebarCollapsed,
                    selectedAgentId: shownAgentId,
                    onSelect: { agentId in
                        actions.showPage(.agent(agentId))
                    },
                    onOpenSettings: {
                        actions.showPage(.settings)
                    },
                    isRookmasterShown: model.shownPage == .rookmaster,
                    onOpenRookmaster: {
                        actions.showPage(.rookmaster)
                    },
                    onBeginEditing: actions.beginEditing,
                    onEndEditing: actions.endEditing
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
            if !model.isSidebarCollapsed && !mixer.browserTabs.pictures.listPictures.isEmpty {
                SidebarPicturesView(
                    pictures: mixer.browserTabs.pictures,
                    browserTabs: mixer.browserTabs,
                    width: StageModel.sidebarWidth,
                    heightBudget: sidebarHeight * Self.pictureHeightShare
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(StageColors.separator)
                        .frame(height: 1)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !model.isSidebarCollapsed && !agentUsage.listShownAccounts.isEmpty {
                AgentUsagePanel(monitor: agentUsage)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(StageColors.separator)
                            .frame(height: 1)
                    }
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            sidebarHeight = height
        }
        .background {
            Rectangle()
                .fill(StageColors.sidebar)
                .onTapGesture(perform: finishEditingOnEmptySpace)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(StageColors.separator)
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { listTexts, _ in
            switch Self.payload(from: listTexts) {
            case .window:
                return false
            case .group(let groupId):
                return dropGroup(groupId, before: nil)
            case nil:
                return false
            }
        } isTargeted: { isTargeted in
            if isTargeted {
                actions.dragEntered()
            }
            if model.draggingGroupId != nil {
                model.isGroupOverSidebarEnd = isTargeted
            }
        }
        .modifier(ZoneFrameReporter(zone: .sidebar, model: model))
    }

    private var sidebarHeader: some View {
        Group {
            if model.isSidebarCollapsed {
                VStack(spacing: 12) {
                    CloseButton(action: actions.exitStage)
                    VStack(spacing: 6) {
                        headerButton(.sidebar, help: "Show the sidebar", action: actions.toggleSidebar)
                        stageTools
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 4) {
                        CloseButton(action: actions.exitStage)
                            .padding(.trailing, 4)
                        stageTools
                        Spacer(minLength: 0)
                        headerButton(.sidebar, help: "Hide the sidebar", action: actions.toggleSidebar)
                    }
                    RookeryLogo()
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            actions.toggleMaximize()
        }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in
                    actions.moveStageChanged()
                }
                .onEnded { _ in
                    actions.moveStageEnded()
                }
        )
        .help("Drag to move the stage; double-click to fill the display")
    }

    /// The stage's tools beside the sidebar's own buttons at its top: a new window, the theme, the screen
    /// saver and the settings.
    @ViewBuilder
    private var stageTools: some View {
        headerButton(.plus, help: "New Rookery window", action: actions.newStage)
        headerButton(
            model.shownTheme.isDark ? .sun : .moon,
            help: "Switch to the \(model.shownTheme.opposite.title) theme",
            action: actions.toggleTheme
        )
        headerButton(.screenSaver, help: "Screen saver") {
            actions.showPage(.screenSaver)
        }
        headerButton(.gear, help: "Settings") {
            actions.showPage(.settings)
        }
    }

    private func headerButton(_ symbol: RookeryIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RookeryIconView(symbol)
                .foregroundStyle(StageColors.secondaryText)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func groupRow(_ row: StageGroupRow) -> some View {
        let isDropTarget = model.highlightedZone == .group(row.groupId)
        let isLanded = model.landedZone == .group(row.groupId)
        let isHovered = hoveredGroupId == row.groupId
        return Button {
            actions.selectGroup(row.groupId)
        } label: {
            Group {
                if model.isSidebarCollapsed {
                    GroupAvatar(listBundleIds: row.listBundleIds, size: 38)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                } else {
                    HStack(spacing: 10) {
                        GroupAvatar(listBundleIds: row.listBundleIds, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            if model.editingGroupId == row.groupId {
                                InlineRenameField(initialText: row.name, placeholder: "Group name") { name in
                                    finishEditing()
                                    actions.renameGroup(row.groupId, to: name)
                                } onCancel: {
                                    finishEditing()
                                }
                                .font(.system(size: 13, weight: .semibold))
                            } else {
                                Text(row.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(StageColors.primaryText)
                                    .lineLimit(1)
                            }
                            GroupSubtitleText(model: model, row: row)
                                .font(.system(size: 11))
                                .foregroundStyle(StageColors.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if model.switchingGroupId == row.groupId && !row.isActive {
                            ProgressView()
                                .controlSize(.mini)
                                .transition(.opacity)
                        }
                        if isHovered && model.editingGroupId != row.groupId {
                            groupMenu(row)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill(isActive: row.isActive, isHovered: isHovered, isDropTarget: isDropTarget))
                    .strokeBorder(row.isActive ? StageColors.contrastActiveBorder : .clear)
                    .shadow(color: row.isActive && !isDropTarget ? .black.opacity(0.08) : .clear, radius: 3, y: 1)
            }
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .overlay(alignment: .leading) {
                if row.isActive {
                    Capsule()
                        .fill(StageColors.primaryText)
                        .frame(width: 3, height: 20)
                        .offset(x: -6)
                        .transition(.opacity)
                }
            }
            .scaleEffect(isLanded ? 1.05 : (isDropTarget ? 1.02 : 1))
            .contentShape(Rectangle())
        }
        .onHover { isInside in
            withAnimation(.easeOut(duration: 0.12)) {
                if isInside {
                    hoveredGroupId = row.groupId
                } else if hoveredGroupId == row.groupId {
                    hoveredGroupId = nil
                }
            }
        }
        .buttonStyle(.plain)
        .help(row.name)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            beginRenaming(group: row.groupId)
        })
        .contextMenu {
            Button("Rename Group…") {
                beginRenaming(group: row.groupId)
            }
        }
        .overlay(alignment: .top) {
            if model.groupInsertBeforeId == row.groupId {
                InsertionMark(isVertical: false)
                    .offset(y: -3)
            }
        }
        .onDrag {
            actions.groupDragBegan(row.groupId)
            return NSItemProvider(object: StagePayload.group(row.groupId).text as NSString)
        } preview: {
            HStack(spacing: 8) {
                IconStack(listBundleIds: row.listBundleIds, iconSize: 20, overlap: -8)
                Text(row.name)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
        }
        .dropDestination(for: String.self) { listTexts, _ in
            switch Self.payload(from: listTexts) {
            case .window(let windowId):
                return dropWindow(windowId, into: row.groupId)
            case .group(let groupId):
                return dropGroup(groupId, before: row.groupId)
            case nil:
                return false
            }
        } isTargeted: { isTargeted in
            if isTargeted {
                actions.dragEntered()
            }
            if model.draggingGroupId != nil {
                if isTargeted {
                    model.groupInsertBeforeId = row.groupId
                } else if model.groupInsertBeforeId == row.groupId {
                    model.groupInsertBeforeId = nil
                }
            } else if isTargeted {
                model.tabDropGroupId = row.groupId
            } else if model.tabDropGroupId == row.groupId {
                model.tabDropGroupId = nil
            }
        }
        .modifier(ZoneFrameReporter(zone: .group(row.groupId), model: model))
    }

    private func rowFill(isActive: Bool, isHovered: Bool, isDropTarget: Bool) -> AnyShapeStyle {
        if isDropTarget {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        }
        if isActive {
            return AnyShapeStyle(isHovered ? StageColors.selectedRowHovered : StageColors.selectedRow)
        }
        return isHovered ? AnyShapeStyle(StageColors.hoveredRow) : AnyShapeStyle(.clear)
    }

    /// The "⋯" button a hovered group row shows, with what can be done to the group.
    private func groupMenu(_ row: StageGroupRow) -> some View {
        Menu {
            Button("Rename Group…") {
                beginRenaming(group: row.groupId)
            }
        } label: {
            RookeryIconView(.ellipsis)
                .foregroundStyle(StageColors.secondaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    /// The row a new group would take, shown while a drop would start one.
    private var newGroupPlaceholder: some View {
        HStack(spacing: 10) {
            RookeryIconView(.plus)
                .frame(width: 22, height: 22)
            Text("New Group")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .modifier(ZoneFrameReporter(zone: .newGroupRow, model: model))
    }

    private func dropZone(_ zone: StageZone, title: String, symbol: RookeryIcon, tint: Color) -> some View {
        let isHovered = model.highlightedZone == zone
        return HStack(spacing: 8) {
            RookeryIconView(symbol)
            if !model.isSidebarCollapsed {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .foregroundStyle(isHovered ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.08)))
        }
        .overlay {
            if !isHovered {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .scaleEffect(isHovered ? 1.03 : 1)
        .help(title)
        .dropDestination(for: String.self) { listTexts, _ in
            guard case .window(let windowId) = Self.payload(from: listTexts) else {
                return false
            }
            guard zone == .release else {
                return dropWindow(windowId, into: nil)
            }
            clearDragState()
            actions.releaseWindow(windowId)
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                actions.dragEntered()
                model.tabDropZone = zone
            } else if model.tabDropZone == zone {
                model.tabDropZone = nil
            }
        }
        .modifier(ZoneFrameReporter(zone: zone, model: model))
    }

    // MARK: - Tabs

    /// The tabs, scrolling sideways when they do not fit, faded at an edge with more beyond it, and kept
    /// scrolled to the selected one. The strip's empty end takes a dragged tab to place it last.
    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(model.listTabs) { tab in
                        tabButton(tab)
                            .id(tab.windowId)
                    }
                    if model.isTabOverTabBarEnd {
                        InsertionMark(isVertical: true)
                    }
                }
                .backgroundPreferenceValue(TabBoundsKey.self) { mapTabBounds in
                    TabBackgrounds(model: model, mapTabBounds: mapTabBounds)
                }
                .padding(.horizontal, StageView.tabBarInset)
                .frame(minWidth: tabBarWidth, maxHeight: .infinity, alignment: .bottomLeading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { listTexts, _ in
                    guard case .window(let windowId) = Self.payload(from: listTexts) else {
                        return false
                    }
                    clearDragState()
                    actions.moveTab(windowId, before: nil)
                    return true
                } isTargeted: { isTargeted in
                    if isTargeted {
                        actions.dragEntered()
                    }
                    model.isTabOverTabBarEnd = isTargeted
                }
                .onGeometryChange(for: Bool.self) { geometry in
                    -geometry.frame(in: .named(Self.tabBarSpace)).minX > Self.tabFadeThreshold
                } action: { hasMore in
                    hasTabsBefore = hasMore
                }
                .onGeometryChange(for: Bool.self) { [tabBarWidth] geometry in
                    geometry.frame(in: .named(Self.tabBarSpace)).maxX - tabBarWidth > Self.tabFadeThreshold
                } action: { hasMore in
                    hasTabsAfter = hasMore
                }
            }
            .coordinateSpace(.named(Self.tabBarSpace))
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: hasTabsBefore ? Self.tabFadeWidth : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: hasTabsAfter ? Self.tabFadeWidth : 0)
                }
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                tabBarWidth = width
            }
            .onChange(of: model.selectedWindowId) { _, selectedWindowId in
                guard
                    let selectedWindowId,
                    hasTabsBefore || hasTabsAfter
                else {
                    return
                }
                withAnimation(Self.tabScrollAnimation) {
                    proxy.scrollTo(selectedWindowId)
                }
            }
        }
        .padding(.trailing, StageModel.contentInset)
    }

    private func tabButton(_ tab: StageTab) -> some View {
        let isSelected = tab.windowId == model.selectedWindowId
        return Button {
            actions.selectTab(tab.windowId)
        } label: {
            HStack(spacing: 7) {
                if let icon = ApplicationIcon.icon(forBundleId: tab.bundleId) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                if model.editingWindowId == tab.windowId {
                    let name = model.mapWindowNames[tab.windowId] ?? ""
                    InlineRenameField(
                        initialText: tab.hasCustomName ? name : "",
                        placeholder: name
                    ) { name in
                        finishEditing()
                        actions.renameWindow(tab.windowId, to: name)
                    } onCancel: {
                        finishEditing()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 180)
                } else {
                    WindowNameText(model: model, windowId: tab.windowId)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 220)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: StageView.tabHeight)
            .anchorPreference(key: TabBoundsKey.self, value: .bounds) { [tab.windowId: $0] }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.activeTabText) : AnyShapeStyle(StageColors.secondaryText))
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            beginRenaming(tab: tab.windowId)
        })
        .onDrag {
            actions.tabDragBegan()
            return NSItemProvider(object: StagePayload.window(tab.windowId).text as NSString)
        } preview: {
            HStack(spacing: 7) {
                if let icon = ApplicationIcon.icon(forBundleId: tab.bundleId) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                WindowNameText(model: model, windowId: tab.windowId)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: .rect(cornerRadius: 9))
        }
        .overlay(alignment: .leading) {
            if model.tabInsertBeforeId == tab.windowId {
                InsertionMark(isVertical: true)
                    .offset(x: -4)
            }
        }
        .dropDestination(for: String.self) { listTexts, _ in
            guard case .window(let windowId) = Self.payload(from: listTexts) else {
                return false
            }
            clearDragState()
            actions.moveTab(windowId, before: tab.windowId)
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                actions.dragEntered()
                model.tabInsertBeforeId = tab.windowId
            } else if model.tabInsertBeforeId == tab.windowId {
                model.tabInsertBeforeId = nil
            }
        }
        .contextMenu {
            Button("Rename Tab…") {
                beginRenaming(tab: tab.windowId)
            }
            Button("Release Window") {
                actions.releaseWindow(tab.windowId)
            }
        }
    }

    // MARK: - Content

    /// Whether a managed window fills the content area, which then draws nothing of its own around it.
    private var isWindowShown: Bool {
        model.shownPage == nil && model.selectedWindowId != nil && !showsDropZones
    }

    private var contentCornerRadius: CGFloat {
        isPageFullBleed ? 0 : 12
    }

    private var content: some View {
        ZStack {
            RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous)
                .fill(isWindowShown ? AnyShapeStyle(StageColors.window) : AnyShapeStyle(StageColors.content))
            if let page = model.shownPage, !model.isPageReady {
                PageLoading(title: Self.loadingTitle(of: page))
                    .transition(.opacity)
            } else if model.shownPage == .settings {
                SettingsView(
                    preferences: preferences,
                    recorder: shortcutRecorder,
                    agentUsageMonitor: agentUsage,
                    fleetModel: fleetModel,
                    onClose: actions.closePage
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if model.shownPage == .calendar {
                CalendarPage(fleetModel: fleetModel, onClose: actions.closePage)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if model.shownPage == .mail {
                MailPage(fleetModel: fleetModel, onClose: actions.closePage)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if model.shownPage == .mixer {
                MixerPage(mixer: mixer, preferences: preferences, onClose: actions.closePage)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if model.shownPage == .rookmaster {
                RookmasterView(
                    fleetModel: fleetModel,
                    logClock: preferences.logClock,
                    onOpenAgent: { agentId in
                        actions.showPage(.agent(agentId))
                    },
                    onClose: actions.closePage
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if case .agent(let agentId) = model.shownPage {
                AgentDetailView(
                    fleetModel: fleetModel,
                    agentId: agentId,
                    backTitle: "Rookmaster",
                    onBack: {
                        actions.open(.rookmaster)
                    },
                    onClose: actions.closePage
                )
                .id(agentId)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if model.shownPage == .screenSaver {
                ScreenSaverView(
                    text: preferences.shownScreenSaverText,
                    textSize: preferences.screenSaverTextSize,
                    onClose: actions.closePage
                )
                .transition(.opacity)
            } else if model.selectedWindowId == nil {
                VStack(spacing: 10) {
                    RookeryIconView(.newStage, scale: 3)
                        .foregroundStyle(.tint)
                    Text("Drag a window here")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Drop it on the pill that appears above to open it here as a tab.")
                        .font(.system(size: 12))
                        .foregroundStyle(StageColors.secondaryText)
                }
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous)
                .strokeBorder(isPageFullBleed || isWindowShown ? AnyShapeStyle(StageColor.clear) : AnyShapeStyle(StageColors.contrastBorder))
                .allowsHitTesting(false)
        }
        .animation(Self.zoneAnimation, value: model.shownPage)
        .animation(.easeOut(duration: 0.15), value: model.isPageReady)
        .modifier(ZoneFrameReporter(zone: .content, model: model))
    }

    // MARK: - Editing and dropping

    private func beginRenaming(group groupId: GroupId) {
        guard !model.isSidebarCollapsed else {
            return
        }
        actions.beginEditing()
        model.editingWindowId = nil
        model.editingGroupId = groupId
    }

    private func beginRenaming(tab windowId: WindowId) {
        actions.beginEditing()
        model.editingGroupId = nil
        model.editingWindowId = windowId
    }

    private func finishEditing() {
        model.editingGroupId = nil
        model.editingWindowId = nil
        actions.endEditing()
    }

    /// Finish whatever name is being edited, keeping what was typed, as a click on the sidebar's empty space
    /// does.
    private func finishEditingOnEmptySpace() {
        guard
            model.editingGroupId != nil
            || model.editingWindowId != nil
        else {
            return
        }
        model.editingGroupId = nil
        model.editingWindowId = nil
    }

    /// Move a dragged tab's window into a group, or into a new group with nil.
    private func dropWindow(_ windowId: WindowId, into groupId: GroupId?) -> Bool {
        clearDragState()
        actions.moveWindow(windowId, to: groupId)
        return true
    }

    /// Move a dragged group to just before another, or to the end with nil.
    private func dropGroup(_ groupId: GroupId, before targetGroupId: GroupId?) -> Bool {
        clearDragState()
        actions.moveGroup(groupId, before: targetGroupId)
        return true
    }

    private func clearDragState() {
        model.clearDragState()
    }

    private static func payload(from listTexts: [String]) -> StagePayload? {
        listTexts.first.flatMap(StagePayload.init)
    }
}

/// The red close button of a Rookery window, showing its cross while the pointer is over it, as the
/// close button of any macOS window does.
struct CloseButton: View {
    private static let diameter: CGFloat = 13

    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: .systemRed))
                .overlay {
                    Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                }
                .overlay {
                    if isHovered {
                        RookeryIconView(.close)
                            .foregroundStyle(.black.opacity(0.55))
                    }
                }
                .frame(width: Self.diameter, height: Self.diameter)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Close this Rookery window")
    }
}

/// Where each tab lies in the tab bar, for drawing the tabs' backgrounds beneath them.
struct TabBoundsKey: PreferenceKey {
    static let defaultValue: [WindowId: Anchor<CGRect>] = [:]

    static func reduce(value: inout [WindowId: Anchor<CGRect>], nextValue: () -> [WindowId: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// The tabs' backgrounds: a faint one behind each tab, and the selected tab's raised one, which slides to
/// the tab selected next.
///
/// The faint ones are keyed by position, not by window: the tabs themselves carry the windows' ids, and
/// scrolling the tab bar to a window would otherwise find the background instead.
struct TabBackgrounds: View {

    let model: StageModel
    let mapTabBounds: [WindowId: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(model.listTabs.indices, id: \.self) { tabIndex in
                    if let anchor = mapTabBounds[model.listTabs[tabIndex].windowId] {
                        let bounds = proxy[anchor]
                        FolderTabShape()
                            .fill(StageColors.idleTab)
                            .overlay {
                                FolderTabShape()
                                    .stroke(StageColors.contrastBorder)
                            }
                            .frame(width: bounds.width, height: bounds.height)
                            .offset(x: bounds.minX, y: bounds.minY)
                    }
                }
                TabHighlight(frame: model.selectedWindowId.flatMap { mapTabBounds[$0] }.map { proxy[$0] })
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

/// A window's name as the stage shows it, read on its own so that a window retitling itself redraws only
/// this text.
struct WindowNameText: View {
    let model: StageModel
    let windowId: WindowId

    var body: some View {
        Text(model.mapWindowNames[windowId] ?? "")
    }
}

/// A group's front window and how many windows it holds, as its row's second line, read on its own like
/// `WindowNameText`.
struct GroupSubtitleText: View {
    let model: StageModel
    let row: StageGroupRow

    var body: some View {
        let count = row.listBundleIds.count
        let countText = count == 1 ? "1 window" : "\(count) windows"
        let frontWindowName = row.frontWindowId.flatMap { model.mapWindowNames[$0] }
        if let frontWindowName, !frontWindowName.isEmpty, count > 1 {
            HStack(spacing: 5) {
                Text(frontWindowName)
                    .lineLimit(1)
                Text(countText)
                    .foregroundStyle(StageColors.tertiaryText)
                    .layoutPriority(1)
            }
        } else {
            Text(frontWindowName ?? countText)
        }
    }
}

/// The accent line that marks where a dragged tab or group would land.
struct InsertionMark: View {
    let isVertical: Bool

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: isVertical ? 3 : nil, height: isVertical ? 24 : 3)
            .frame(maxWidth: isVertical ? nil : .infinity)
            .shadow(color: .accentColor.opacity(0.6), radius: 3)
            .transition(.opacity)
    }
}

/// Fill the rest of a scrolling list's height, so a click on the empty space below its rows reaches
/// `action` rather than the scroll view.
struct EmptySpaceTap: ViewModifier {
    let minHeight: CGFloat
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// A text field that edits a name in place: return commits, escape cancels, and leaving it, or the field
/// going away, commits.
struct InlineRenameField: View {
    let initialText: String
    let placeholder: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @State private var isFinished = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onAppear {
                text = initialText
                isFocused = true
            }
            .onSubmit {
                finish(isCommitted: true)
            }
            .onExitCommand {
                finish(isCommitted: false)
            }
            .onChange(of: isFocused) { _, isNowFocused in
                if !isNowFocused {
                    finish(isCommitted: true)
                }
            }
            .onDisappear {
                finish(isCommitted: true)
            }
    }

    private func finish(isCommitted: Bool) {
        guard !isFinished else {
            return
        }
        isFinished = true
        if isCommitted {
            onCommit(text)
        } else {
            onCancel()
        }
    }
}

/// Up to three application icons overlapping left to right.
struct IconStack: View {
    let listBundleIds: [String?]
    let iconSize: CGFloat
    let overlap: CGFloat

    var body: some View {
        HStack(spacing: overlap) {
            ForEach(Array(listBundleIds.prefix(3).enumerated()), id: \.offset) { _, bundleId in
                if let icon = ApplicationIcon.icon(forBundleId: bundleId) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                } else {
                    RookeryIconView(.window)
                        .frame(width: iconSize, height: iconSize)
                }
            }
        }
    }
}

/// A group's picture: the icon of its only application, or up to four of its applications' icons in a
/// grid, on a rounded tile.
struct GroupAvatar: View {
    let listBundleIds: [String?]
    let size: CGFloat

    var body: some View {
        let listDistinct = listBundleIds.reduce(into: [String?]()) { list, bundleId in
            if !list.contains(bundleId) {
                list.append(bundleId)
            }
        }
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(StageColors.tile)
            .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(StageColors.separator, lineWidth: 0.5)
            }
            .overlay {
                if listDistinct.count <= 1 {
                    ApplicationIconView(bundleId: listDistinct.first ?? nil, size: size * 0.74)
                } else {
                    let iconSize = size * 0.39
                    let listIcons = Array(listDistinct.prefix(4))
                    // Two icons sit side by side in the middle; more fill a grid of two rows.
                    VStack(spacing: size * 0.04) {
                        ForEach(0..<(listIcons.count > 2 ? 2 : 1), id: \.self) { line in
                            HStack(spacing: size * 0.04) {
                                ForEach(0..<2, id: \.self) { column in
                                    let index = line * 2 + column
                                    if index < listIcons.count {
                                        ApplicationIconView(bundleId: listIcons[index], size: iconSize)
                                    } else {
                                        Color.clear.frame(width: iconSize, height: iconSize)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: size, height: size)
    }
}

/// Records a view's frame in the hosting view under a stage zone, for hit-testing drops.
struct ZoneFrameReporter: ViewModifier {
    let zone: StageZone
    let model: StageModel

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            model.mapZoneFrames[zone] = frame
        }
    }
}

/// The tab bar while a switch brings a group forward: the group's name with a spinner, and placeholder
/// tabs a light sweeps across, until the group's own tabs arrive.
struct SwitchingTabs: View {
    private static let placeholderWidths: [CGFloat] = [150, 120, 170]

    let groupName: String

    @State private var phase: CGFloat = -1

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(groupName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: StageView.tabHeight)
            .foregroundStyle(StageColors.activeTabText)
            .background(StageColors.activeTab, in: FolderTabShape())
            ForEach(Self.placeholderWidths, id: \.self) { width in
                FolderTabShape()
                    .fill(StageColors.idleTab)
                    .frame(width: width, height: StageView.tabHeight)
                    .overlay {
                        GeometryReader { proxy in
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(0.18), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: phase * proxy.size.width * 1.6)
                        }
                        .clipShape(FolderTabShape())
                    }
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, StageView.tabBarInset)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

/// What stands in for a page of Rookery's own while the windows it covers are set aside and it is built,
/// or while it reads what it shows: a spinner and what is on the way.
struct PageLoading: View {
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StageColors.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
