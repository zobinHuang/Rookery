import CoreGraphics
import Foundation
import Testing
@testable import RookeryCore

/// The crow's acts loop without a seam and stay in their frame; the mark reads its typeface and refuses a
/// file that is none.
struct CrowRigTests {
    private static let side = 96

    private static func pixels(of act: CrowAct, at time: Double) -> [UInt8] {
        var listBytes = [UInt8](repeating: 0, count: side * side * 4)
        listBytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return
            }
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            CrowRig.draw(act, at: time, in: context, side: CGFloat(side), look: .light)
        }
        return listBytes
    }

    @Test(arguments: CrowRig.listActs)
    func everyActEndsWhereItBegins(act: CrowAct) {
        #expect(Self.pixels(of: act, at: 0) == Self.pixels(of: act, at: CrowRig.period(of: act)))
    }

    @Test(arguments: CrowRig.listActs)
    func everyActStaysInsideItsFrame(act: CrowAct) throws {
        let box = try #require(CrowRig.mapBoxes[act])
        let scale = act.isRaven ? CrowRig.ravenScale : CrowRig.crowScale
        #expect(box.width * scale <= CrowRig.unit + 0.5)
        #expect(box.height * scale <= CrowRig.unit + 0.5)
    }

    @Test func theWordmarkIsWiderThanTallAndAFileThatIsNoFontIsRefused() throws {
        let fonts = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/Fonts")
        let font = try BrandMark.font(at: fonts.appending(path: "Michroma-Regular.ttf"), size: 40)
        let bounds = BrandMark.wordmarkBounds(font: font)
        #expect(bounds.width > bounds.height * 2)
        let notAFont = fonts.appending(path: "OFL.txt")
        #expect(throws: BrandMarkError.fontUnreadable(notAFont)) {
            try BrandMark.font(at: notAFont, size: 40)
        }
    }
}
