// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import AppKit
import Combine
import UniformTypeIdentifiers

// UI state is main-thread confined; repository and scoped access are confined to queue.
final class StockService: ObservableObject, @unchecked Sendable {
    private static var instance: StockService?
    static var shared: StockService {
        if let instance { return instance }; let s = StockService(); instance = s; return s
    }
    static func syncAvailability() {
        if AppFeature.stocks.isAvailable { _ = shared }
        else { instance?.stop(); StockWindowController.close(); instance = nil }
    }
    @Published private(set) var data = StockDataset()
    @Published private(set) var ledger = StockLedger(positions: [], saleProfit: [:], fees: 0)
    @Published private(set) var busy = false
    @Published private(set) var collecting = false
    @Published private(set) var storagePath = ""
    @Published var message: String?
    @Published var collectionStatus = ""
    @Published private(set) var lastRequestAt: Date?
    @Published var importRows: [StockImportRow] = []
    @Published var showImport = false
    // Main-thread drafts survive navigation and closing the workspace window.
    var reviewDrafts: [String: (draft: StockReview, original: StockReview?)] = [:]
    @Published var autoCollect: Bool { didSet { UserDefaults.standard.set(autoCollect, forKey: "stocks.autoCollect") } }
    private let queue = DispatchQueue(label: "com.vorssaint.stocks.files", qos: .userInitiated)
    private var repository: StockRepository?
    private var observers: [NSObjectProtocol] = []
    private var collectionTask: Task<Void, Never>?
    private var reviewOpenRequestTask: Task<Void, Never>?
    private var stopped = false
    private var accessURL: URL?
    private var generation = 0
    private static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.vorssaint.utils").appendingPathComponent("StockReview")
    }
    private init() {
        autoCollect = UserDefaults.standard.object(forKey: "stocks.autoCollect") as? Bool ?? true
        lastRequestAt = UserDefaults.standard.object(forKey: "stocks.lastRequestAt") as? Date
        storagePath = UserDefaults.standard.string(forKey: "stocks.storagePath") ?? Self.defaultRoot.path
        refresh()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) } }
    private func stop() {
        stopped = true; generation += 1; collectionTask?.cancel(); reviewOpenRequestTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        queue.async { [self] in repository = nil; accessURL?.stopAccessingSecurityScopedResource(); accessURL = nil }
    }
    private func repo() throws -> StockRepository {
        if let repository { return repository }
        var root = Self.defaultRoot
        if let bookmark = UserDefaults.standard.data(forKey: "stocks.storageBookmark") {
            var stale = false
            root = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw StockError("数据目录授权已变化，请重新打开该目录") }
        }
        if root.startAccessingSecurityScopedResource() { accessURL = root }
        let result = try StockRepository(root: root); repository = result; return result
    }
    private func apply(_ value: StockDataset) {
        data = value
        ledger = (try? StockLedger.calculate(value.trades)) ?? StockLedger(positions: [], saleProfit: [:], fees: 0)
    }
    func refresh() {
        guard !busy, !stopped else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.repo().load() }
            DispatchQueue.main.async {
                guard !self.stopped else { return }; self.busy = false
                switch result { case .success(let d): self.apply(d)
                case .failure(let e): self.message = e.localizedDescription }
            }
        }
    }
    private func write(_ action: @escaping (StockRepository) throws -> StockDataset, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !busy, !stopped else { message = "正在处理数据，请稍后重试"; completion(false); return }
        busy = true; message = nil
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try action(self.repo()) }
            DispatchQueue.main.async {
                guard !self.stopped else { return }; self.busy = false
                switch result {
                case .success(let value): self.apply(value); completion(true)
                case .failure(let error): self.message = error.localizedDescription; completion(false)
                }
            }
        }
    }
    func saveTrade(_ trade: StockTrade, original: StockTrade?, completion: @escaping (Bool) -> Void) {
        write({ repo in
            let latest = try repo.load()
            guard latest.trades.first(where: { $0.id == trade.id }) == original else { throw StockError("这笔成交已被外部修改，请刷新后核对。当前草稿保留") }
            var row = trade; row.updatedAt = StockDay.timestamp()
            return try repo.saveTrades([row], expected: latest.revision)
        }, completion: completion)
    }
    func deleteTrade(_ trade: StockTrade) {
        var deleted = trade; deleted.deletedAt = StockDay.timestamp()
        saveTrade(deleted, original: trade) { _ in }
    }
    func saveReview(_ review: StockReview, original: StockReview?, completion: @escaping (Bool) -> Void) {
        write({ repo in
            let latest = try repo.load(), current = latest.reviews.first { $0.date == review.date }
            let generated = current.map { !$0.hasUserContent } ?? false
            guard current == original || (original == nil && generated) else { throw StockError("这篇复盘已被外部修改，请保留草稿并重新打开核对") }
            var row = review; row.updatedAt = StockDay.timestamp()
            return try repo.saveReview(row, expected: latest.revision)
        }, completion: completion)
    }
    func saveRules(_ value: StockRuleBook, original: StockRuleBook, completion: @escaping (Bool) -> Void) {
        write({ repo in
            let latest = try repo.load()
            guard latest.rules == original else { throw StockError("规则已被修改，请保留草稿并重新打开核对") }
            return try repo.saveRules(value, expected: latest.revision)
        }, completion: completion)
    }
    func chooseFolder(migrate: Bool) {
        guard !busy, !collecting else { return }
        guard reviewDrafts.isEmpty else { message = "每日复盘有未保存的正文，请先保存或撤销修改，再切换数据目录"; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = migrate ? "选择空文件夹。校验后复制全部交易、复盘和行情数据，原目录保留。" : "选择已有股票复盘目录或空文件夹。可选 iCloud Drive 中的文件夹。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; generation += 1
        queue.async { [weak self] in
            guard let self else { return }
            let access = url.startAccessingSecurityScopedResource()
            let result = Result { () -> (StockRepository, StockDataset) in
                let entries = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0 != ".DS_Store" }
                if !migrate && !entries.isEmpty && !entries.contains(where: { ["trades","reviews","market","rules.json"].contains($0) }) { throw StockError("此目录不包含股票复盘数据，请选择空文件夹或已有数据根目录") }
                let repo = try migrate ? self.repo().migrate(to: url) : StockRepository(root: url)
                let data = try repo.load()
                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: "stocks.storageBookmark"); UserDefaults.standard.set(url.path, forKey: "stocks.storagePath")
                self.accessURL?.stopAccessingSecurityScopedResource(); self.accessURL = access ? url : nil; self.repository = repo
                return (repo, data)
            }
            if case .failure = result, access { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let (_, data)): self.reviewDrafts = [:]; self.storagePath = url.path; self.apply(data); self.message = migrate ? "迁移成功，原目录保留" : "已打开数据目录"
                case .failure(let e): self.message = e.localizedDescription
                }
            }
        }
    }
    func revealStorage() { NSWorkspace.shared.open(URL(fileURLWithPath: storagePath)) }
    func chooseImport() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url); guard data.count <= 20_000_000 else { throw StockError("导入文件不能超过 20 MB") }
            importRows = try StockCSV.preview(StockCSV.decode(data), existing: self.data.trades); showImport = true
        } catch { message = error.localizedDescription }
    }
    func commitImport() {
        let rows = importRows.filter { $0.selected && !$0.duplicate }.compactMap(\.trade)
        guard !rows.isEmpty else { message = "请先选择要导入的记录"; return }
        write({ repo in
            let latest = try repo.load()
            for row in rows {
                if latest.trades.contains(where: { $0.id == row.id || ($0.deletedAt == nil && !row.brokerID.isEmpty && $0.brokerID == row.brokerID && $0.date == row.date && $0.instrument.id == row.instrument.id) }) { throw StockError("预览后发现重复成交，请重新导入预览") }
            }
            return try repo.saveTrades(rows, expected: latest.revision)
        }, completion: { [weak self] ok in if ok { self?.showImport = false; self?.importRows = []; self?.message = "成交已全部导入" } })
    }
    func exportCSV(template: Bool = false) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = template ? "成交导入模板.csv" : "全部成交-\(StockDay.string()).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(StockCSV.export(template ? [] : data.trades).utf8).write(to: url, options: .atomic) } catch { message = error.localizedDescription }
    }
    func restoreBackup() {
        guard !busy, !collecting else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: storagePath).appendingPathComponent("backups")
        panel.message = "选择 backups 中的一个备份目录。恢复前会再次备份当前记录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "恢复所选备份？"; alert.informativeText = "当前交易、复盘和市场快照将恢复到该备份；当前版本先自动备份。"; alert.addButton(withTitle: "恢复"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        write { repo in
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            guard names.contains(where: { ["trades","reviews","market","rules.json"].contains($0) }) else { throw StockError("所选目录不包含有效备份") }
            let latest = try repo.load(); return try repo.restore(from: url, expected: latest.revision)
        }
    }
    var instruments: [StockInstrument] {
        var list: [String: StockInstrument] = [:]
        for trade in data.trades where trade.deletedAt == nil { list[trade.instrument.id] = trade.instrument }
        return list.values.sorted { $0.id < $1.id }
    }
    func reviewWindowOpened(now: Date = Date()) {
        guard autoCollect, !stopped, StockMarketClient.isTradingHours(now: now) else { return }
        reviewOpenRequestTask?.cancel()
        reviewOpenRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.busy || self.collecting {
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
                guard !self.stopped else { return }
            }
            guard await StockMarketClient.hasLiveSession(now: now), !self.stopped else {
                self.reviewOpenRequestTask = nil
                return
            }
            self.collect(date: StockDay.string(now))
            self.reviewOpenRequestTask = nil
        }
    }
    func collect(date: String?) {
        guard !collecting, !busy, !stopped else { return }
        let requestTime = Date()
        lastRequestAt = requestTime
        UserDefaults.standard.set(requestTime, forKey: "stocks.lastRequestAt")
        collecting = true; collectionStatus = "核对交易日…"
        let token = generation
        collectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.collecting = false }
            do {
                let day: String
                if let date {
                    guard let selected = StockDay.date(date), selected <= StockDay.calendar.startOfDay(for: Date()) else { throw StockError("请选择有效的今天或过去日期") }
                    _ = try StockDay.year(date)
                    day = date
                }
                else {
                    guard let latest = try await StockMarketClient.latestTradingDate() else { throw StockError("实时指数行情暂不可用，无法识别最近交易日") }
                    day = latest
                }
                try Task.checkCancellation(); guard self.generation == token, !self.stopped else { return }
                self.collectionStatus = "采集 \(day)…"
                let previous = self.data.snapshots.filter { $0.date < day }.map(\.date).max()
                let snapshot = try await StockMarketClient.collect(day: day, previous: previous)
                guard snapshot.sources.contains(where: { $0.status == "ok" && $0.name != "昨日涨停反馈" }) else { throw StockError("该日期没有可验证的市场行情，未保存空快照") }
                try Task.checkCancellation(); guard self.generation == token, !self.stopped else { return }
                let saved: StockDataset = try await withCheckedThrowingContinuation { continuation in
                    self.queue.async {
                        do {
                            continuation.resume(returning: try self.repo().saveSnapshot(snapshot))
                        }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                guard self.generation == token, !self.stopped else { return }
                self.apply(saved)
                let missing = snapshot.sources.filter { $0.status != "ok" }.count
                self.collectionStatus = "\(day) 已保存" + (missing > 0 ? " · \(missing) 项缺失，可稍后重试" : " · 采集完成")
            } catch { if !Task.isCancelled { self.collectionStatus = error.localizedDescription } }
        }
    }
}
