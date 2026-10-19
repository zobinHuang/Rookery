import AppKit
import MuxShotsCore
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
    /// Give keyboard input back to the stage's front window.
    func endEditing()
    func tabDragBegan()
    func groupDragBegan(_ groupId: GroupId)
    /// Move a group to just before another, or to the end with nil.
    func moveGroup(_ groupId: GroupId, before targetGroupId: GroupId?)
    /// Move a tab to just before another tab, or to the end with nil.
    func moveTab(_ windowId: WindowId, before targetWindowId: WindowId?)
    func toggleSidebar()
    /// Switch between the light and the dark theme.
    func toggleTheme()
    /// Fill the display with the stage, or go back to its earlier frame.
    func toggleMaximize()
    func exitStage()
    /// Open another MuxShots window.
    func newStage()
    func showSettings()
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

    let model: StageModel
    let mixer: MixerController
    unowned let actions: any StageActions
    @Namespace private var tabNamespace
    @Namespace private var modeNamespace
    @State private var hoveredGroupId: GroupId?
    @State private var sidebarHeight: CGFloat = 0

    /// An AppKit view hosting the stage.
    static func makeHostingView(model: StageModel, mixer: MixerController, actions: any StageActions) -> NSView {
        let view = NSHostingView(rootView: StageView(model: model, mixer: mixer, actions: actions))
        view.sizingOptions = []
        return view
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: model.sidebarWidth)
            VStack(spacing: 0) {
                tabBar
                    .frame(height: StageModel.tabBarHeight)
                content
                    .padding(.trailing, StageModel.contentInset)
                    .padding(.bottom, StageModel.contentInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StageColors.window)
        .opacity(model.isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.22), value: model.isVisible)
        .animation(Self.zoneAnimation, value: model.highlightedZone)
        .animation(Self.zoneAnimation, value: showsDropZones)
        .animation(Self.zoneAnimation, value: model.tabInsertBeforeId)
        .animation(Self.zoneAnimation, value: model.groupInsertBeforeId)
        .animation(Self.sidebarAnimation, value: model.isSidebarCollapsed)
        .animation(Self.sidebarAnimation, value: sidebarMode)
    }

    // MARK: - Sidebar

    private var showsDropZones: Bool {
        model.isReceivingWindow || model.isDraggingTab
    }

    /// What the sidebar shows: the groups whenever a window or tab is being dragged, so it can be dropped
    /// on one, else the chosen mode.
    private var sidebarMode: SidebarMode {
        showsDropZones ? .groups : model.sidebarMode
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            sidebarHeader
            modeSwitch
            ZStack(alignment: .top) {
                if sidebarMode == .groups {
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
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                } else {
                    ScrollView {
                        MixerView(mixer: mixer, isCollapsed: model.isSidebarCollapsed)
                            .padding(.vertical, 2)
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            if showsDropZones {
                VStack(spacing: 6) {
                    dropZone(.newGroup, title: "New Group", symbol: "plus", tint: .accentColor)
                    if model.isDraggingManagedWindow || model.isDraggingTab {
                        dropZone(.release, title: "Release", symbol: "arrow.up.forward.square", tint: .red)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if sidebarMode == .groups && model.listGroups.isEmpty && !model.isSidebarCollapsed {
                Text("Drag a window here to start a group.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
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
            if !model.isSidebarCollapsed && !model.listClockCities.isEmpty {
                WorldClockView(listCities: model.listClockCities)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(StageColors.separator)
                            .frame(height: 1)
                    }
                    .transition(.opacity)
            }
            sidebarToolbar
        }
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            sidebarHeight = height
        }
        .background(StageColors.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(StageColors.separator)
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { listTexts, _ in
            switch Self.payload(from: listTexts) {
            case .window(let windowId):
                return dropWindow(windowId, into: nil)
            case .group(let groupId):
                return dropGroup(groupId, before: nil)
            case nil:
                return false
            }
        } isTargeted: { isTargeted in
            if model.draggingGroupId != nil {
                model.isGroupOverSidebarEnd = isTargeted
            } else {
                model.isTabOverSidebar = isTargeted
            }
        }
        .modifier(ZoneFrameReporter(zone: .sidebar, model: model))
    }

    private var sidebarHeader: some View {
        Group {
            if model.isSidebarCollapsed {
                VStack(spacing: 12) {
                    CloseButton(action: actions.exitStage)
                    headerButton("sidebar.left", help: "Show the sidebar", action: actions.toggleSidebar)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    CloseButton(action: actions.exitStage)
                    Text("MuxShots")
                        .font(.system(size: 15, weight: .bold))
                    Spacer()
                    headerButton("sidebar.left", help: "Hide the sidebar", action: actions.toggleSidebar)
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

    /// The switch between the groups and the mixer: a segmented control, or a column of two buttons in the
    /// collapsed sidebar.
    private var modeSwitch: some View {
        Group {
            if model.isSidebarCollapsed {
                VStack(spacing: 4) {
                    ForEach(SidebarMode.allCases, id: \.self) { mode in
                        Button {
                            model.sidebarMode = mode
                        } label: {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(sidebarMode == mode ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                                .frame(width: 34, height: 26)
                                .background {
                                    if sidebarMode == mode {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.16))
                                            .matchedGeometryEffect(id: "mode", in: modeNamespace)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(mode.title)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 2) {
                    ForEach(SidebarMode.allCases, id: \.self) { mode in
                        Button {
                            model.sidebarMode = mode
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: mode.symbol)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(mode.title)
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(sidebarMode == mode ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background {
                                if sidebarMode == mode {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(StageColors.selectedSegment)
                                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                        .matchedGeometryEffect(id: "mode", in: modeNamespace)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StageColors.groove.opacity(0.7))
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 4)
    }

    /// The tools along the bottom of the sidebar.
    private var sidebarToolbar: some View {
        let layout = model.isSidebarCollapsed ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            headerButton("plus", help: "New MuxShots window", action: actions.newStage)
            headerButton(
                model.isDarkTheme ? "sun.max" : "moon",
                help: model.isDarkTheme ? "Switch to the light theme" : "Switch to the dark theme",
                action: actions.toggleTheme
            )
            headerButton("gearshape", help: "Settings", action: actions.showSettings)
            if !model.isSidebarCollapsed {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: model.isSidebarCollapsed ? .center : .leading)
        .padding(.vertical, model.isSidebarCollapsed ? 8 : 0)
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
        }
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
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
                                    .foregroundStyle(row.isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                                    .lineLimit(1)
                            }
                            Text(Self.subtitle(of: row))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
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
                        .fill(Color.accentColor)
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
            return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.2 : 0.15))
        }
        return isHovered ? AnyShapeStyle(StageColors.hoveredRow) : AnyShapeStyle(.clear)
    }

    /// The group's front window and how many windows it holds, as its row's second line.
    private static func subtitle(of row: StageGroupRow) -> String {
        let count = row.listBundleIds.count
        let countText = count == 1 ? "1 window" : "\(count) windows"
        guard let frontWindowName = row.frontWindowName, !frontWindowName.isEmpty, count > 1 else {
            return row.frontWindowName ?? countText
        }
        return "\(frontWindowName) · \(countText)"
    }

    /// The "⋯" button a hovered group row shows, with what can be done to the group.
    private func groupMenu(_ row: StageGroupRow) -> some View {
        Menu {
            Button("Rename Group…") {
                beginRenaming(group: row.groupId)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
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
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
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

    private func dropZone(_ zone: StageZone, title: String, symbol: String, tint: Color) -> some View {
        let isHovered = model.highlightedZone == zone
        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
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
        }
        .modifier(ZoneFrameReporter(zone: zone, model: model))
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(model.listTabs) { tab in
                tabButton(tab)
            }
            if model.isTabOverTabBarEnd {
                InsertionMark(isVertical: true)
            }
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { listTexts, _ in
                    guard case .window(let windowId) = Self.payload(from: listTexts) else {
                        return false
                    }
                    clearDragState()
                    actions.moveTab(windowId, before: nil)
                    return true
                } isTargeted: { isTargeted in
                    model.isTabOverTabBarEnd = isTargeted
                }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.trailing, StageModel.contentInset)
        .animation(.spring(response: 0.26, dampingFraction: 0.85), value: model.selectedWindowId)
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
                    InlineRenameField(
                        initialText: tab.hasCustomName ? tab.title : "",
                        placeholder: tab.title
                    ) { name in
                        finishEditing()
                        actions.renameWindow(tab.windowId, to: name)
                    } onCancel: {
                        finishEditing()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 180)
                } else {
                    Text(tab.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 220)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(StageColors.selectedTab)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "selectedTab", in: tabNamespace)
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(StageColors.idleTab)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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
                Text(tab.title)
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

    private var content: some View {
        let isHovered = model.highlightedZone == .content
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StageColors.content)
            if model.selectedWindowId == nil || isHovered {
                VStack(spacing: 10) {
                    Image(systemName: isHovered ? "arrow.down.to.line" : "macwindow.badge.plus")
                        .font(.system(size: 40, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                    Text(contentHint)
                        .font(.system(size: 15, weight: .semibold))
                    if !isHovered {
                        Text("Windows in a group open here as tabs.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isHovered ? 3 : 0)
                .shadow(color: .accentColor.opacity(isHovered ? 0.8 : 0), radius: 10)
        }
        .modifier(ZoneFrameReporter(zone: .content, model: model))
    }

    private var contentHint: String {
        guard model.highlightedZone == .content else {
            return "Drag a window here"
        }
        return model.activeGroupName.map { "Drop to add to \($0)" } ?? "Drop to start a group"
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

/// The red close button of a MuxShots window, showing its cross while the pointer is over it, as the
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
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(.black.opacity(0.55))
                    }
                }
                .frame(width: Self.diameter, height: Self.diameter)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Close this MuxShots window")
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

/// A text field that edits a name in place: return commits, escape cancels, and leaving it commits.
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
                    Image(systemName: "macwindow")
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
