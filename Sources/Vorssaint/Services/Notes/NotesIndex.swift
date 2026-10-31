// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

final class NotesIndex {
    private static let wikiLinkRegex = try! NSRegularExpression(
        pattern: #"\[\[([^|\]\n]*)\|([0-9a-fA-F-]{36})(?:#([^|\]]+))?\]\]"#
    )
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        sqlite3_busy_timeout(db, 3000)
        do {
            try execute("PRAGMA cache_size=-8192")
            try execute("PRAGMA temp_store=MEMORY")
            if readOnly {
                try execute("PRAGMA query_only=ON")
                return
            }
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS file_state(id TEXT PRIMARY KEY, signature TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS notes(id TEXT PRIMARY KEY, metadata TEXT NOT NULL, summary TEXT NOT NULL, updated REAL NOT NULL)")
            let schemaVersion = Int(try rows("PRAGMA user_version").first?.first ?? "0") ?? 0
            if schemaVersion < 1 {
                // Development schema: discard the old relationship table once.
                try execute("DROP TABLE IF EXISTS links")
                try execute("CREATE TABLE links(source TEXT NOT NULL,target TEXT NOT NULL, label TEXT NOT NULL, heading TEXT NOT NULL, PRIMARY KEY(source,target,label,heading))")
                try execute("PRAGMA user_version=1")
            } else {
                try execute("CREATE TABLE IF NOT EXISTS links(source TEXT NOT NULL,target TEXT NOT NULL, label TEXT NOT NULL, heading TEXT NOT NULL, PRIMARY KEY(source,target,label,heading))")
            }
            try execute("CREATE INDEX IF NOT EXISTS links_target ON links(target)")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED,title,body,tags,tokenize='trigram')")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError {
        NSError(domain: "NotesIndex", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
        }
    }
    private func prepare(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        for (index,value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement,column).map { String(cString:$0) } ?? ""
            })
        }
    }
    func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func clear() throws {
        for table in ["notes","links","search","file_state"] { try execute("DELETE FROM \(table)") }
    }
    func optimizeSearch() throws {
        try execute("INSERT INTO search(search) VALUES('optimize')")
    }
    func remove(_ id: UUID) throws {
        let key = id.uuidString.lowercased()
        try execute("DELETE FROM file_state WHERE id=?",[key])
        try execute("DELETE FROM notes WHERE id=?",[key])
        try execute("DELETE FROM search WHERE id=?",[key])
        try execute("DELETE FROM links WHERE source=?",[key])
    }
    func update(_ note: NoteDocument) throws {
        try remove(note.id)
        let key = note.id.uuidString.lowercased()
        var metadata = note; metadata.body = ""
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        let summary = note.type == "markdown" ? String(note.body.prefix(160)) : ""
        try execute("INSERT INTO notes VALUES(?,?,?,?)",[key,String(decoding:data,as:UTF8.self),summary,String(note.updatedAt.timeIntervalSince1970)])
        var searchable = note.body
        if note.type == "excalidraw" {
            let scene = try JSONSerialization.jsonObject(with: Data(note.body.utf8)) as? [String:Any]
            searchable = (scene?["elements"] as? [[String:Any]] ?? []).filter { $0["isDeleted"] as? Bool != true }.compactMap { $0["text"] as? String }.joined(separator:"\n")
        }
        try execute("INSERT INTO search VALUES(?,?,?,?)",[key,note.title,searchable,note.tags.joined(separator:" ")])
        if note.type == "markdown" {
            let text = note.body as NSString
            for match in Self.wikiLinkRegex.matches(in:note.body,range:NSRange(location:0,length:text.length)) {
                guard let target = UUID(uuidString:text.substring(with:match.range(at:2))) else { continue }
                let heading = match.range(at:3).location == NSNotFound ? "" : text.substring(with:match.range(at:3))
                try execute("INSERT OR IGNORE INTO links VALUES(?,?,?,?)",[key,target.uuidString.lowercased(),text.substring(with:match.range(at:1)),heading])
            }
        }
    }
    func catalog() throws -> [NoteDocument] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try rows("SELECT metadata,summary FROM notes ORDER BY updated DESC,id").map { row in
            var note = try decoder.decode(NoteDocument.self,from:Data(row[0].utf8)); note.body = row[1]; return note
        }
    }
    func outgoing(_ id: UUID) throws -> [String] {
        try rows("SELECT target FROM links WHERE source=?", [id.uuidString.lowercased()]).map { $0[0] }
    }
    func relationships() throws -> [String:[String]] {
        var result: [String:[String]] = [:]
        for row in try rows("SELECT source,target FROM links") { result[row[0],default:[]].append(row[1]) }
        return result
    }
    func signatures() throws -> [String:String] {
        Dictionary(uniqueKeysWithValues: try rows("SELECT id,signature FROM file_state").map { ($0[0],$0[1]) })
    }
    func recordSignature(_ signature:String, id:UUID) throws {
        try execute("INSERT OR REPLACE INTO file_state VALUES(?,?)",[id.uuidString.lowercased(),signature])
    }
    func search(_ query: String) throws -> [String] {
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !term.isEmpty else { return try rows("SELECT id FROM notes ORDER BY updated DESC").map { $0[0] } }
        // Trigram LIKE accelerates substring searches (including Chinese); one/two
        // character terms correctly fall back to a scan of the index, not files.
        if term.count >= 3 {
            let phrase = "\"" + term.replacingOccurrences(of:"\"",with:"\"\"") + "\""
            return try rows("SELECT id FROM search WHERE search MATCH ?",[phrase]).map { $0[0] }
        }
        let escaped = term.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"%",with:"\\%").replacingOccurrences(of:"_",with:"\\_")
        return try rows("SELECT id FROM search WHERE title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' OR tags LIKE ? ESCAPE '\\'",Array(repeating:"%"+escaped+"%",count:3)).map { $0[0] }
    }
}
