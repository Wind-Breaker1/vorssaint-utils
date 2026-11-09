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
    private let folders = ["trades", "reviews", "market", "charts"]
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
        guard ["watchlist.json", "rules.json"].contains(path) || path.range(of: #"^(trades|reviews|market|charts)/[0-9]{4}\.json$"#, options: .regularExpression) != nil else { throw failure("无效的数据文件路径") }
        let url = root.appendingPathComponent(path)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw failure("数据路径超出存储目录") }; return url
    }
    private func files() throws -> [String: Data] {
        var output: [String: Data] = [:]
        for name in folders + ["watchlist.json", "rules.json", ".transaction.json"] {
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
        for name in ["watchlist.json", "rules.json"] {
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
            if path == "watchlist.json" { data.watchlist = try decoder.decode([StockInstrument].self, from: bytes); continue }
            if path == "rules.json" {
                data.rules = try decoder.decode(StockRuleBook.self, from: bytes)
                guard data.rules.schemaVersion == 2, Set(data.rules.rules.map(\.id)).count == data.rules.rules.count else { throw failure("规则文件版本或 ID 无效") }
                for rule in data.rules.rules {
                    guard !rule.versions.isEmpty, Set(rule.versions.map(\.version)).count == rule.versions.count,
                          rule.versions.allSatisfy({ $0.ruleID == rule.id && $0.version > 0 }),
                          rule.snapshot.title == rule.title, rule.snapshot.prompt == rule.prompt, rule.snapshot.style == rule.style else { throw failure("规则历史版本无效") }
                }
                continue
            }
            let year = Int(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)!
            func read<T: Codable>(_ type: T.Type) throws -> [T] {
                let f = try decoder.decode(StockYear<T>.self, from: bytes)
                guard (f.schemaVersion == 1 || (path.hasPrefix("reviews/") && f.schemaVersion == 2)), f.year == year else { throw failure("\(path) 版本或年份不匹配，原文件已保留") }; return f.entries
            }
            if path.hasPrefix("charts/") {
                for record in try read(StockChartRecord.self) {
                    guard record.code.range(of: #"^(sh|sz|bj)[0-9]{6}$"#, options: .regularExpression) != nil,
                          Set(record.bars.map(\.date)).count == record.bars.count else { throw failure("日 K 代码或日期重复") }
                    for bar in record.bars { guard try StockDay.year(bar.date) == year, bar.open.isFinite, bar.close.isFinite, bar.high.isFinite, bar.low.isFinite, bar.volume.isFinite, bar.low > 0, bar.high >= max(bar.open, bar.close), bar.low <= min(bar.open, bar.close), bar.volume >= 0 else { throw failure("日 K 读数无效") } }
                    data.charts[record.code, default: []] += record.bars
                }
            } else if path.hasPrefix("trades/") {
                let rows = try read(StockTrade.self)
                for row in rows { try row.validate(); guard try StockDay.year(row.date) == year else { throw failure("成交年份与文件不符") } }
                data.trades += rows
            } else if path.hasPrefix("reviews/") {
                let rows = try read(StockReview.self)
                for row in rows {
                    guard try StockDay.year(row.date) == year, Set(row.plans.map(\.id)).count == row.plans.count else { throw failure("复盘年份或计划 ID 无效") }
                    for assessment in row.journal?.assessments ?? [] {
                        try assessment.validate()
                        guard assessment.date == row.date else { throw failure("操作评价须存入操作发生日期的复盘") }
                    }
                    for note in row.journal?.rounds ?? [] { guard note.date == row.date else { throw failure("轮次备注日期与复盘不符") } }
                    for plan in row.plans {
                        if let versions = plan.versions {
                            guard !versions.isEmpty, Set(versions.map(\.version)).count == versions.count,
                                  versions.allSatisfy({ $0.planID == plan.id && $0.version > 0 }), plan.snapshot.matches(plan) else { throw failure("计划版本无效") }
                        }
                    }
                }
                data.reviews += rows
            } else {
                let rows = try read(StockMarketSnapshot.self)
                for row in rows { guard try StockDay.year(row.date) == year else { throw failure("市场快照年份不符") } }; data.snapshots += rows
            }
        }
        guard Set(data.trades.map(\.id)).count == data.trades.count,
              Set(data.reviews.map(\.id)).count == data.reviews.count,
              Set(data.snapshots.map(\.id)).count == data.snapshots.count,
              Set(data.watchlist.map(\.id)).count == data.watchlist.count else { throw failure("文件内有重复 ID，停止写入以保留原始记录") }
        let evaluatedTrades = data.assessments.flatMap(\.tradeIDs)
        guard Set(data.assessments.map(\.id)).count == data.assessments.count,
              Set(data.roundNotes.map(\.id)).count == data.roundNotes.count,
              Set(evaluatedTrades).count == evaluatedTrades.count,
              Set(data.reviews.flatMap(\.plans).map(\.id)).count == data.reviews.flatMap(\.plans).count else { throw failure("操作评价、轮次、计划或成交关联重复") }
        let executions = data.trades.filter { $0.deletedAt == nil && !$0.brokerID.isEmpty }.map { $0.date + "|" + $0.instrument.id + "|" + $0.brokerID }
        guard Set(executions).count == executions.count else { throw failure("同一交易日、证券和券商成交编号重复，请核对交割单") }
        for item in data.watchlist { try item.validate() }
        _ = try StockLedger.calculate(data.trades)
        for code in data.charts.keys { data.charts[code]?.sort { $0.date < $1.date } }
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
            var revised = review
            let old = current.reviews.first { $0.date == review.date }
            let timestamp = StockDay.timestamp()
            revised.plans = try review.plans.map { plan in try plan.revised(from: old?.plans.first(where: { $0.id == plan.id }), at: timestamp) }
            for var removed in old?.plans ?? [] where !revised.plans.contains(where: { $0.id == removed.id }) {
                removed.status = "已取消"; revised.plans.append(removed)
            }
            // Full review editing never replaces separately saved evaluations.
            revised.journal = old?.journal ?? review.journal
            current.reviews.removeAll { $0.date == review.date }; current.reviews.append(revised)
            return try years(current.reviews.sorted { $0.date < $1.date }, folder: "reviews", date: { $0.date }, existing: files)
        }
    }
    func saveRules(_ rules: StockRuleBook, expected: String) throws -> StockDataset {
        try mutate(expected: expected) { current, _ in
            ["rules.json": try encoder.encode(rules.revised(from: current.rules, at: StockDay.timestamp()))]
        }
    }
    private func reviewIndex(_ date: String, in data: inout StockDataset) -> Int {
        if let index = data.reviews.firstIndex(where: { $0.date == date }) {
            if data.reviews[index].journal == nil { data.reviews[index].journal = StockReviewJournal() }; return index
        }
        data.reviews.append(StockReview(date: date, journal: StockReviewJournal())); return data.reviews.count - 1
    }
    func saveAssessment(_ value: StockAssessment, expected: String) throws -> StockDataset {
        try mutate(expected: expected) { current, files in
            var assessment = value
            let previous = current.assessments.first { $0.id == value.id }
            let timestamp = StockDay.timestamp()
            assessment.createdAt = previous?.createdAt ?? timestamp; assessment.updatedAt = timestamp
            assessment.reasonTags = StockJournalText.tags(assessment.reasonTags.joined(separator: ","))
            assessment.mistakes = StockJournalText.tags(assessment.mistakes.joined(separator: ","))
            assessment.improvementAt = assessment.improvement.isEmpty ? previous?.improvementAt : (previous?.improvementAt ?? timestamp)
            if assessment.isTrade {
                let trades = current.trades.filter { $0.deletedAt == nil && assessment.tradeIDs.contains($0.id) }.sorted { $0.sortKey < $1.sortKey }
                guard trades.count == assessment.tradeIDs.count, let first = trades.first,
                      let round = current.rounds.first(where: { $0.trades.contains { $0.id == first.id } }),
                      trades.allSatisfy({ t in round.trades.contains { $0.id == t.id } && t.action == first.action && t.date == first.date }),
                      first.action == .buy || first.action == .sell else { throw failure("一次评价只能关联同日、同一轮次、同一买卖方向的成交") }
                guard !current.assessments.contains(where: { $0.id != assessment.id && !Set($0.tradeIDs).isDisjoint(with: assessment.tradeIDs) }) else { throw failure("所选成交已有评价，请先在原评价中解除关联") }
                assessment.tradeSnapshots = trades; assessment.roundID = round.id
                assessment.date = first.date; assessment.time = first.time; assessment.symbol = first.instrument.symbol
            }
            assessment.retrospective = Self.isRecordedAfter(assessment.createdAt, day: assessment.date, time: assessment.time)
            try assessment.validate()
            guard assessment.linkIssue(in: current, rounds: current.rounds) == nil else { throw failure("关联轮次或成交无效，请重新选择") }
            for i in current.reviews.indices { current.reviews[i].journal?.assessments.removeAll { $0.id == assessment.id } }
            let index = reviewIndex(assessment.date, in: &current)
            current.reviews[index].journal!.assessments.append(assessment); current.reviews[index].updatedAt = timestamp
            return try years(current.reviews.sorted { $0.date < $1.date }, folder: "reviews", date: { $0.date }, existing: files)
        }
    }
    static func isRecordedAfter(_ timestamp: String, day: String, time: String) -> Bool {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let recorded = iso.date(from: timestamp), let date = StockDay.date(day) else { return true }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return true }
        return recorded > date.addingTimeInterval(Double(parts[0] * 3600 + parts[1] * 60 + parts[2]))
    }
    func deleteAssessment(_ id: String, expected: String) throws -> StockDataset {
        try mutate(expected: expected) { current, files in
            for i in current.reviews.indices { current.reviews[i].journal?.assessments.removeAll { $0.id == id } }
            return try years(current.reviews.sorted { $0.date < $1.date }, folder: "reviews", date: { $0.date }, existing: files)
        }
    }
    func saveRoundNote(_ value: StockRoundNote, reason: String, expected: String) throws -> StockDataset {
        try mutate(expected: expected) { current, files in
            guard let round = current.rounds.first(where: { $0.id == value.id }) else { throw failure("轮次已变化，原备注已保留，请重新核对成交") }
            var note = value
            let old = current.roundNotes.first { $0.id == value.id }
            note.date = round.start; note.changes = old?.changes ?? []
            if old?.style != note.style {
                guard old == nil || old?.style == .unspecified || !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("调整超短 / 波段分类需要填写原因") }
                note.changes.append(StockStyleChange(style: note.style, reason: reason.isEmpty ? "首次分类" : reason))
            }
            for i in current.reviews.indices { current.reviews[i].journal?.rounds.removeAll { $0.id == note.id } }
            let index = reviewIndex(note.date, in: &current)
            current.reviews[index].journal!.rounds.append(note)
            return try years(current.reviews.sorted { $0.date < $1.date }, folder: "reviews", date: { $0.date }, existing: files)
        }
    }
    func relinkRoundNote(_ value: StockRoundNote, to roundID: String, expected: String) throws -> StockDataset {
        try mutate(expected: expected) { current, files in
            guard current.roundNotes.first(where: { $0.id == value.id }) == value,
                  !current.rounds.contains(where: { $0.id == value.id }),
                  !current.roundNotes.contains(where: { $0.id == roundID }),
                  let target = current.rounds.first(where: { $0.id == roundID }) else { throw failure("轮次或备注已经变化，请重新核对") }
            var note = value; note.id = target.id; note.date = target.start
            note.changes.append(StockStyleChange(style: note.style, reason: "历史成交修改后重新关联轮次；原起始日期 " + value.date))
            for i in current.reviews.indices { current.reviews[i].journal?.rounds.removeAll { $0.id == value.id } }
            let index = reviewIndex(note.date, in: &current); current.reviews[index].journal!.rounds.append(note)
            return try years(current.reviews.sorted { $0.date < $1.date }, folder: "reviews", date: { $0.date }, existing: files)
        }
    }
    func saveSnapshot(_ snapshot: StockMarketSnapshot) throws -> StockDataset {
        // Automatic collection always reads the latest files and only mutates market data.
        let latest = try load()
        return try mutate(expected: latest.revision) { current, files in
            var s = snapshot
            if let old = current.snapshots.first(where: { $0.date == s.date }) {
                if s.indices.isEmpty { s.indices = old.indices }
                var quotes = Dictionary(uniqueKeysWithValues: old.quotes.map { ($0.code, $0) })
                for quote in s.quotes { quotes[quote.code] = quote }
                s.quotes = quotes.values.sorted { $0.code < $1.code }
                if !s.sources.contains(where: { $0.name == "涨停池" && $0.status == "ok" }) { s.limits = old.limits }
                for kind in ["行业", "概念"] where !s.sources.contains(where: { $0.name == kind + "涨幅前100" && $0.status == "ok" }) {
                    s.sectors.removeAll { $0.kind == kind }
                    s.sectors += old.sectors.filter { $0.kind == kind }
                }
                if s.industryDecliners == nil { s.industryDecliners = old.industryDecliners }
                s.metrics = old.metrics.merging(s.metrics) { _, new in new }
                // Preserve each retained value's collection timestamp on a failed refresh.
                for i in s.sources.indices where s.sources[i].status != "ok" {
                    if let source = old.sources.first(where: { $0.name == s.sources[i].name && $0.status == "ok" }) {
                        s.sources[i].detail += "；保留 \(source.fetchedAt) 的已保存读数"
                    }
                }
            }
            current.snapshots.removeAll { $0.date == s.date }; current.snapshots.append(s)
            var updates = try years(current.snapshots.sorted { $0.date < $1.date }, folder: "market", date: { $0.date }, existing: files)
            if !current.reviews.contains(where: { $0.date == s.date }) {
                let ids = current.trades.filter { $0.date == s.date && $0.deletedAt == nil }.map(\.id)
                current.reviews.append(StockReview(date: s.date, tradeIDs: ids))
                updates.merge(try years(current.reviews.sorted { $0.date < $1.date }, folder: "reviews", date: { $0.date }, existing: files)) { _, n in n }
            }
            return updates
        }
    }
    func saveBars(_ values: [String: [StockBar]]) throws -> StockDataset {
        let latest = try load()
        return try mutate(expected: latest.revision) { current, files in
            for (code, bars) in values {
                var merged = Dictionary(uniqueKeysWithValues: (current.charts[code] ?? []).map { ($0.date, $0) })
                for bar in bars { merged[bar.date] = bar }
                current.charts[code] = merged.values.sorted { $0.date < $1.date }
            }
            var grouped: [Int: [StockChartRecord]] = [:]
            for code in current.charts.keys.sorted() {
                var yearly: [Int: [StockBar]] = [:]
                for bar in current.charts[code]! { yearly[try StockDay.year(bar.date), default: []].append(bar) }
                for (year, bars) in yearly { grouped[year, default: []].append(StockChartRecord(code: code, bars: bars)) }
            }
            var output: [String: Data] = [:]
            for (year, entries) in grouped { output["charts/\(year).json"] = try encoder.encode(StockYear(year: year, entries: entries)) }
            return output
        }
    }
    func saveWatchlist(_ list: [StockInstrument], expected: String) throws -> StockDataset {
        try mutate(expected: expected) { _, _ in ["watchlist.json": try encoder.encode(list)] }
    }
    func migrate(to destination: URL) throws -> StockRepository {
        try coordinated {
            try recover(); _ = try decode(files())
            let dest = destination.standardizedFileURL.resolvingSymlinksInPath()
            guard dest != root, !dest.path.hasPrefix(root.path + "/"), !root.path.hasPrefix(dest.path + "/") else { throw failure("新目录不能是原目录或其父子目录") }
            guard try fm.contentsOfDirectory(atPath: dest.path).filter({ $0 != ".DS_Store" }).isEmpty else { throw failure("迁移目标必须为空目录；已有数据请使用“打开数据目录”") }
            for name in folders + ["watchlist.json", "rules.json", "backups"] {
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
            output["watchlist.json"] = try encoder.encode(saved.watchlist)
            output["rules.json"] = try encoder.encode(saved.rules); return output
        }
    }
}
