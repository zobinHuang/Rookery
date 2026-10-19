// Draws the MuxShots app icon and writes Resources/AppIcon.icns: three stacked window cards on a gradient.
import AppKit

let canvasSize: CGFloat = 1024
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize), flipped: false) { _ in
    let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(red: 0.36, green: 0.42, blue: 0.98, alpha: 1),
        NSColor(red: 0.16, green: 0.20, blue: 0.62, alpha: 1),
    ])?.draw(in: tile, angle: -70)

    let cardSize = NSSize(width: 470, height: 340)
    let listOffsets: [(CGFloat, CGFloat, CGFloat)] = [(-90, 110, 0.35), (-20, 40, 0.6), (50, -30, 1)]
    for (dx, dy, alpha) in listOffsets {
        let origin = NSPoint(x: tileRect.midX - cardSize.width / 2 + dx, y: tileRect.midY - cardSize.height / 2 + dy)
        let card = NSBezierPath(roundedRect: NSRect(origin: origin, size: cardSize), xRadius: 46, yRadius: 46)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor.white.withAlphaComponent(alpha).setFill()
        card.fill()
        NSGraphicsContext.restoreGraphicsState()
        if alpha == 1 {
            let bar = NSBezierPath(
                roundedRect: NSRect(x: origin.x, y: origin.y + cardSize.height - 70, width: cardSize.width, height: 70),
                xRadius: 46,
                yRadius: 46
            )
            NSColor(red: 0.36, green: 0.42, blue: 0.98, alpha: 0.18).setFill()
            bar.fill()
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: origin.x + 36 + CGFloat(index) * 44, y: origin.y + cardSize.height - 48, width: 26, height: 26)).fill()
            }
        }
    }
    return true
}

let iconset = outputDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
    }
}
