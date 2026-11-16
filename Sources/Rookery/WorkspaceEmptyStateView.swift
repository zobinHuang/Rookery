import AppKit
import SwiftUI

/// What the panel shows before any window is managed: how to hand one over.
struct WorkspaceEmptyStateView: View {
    /// An AppKit view hosting the empty state.
    static func makeHostingView() -> NSView {
        NSHostingView(rootView: WorkspaceEmptyStateView())
    }

    var body: some View {
        VStack(spacing: 10) {
            RookeryIconView(.newStage, scale: 3)
                .foregroundStyle(.tint)
            Text("No Managed Windows")
                .font(.system(size: 15, weight: .semibold))
            Text("Drag any window toward the top of the screen and drop it on a group.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
