// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation
import CryptoKit

/// Access from one serial queue. JSON is authoritative; no local database is required.
final class StockRepository {
    let root: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e
    }()
    private let decoder = JSONDecoder()
    private let folders = ["trades", "reviews", "market"]
    init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    private func failure(_ message: String) -> StockError { StockError(message) }
    private func coordinated<T>(_ action: () throws -> T) throws -> T {
        var error: NSError?, result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: root, options: .forMerging, error: &error) { _ in result = Result { try action() } }
        if let error { throw error }; guard let result else { throw failure("数据目录暂不可用") }; return try result.get()
    }
    static func requireDownloaded(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw StockError("数据文件不能是符号链接：\(url.lastPathComponent)") }
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw StockError("iCloud 正在下载 \(url.lastPathComponent)，请稍后刷新")
        }
        if !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty {
            throw StockError("\(url.lastPathComponent) 存在 iCloud 冲突，所有版本已保留，请先处理冲突再保存")
        }
    }
    private func safeURL(_ path: String) throws -> URL {
        guard path == "rules.json" || path.range(of: #"^(trades|reviews|market)/[0-9]{4}\.json$"#, options: .regularExpression) != nil else { throw failure("无效的数据文件路径") }
        let url = root.appendingPathComponent(path)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw failure("数据路径超出存储目录") }; return url
    }
    private func files() throws -> [String: Data] {
        var output: [String: Data] = [:]
        for name in folders + ["rules.json", ".transaction.json"] {
            if fm.fileExists(atPath: root.appendingPathComponent("." + name + ".icloud").path) { throw failure("iCloud 中的 \(name) 尚未下载，请稍后重试") }
        }
        for folder in folders {
            let dir = root.appendingPathComponent(folder)
            if !fm.fileExists(atPath: dir.path) { continue }
            try Self.requireDownloaded(dir)
            for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                if file.pathExtension == "icloud" { throw failure("iCloud 中有未下载的年度文件，请在 Finder 中选择“立即下载”后刷新") }
                guard file.pathExtension == "json" else { continue }
                let path = folder + "/" + file.lastPathComponent
                _ = try safeURL(path); try Self.requireDownloaded(file); output[path] = try Data(contentsOf: file)
            }
        }
        for name in ["rules.json"] {
            let file = root.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) { try Self.requireDownloaded(file); output[name] = try Data(contentsOf: file) }
        }
        return output
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func revision(_ files: [String: Data]) -> String {
        Self.digest(Data(files.keys.sorted().map { $0 + ":" + Self.digest(files[$0]!) }.joined(separator: "\n").utf8))
    }
    private func decode(_ files: [String: Data]) throws -> StockDataset {
        var data = StockDataset()
        for (path, bytes) in files.sorted(by: { $0.key < $1.key }) {
            if path == "rules.json" {
                data.rules = try decoder.decode(StockRuleBook.self, from: bytes)
                continue
            }
            let year = Int(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)!
            func read<T: Codable>(_ type: T.Type) throws -> [T] {
                let f = try decoder.decode(StockYear<T>.self, from: bytes)
                guard (f.schemaVersion == 1 || (path.hasPrefix("reviews/") && f.schemaVersion == 2)), f.year == year else { throw failure("\(path) 版本或年份不匹配，原文件已保留") }; return f.entries
            }
            if path.hasPrefix("trades/") {
                let rows = try read(StockTrade.self)
                for row in rows { try row.validate(); guard try StockDay.year(row.date) == year else { throw failure("成交年份与文件不符") } }
                data.trades += rows
            } else if path.hasPrefix("reviews/") {
                let rows = try read(StockReview.self)
                for row in rows {
                    guard try StockDay.year(row.date) == year else { throw failure("复盘年份与文件不符") }
                }
                data.reviews += rows.filter(\.hasUserContent)
            } else {
                let rows = try read(StockMarketSnapshot.self)
                for row in rows { guard try StockDay.year(row.date) == year else { throw failure("市场快照年份不符") } }; data.snapshots += rows
            }
        }
        guard Set(data.trades.map(\.id)).count == data.trades.count,
              Set(data.reviews.map(\.id)).count == data.reviews.count,
              Set(data.snapshots.map(\.id)).count == data.snapshots.count else { throw failure("文件内有重复 ID，停止写入以保留原始记录") }
        let executions = data.trades.filter { $0.deletedAt == nil && !$0.brokerID.isEmpty }.map { $0.date + "|" + $0.instrument.id + "|" + $0.brokerID }
        guard Set(executions).count == executions.count else { throw failure("同一交易日、证券和券商成交编号重复，请核对交割单") }
        _ = try StockLedger.calculate(data.trades)
        data.revision = revision(files); return data
    }
    func load() throws -> StockDataset { try coordinated { try recover(); return try decode(files()) } }

    private struct Write: Codable { var path: String; var before: String?; var data: Data }
    private struct Transaction: Codable { var version = 1; var writes: [Write] }
    private var journal: URL { root.appendingPathComponent(".transaction.json") }
    /// Recover interrupted cross-year writes before allowing any read or edit.
    private func recover() throws {
        guard fm.fileExists(atPath: journal.path) else { return }
        try Self.requireDownloaded(journal)
        let transaction = try decoder.decode(Transaction.self, from: Data(contentsOf: journal))
        guard transaction.version == 1 else { throw failure("不支持的写入恢复版本") }
        for item in transaction.writes {
            let url = try safeURL(item.path)
            let current: String?
            if fm.fileExists(atPath: url.path) { try Self.requireDownloaded(url); current = Self.digest(try Data(contentsOf: url)) } else { current = nil }
            guard current == item.before || current == Self.digest(item.data) else { throw failure("发现外部修改，未完成写入和备份已保留，请先处理冲突：\(item.path)") }
        }
        for item in transaction.writes {
            let url = try safeURL(item.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try item.data.write(to: url, options: .atomic)
        }
        try fm.removeItem(at: journal)
    }
    private func commit(_ updates: [String: Data], original: [String: Data]) throws {
        let changed = updates.filter { original[$0.key] != $0.value }
        guard !changed.isEmpty else { return }
        try backup(original)
        let transaction = Transaction(writes: changed.keys.sorted().map { Write(path: $0, before: original[$0].map(Self.digest), data: changed[$0]!) })
        try encoder.encode(transaction).write(to: journal, options: .atomic)
        try recover()
    }
    private func backup(_ files: [String: Data]) throws {
        guard !files.isEmpty else { return }
        let base = root.appendingPathComponent("backups", isDirectory: true)
        let dir = base.appendingPathComponent(StockDay.timestamp().replacingOccurrences(of: ":", with: "-") + "-" + String(format: "%.6f", locale: StockDecimal.locale, Date().timeIntervalSince1970) + "-" + UUID().uuidString.prefix(8))
        for (path, bytes) in files {
            let to = dir.appendingPathComponent(path); try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: to, options: .atomic)
        }
        let old = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in old.dropFirst(30) { try? fm.removeItem(at: url) }
    }
    private func mutate(expected: String, operation: (inout StockDataset, [String: Data]) throws -> [String: Data]) throws -> StockDataset {
        try coordinated {
            try recover(); let original = try files(); var current = try decode(original)
            guard current.revision == expected else { throw failure("数据已在外部修改。你的编辑尚未覆盖文件，请刷新后重新核对再保存") }
            let updates = try operation(&current, original)
            var proposed = original; updates.forEach { proposed[$0.key] = $0.value }
            _ = try decode(proposed)
            try commit(updates, original: original)
            return try decode(files())
        }
    }
    private func years<T: Codable>(_ entries: [T], folder: String, date: (T) -> String, existing: [String: Data]) throws -> [String: Data] {
        var groups: [Int: [T]] = [:]
        for value in entries { groups[try StockDay.year(date(value)), default: []].append(value) }
        for path in existing.keys where path.hasPrefix(folder + "/") {
            let y = Int(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)!
            if groups[y] == nil { groups[y] = [] }
        }
        var output: [String: Data] = [:]
        for (year, values) in groups { output["\(folder)/\(year).json"] = try encoder.encode(StockYear(schemaVersion: folder == "reviews" ? 2 : 1, year: year, entries: values)) }; return output
    }
    func saveTrades(_ rows: [StockTrade], expected: String) throws -> StockDataset {
        try mutate(expected: expected) { current, files in
            for row in rows {
                try row.validate()
                if let i = current.trades.firstIndex(where: { $0.id == row.id }) { current.trades[i] = row } else { current.trades.append(row) }
            }
            _ = try StockLedger.calculate(current.trades)
            return try years(current.trades.sorted { $0.sortKey < $1.sortKey }, folder: "trades", date: { $0.date }, existing: files)
        }
    }
    func saveReview(_ review: StockReview, expected: String) throws -> StockDataset {
        try mutate(expected: expected) { current, files in
            current.reviews.removeAll { $0.date == review.date }
            if review.hasUserContent { current.reviews.append(review) }
            return try years(current.reviews.sorted { $0.date < $1.date }, folder: "reviews", date: { $0.date }, existing: files)
        }
    }
    func saveRules(_ rules: StockRuleBook, expected: String) throws -> StockDataset {
        try mutate(expected: expected) { current, _ in
            ["rules.json": try encoder.encode(rules)]
        }
    }
    func saveSnapshot(_ snapshot: StockMarketSnapshot) throws -> StockDataset {
        // Automatic collection always reads the latest files and only mutates market data.
        let latest = try load()
        return try mutate(expected: latest.revision) { current, files in
            var s = snapshot
            if let old = current.snapshots.first(where: { $0.date == s.date }) {
                if s.indices.isEmpty { s.indices = old.indices }
                if s.limits.isEmpty && !s.sources.contains(where: { $0.name == "涨停池" && $0.status == "ok" }) { s.limits = old.limits }
                if s.sectors.isEmpty && s.sources.first(where: { $0.name == "行业涨幅前5" })?.status != "ok" { s.sectors = old.sectors }
                if (s.industryDecliners ?? []).isEmpty && s.sources.first(where: { $0.name == "行业跌幅前5" })?.status != "ok" { s.industryDecliners = old.industryDecliners }
                s.metrics = old.metrics.merging(s.metrics) { _, new in new }
                for key in ["最高连板", "首板家数", "昨日涨停平均涨幅"] { s.metrics.removeValue(forKey: key) }
            }
            current.snapshots.removeAll { $0.date == s.date }; current.snapshots.append(s)
            let updates = try years(current.snapshots.sorted { $0.date < $1.date }, folder: "market", date: { $0.date }, existing: files)
            return updates
        }
    }
    func migrate(to destination: URL) throws -> StockRepository {
        try coordinated {
            try recover(); _ = try decode(files())
            let dest = destination.standardizedFileURL.resolvingSymlinksInPath()
            guard dest != root, !dest.path.hasPrefix(root.path + "/"), !root.path.hasPrefix(dest.path + "/") else { throw failure("新目录不能是原目录或其父子目录") }
            guard try fm.contentsOfDirectory(atPath: dest.path).filter({ $0 != ".DS_Store" }).isEmpty else { throw failure("迁移目标必须为空目录；已有数据请使用“打开数据目录”") }
            for name in folders + ["rules.json", "backups"] {
                let source = root.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) {
                    try Self.requireDownloaded(source)
                    if let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: nil) {
                        for case let file as URL in enumerator { if file.pathExtension == "icloud" { throw failure("请先下载全部文件再迁移") }; try Self.requireDownloaded(file) }
                    }
                    try fm.copyItem(at: source, to: dest.appendingPathComponent(name))
                }
            }
            let repo = try StockRepository(root: dest); let data = try repo.load()
            guard data.revision == revision(try files()) else { throw failure("迁移校验失败，原目录保留") }; return repo
        }
    }
    func restore(from folder: URL, expected: String) throws -> StockDataset {
        let source = try StockRepository(root: folder)
        let saved = try source.load()
        return try mutate(expected: expected) { _, original in
            var output: [String: Data] = [:]
            output.merge(try years(saved.trades, folder: "trades", date: { $0.date }, existing: original)) { _, n in n }
            output.merge(try years(saved.reviews, folder: "reviews", date: { $0.date }, existing: original)) { _, n in n }
            output.merge(try years(saved.snapshots, folder: "market", date: { $0.date }, existing: original)) { _, n in n }
            output["rules.json"] = try encoder.encode(saved.rules); return output
        }
    }
}
