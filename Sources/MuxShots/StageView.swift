import AppKit
import MuxShotsCore
import SwiftUI

/// The stage: groups down the left, the active group's windows as tabs along the top, and the content
/// area the front window is laid over.
struct StageView: View {
    private static let zoneAnimation = Animation.spring(response: 0.28, dampingFraction: 0.82)

    let model: StageModel
    let onSelectGroup: (GroupId) -> Void
    let onSelectTab: (WindowId) -> Void
    let onReleaseTab: (WindowId) -> Void
    let onExit: () -> Void
    @Namespace private var tabNamespace

    /// An AppKit view hosting the stage.
    static func makeHostingView(
        model: StageModel,
        onSelectGroup: @escaping (GroupId) -> Void,
        onSelectTab: @escaping (WindowId) -> Void,
        onReleaseTab: @escaping (WindowId) -> Void,
        onExit: @escaping () -> Void
    ) -> NSView {
        let view = NSHostingView(rootView: StageView(
            model: model,
            onSelectGroup: onSelectGroup,
            onSelectTab: onSelectTab,
            onReleaseTab: onReleaseTab,
            onExit: onExit
        ))
        view.sizingOptions = []
        return view
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: StageModel.sidebarWidth)
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
        .animation(Self.zoneAnimation, value: model.hoveredZone)
        .animation(Self.zoneAnimation, value: model.isReceivingWindow)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MuxShots")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button(action: onExit) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Leave the stage")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.listGroups) { row in
                        groupRow(row)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
            if model.isReceivingWindow {
                VStack(spacing: 6) {
                    dropZone(.newGroup, title: "New Group", symbol: "plus", tint: .accentColor)
                    if model.isDraggingManagedWindow {
                        dropZone(.release, title: "Release", symbol: "arrow.up.forward.square", tint: .red)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if model.listGroups.isEmpty {
                Text("Drag a window here to start a group.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
        .background(.thinMaterial)
    }

    private func groupRow(_ row: StageGroupRow) -> some View {
        let isHovered = model.hoveredZone == .group(row.groupId)
        let isLanded = model.landedZone == .group(row.groupId)
        return Button {
            onSelectGroup(row.groupId)
        } label: {
            HStack(spacing: 10) {
                IconStack(listBundleIds: row.listBundleIds, iconSize: 22, overlap: -9)
                Text(row.name)
                    .font(.system(size: 13, weight: row.isActive ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(row.listBundleIds.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(row.isActive ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(row.isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
        .modifier(ZoneFrameReporter(zone: .group(row.groupId), model: model))
    }

    private func rowFill(isActive: Bool, isHovered: Bool) -> AnyShapeStyle {
        if isActive {
            return AnyShapeStyle(Color.accentColor.gradient)
        }
        return isHovered ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear)
    }

    private func dropZone(_ zone: StageZone, title: String, symbol: String, tint: Color) -> some View {
        let isHovered = model.hoveredZone == zone
        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
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
        .modifier(ZoneFrameReporter(zone: zone, model: model))
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(model.listTabs) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.trailing, StageModel.contentInset)
        .animation(.spring(response: 0.26, dampingFraction: 0.85), value: model.selectedWindowId)
    }

    private func tabButton(_ tab: StageTab) -> some View {
        let isSelected = tab.windowId == model.selectedWindowId
        return Button {
            onSelectTab(tab.windowId)
        } label: {
            HStack(spacing: 7) {
                if let icon = ApplicationIcon.icon(forBundleId: tab.bundleId) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text(tab.title.isEmpty ? tab.applicationName : tab.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .contextMenu {
            Button("Release Window") {
                onReleaseTab(tab.windowId)
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        let isHovered = model.hoveredZone == .content
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
        guard model.hoveredZone == .content else {
            return "Drag a window here"
        }
        return model.activeGroupName.map { "Drop to add to \($0)" } ?? "Drop to start a group"
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
