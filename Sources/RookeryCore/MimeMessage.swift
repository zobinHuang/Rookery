import Foundation

/// One message as the internet carries it, read from its raw bytes: its headers, its readable text, and the
/// names of its attachments. Multipart bodies are walked; base64 and quoted-printable are decoded in their
/// charset; HTML is turned to text where a message has no plain part.
public struct MimeMessage: Equatable, Sendable {
    /// The most characters of text a message keeps, so one huge message cannot flood a reader.
    public static let textLimit = 200_000
    public static let htmlLimit = 2_000_000

    public let mapHeaders: [String: String]
    public let text: String
    /// The HTML part as sent, for showing the message formatted; nil when it has none.
    public let html: String?
    public let listAttachmentNames: [String]
    /// The images the HTML shows by their content id, with their bytes where the file holds them.
    public let listInlineImages: [MailInlineImage]

    /// Read a message from its raw bytes.
    public init(data: Data) {
        let part = MimePart(data: data)
        mapHeaders = part.mapHeaders
        var plain: String?
        var html: String?
        var listAttachments: [String] = []
        var listImages: [MailInlineImage] = []
        part.collect(plain: &plain, html: &html, attachments: &listAttachments, images: &listImages)
        let body = plain ?? html.map(MimePart.text(ofHTML:)) ?? ""
        text = String(body.prefix(Self.textLimit))
        self.html = html.map { String($0.prefix(Self.htmlLimit)) }
        listAttachmentNames = listAttachments
        listInlineImages = listImages
    }

    /// The HTML with each `cid:` reference to an inline image whose bytes are known replaced by the image
    /// itself, so it shows without fetching anything.
    ///
    /// - Parameters:
    ///   - html: the message's HTML
    ///   - listImages: its inline images
    /// - Returns: the HTML with the images in it
    public static func embedding(_ listImages: [MailInlineImage], in html: String) -> String {
        var embedded = html
        var budget = inlineImageBudget
        for image in listImages {
            guard let data = image.data, !image.contentId.isEmpty, data.count <= budget else {
                continue
            }
            budget -= data.count
            embedded = embedded.replacingOccurrences(
                of: "cid:" + image.contentId,
                with: "data:\(image.mediaType);base64,\(data.base64EncodedString())",
                options: .caseInsensitive
            )
        }
        return embedded
    }

    /// The most bytes of inline images one message embeds.
    public static let inlineImageBudget = 25_000_000

    /// Read a message from an `.emlx` file's bytes: a byte count on the first line, the message, then Mail's
    /// own property list, which is left out.
    public init(emlx data: Data) {
        guard
            let newline = data.firstIndex(of: UInt8(ascii: "\n")),
            let count = Int(String(decoding: data[data.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces))
        else {
            self.init(data: data)
            return
        }
        let start = data.index(after: newline)
        let end = min(data.endIndex, start + count)
        self.init(data: data.subdata(in: start..<end))
    }

    /// A header's value, decoded, by its name in any case.
    public func header(_ name: String) -> String? {
        mapHeaders[name.lowercased()]
    }
}

/// An image a message's HTML shows inline, by the content id it refers to it with: its type, its file
/// name, and its bytes, or nil where Mail keeps them outside the message file.
public struct MailInlineImage: Equatable, Sendable {
    public let contentId: String
    public let mediaType: String
    public let fileName: String?
    public let data: Data?

    public init(contentId: String, mediaType: String, fileName: String?, data: Data?) {
        self.contentId = contentId
        self.mediaType = mediaType
        self.fileName = fileName
        self.data = data
    }
}

/// One part of a message: its headers and its raw body.
struct MimePart {
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let headerEndBare = Data("\n\n".utf8)
    private static let maxDepth = 12

    let mapHeaders: [String: String]
    let body: Data

    init(data: Data) {
        let split = data.range(of: Self.headerEnd) ?? data.range(of: Self.headerEndBare)
        let headerData = split.map { data[data.startIndex..<$0.lowerBound] } ?? data
        body = split.map { data[$0.upperBound...] } ?? Data()
        mapHeaders = Self.headers(of: String(decoding: headerData, as: UTF8.self))
    }

    /// Gather the first plain text, the first HTML, and the attachments' names, walking nested multiparts.
    func collect(
        plain: inout String?,
        html: inout String?,
        attachments listAttachments: inout [String],
        images listImages: inout [MailInlineImage],
        depth: Int = 0
    ) {
        guard depth < Self.maxDepth else {
            return
        }
        let contentType = mapHeaders["content-type"] ?? "text/plain"
        let mediaType = Self.mediaType(of: contentType)
        let mapParameters = Self.parameters(of: contentType)
        let disposition = (mapHeaders["content-disposition"] ?? "").lowercased()
        let fileName = Self.parameters(of: mapHeaders["content-disposition"] ?? "")["filename"] ?? mapParameters["name"]
        if mediaType.hasPrefix("multipart/"), let boundary = mapParameters["boundary"] {
            for partData in Self.split(body, boundary: boundary) {
                MimePart(data: partData).collect(plain: &plain, html: &html, attachments: &listAttachments, images: &listImages, depth: depth + 1)
            }
            return
        }
        if
            mediaType.hasPrefix("image/"),
            let contentId = mapHeaders["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")),
            !contentId.isEmpty
        {
            let data = decodedData()
            listImages.append(MailInlineImage(
                contentId: contentId,
                mediaType: mediaType,
                fileName: fileName.map(Self.decodeWords),
                data: data.isEmpty ? nil : data
            ))
            if !disposition.hasPrefix("attachment") {
                return
            }
        }
        if disposition.hasPrefix("attachment") || (fileName != nil && !mediaType.hasPrefix("text/")) {
            listAttachments.append(fileName.map(Self.decodeWords) ?? mediaType)
            return
        }
        if mediaType == "text/plain", plain == nil {
            plain = decodedText(charset: mapParameters["charset"])
        } else if mediaType == "text/html", html == nil {
            html = decodedText(charset: mapParameters["charset"])
        } else if mediaType == "message/rfc822" {
            MimePart(data: body).collect(plain: &plain, html: &html, attachments: &listAttachments, images: &listImages, depth: depth + 1)
        }
    }

    private func decodedText(charset: String?) -> String {
        Self.string(decodedData(), charset: charset)
    }

    /// The body with its transfer encoding undone.
    private func decodedData() -> Data {
        switch (mapHeaders["content-transfer-encoding"] ?? "").lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            Data(base64Encoded: String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }) ?? body
        case "quoted-printable":
            Self.decodeQuotedPrintable(body)
        default:
            body
        }
    }

    // MARK: - Headers

    static func headers(of text: String) -> [String: String] {
        var mapHeaders: [String: String] = [:]
        var currentName: String?
        for line in text.components(separatedBy: "\n").map({ $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }) {
            if let first = line.first, first == " " || first == "\t", let name = currentName {
                mapHeaders[name, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if mapHeaders[name] == nil {
                mapHeaders[name] = value
            }
            currentName = name
        }
        return mapHeaders.mapValues(decodeWords)
    }

    /// A header with RFC 2047 encoded words, such as `=?UTF-8?B?...?=`, decoded.
    static func decodeWords(_ value: String) -> String {
        guard value.contains("=?") else {
            return value
        }
        let pattern = /=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/
        var result = ""
        var rest = Substring(value)
        var isAfterEncodedWord = false
        while let match = rest.firstMatch(of: pattern) {
            let between = rest[rest.startIndex..<match.range.lowerBound]
            if !(isAfterEncodedWord && between.allSatisfy(\.isWhitespace)) {
                result += between
            }
            isAfterEncodedWord = true
            let charset = String(match.1)
            let payload = String(match.3)
            let raw: Data
            if match.2.lowercased() == "b" {
                raw = Data(base64Encoded: payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)) ?? Data()
            } else {
                raw = decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            }
            result += string(raw, charset: charset)
            rest = rest[match.range.upperBound...]
        }
        return result + rest
    }

    static func mediaType(of value: String) -> String {
        value.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
    }

    static func parameters(of value: String) -> [String: String] {
        var mapParameters: [String: String] = [:]
        for item in value.split(separator: ";").dropFirst() {
            let listParts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard listParts.count == 2 else {
                continue
            }
            let name = listParts[0].lowercased().replacingOccurrences(of: "*", with: "")
            var parameterValue = listParts[1]
            if parameterValue.hasPrefix("\""), parameterValue.hasSuffix("\""), parameterValue.count >= 2 {
                parameterValue = String(parameterValue.dropFirst().dropLast())
            }
            if listParts[0].hasSuffix("*"), let quote = parameterValue.range(of: "''") {
                parameterValue = String(parameterValue[quote.upperBound...]).removingPercentEncoding ?? parameterValue
            }
            mapParameters[name] = mapParameters[name].map { $0 + parameterValue } ?? parameterValue
        }
        return mapParameters
    }

    // MARK: - Bodies

    static func split(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var listParts: [Data] = []
        var searchStart = body.startIndex
        var partStart: Data.Index?
        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            if let partStart {
                var end = range.lowerBound
                while end > partStart, body[body.index(before: end)] == UInt8(ascii: "\n") || body[body.index(before: end)] == UInt8(ascii: "\r") {
                    end = body.index(before: end)
                }
                listParts.append(body.subdata(in: partStart..<end))
            }
            var next = range.upperBound
            if body[next...].starts(with: Data("--".utf8)) {
                break
            }
            while next < body.endIndex, body[next] == UInt8(ascii: "\r") || body[next] == UInt8(ascii: "\n") {
                next = body.index(after: next)
            }
            partStart = next
            searchStart = next
        }
        return listParts
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var output = Data()
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if byte == UInt8(ascii: "=") {
                var after = index + 1
                while after < data.endIndex, data[after] == UInt8(ascii: " ") || data[after] == UInt8(ascii: "\t") {
                    after += 1
                }
                if after == data.endIndex {
                    break
                }
                let next = data[after]
                if next == UInt8(ascii: "\r") || next == UInt8(ascii: "\n") {
                    index = after + (next == UInt8(ascii: "\r") && after + 1 < data.endIndex && data[after + 1] == UInt8(ascii: "\n") ? 2 : 1)
                    continue
                }
            }
            if byte == UInt8(ascii: "="), index + 1 < data.endIndex {
                if index + 2 < data.endIndex, let value = UInt8(String(decoding: data[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                    output.append(value)
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return output
    }

    static func string(_ data: Data, charset: String?) -> String {
        if let charset {
            let encoding = CFStringConvertIANACharSetNameToEncoding(charset.trimmingCharacters(in: .whitespaces) as CFString)
            if encoding != kCFStringEncodingInvalidId {
                let stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
                if let decoded = String(data: data, encoding: stringEncoding) {
                    return decoded
                }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// HTML as readable text: scripts and styles dropped, breaks and blocks as newlines, tags removed,
    /// common entities decoded, runs of blank lines folded.
    static func text(ofHTML html: String) -> String {
        var text = html
        for element in ["script", "style", "head"] {
            text = text.replacingOccurrences(of: "<\(element)[^>]*>[\\s\\S]*?</\(element)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<(br|/p|/div|/tr|/li|/h[1-6])[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
