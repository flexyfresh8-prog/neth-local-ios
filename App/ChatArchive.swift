import Foundation
import SQLite3

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    var id: Int64 = -1
    let role: Role
    var text: String
    var photo: URL? = nil
    var evidence: WebEvidence? = nil
    var notice: String? = nil
}

struct Conversation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

struct TranscriptMatch: Identifiable, Equatable, Sendable {
    let id: Int64
    let conversationID: String
    let title: String
    let role: ChatMessage.Role
    let excerpt: String
}

actor ChatArchive {
    private enum Binding {
        case text(String)
        case integer(Int64)
        case real(Double)
        case null
    }

    private let directory: URL
    private let photos: URL
    private var connection: OpaquePointer?
    private var hasFTS = true

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Chats", directoryHint: .isDirectory)) {
        self.directory = directory
        photos = directory.appending(path: "Photos", directoryHint: .isDirectory)
    }

    deinit { if let connection { sqlite3_close(connection) } }

    func conversations() throws -> [Conversation] {
        try rows("SELECT id, title FROM conversations ORDER BY updated_at DESC LIMIT 160") { row in
            Conversation(id: text(row, 0), title: text(row, 1))
        }
    }

    func page(in id: String, before: Int64? = nil, limit: Int) throws -> [ChatMessage] {
        let data = try rows("""
            SELECT id, role, body, photo, evidence, notice
            FROM messages WHERE conversation_id = ? AND id < ?
            ORDER BY id DESC LIMIT ?
            """, [.text(id), .integer(before ?? .max), .integer(Int64(limit))]) { row in
            let evidence = optionalText(row, 4).flatMap { try? JSONDecoder().decode(WebEvidence.self, from: Data($0.utf8)) }
            return ChatMessage(id: sqlite3_column_int64(row, 0),
                               role: ChatMessage.Role(rawValue: text(row, 1)) ?? .assistant,
                               text: text(row, 2),
                               photo: optionalText(row, 3).map { photos.appending(path: $0) },
                               evidence: evidence, notice: optionalText(row, 5))
        }
        return data.reversed()
    }

    func hasNewer(in id: String, than message: Int64) throws -> Bool {
        try !rows("SELECT 1 FROM messages WHERE conversation_id = ? AND id > ? LIMIT 1",
                  [.text(id), .integer(message)]) { _ in true }.isEmpty
    }

    func append(_ message: ChatMessage, to id: String) throws -> ChatMessage {
        let db = try database()
        var saved = message
        var attachment: URL?
        if let image = message.photo {
            let destination = photos.appending(path: "\(UUID().uuidString).jpg")
            try FileManager.default.copyItem(at: image, to: destination)
            attachment = destination
            saved.photo = destination
        }
        do {
            let evidence: Binding = try message.evidence.map {
                .text(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))
            } ?? .null
            try execute("BEGIN IMMEDIATE", db: db)
            let timestamp = Date().timeIntervalSince1970
            let title = message.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            try write("INSERT OR IGNORE INTO conversations (id, title, updated_at) VALUES (?, ?, ?)",
                      [.text(id), .text(title.isEmpty ? "New chat" : String(title.prefix(60))), .real(timestamp)])
            try write("""
                INSERT INTO messages (conversation_id, role, body, photo, evidence, notice)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [.text(id), .text(message.role.rawValue), .text(message.text),
                      attachment.map { .text($0.lastPathComponent) } ?? .null,
                      evidence, message.notice.map { .text($0) } ?? .null])
            saved.id = sqlite3_last_insert_rowid(db)
            try write("UPDATE conversations SET updated_at = ? WHERE id = ?", [.real(timestamp), .text(id)])
            try execute("COMMIT", db: db)
            return saved
        } catch {
            try? execute("ROLLBACK", db: db)
            if let attachment { try? FileManager.default.removeItem(at: attachment) }
            throw error
        }
    }

    func delete(_ id: String) throws {
        let attachments = try rows("SELECT photo FROM messages WHERE conversation_id = ? AND photo IS NOT NULL",
                                   [.text(id)]) { photos.appending(path: text($0, 0)) }
        try write("DELETE FROM conversations WHERE id = ?", [.text(id)])
        for attachment in attachments { try? FileManager.default.removeItem(at: attachment) }
    }

    func search(_ query: String) throws -> [TranscriptMatch] {
        let words = Self.words(query)
        guard !words.isEmpty else { return [] }
        return try matches(words, conversation: nil, before: nil, limit: 48)
    }

    func recall(_ query: String, in id: String, before: Int64) throws -> [TranscriptMatch] {
        let filler: Set<String> = ["what", "when", "where", "which", "tell", "this", "that", "about",
                                   "were", "with", "have", "from", "would", "could", "should",
                                   "just", "here", "there", "again", "please", "remember"]
        let terms = Self.words(query).filter { $0.count >= 3 && !filler.contains($0.lowercased()) }
        guard !terms.isEmpty, before > 1 else { return [] }
        return try matches(terms, conversation: id, before: before, limit: 3)
    }

    private static func words(_ text: String) -> [String] {
        text.prefix(520).split { !$0.isLetter && !$0.isNumber }.prefix(12).map(String.init)
    }

    private func matches(_ words: [String], conversation: String?, before: Int64?,
                         limit: Int64) throws -> [TranscriptMatch] {
        _ = try database()
        let scoped = conversation != nil
        let glue = scoped ? " OR " : " AND "
        let filter = scoped ? " AND m.conversation_id = ? AND m.id < ?" : ""
        let bound: [Binding] = scoped ? [.text(conversation ?? ""), .integer(before ?? .max)] : []
        let sql: String
        let criteria: [Binding]
        if hasFTS {
            sql = """
                SELECT m.id, m.conversation_id, c.title, m.role,
                       snippet(messages_fts, 0, '', '', ' … ', 24)
                FROM messages_fts
                JOIN messages m ON m.id = messages_fts.rowid
                JOIN conversations c ON c.id = m.conversation_id
                WHERE messages_fts MATCH ?\(filter)
                ORDER BY bm25(messages_fts), m.id DESC LIMIT ?
                """
            criteria = [.text(words.map { "\"\($0)\"*" }.joined(separator: glue))]
        } else {
            let conditions = words.map { _ in "m.body LIKE ?" }.joined(separator: glue)
            sql = """
                SELECT m.id, m.conversation_id, c.title, m.role, substr(m.body, 1, 320)
                FROM messages m JOIN conversations c ON c.id = m.conversation_id
                WHERE (\(conditions))\(filter) ORDER BY m.id DESC LIMIT ?
                """
            criteria = words.map { .text("%\($0)%") }
        }
        return try rows(sql, criteria + bound + [.integer(limit)]) { row in
            TranscriptMatch(id: sqlite3_column_int64(row, 0), conversationID: text(row, 1),
                            title: text(row, 2), role: ChatMessage.Role(rawValue: text(row, 3)) ?? .assistant,
                            excerpt: text(row, 4))
        }
    }

    private func database() throws -> OpaquePointer {
        if let connection { return connection }
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let path = directory.appending(path: "transcripts.sqlite").path
        let opened = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard opened == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw LocalError(message: "Couldn't open chat history on this iPad.")
        }
        do {
            sqlite3_busy_timeout(handle, 1500)
            try execute("""
                PRAGMA foreign_keys = ON;
                PRAGMA journal_mode = WAL;
                CREATE TABLE IF NOT EXISTS conversations (
                    id TEXT PRIMARY KEY, title TEXT NOT NULL, updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    role TEXT NOT NULL, body TEXT NOT NULL, photo TEXT, evidence TEXT, notice TEXT
                );
                CREATE INDEX IF NOT EXISTS messages_by_conversation ON messages(conversation_id, id);
                """, db: handle)
            do {
                try execute("""
                    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
                    USING fts5(body, content='messages', content_rowid='id');
                    CREATE TRIGGER IF NOT EXISTS index_message AFTER INSERT ON messages BEGIN
                        INSERT INTO messages_fts(rowid, body) VALUES (new.id, new.body);
                    END;
                    CREATE TRIGGER IF NOT EXISTS unindex_message AFTER DELETE ON messages BEGIN
                        INSERT INTO messages_fts(messages_fts, rowid, body) VALUES ('delete', old.id, old.body);
                    END;
                    """, db: handle)
            } catch let error as LocalError where error.message.contains("no such module: fts5") {
                hasFTS = false
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
        connection = handle
        return handle
    }

    private func execute(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError(db) }
    }

    private func write(_ sql: String, _ values: [Binding]) throws {
        let db = try database()
        let statement = try prepare(sql, values, db: db)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
    }

    private func rows<T>(_ sql: String, _ values: [Binding] = [], transform: (OpaquePointer) -> T) throws -> [T] {
        let db = try database()
        let statement = try prepare(sql, values, db: db)
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        var state = sqlite3_step(statement)
        while state == SQLITE_ROW {
            result.append(transform(statement))
            state = sqlite3_step(statement)
        }
        guard state == SQLITE_DONE else { throw databaseError(db) }
        return result
    }

    private func prepare(_ sql: String, _ values: [Binding], db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(db)
        }
        let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            let status: Int32
            switch value {
            case .text(let value):
                status = value.withCString { sqlite3_bind_text(statement, slot, $0, Int32(value.utf8.count), copy) }
            case .integer(let value): status = sqlite3_bind_int64(statement, slot, value)
            case .real(let value): status = sqlite3_bind_double(statement, slot, value)
            case .null: status = sqlite3_bind_null(statement, slot)
            }
            if status != SQLITE_OK {
                sqlite3_finalize(statement)
                throw databaseError(db)
            }
        }
        return statement
    }

    private func databaseError(_ db: OpaquePointer) -> LocalError {
        LocalError(message: "Chat history: \(String(cString: sqlite3_errmsg(db))).")
    }

    private func optionalText(_ row: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(row, index) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(row, index))), as: UTF8.self)
    }

    private func text(_ row: OpaquePointer, _ index: Int32) -> String { optionalText(row, index) ?? "" }
}
