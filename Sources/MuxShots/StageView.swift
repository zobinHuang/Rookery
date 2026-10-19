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
    /// The user is dragging the stage by its sidebar header, towards another display.
    func moveStageChanged()
    func moveStageEnded()
}

/// The stage: groups down the left, the active group's windows as tabs along the top, and the content
/// area the front window is laid over.
struct StageView: View {
    private static let zoneAnimation = Animation.spring(response: 0.28, dampingFraction: 0.82)
    private static let sidebarAnimation = Animation.spring(response: 0.34, dampingFraction: 0.86)

    let model: StageModel
    unowned let actions: any StageActions
    @Namespace private var tabNamespace

    /// An AppKit view hosting the stage.
    static func makeHostingView(model: StageModel, actions: any StageActions) -> NSView {
        let view = NSHostingView(rootView: StageView(model: model, actions: actions))
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
        .opacity(model.isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.22), value: model.isVisible)
        .animation(Self.zoneAnimation, value: model.highlightedZone)
        .animation(Self.zoneAnimation, value: showsDropZones)
        .animation(Self.zoneAnimation, value: model.tabInsertBeforeId)
        .animation(Self.zoneAnimation, value: model.groupInsertBeforeId)
        .animation(Self.sidebarAnimation, value: model.isSidebarCollapsed)
    }

    // MARK: - Sidebar

    private var showsDropZones: Bool {
        model.isReceivingWindow || model.isDraggingTab
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            sidebarHeader
            ScrollView {
                VStack(spacing: 4) {
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
            }
            Spacer(minLength: 0)
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
            } else if model.listGroups.isEmpty && !model.isSidebarCollapsed {
                Text("Drag a window here to start a group.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
            sidebarToolbar
        }
        .frame(maxHeight: .infinity)
        .background(.thinMaterial)
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
                VStack(spacing: 10) {
                    headerButton("sidebar.left", help: "Show the sidebar", action: actions.toggleSidebar)
                    headerButton("arrow.down.right.and.arrow.up.left", help: "Leave the stage", action: actions.exitStage)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    Text("MuxShots")
                        .font(.system(size: 15, weight: .bold))
                    Spacer()
                    headerButton("sidebar.left", help: "Hide the sidebar", action: actions.toggleSidebar)
                    headerButton("arrow.down.right.and.arrow.up.left", help: "Leave the stage", action: actions.exitStage)
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

    /// The tools along the bottom of the sidebar.
    private var sidebarToolbar: some View {
        HStack(spacing: 4) {
            headerButton(
                model.isDarkTheme ? "sun.max" : "moon",
                help: model.isDarkTheme ? "Switch to the light theme" : "Switch to the dark theme",
                action: actions.toggleTheme
            )
            if !model.isSidebarCollapsed {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: model.isSidebarCollapsed ? .center : .leading)
        .padding(.horizontal, 10)
        .frame(height: 38)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
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
        let isHovered = model.highlightedZone == .group(row.groupId)
        let isLanded = model.landedZone == .group(row.groupId)
        return Button {
            actions.selectGroup(row.groupId)
        } label: {
            Group {
                if model.isSidebarCollapsed {
                    IconStack(listBundleIds: Array(row.listBundleIds.prefix(1)), iconSize: 30, overlap: 0)
                        .overlay(alignment: .bottomTrailing) {
                            if row.listBundleIds.count > 1 {
                                Text("\(row.listBundleIds.count)")
                                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary, in: .capsule)
                                    .offset(x: 6, y: 4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                } else {
                    HStack(spacing: 10) {
                        IconStack(listBundleIds: row.listBundleIds, iconSize: 22, overlap: -9)
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
                                .font(.system(size: 13, weight: row.isActive ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text("\(row.listBundleIds.count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(row.isActive ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .foregroundStyle(row.isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill(isActive: row.isActive, isHovered: isHovered))
            }
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(row.isActive ? Color.white.opacity(0.7) : Color.accentColor, lineWidth: 2)
                }
            }
            .scaleEffect(isLanded ? 1.06 : (isHovered ? 1.03 : 1))
            .contentShape(Rectangle())
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

    private func rowFill(isActive: Bool, isHovered: Bool) -> AnyShapeStyle {
        if isActive {
            return AnyShapeStyle(Color.accentColor.gradient)
        }
        return isHovered ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear)
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
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "selectedTab", in: tabNamespace)
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
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
                .fill(Color.primary.opacity(0.04))
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
