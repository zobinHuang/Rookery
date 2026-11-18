import Foundation

/// The earlier mail a reply carries below its own text: where it starts, so a conversation shows each
/// message's own words once, in its own card, and the quoted history only when asked.
public enum MailQuote {
    /// The lines that open a quoted message in plain text, as mail clients write them.
    private static let listAttributionPatterns = [
        #"^\s*On .{3,300}wrote:\s*$"#,
        #"^.{3,300}写道[:：]\s*$"#,
        #"^\s*Le .{3,300}a écrit\s*:\s*$"#,
        #"^\s*Am .{3,300}schrieb.{0,120}:\s*$"#,
        #"^\s*-{2,}\s*(Original Message|Forwarded message|原始邮件|转发邮件)\s*-{2,}"#,
        #"^\s*_{10,}\s*$"#,
    ]
    /// A header block of a quoted message, as Outlook writes it: `From:` and, within a few lines, `Sent:`.
    private static let headerStartPattern = #"^\s*\*?(From|发件人)\s*[:：]"#
    private static let headerFollowPattern = #"^\s*\*?(Sent|Date|发送时间|时间)\s*[:：]"#
    private static let headerReach = 4
    private static let quotedLinePrefix = ">"
    /// How many lines an attribution may be wrapped over, found from the line it ends on.
    private static let attributionLineReach = 3

    /// A reply as it is sent: the reply's own text, then a line naming who wrote what it answers and when,
    /// then that message whole, each line marked as quoted, its own quotes one level deeper, so the one
    /// it goes to reads it in its thread as any mail client writes it.
    ///
    /// - Parameters:
    ///   - body: what the reply says
    ///   - original: the text of the message answered
    ///   - sender: who wrote that message
    ///   - sentAt: when it was sent
    ///   - timeZone: the zone its time is written in
    /// - Returns: the text to send
    public static func reply(to original: String, from sender: MailAddress, sentAt: Date, body: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        let who = sender.name.isEmpty ? sender.address : "\(sender.name) <\(sender.address)>"
        let quoted = original
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { line in line.hasPrefix(quotedLinePrefix) ? quotedLinePrefix + line : quotedLinePrefix + " " + line }
            .joined(separator: "\n")
        let own = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(own)\n\nOn \(formatter.string(from: sentAt)), \(who) wrote:\n\n\(quoted)\n"
    }

    /// A plain-text message without the earlier mail it quotes: cut at the first line that opens a
    /// quote, or at a run of `>` lines that runs to the end.
    ///
    /// - Parameter text: the message's text
    /// - Returns: the text before the quote, trimmed; nil when it quotes nothing or nothing would be left
    public static func trimmed(_ text: String) -> String? {
        let listLines = text.components(separatedBy: .newlines)
        guard let cutIndex = quoteStart(in: listLines) else {
            return nil
        }
        let kept = listLines[..<cutIndex].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? nil : kept
    }

    private static func quoteStart(in listLines: [String]) -> Int? {
        for (index, line) in listLines.enumerated() {
            for reach in 1...attributionLineReach where index - reach + 1 >= 0 {
                let startIndex = index - reach + 1
                let joined = listLines[startIndex...index].joined(separator: " ")
                if listAttributionPatterns.contains(where: { joined.range(of: $0, options: .regularExpression) != nil }) {
                    return startIndex
                }
            }
            if
                line.range(of: headerStartPattern, options: .regularExpression) != nil,
                listLines[(index + 1)..<min(listLines.count, index + 1 + headerReach)].contains(where: {
                    $0.range(of: headerFollowPattern, options: .regularExpression) != nil
                })
            {
                return index
            }
            if
                line.hasPrefix(quotedLinePrefix),
                listLines[index...].allSatisfy({ $0.hasPrefix(quotedLinePrefix) || $0.trimmingCharacters(in: .whitespaces).isEmpty })
            {
                return index
            }
        }
        return nil
    }

    /// A script, run in a message's page by Rookery rather than by the message, that takes away the
    /// quoted earlier mail: the first element that opens a quote, as clients mark it or by its words, and
    /// everything after it. It leaves the page as it was when nothing of the message's own would remain,
    /// as in a forward, and returns whether it took anything away.
    public static let trimScript = #"""
    const selectors = [
        ".gmail_quote", ".gmail_quote_container", "blockquote[type=cite]", ".yahoo_quoted",
        ".moz-cite-prefix", "#divRplyFwdMsg", "#appendonsend", "hr#stopSpelling",
        "div[style*='border-top:solid #E1E1E1']", "div[style*='border-top: solid #E1E1E1']",
        "div[style*='border-top:solid #B5C4DF']", "div[style*='border-top: solid rgb(225, 225, 225)']",
        ".OutlookMessageHeader", "#mail-editor-reference-message-container", ".protonmail_quote",
        "#isReplyContent", "#isForwardContent", ".ntes-mailmaster-quote", "#ntes-pcmail-quote",
        ".sh-quoted-content", ".spark_quote", ".x_gmail_quote", "#x_divRplyFwdMsg"
    ];
    const patterns = [
        /^\s*On [\s\S]{3,300}wrote:\s*$/,
        /^[\s\S]{3,300}写道[:：]\s*$/,
        /^\s*Le [\s\S]{3,300}a écrit\s*:\s*$/,
        /^\s*Am [\s\S]{3,300}schrieb[\s\S]{0,120}:\s*$/,
        /^\s*-{2,}\s*(Original Message|Forwarded message|原始邮件|转发邮件)\s*-{2,}/i,
        /^\s*(From|发件人)\s*[:：][\s\S]{0,400}(Sent|Date|发送时间|时间)\s*[:：]/
    ];
    const blockTags = /^(DIV|P|BLOCKQUOTE|TABLE|TBODY|TR|TD|UL|OL|LI|HR|BR|H[1-6]|PRE|SECTION|ARTICLE|HEADER|FOOTER)$/;
    const body = document.body;
    if (!body) { return false; }
    const isBreak = node => node && node.nodeType === Node.ELEMENT_NODE && blockTags.test(node.tagName);
    const candidates = [];
    for (const selector of selectors) {
        const found = body.querySelector(selector);
        if (found) { candidates.push(found); }
    }
    const elementWalker = document.createTreeWalker(body, NodeFilter.SHOW_ELEMENT);
    while (elementWalker.nextNode()) {
        const element = elementWalker.currentNode;
        if (!/^(P|DIV|SPAN|FONT|B|TD)$/.test(element.tagName)) { continue; }
        if (element.querySelector("p, div, table, blockquote")) { continue; }
        const text = (element.innerText || "").trim();
        if (text.length > 500) { continue; }
        if (patterns.some(pattern => pattern.test(text))) { candidates.push(element); break; }
    }
    const textWalker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
    while (textWalker.nextNode()) {
        const start = textWalker.currentNode;
        if (!/\S/.test(start.textContent)) { continue; }
        let previous = start.previousSibling;
        while (previous && previous.nodeType === Node.TEXT_NODE && !/\S/.test(previous.textContent)) { previous = previous.previousSibling; }
        if (previous && !isBreak(previous)) { continue; }
        let line = "";
        let breaks = 0;
        for (let node = start; node && line.length < 500; node = node.nextSibling) {
            if (isBreak(node)) {
                if (node.tagName !== "BR" || ++breaks > 2) { break; }
                line += " ";
                continue;
            }
            line += node.textContent;
            if (patterns.some(pattern => pattern.test(line.replace(/\s+/g, " ")))) {
                candidates.push(start);
                break;
            }
        }
    }
    if (candidates.length === 0) { return false; }
    candidates.sort((a, b) => a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);
    const marker = candidates[0];
    const range = document.createRange();
    range.setStart(body, 0);
    range.setEndBefore(marker);
    if (range.toString().trim().length === 0 && !range.cloneContents().querySelector("img")) { return false; }
    let node = marker;
    while (node && node !== body) {
        while (node.nextSibling) { node.nextSibling.remove(); }
        node = node.parentNode;
    }
    marker.remove();
    return true;
    """#
}
