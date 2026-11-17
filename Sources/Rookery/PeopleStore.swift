import AppKit
import Observation
import os
import RookeryCore
import SwiftUI

/// The people the user set down, kept in the data directory with a photo each may have, read once and
/// written on every change; and their marks, drawn as views and as images for text.
@MainActor
@Observable
final class PeopleStore {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "people")
    private static let photoFolderName = "people"
    /// The side of a photo kept, in pixels, enough for the largest mark at twice the scale.
    private static let photoSide: CGFloat = 256
    /// The longest side of the whole picture kept for framing the photo again.
    private static let originalSide: CGFloat = 1600

    private(set) var book = PeopleBook()
    /// Changes whenever a photo does, so marks drawn from it are drawn again.
    private(set) var photoGeneration = 0
    @ObservationIgnored private var mapPhotos: [String: NSImage] = [:]
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let photoFolder: URL

    init(directory: URL = DataDirectory.url) {
        fileURL = directory.appending(path: PeopleBook.fileName)
        photoFolder = directory.appending(path: Self.photoFolderName, directoryHint: .isDirectory)
        load()
    }

    var listPeople: [Person] {
        book.listPeople
    }

    func person(withAddress address: String) -> Person? {
        book.person(withAddress: address)
    }

    /// Add a person or change one, and keep it.
    func put(_ person: Person) {
        book.put(person)
        save()
    }

    func remove(_ personId: String) {
        book.remove(personId)
        try? FileManager.default.removeItem(at: photoURL(of: personId))
        try? FileManager.default.removeItem(at: originalURL(of: personId))
        mapPhotos[personId] = nil
        save()
    }

    /// Read a picture the user chose for a photo.
    ///
    /// - Throws: when it cannot be read as a picture
    static func picture(at url: URL) throws -> NSImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw PeopleError.unreadablePicture(url.lastPathComponent)
        }
        return image
    }

    /// Keep the part of a picture the user framed as a person's photo, made small, and the picture
    /// itself, so the framing can be changed later.
    ///
    /// - Parameters:
    ///   - image: the picture
    ///   - source: the square framed, in the picture's points, from its bottom left
    ///   - personId: whose photo it is
    /// - Throws: when the photo cannot be drawn or kept
    func takePhoto(_ image: NSImage, cropping source: CGRect, for personId: String) throws {
        guard var person = book.person(withId: personId), let data = Self.squarePNG(of: image, from: source) else {
            throw PeopleError.unreadablePicture(person(withId: personId)?.name ?? personId)
        }
        try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
        try data.write(to: photoURL(of: personId), options: .atomic)
        if let original = Self.png(of: image) {
            try original.write(to: originalURL(of: personId), options: .atomic)
        }
        mapPhotos[personId] = NSImage(data: data)
        person.hasPhoto = true
        book.put(person)
        photoGeneration += 1
        save()
    }

    func removePhoto(of personId: String) {
        guard var person = book.person(withId: personId) else {
            return
        }
        try? FileManager.default.removeItem(at: photoURL(of: personId))
        try? FileManager.default.removeItem(at: originalURL(of: personId))
        mapPhotos[personId] = nil
        person.hasPhoto = false
        book.put(person)
        photoGeneration += 1
        save()
    }

    /// A person's photo, if they have one.
    func photo(of person: Person) -> NSImage? {
        guard person.hasPhoto else {
            return nil
        }
        if let photo = mapPhotos[person.id] {
            return photo
        }
        let photo = NSImage(contentsOf: photoURL(of: person.id))
        mapPhotos[person.id] = photo
        return photo
    }

    /// A person's mark as an image, round, for setting inside a line of text.
    func markImage(of person: Person, side: CGFloat) -> NSImage {
        let photo = photo(of: person)
        let initials = person.initials
        let color = NSColor(PersonMark.color(of: person.listAddresses.first ?? person.name))
        return NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect)
            circle.addClip()
            if let photo {
                photo.draw(in: rect)
            } else {
                color.setFill()
                rect.fill()
                let font = NSFont.systemFont(ofSize: side * 0.42, weight: .semibold)
                let text = NSAttributedString(string: initials, attributes: [.font: font, .foregroundColor: NSColor.white])
                let size = text.size()
                text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
            return true
        }
    }

    /// The whole picture a person's photo was framed from, to frame it again; nil for a photo kept
    /// before pictures were.
    func originalPicture(of personId: String) -> NSImage? {
        NSImage(contentsOf: originalURL(of: personId))
    }

    /// Whether the whole picture a person's photo was framed from is kept.
    func hasOriginalPicture(of personId: String) -> Bool {
        FileManager.default.fileExists(atPath: originalURL(of: personId).path)
    }

    private func person(withId personId: String) -> Person? {
        book.person(withId: personId)
    }

    private func photoURL(of personId: String) -> URL {
        photoFolder.appending(path: "\(personId).png")
    }

    private func originalURL(of personId: String) -> URL {
        photoFolder.appending(path: "\(personId)-original.png")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            return
        }
        do {
            book = try JSONDecoder().decode(PeopleBook.self, from: data)
        } catch {
            Self.logger.error("cannot read the people: \(error, privacy: .public)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(book).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("cannot keep the people: \(error, privacy: .public)")
        }
    }

    /// A square of a picture drawn at the photo's side, as PNG.
    private static func squarePNG(of image: NSImage, from source: CGRect) -> Data? {
        guard source.width > 0, source.height > 0 else {
            return nil
        }
        let output = NSImage(size: CGSize(width: photoSide, height: photoSide), flipped: false) { rect in
            image.draw(in: rect, from: source, operation: .copy, fraction: 1)
            return true
        }
        return png(of: output)
    }

    /// A picture as PNG, at most the original's side kept so a large picture stays small on disk.
    private static func png(of image: NSImage) -> Data? {
        let scale = min(1, originalSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            return nil
        }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        return bitmap.representation(using: .png, properties: [:])
    }
}

enum PeopleError: Error, CustomStringConvertible {
    case unreadablePicture(String)

    var description: String {
        switch self {
        case .unreadablePicture(let name): "Rookery cannot read \(name) as a picture"
        }
    }
}

/// The round mark that stands for someone: their photo, else their initials on their color; for an address
/// no person holds, the initials of the name it came with on the address's color.
struct PersonMark: View {
    /// The colors marks are drawn in, one for each address, the same every time.
    static let listColors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]

    let person: Person?
    /// The name and address shown when no person holds the address.
    var fallbackName = ""
    var fallbackAddress = ""
    var size: CGFloat = 30

    @Environment(\.people) private var people

    var body: some View {
        Group {
            if let person, let photo = people?.photo(of: person) {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(person?.initials ?? Person.initials(of: fallbackName.isEmpty ? fallbackAddress : fallbackName))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Self.color(of: person?.listAddresses.first ?? fallbackAddress))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .id(people?.photoGeneration ?? 0)
    }

    /// An address's color.
    static func color(of address: String) -> Color {
        let sum = address.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return listColors[sum % listColors.count]
    }
}

/// An address as the user knows it: the name of the person it belongs to, with their mark before it when
/// asked, else the name the mail gave with it, else the address itself; the address in its tooltip.
struct AddressLabel: View {
    let address: MailAddress
    var markSize: CGFloat?

    @Environment(\.people) private var people

    var body: some View {
        let person = people?.person(withAddress: address.address)
        HStack(spacing: 5) {
            if let markSize, let person {
                PersonMark(person: person, size: markSize)
            }
            Text(person?.name ?? (address.name.isEmpty ? address.address : address.name))
                .lineLimit(1)
        }
        .help(address.address)
    }

    /// The names of several addresses, each as the user knows it, joined by commas.
    @MainActor
    static func names(_ listAddresses: [MailAddress], people: PeopleStore?) -> String {
        listAddresses.map { address in
            people?.person(withAddress: address.address)?.name ?? (address.name.isEmpty ? address.address : address.name)
        }.joined(separator: ", ")
    }
}

/// Where the environment keeps the people, for the views that show them deep in the stage.
private struct PeopleKey: EnvironmentKey {
    static let defaultValue: PeopleStore? = nil
}

extension EnvironmentValues {
    /// The people the user set down, set at the root of each of Rookery's views.
    var people: PeopleStore? {
        get { self[PeopleKey.self] }
        set { self[PeopleKey.self] = newValue }
    }
}
