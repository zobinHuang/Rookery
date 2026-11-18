import Foundation
import RookeryCore

/// Searching Mail's library and reading its messages.
extension MailLibrary {
    private static let summaryColumns = """
        m.ROWID, mb.url, IFNULL(a.address, ''), IFNULL(a.comment, ''), IFNULL(m.subject_prefix, ''),
        IFNULL(s.subject, ''), m.date_sent, m.date_received, m.read, m.flagged, IFNULL(su.summary, ''),
        m.conversation_id, (SELECT COUNT(*) FROM attachments at WHERE at.message = m.ROWID),
        (SELECT GROUP_CONCAT(lm.url, char(31)) FROM labels l JOIN mailboxes lm ON lm.ROWID = l.mailbox_id
         WHERE l.message_id = m.ROWID)
        """
    /// The folders a message labelled with several shows as, the first that applies: Gmail keeps every
    /// message in All Mail and its inbox, starred and the rest as labels.
    private static let listFolderPrecedence: [MailFolder] = [.inbox, .drafts, .sent, .junk, .trash, .starred, .important]
    private static let summaryJoins = """
        FROM messages m
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN summaries su ON su.ROWID = m.summary
        """
    private static let recipientTo = "0"
    private static let recipientCc = "1"
    private static let threadLimit = 100
    private static let snippetLimit = 160

    /// The mailboxes, by their row, with their URLs.
    public func mailboxURLs() throws -> [String: String] {
        Dictionary(try rows("SELECT ROWID, url FROM mailboxes").compactMap { row -> (String, String)? in
            guard let rowId = row[0], let url = row[1] else {
                return nil
            }
            return (rowId, url)
        }) { first, _ in first }
    }

    /// The messages a query matches, newest first, in the accounts given.
    ///
    /// - Parameters:
    ///   - query: what to match
    ///   - mapAccountAddresses: the accounts that may be searched, their addresses by id
    /// - Throws: `MailLibraryError.sqlite`
    public func search(_ query: MailQuery, accounts mapAccountAddresses: [String: String]) throws -> [MailMessageSummary] {
        var listBindings: [String] = []
        guard let whereClause = try matching(query, accounts: mapAccountAddresses, bindings: &listBindings) else {
            return []
        }
        let limit = max(1, min(query.limit, MailQuery.maximumLimit))
        let sql = "SELECT \(Self.summaryColumns) \(Self.summaryJoins) WHERE \(whereClause) "
            + "ORDER BY m.date_received DESC LIMIT \(limit) OFFSET \(max(0, query.offset))"
        return try rows(sql, listBindings).compactMap { summary(of: $0, accounts: mapAccountAddresses) }
    }

    /// How many messages a query matches, however many.
    ///
    /// - Throws: `MailLibraryError.sqlite`
    public func count(_ query: MailQuery, accounts mapAccountAddresses: [String: String]) throws -> Int {
        var listBindings: [String] = []
        guard let whereClause = try matching(query, accounts: mapAccountAddresses, bindings: &listBindings) else {
            return 0
        }
        let sql = "SELECT COUNT(*) \(Self.summaryJoins) WHERE \(whereClause)"
        return try rows(sql, listBindings).first?.first.flatMap { $0 }.flatMap(Int.init) ?? 0
    }

    /// Each account's inbox as Mail counts it: its messages and the unread among them, by account id.
    public func inboxCounts() throws -> [String: MailboxCount] {
        var mapCounts: [String: MailboxCount] = [:]
        for row in try rows("SELECT url, total_count, unread_count FROM mailboxes") {
            guard let url = row[0], MailFolder.of(mailboxURL: url) == .inbox else {
                continue
            }
            let accountId = MailFolder.accountId(ofMailboxURL: url)
            let previous = mapCounts[accountId] ?? MailboxCount(total: 0, unread: 0)
            mapCounts[accountId] = MailboxCount(
                total: previous.total + (row[1].flatMap(Int.init) ?? 0),
                unread: previous.unread + (row[2].flatMap(Int.init) ?? 0)
            )
        }
        return mapCounts
    }

    /// The SQL condition a query comes to, its values added to the bindings; nil when no mailbox can match.
    private func matching(
        _ query: MailQuery,
        accounts mapAccountAddresses: [String: String],
        bindings listBindings: inout [String]
    ) throws -> String? {
        let mapMailboxes = try mailboxURLs()
        let setAccountIds = Set(mapAccountAddresses.keys).intersection(
            query.listAccounts.isEmpty
                ? Set(mapAccountAddresses.keys)
                : Set(query.listAccounts.flatMap { wanted in
                    mapAccountAddresses.filter { $0.key == wanted || $0.value.caseInsensitiveCompare(wanted) == .orderedSame }.map(\.key)
                })
        )
        let listMailboxIds = mapMailboxes.filter { rowId, url in
            let folder = MailFolder.of(mailboxURL: url)
            return setAccountIds.contains(MailFolder.accountId(ofMailboxURL: url))
                && (query.folder.map { $0 == folder } ?? !folder.isHiddenByDefault)
        }.map(\.key)
        guard !listMailboxIds.isEmpty else {
            return nil
        }
        let placeholders = Array(repeating: "?", count: listMailboxIds.count).joined(separator: ",")
        var listConditions = [
            "m.deleted = 0",
            "(m.mailbox IN (\(placeholders)) OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(placeholders))))",
        ]
        listBindings += listMailboxIds + listMailboxIds
        if query.folder == nil {
            let listHidden = mapMailboxes.filter { MailFolder.of(mailboxURL: $0.value).isHiddenByDefault }.map(\.key)
            if !listHidden.isEmpty {
                let hiddenPlaceholders = Array(repeating: "?", count: listHidden.count).joined(separator: ",")
                listConditions.append("m.mailbox NOT IN (\(hiddenPlaceholders))")
                listBindings += listHidden
            }
        }
        if !query.text.isEmpty {
            listConditions.append("(s.subject LIKE ? OR a.address LIKE ? OR a.comment LIKE ? OR su.summary LIKE ?)")
            listBindings += Array(repeating: "%\(query.text)%", count: 4)
        }
        if !query.from.isEmpty {
            listConditions.append("(a.address LIKE ? OR a.comment LIKE ?)")
            listBindings += Array(repeating: "%\(query.from)%", count: 2)
        }
        if !query.to.isEmpty {
            listConditions.append("""
                EXISTS (SELECT 1 FROM recipients r JOIN addresses ra ON ra.ROWID = r.address
                        WHERE r.message = m.ROWID AND (ra.address LIKE ? OR ra.comment LIKE ?))
                """)
            listBindings += Array(repeating: "%\(query.to)%", count: 2)
        }
        if query.isUnreadOnly {
            listConditions.append("m.read = 0")
        }
        if query.isReadOnly {
            listConditions.append("m.read = 1")
        }
        if query.isFlaggedOnly {
            listConditions.append("m.flagged = 1")
        }
        if let after = query.after {
            listConditions.append("m.date_received >= ?")
            listBindings.append(String(Int(after.timeIntervalSince1970)))
        }
        if let before = query.before {
            listConditions.append("m.date_received < ?")
            listBindings.append(String(Int(before.timeIntervalSince1970)))
        }
        return listConditions.joined(separator: " AND ")
    }

    /// One message, read whole from its file.
    ///
    /// - Parameters:
    ///   - messageId: its row in the library
    ///   - mapAccountAddresses: the accounts that may be read, their addresses by id
    /// - Returns: the message, or nil when there is no such message in those accounts
    /// - Throws: `MailLibraryError.sqlite`
    public func message(_ messageId: Int, accounts mapAccountAddresses: [String: String]) throws -> MailMessageDetail? {
        let sql = "SELECT \(Self.summaryColumns) \(Self.summaryJoins) WHERE m.ROWID = ?"
        guard
            let row = try rows(sql, [String(messageId)]).first,
            let summary = summary(of: row, accounts: mapAccountAddresses),
            let mailboxURL = row[1]
        else {
            return nil
        }
        let listRecipients = try rows(
            """
            SELECT r.type, IFNULL(ra.address, ''), IFNULL(ra.comment, '') FROM recipients r
            JOIN addresses ra ON ra.ROWID = r.address WHERE r.message = ? ORDER BY r.type, r.position
            """,
            [String(messageId)]
        )
        let file = messageFile(messageId, mailboxURL: mailboxURL)
        let mime = file.flatMap { try? Data(contentsOf: $0) }.map(MimeMessage.init(emlx:))
        return MailMessageDetail(
            summary: summary,
            listTo: listRecipients.filter { $0[0] == Self.recipientTo }.map { MailAddress(address: $0[1] ?? "", name: $0[2] ?? "") },
            listCc: listRecipients.filter { $0[0] == Self.recipientCc }.map { MailAddress(address: $0[1] ?? "", name: $0[2] ?? "") },
            text: mime?.text ?? "",
            listAttachments: mime?.listAttachmentNames ?? [],
            isPartial: file == nil || file?.lastPathComponent.hasSuffix(".partial.emlx") == true,
            messageIdHeader: (mime?.header("message-id") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> ")),
            html: mime.map { message in
                MimeMessage.embedding(inlineImages(of: message, messageId: messageId, file: file), in: message.html ?? "")
            } ?? "",
            mailboxURL: mailboxURL
        )
    }

    /// A message's inline images, those whose bytes the message file leaves out read from where Mail keeps
    /// a message's parts: `Attachments/<id>/<part>/<name>`, beside its `Messages`.
    private func inlineImages(of message: MimeMessage, messageId: Int, file: URL?) -> [MailInlineImage] {
        guard
            let file,
            message.listInlineImages.contains(where: { $0.data == nil })
        else {
            return message.listInlineImages
        }
        let attachments = file.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Attachments", directoryHint: .isDirectory)
            .appending(path: String(messageId), directoryHint: .isDirectory)
        let listFiles = (FileManager.default.enumerator(at: attachments, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        return message.listInlineImages.map { image in
            guard
                image.data == nil,
                let fileName = image.fileName,
                let found = listFiles.first(where: { $0.lastPathComponent == fileName }),
                let data = try? Data(contentsOf: found)
            else {
                return image
            }
            return MailInlineImage(contentId: image.contentId, mediaType: image.mediaType, fileName: fileName, data: data)
        }
    }

    /// The messages of one conversation, oldest first.
    public func thread(_ conversationId: Int, accounts mapAccountAddresses: [String: String]) throws -> [MailMessageSummary] {
        let sql = "SELECT \(Self.summaryColumns) \(Self.summaryJoins) WHERE m.deleted = 0 AND m.conversation_id = ? "
            + "ORDER BY m.date_received LIMIT \(Self.threadLimit)"
        return try rows(sql, [String(conversationId)]).compactMap { summary(of: $0, accounts: mapAccountAddresses) }
    }

    /// Where a message's file is: `<account>/<folder>.mbox/.../<store>/Data/<digits>/Messages/<id>.emlx`,
    /// the digits being those of its id over a thousand, last first; a message Mail holds only in part is
    /// a `.partial.emlx`.
    public func messageFile(_ messageId: Int, mailboxURL: String) -> URL? {
        var mailbox = root.appending(path: MailFolder.accountId(ofMailboxURL: mailboxURL), directoryHint: .isDirectory)
        for component in MailFolder.path(ofMailboxURL: mailboxURL) {
            mailbox.append(path: component + ".mbox", directoryHint: .isDirectory)
        }
        var data = URL(filePath: "Data", directoryHint: .isDirectory)
        let thousands = messageId / 1000
        if thousands > 0 {
            data = String(thousands).reversed().reduce(data) { $0.appending(path: String($1), directoryHint: .isDirectory) }
        }
        let listStores = (try? FileManager.default.contentsOfDirectory(atPath: mailbox.path))?.filter { !$0.hasSuffix(".mbox") } ?? []
        for store in listStores {
            let messages = mailbox.appending(path: store).appending(path: data.relativePath).appending(path: "Messages")
            for name in ["\(messageId).emlx", "\(messageId).partial.emlx"] {
                let file = messages.appending(path: name)
                if FileManager.default.fileExists(atPath: file.path) {
                    return file
                }
            }
        }
        return nil
    }

    private static func folder(mailboxURL: String, labelURLs: String) -> MailFolder {
        let setFolders = Set(([mailboxURL] + labelURLs.split(separator: "\u{1F}").map(String.init)).map(MailFolder.of(mailboxURL:)))
        return listFolderPrecedence.first(where: setFolders.contains) ?? MailFolder.of(mailboxURL: mailboxURL)
    }

    private func summary(of row: [String?], accounts mapAccountAddresses: [String: String]) -> MailMessageSummary? {
        guard
            row.count >= 14,
            let rowId = row[0].flatMap(Int.init),
            let url = row[1],
            let account = mapAccountAddresses[MailFolder.accountId(ofMailboxURL: url)]
        else {
            return nil
        }
        return MailMessageSummary(
            id: rowId,
            account: account,
            folder: Self.folder(mailboxURL: url, labelURLs: row[13] ?? ""),
            from: MailAddress(address: row[2] ?? "", name: row[3] ?? ""),
            subject: (row[4] ?? "") + (row[5] ?? ""),
            sentAt: Date(timeIntervalSince1970: Double(row[6] ?? "") ?? 0),
            receivedAt: Date(timeIntervalSince1970: Double(row[7] ?? "") ?? 0),
            isRead: row[8] == "1",
            isFlagged: row[9] == "1",
            snippet: String((row[10] ?? "").prefix(Self.snippetLimit)),
            conversationId: row[11].flatMap(Int.init) ?? 0,
            attachmentCount: row[12].flatMap(Int.init) ?? 0
        )
    }
}
