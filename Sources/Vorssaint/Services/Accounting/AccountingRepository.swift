// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private struct LedgerYearFile: Codable {
    var schemaVersion = 2
    var year: Int
    var entries: [LedgerEntry]
}

/// Serial-queue confined. iCloud transports ordinary coordinated JSON files.
final class AccountingRepository {
    let root: URL
    private var scopedAccess = false
    deinit { if scopedAccess { root.stopAccessingSecurityScopedResource() } }
    private var categories: [LedgerCategory] = []
    private var categoryURL: URL { root.appendingPathComponent("categories.json") }
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601; return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()
    private func failure(_ message: String) -> NSError { NSError(domain: "Accounting", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func year(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.component(.year, from: date)
    }
    init(url: URL) throws {
        root = url
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try coordinated(root) { _ in
            try self.ensureDownloaded(self.categoryURL)
            if FileManager.default.fileExists(atPath: self.categoryURL.path) {
                self.categories = try self.decoder.decode([LedgerCategory].self, from: Data(contentsOf: self.categoryURL))
            } else {
                for (kind, names) in [(LedgerKind.expense, ["餐饮", "交通", "购物", "居住", "娱乐", "医疗", "学习", "其他支出"]), (.income, ["工资", "奖金", "其他收入"])] {
                    self.categories += names.map { LedgerCategory(id: "default-\(kind.rawValue)-\($0)", name: $0, kind: kind, archived: false) }
                }
                try self.write(self.encoder.encode(self.categories), to: self.categoryURL)
            }
        }
        scopedAccess = root.startAccessingSecurityScopedResource()
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func ensureDownloaded(_ url: URL) throws {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw failure("iCloud 文件正在下载，请稍后重试")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw failure("iCloud 文件正在下载，请稍后重试")
        }
        // Retain system conflict versions; never silently resolve them or discard data.
        if !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty {
            throw failure("\(url.lastPathComponent) 存在 iCloud 文件冲突，各版本已保留，请先在 iCloud 中处理文件版本后重试")
        }
    }
    private func coordinated<T>(_ url: URL, operation: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { value in
            result = Result { try operation(value) }
        }
        if let error = coordinationError { throw error }
        guard let result else { throw failure("无法访问账本目录") }
        return try result.get()
    }
    private func readYear(_ url: URL, year: Int) throws -> [LedgerEntry] {
        try ensureDownloaded(url)
        let data = try Data(contentsOf: url)
        let file = try decoder.decode(LedgerYearFile.self, from: data)
        guard file.schemaVersion == 2, file.year == year else { throw failure("不支持的年度文件格式") }
        let entries = file.entries
        guard Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ !$0.id.isEmpty && $0.amount > 0 && $0.amount <= 999_999_999_999 && $0.date.timeIntervalSince1970.isFinite }) else { throw failure("账目内容无效，原文件未改写") }
        return entries
    }
    private func load(years: Set<Int>? = nil) throws -> [Int: [LedgerEntry]] {
        var files: [Int: [LedgerEntry]] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if url.pathExtension == "icloud" {
                let name = String(url.lastPathComponent.dropFirst().dropLast(7))
                let stem = (name as NSString).deletingPathExtension
                if name.hasSuffix(".json"), stem.count == 4, let year = Int(stem), (years?.contains(year) ?? true) {
                    try ensureDownloaded(root.appendingPathComponent(name))
                }
            }
            guard url.pathExtension == "json", url.deletingPathExtension().lastPathComponent.count == 4,
                  let year = Int(url.deletingPathExtension().lastPathComponent),
                  (years?.contains(year) ?? true) else { continue }
            files[year] = try readYear(url, year: year)
        }
        let entries = files.values.flatMap { $0 }
        guard Set(entries.map(\.id)).count == entries.count else { throw failure("不同年度存在重复账目，请先检查年度文件") }
        return files
    }
    private func persist(_ files: [Int: [LedgerEntry]]) throws {
        for (year, entries) in files {
            let url = root.appendingPathComponent("\(year).json")
            try ensureDownloaded(url)
            let data = try encoder.encode(LedgerYearFile(year: year, entries: entries.sorted { $0.id < $1.id }))
            if FileManager.default.fileExists(atPath: url.path) {
                let previous = try Data(contentsOf: url)
                if previous == data { continue }
            }
            try write(data, to: url)
        }
    }
    func snapshot(month: Date, limit: Int, kind: LedgerKind?, category: String) throws -> LedgerSnapshot {
        try coordinated(root) { _ in
            try self.makeSnapshot(month: month, limit: limit, kind: kind, category: category)
        }
    }
    private func makeSnapshot(month: Date, limit: Int, kind: LedgerKind?, category: String) throws -> LedgerSnapshot {
        let interval = Calendar.current.dateInterval(of: .month, for: month)!
        // A local-calendar month can straddle two UTC storage years.
        let years = Set([year(interval.start), year(interval.end.addingTimeInterval(-1))])
        let stored = try load(years: years).values.flatMap { $0 }
        try reloadCategories(entries: stored)
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let renamed: [LedgerEntry] = stored.map { original -> LedgerEntry in
            var entry = original
            if let name = names[entry.categoryID] {
                entry = LedgerEntry(id: entry.id, amount: entry.amount, categoryID: entry.categoryID, categoryName: name, kind: entry.kind, date: entry.date, note: entry.note)
            }
            return entry
        }
        let filtered: [LedgerEntry] = renamed.filter { $0.date >= interval.start && $0.date < interval.end && (kind == nil || $0.kind == kind) && (category.isEmpty || $0.categoryID == category) }
        let entries = filtered.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        let totals: [LedgerCategoryTotal] = Dictionary(grouping: entries, by: \.categoryID).map { id, values in
            LedgerCategoryTotal(id: id, name: values[0].categoryName, kind: values[0].kind, amount: values.reduce(0) { $0 + $1.amount })
        }.sorted { $0.amount > $1.amount }
        let daily: [LedgerDailyTotal] = Dictionary(grouping: entries, by: { "\(Calendar.current.component(.day, from: $0.date))-\($0.kind.rawValue)" }).values.map { values in
            LedgerDailyTotal(day: Calendar.current.component(.day, from: values[0].date), kind: values[0].kind, amount: values.reduce(0) { $0 + $1.amount })
        }.sorted { $0.day < $1.day }
        return LedgerSnapshot(dailyTotals: daily, categories: categories.sorted { $0.archived == $1.archived ? $0.name < $1.name : !$0.archived }, entries: Array(entries.prefix(max(0, limit))), totals: totals, count: entries.count)
    }
    func saveEntry(id: String, amount: Int64, category: String, date: Date, note: String) throws {
        guard amount > 0, amount <= 999_999_999_999, date.timeIntervalSince1970.isFinite else { throw failure("金额或日期无效") }
        try coordinated(root) { _ in
            var files = try self.load()
            let previous = files.values.flatMap { $0 }.first { $0.id == id }
            try self.reloadCategories(entries: files.values.flatMap { $0 })
            guard let cat = self.categories.first(where: { $0.id == category }), !cat.archived || previous?.categoryID == category else { throw self.failure("请选择有效分类") }
            let entry = LedgerEntry(id: id, amount: amount, categoryID: cat.id, categoryName: cat.name, kind: cat.kind, date: date, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            let newYear = self.year(date)
            let oldYear = files.first(where: { $0.value.contains(where: { $0.id == id }) })?.key
            files[newYear, default: []].removeAll { $0.id == id }
            files[newYear, default: []].append(entry)
            // Write the destination year first: interruption may leave a visible
            // duplicate, but never removes the only copy of a moved entry.
            try self.persist([newYear: files[newYear] ?? []])
            if let oldYear, oldYear != newYear, let oldEntries = files[oldYear]?.filter({ $0.id != id }) {
                try self.persist([oldYear: oldEntries])
            }
        }
    }
    func deleteEntry(_ id: String) throws {
        try coordinated(root) { _ in
            let files = try self.load()
            for (year, entries) in files where entries.contains(where: { $0.id == id }) {
                try self.persist([year: entries.filter { $0.id != id }])
            }
        }
    }
    func saveCategory(id: String, name: String, kind: LedgerKind) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw failure("分类名称需为 1–40 个字符") }
        try coordinated(root) { _ in try self.updateCategories { values in
            guard !values.contains(where: { $0.id != id && $0.kind == kind && $0.name == name }) else { throw self.failure("该类型中已有同名分类") }
            if let i = values.firstIndex(where: { $0.id == id }) {
                values[i] = LedgerCategory(id: id, name: name, kind: values[i].kind, archived: values[i].archived)
            } else { values.append(LedgerCategory(id: id, name: name, kind: kind, archived: false)) }
        } }
    }
    func archiveCategory(_ id: String, archived: Bool) throws {
        try coordinated(root) { _ in try self.updateCategories { values in
            guard let i = values.firstIndex(where: { $0.id == id }) else { return }
            let old = values[i]
            values[i] = LedgerCategory(id: id, name: old.name, kind: old.kind, archived: archived)
        } }
    }

    /// Copy and validate the destination. Source JSON remains until explicit cleanup.
    func moveStorage(to destination: URL) throws -> AccountingRepository {
        let source = root.resolvingSymlinksInPath().standardizedFileURL.path
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard target != source, !target.hasPrefix(source + "/"), !source.hasPrefix(target + "/") else {
            throw failure("请选择当前目录以外的独立空文件夹")
        }
        var copied: [URL] = []
        try coordinated(root) { _ in
            try self.coordinated(destination) { _ in
                guard try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).allSatisfy({ $0.lastPathComponent == ".DS_Store" }) else {
                    throw self.failure("请选择空文件夹，迁移不会覆盖或合并已有数据")
                }
                _ = try self.load()
                try self.ensureDownloaded(self.categoryURL)
                let files = try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
                do {
                    for file in files {
                        try self.ensureDownloaded(file)
                        let target = destination.appendingPathComponent(file.lastPathComponent)
                        try FileManager.default.copyItem(at: file, to: target)
                        copied.append(target)
                        guard try Data(contentsOf: file) == Data(contentsOf: target) else { throw self.failure("JSON 迁移校验失败") }
                    }
                    _ = try self.decoder.decode([LedgerCategory].self, from: Data(contentsOf: destination.appendingPathComponent("categories.json")))
                    for target in copied where target.deletingPathExtension().lastPathComponent.count == 4 {
                        if let year = Int(target.deletingPathExtension().lastPathComponent) { _ = try self.readYear(target, year: year) }
                    }
                    return
                } catch {
                    for file in copied { try? FileManager.default.removeItem(at: file) }
                    throw error
                }
            }
        }
        // Opening another coordinator must happen outside the nested coordination.
        return try AccountingRepository(url: destination)
    }
    static func removeMigratedJSON(at source: URL) throws {
        var coordinationError: NSError?
        var deletionError: Error?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forMerging, error: &coordinationError) { url in
            do {
                let fm = FileManager.default
                guard fm.fileExists(atPath: url.path) else { return }
                for file in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    let name = file.lastPathComponent
                    if file.pathExtension == "json" || (name.hasPrefix(".") && name.hasSuffix(".json.icloud")) {
                        try fm.removeItem(at: file)
                    }
                }
            } catch { deletionError = error }
        }
        if let error = coordinationError { throw error }
        if let error = deletionError { throw error }
    }
    private func reloadCategories(entries: [LedgerEntry]) throws {
        try updateCategories { values in
            for entry in entries where !values.contains(where: { $0.id == entry.categoryID }) {
                values.append(LedgerCategory(id: entry.categoryID, name: entry.categoryName, kind: entry.kind, archived: false))
            }
        }
    }
    private func updateCategories(_ change: (inout [LedgerCategory]) throws -> Void) throws {
        try ensureDownloaded(categoryURL)
        var values = categories
        if FileManager.default.fileExists(atPath: categoryURL.path) { values = try decoder.decode([LedgerCategory].self, from: Data(contentsOf: categoryURL)) }
        try change(&values)
        let data = try encoder.encode(values)
        if (try? Data(contentsOf: categoryURL)) != data { try write(data, to: categoryURL) }
        categories = values
    }
}
