import SwiftUI

/// A name that keeps itself whole: on one line at its size if it fits, else on one line a little smaller,
/// and only when even that is too wide, wrapped at the smaller size.
struct FittingText: View {
    private static let listShrinkScales: [CGFloat] = [0.9, 0.8]
    private static let wrappedLineLimit = 3

    let text: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default

    init(_ text: String, size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) {
        self.text = text
        self.size = size
        self.weight = weight
        self.design = design
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(scale: 1)
            ForEach(Self.listShrinkScales, id: \.self) { scale in
                line(scale: scale)
            }
            Text(text)
                .font(font(scale: Self.listShrinkScales.last ?? 1))
                .lineLimit(Self.wrappedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(scale: CGFloat) -> some View {
        Text(text)
            .font(font(scale: scale))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func font(scale: CGFloat) -> Font {
        .system(size: size * scale, weight: weight, design: design)
    }
}
