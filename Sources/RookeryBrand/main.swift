import CoreGraphics
import Foundation
import ImageIO
import RookeryCore
import UniformTypeIdentifiers

/// Writes Rookery's app icon as an iconset, and the README's wordmark for light and dark pages, from
/// `BrandMark`: the pair of
/// eyes over the trajectory, white on a black rounded square lit faintly from above, on the margins macOS
/// gives an icon. Usage: rookery-brand <output directory> <font file>

let listArguments = CommandLine.arguments
guard listArguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: rookery-brand <output directory> <font file>\n".utf8))
    exit(64)
}
let outputDirectory = URL(filePath: listArguments[1])
let fontURL = URL(filePath: listArguments[2])
let white = CGColor(gray: 0.97, alpha: 1)
let black = CGColor(gray: 0, alpha: 1)

/// An icon's square on its canvas: 824 of 1024, centred, its corners rounded as macOS rounds them.
let iconShare: CGFloat = 824.0 / 1024.0
let cornerShare: CGFloat = 0.2237

func bitmap(width: Int, height: Int) -> CGContext? {
    CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

func write(_ context: CGContext, to url: URL) throws {
    guard
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

func drawIcon(pixels: Int) -> CGContext? {
    guard let context = bitmap(width: pixels, height: pixels) else {
        return nil
    }
    let side = CGFloat(pixels)
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)
    let squareSide = side * iconShare
    let square = CGRect(x: (side - squareSide) / 2, y: (side - squareSide) / 2 - side * 0.01, width: squareSide, height: squareSide)
    let shape = CGPath(roundedRect: square, cornerWidth: squareSide * cornerShare, cornerHeight: squareSide * cornerShare, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(shape)
    context.setFillColor(black)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(shape)
    context.clip()
    if let gradient = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.11), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: square.minY), end: CGPoint(x: 0, y: square.midY), options: [])
    }
    let markSide = squareSide * 0.66
    BrandMark.drawMark(
        in: context,
        rect: CGRect(x: square.midX - markSide / 2, y: square.midY - markSide / 2, width: markSide, height: markSide),
        ink: white
    )
    context.restoreGState()
    return context
}

do {
    let iconset = outputDirectory.appending(path: "AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            guard let context = drawIcon(pixels: points * scale) else {
                continue
            }
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try write(context, to: iconset.appending(path: name))
        }
    }
    let font = try BrandMark.font(at: fontURL, size: 96)
    let bounds = BrandMark.wordmarkBounds(font: font)
    let margin: CGFloat = 8
    for (name, ink) in [("rookery-logo.png", CGColor(gray: 0.06, alpha: 1)), ("rookery-logo-dark.png", white)] {
        guard let context = bitmap(width: Int(bounds.width + margin * 2), height: Int(bounds.height + margin * 2)) else {
            continue
        }
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 1, y: -1)
        BrandMark.drawWordmark(in: context, x: margin - bounds.minX, baseline: margin - bounds.minY, font: font, ink: ink)
        try write(context, to: outputDirectory.appending(path: name))
    }
} catch {
    FileHandle.standardError.write(Data("rookery-brand: \(error)\n".utf8))
    exit(1)
}
