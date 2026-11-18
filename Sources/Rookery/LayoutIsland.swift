import AppKit
import SwiftUI

/// A part of a view laid out in a hosting view of its own, so that what changes inside it, as a
/// conversation growing line by line, lays out only the part and never the whole window around it, whose
/// layout is far dearer. The window sees a view of the size it gave; the part gets the theme, the people,
/// the text colors and the button style the window's root sets, which a hosting view of its own would not
/// inherit.
struct LayoutIsland<Content: View>: NSViewRepresentable {
    @Environment(\.chosenTheme) private var chosenTheme
    @Environment(\.people) private var people

    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: island())
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        view.rootView = island()
    }

    private func island() -> AnyView {
        AnyView(
            content()
                .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
                .environment(\.chosenTheme, chosenTheme)
                .environment(\.people, people)
                .buttonStyle(StageButtonStyle())
        )
    }
}
