// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

/// Queue-confined SQLite repository. Money is stored as integer cents.
final class AccountingRepository {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS categories(id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL CHECK(kind IN ('expense','income')),archived INTEGER NOT NULL DEFAULT 0)")
            try execute("CREATE TABLE IF NOT EXISTS entries(id TEXT PRIMARY KEY,amount INTEGER NOT NULL CHECK(amount>0 AND amount<=999999999999),category TEXT NOT NULL REFERENCES categories(id),date REAL NOT NULL,note TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS entries_date ON entries(date DESC)")
            try execute("CREATE INDEX IF NOT EXISTS entries_category ON entries(category)")
            if try rows("SELECT id FROM categories LIMIT 1").isEmpty {
                try execute("BEGIN IMMEDIATE")
                do {
                    for (kind, names) in [(LedgerKind.expense, ["餐饮", "交通", "购物", "居住", "娱乐", "医疗", "学习", "其他支出"]), (.income, ["工资", "奖金", "其他收入"])] {
                        for name in names { try saveCategory(id: UUID().uuidString, name: name, kind: kind) }
                    }
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError {
        NSError(domain: "Accounting", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    private func prepare(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient) == SQLITE_OK else { sqlite3_finalize(stmt); throw failure() }
        }
        return stmt
    }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let stmt = try prepare(sql, values); defer { sqlite3_finalize(stmt) }
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW { result = sqlite3_step(stmt) }
        guard result == SQLITE_DONE else { throw failure() }
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let stmt = try prepare(sql, values); defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append((0..<sqlite3_column_count(stmt)).map { sqlite3_column_text(stmt, $0).map { String(cString: $0) } ?? "" })
        }
    }
    private func typedRows(_ sql: String, _ values: [String] = [], map: (OpaquePointer) -> Any) throws -> [Any] {
        let stmt = try prepare(sql, values); defer { sqlite3_finalize(stmt) }
        var result: [Any] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            result.append(map(stmt))
        }
    }
    func snapshot(month: Date, limit: Int, kind: LedgerKind?, category: String) throws -> LedgerSnapshot {
        let range = Calendar.current.dateInterval(of: .month, for: month)!
        var predicate = "e.date>=? AND e.date<?"
        var values = [String(range.start.timeIntervalSince1970), String(range.end.timeIntervalSince1970)]
        if let kind { predicate += " AND c.kind=?"; values.append(kind.rawValue) }
        if !category.isEmpty { predicate += " AND c.id=?"; values.append(category) }
        let join = " FROM entries e JOIN categories c ON e.category=c.id WHERE " + predicate
        let categories = try rows("SELECT id,name,kind,archived FROM categories ORDER BY archived,name COLLATE NOCASE").map {
            LedgerCategory(id: $0[0], name: $0[1], kind: LedgerKind(rawValue: $0[2])!, archived: $0[3] == "1")
        }
        let entries = try typedRows("SELECT e.id,e.amount,c.id,c.name,c.kind,e.date,e.note" + join + " ORDER BY e.date DESC,e.id LIMIT ?", values + [String(limit)]) { stmt in
            LedgerEntry(id: String(cString: sqlite3_column_text(stmt, 0)), amount: sqlite3_column_int64(stmt, 1), categoryID: String(cString: sqlite3_column_text(stmt, 2)), categoryName: String(cString: sqlite3_column_text(stmt, 3)), kind: LedgerKind(rawValue: String(cString: sqlite3_column_text(stmt, 4)))!, date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)), note: String(cString: sqlite3_column_text(stmt, 6)))
        }.compactMap { $0 as? LedgerEntry }
        let totals = try typedRows("SELECT c.id,c.name,c.kind,SUM(e.amount)" + join + " GROUP BY c.id ORDER BY SUM(e.amount) DESC", values) { stmt in
            LedgerCategoryTotal(id: String(cString: sqlite3_column_text(stmt, 0)), name: String(cString: sqlite3_column_text(stmt, 1)), kind: LedgerKind(rawValue: String(cString: sqlite3_column_text(stmt, 2)))!, amount: sqlite3_column_int64(stmt, 3))
        }.compactMap { $0 as? LedgerCategoryTotal }
        let count = try rows("SELECT COUNT(*)" + join, values).first.flatMap { Int($0[0]) } ?? 0
        let daily = try typedRows("SELECT CAST(strftime('%d',e.date,'unixepoch','localtime') AS INTEGER),c.kind,SUM(e.amount)" + join + " GROUP BY 1,c.kind ORDER BY 1", values) { stmt in
            LedgerDailyTotal(day: Int(sqlite3_column_int64(stmt, 0)), kind: LedgerKind(rawValue: String(cString: sqlite3_column_text(stmt, 1)))!, amount: sqlite3_column_int64(stmt, 2))
        }.compactMap { $0 as? LedgerDailyTotal }
        return LedgerSnapshot(dailyTotals: daily, categories: categories, entries: entries, totals: totals, count: count)
    }
    func saveEntry(id: String, amount: Int64, category: String, date: Date, note: String) throws {
        guard amount > 0, amount <= 999_999_999_999, date.timeIntervalSince1970.isFinite else { throw validation("金额或日期无效") }
        guard let row = try rows("SELECT archived FROM categories WHERE id=?", [category]).first,
              try row[0] == "0" || !rows("SELECT id FROM entries WHERE id=? AND category=?", [id,category]).isEmpty else { throw validation("请选择有效分类") }
        try execute("INSERT INTO entries VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET amount=excluded.amount,category=excluded.category,date=excluded.date,note=excluded.note", [id,String(amount),category,String(date.timeIntervalSince1970),note.trimmingCharacters(in: .whitespacesAndNewlines)])
    }
    func deleteEntry(_ id: String) throws { try execute("DELETE FROM entries WHERE id=?", [id]) }
    func saveCategory(id: String, name: String, kind: LedgerKind) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw validation("分类名称需为 1–40 个字符") }
        guard try rows("SELECT id FROM categories WHERE kind=? AND name=? AND id<>?", [kind.rawValue,name,id]).isEmpty else { throw validation("该类型中已有同名分类") }
        // Renaming never changes historical income/expense semantics.
        try execute("INSERT INTO categories(id,name,kind) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name", [id,name,kind.rawValue])
    }
    func archiveCategory(_ id: String, archived: Bool) throws {
        try execute("UPDATE categories SET archived=? WHERE id=?", [archived ? "1" : "0", id])
    }
    private func validation(_ message: String) -> NSError { NSError(domain: "Accounting", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
