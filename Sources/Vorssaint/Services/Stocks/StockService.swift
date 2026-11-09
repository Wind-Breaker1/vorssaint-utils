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
    @Published private(set) var rounds: [StockRound] = []
    @Published private(set) var qualitySamples: [StockQualitySample] = []
    @Published private(set) var ledger = StockLedger(positions: [], saleProfit: [:], fees: 0)
    @Published private(set) var busy = false
    @Published private(set) var collecting = false
    @Published private(set) var storagePath = ""
    @Published var message: String?
    @Published var collectionStatus = ""
    @Published var liveQuotes: [StockQuote] = []
    @Published var bars: [StockBar] = []
    @Published var chartCode = ""
    @Published var chartLoading = false
    @Published var chartError: String?
    @Published var importRows: [StockImportRow] = []
    @Published var showImport = false
    // Main-thread drafts survive navigation and closing the workspace window.
    var reviewDrafts: [String: (draft: StockReview, original: StockReview?)] = [:]
    @Published var autoCollect: Bool { didSet { UserDefaults.standard.set(autoCollect, forKey: "stocks.autoCollect") } }
    private let queue = DispatchQueue(label: "com.vorssaint.stocks.files", qos: .userInitiated)
    private var repository: StockRepository?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var collectionTask: Task<Void, Never>?
    private var chartTask: Task<Void, Never>?
    private var quotesTask: Task<Void, Never>?
    private var lastAutoAttempt: Date = .distantPast
    private var stopped = false
    private var accessURL: URL?
    private var generation = 0
    private static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.vorssaint.utils").appendingPathComponent("StockReview")
    }
    private init() {
        autoCollect = UserDefaults.standard.object(forKey: "stocks.autoCollect") as? Bool ?? true
        storagePath = UserDefaults.standard.string(forKey: "stocks.storagePath") ?? Self.defaultRoot.path
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.automaticCollection() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh(); self?.automaticCollection() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.automaticCollection() })
    }
    deinit { timer?.invalidate(); observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) } }
    private func stop() {
        stopped = true; generation += 1; timer?.invalidate(); collectionTask?.cancel(); chartTask?.cancel(); quotesTask?.cancel()
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
        data = value; rounds = value.rounds; qualitySamples = value.qualitySamples
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
                switch result { case .success(let d): self.apply(d); self.automaticCollection()
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
            let generated = current.map { $0.summary.isEmpty && $0.execution.isEmpty && $0.lesson.isEmpty && $0.emotion.isEmpty && $0.plans.isEmpty && ($0.journal?.assessments.isEmpty ?? true) && ($0.journal?.rounds.isEmpty ?? true) } ?? false
            guard current == original || (original == nil && generated) else { throw StockError("这篇复盘已被外部修改，请保留草稿并重新打开核对") }
            var row = review; row.updatedAt = StockDay.timestamp()
            return try repo.saveReview(row, expected: latest.revision)
        }, completion: completion)
    }
    func changeWatchlist(_ item: StockInstrument, remove: Bool = false) {
        write { repo in
            let latest = try repo.load(); var list = latest.watchlist.filter { $0.id != item.id }
            if !remove { try item.validate(); list.append(item) }
            return try repo.saveWatchlist(list, expected: latest.revision)
        }
    }
    func saveAssessment(_ value: StockAssessment, original: StockAssessment?, completion: @escaping (Bool) -> Void) {
        let visible = data.trades.filter { $0.deletedAt == nil && value.tradeIDs.contains($0.id) }
            .map { $0.id + "|" + $0.fingerprint }.sorted()
        write({ repo in
            let latest = try repo.load()
            guard latest.assessments.first(where: { $0.id == value.id }) == original else { throw StockError("操作评价已被修改，请保留草稿并重新核对") }
            let actual = latest.trades.filter { $0.deletedAt == nil && value.tradeIDs.contains($0.id) }.map { $0.id + "|" + $0.fingerprint }.sorted()
            guard actual == visible else { throw StockError("关联成交在保存前被外部修改，请刷新核对；评价草稿保留") }
            return try repo.saveAssessment(value, expected: latest.revision)
        }, completion: completion)
    }
    func deleteAssessment(_ value: StockAssessment, completion: @escaping (Bool) -> Void) {
        write({ repo in
            let latest = try repo.load()
            guard latest.assessments.first(where: { $0.id == value.id }) == value else { throw StockError("评价已被修改，请刷新核对") }
            return try repo.deleteAssessment(value.id, expected: latest.revision)
        }, completion: completion)
    }
    func saveRules(_ value: StockRuleBook, original: StockRuleBook, completion: @escaping (Bool) -> Void) {
        write({ repo in
            let latest = try repo.load()
            guard latest.rules == original else { throw StockError("规则已被修改，请保留草稿并重新打开核对") }
            return try repo.saveRules(value, expected: latest.revision)
        }, completion: completion)
    }
    func saveRoundNote(_ value: StockRoundNote, original: StockRoundNote?, reason: String, completion: @escaping (Bool) -> Void) {
        write({ repo in
            let latest = try repo.load()
            guard latest.roundNotes.first(where: { $0.id == value.id }) == original else { throw StockError("轮次备注已被修改，请重新核对") }
            return try repo.saveRoundNote(value, reason: reason, expected: latest.revision)
        }, completion: completion)
    }
    func relinkRoundNote(_ value: StockRoundNote, to id: String) {
        write { repo in let latest = try repo.load(); return try repo.relinkRoundNote(value, to: id, expected: latest.revision) }
    }
    func chooseFolder(migrate: Bool) {
        guard !busy, !collecting else { return }
        guard reviewDrafts.isEmpty else { message = "每日复盘有未保存的正文，请先保存或撤销修改，再切换数据目录"; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = migrate ? "选择空文件夹。校验后复制全部交易、复盘和行情数据，原目录保留。" : "选择已有股票复盘目录或空文件夹。可选 iCloud Drive 中的文件夹。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; generation += 1; chartTask?.cancel(); quotesTask?.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            let access = url.startAccessingSecurityScopedResource()
            let result = Result { () -> (StockRepository, StockDataset) in
                let entries = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0 != ".DS_Store" }
                if !migrate && !entries.isEmpty && !entries.contains(where: { ["trades","reviews","market","charts","watchlist.json","rules.json"].contains($0) }) { throw StockError("此目录不包含股票复盘数据，请选择空文件夹或已有数据根目录") }
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
                case .success(let (_, data)): self.reviewDrafts = [:]; self.storagePath = url.path; self.apply(data); self.bars = []; self.liveQuotes = []; self.chartCode = ""; self.message = migrate ? "迁移成功，原目录保留" : "已打开数据目录"
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
        let alert = NSAlert(); alert.messageText = "恢复所选备份？"; alert.informativeText = "当前交易、复盘、自选和市场快照将恢复到该备份；当前版本先自动备份。"; alert.addButton(withTitle: "恢复"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        write { repo in
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            guard names.contains(where: { ["trades","reviews","market","watchlist.json","rules.json"].contains($0) }) else { throw StockError("所选目录不包含有效备份") }
            let latest = try repo.load(); return try repo.restore(from: url, expected: latest.revision)
        }
    }
    var instruments: [StockInstrument] {
        var list = Dictionary(uniqueKeysWithValues: data.watchlist.map { ($0.id,$0) })
        for trade in data.trades where trade.deletedAt == nil { list[trade.instrument.id] = trade.instrument }
        return list.values.sorted { $0.id < $1.id }
    }
    func loadChart(_ item: StockInstrument) {
        chartTask?.cancel(); chartCode = item.id; chartLoading = true; chartError = nil; bars = []
        let cached = data.charts[item.quoteCode]
        if let cached { bars = cached }
        let token = generation
        chartTask = Task { @MainActor [weak self] in
            do {
                let values = try await StockMarketClient.bars(item.quoteCode)
                guard !Task.isCancelled, let self, !self.stopped, self.generation == token else { return }
                self.bars = values; self.chartLoading = false
                let stored: StockDataset = try await withCheckedThrowingContinuation { continuation in
                    self.queue.async {
                        do { continuation.resume(returning: try self.repo().saveBars([item.quoteCode: values])) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                if !Task.isCancelled, self.generation == token, !self.stopped { self.apply(stored) }
            } catch {
                guard !Task.isCancelled, let self else { return }; self.chartLoading = false
                if self.bars.isEmpty { self.chartError = error.localizedDescription }
                else { self.message = "日 K 更新或保存失败，保留当前图表：" + error.localizedDescription }
            }
        }
    }
    func refreshQuotes() {
        quotesTask?.cancel(); let codes = instruments.map(\.quoteCode), token = generation
        guard !codes.isEmpty else { return }
        quotesTask = Task { @MainActor [weak self] in
            do { let values = try await StockMarketClient.quotes(codes); guard !Task.isCancelled, let self, !self.stopped, self.generation == token else { return }; self.liveQuotes = values }
            catch { if !Task.isCancelled { self?.message = error.localizedDescription } }
        }
    }
    func automaticCollection() {
        guard autoCollect, !busy, !collecting, !stopped, Date().timeIntervalSince(lastAutoAttempt) > 1800 else { return }
        lastAutoAttempt = Date(); collect(date: nil)
    }
    func collect(date: String?) {
        guard !collecting, !busy, !stopped else { return }
        collecting = true; collectionStatus = "核对交易日…"
        let token = generation, items = instruments, existing = data.snapshots
        collectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.collecting = false }
            do {
                let days = try await StockMarketClient.eligibleDays()
                let targets: [String]
                if let date { guard days.contains(date) else { throw StockError("请选择最近 90 个交易日内已收盘的交易日；15:30 后可采集当日快照") }; targets = [date] }
                else {
                    // Bootstrap the last close; later catch up missing sessions since last saved day (up to 5 per run).
                    let last = existing.map(\.date).max()
                    if let last {
                        var pending = days.filter { $0 > last }
                        if pending.isEmpty, let latest = days.last, let saved = existing.first(where: { $0.date == latest }), (saved.industryDecliners == nil || saved.sources.contains(where: { $0.status != "ok" })) { pending = [latest] }
                        targets = Array(pending.prefix(5))
                    } else { targets = Array(days.suffix(1)) }
                }
                if targets.isEmpty { self.collectionStatus = "已保存最近收盘快照"; return }
                for day in targets {
                    try Task.checkCancellation(); guard self.generation == token, !self.stopped else { return }
                    self.collectionStatus = "采集 \(day)…"
                    let previous = days.last { $0 < day }
                    var snapshot = try await StockMarketClient.collect(day: day, previous: previous, instruments: items)
                    var collectedBars: [String: [StockBar]] = [:]
                    for item in items {
                        try Task.checkCancellation()
                        do {
                            let history = try await StockMarketClient.bars(item.quoteCode).filter { $0.date <= day }
                            guard !history.isEmpty else { throw StockError("历史区间无可用日 K") }
                            collectedBars[item.quoteCode] = history
                            snapshot.sources.append(StockSource(name: "日 K · " + item.symbol, url: "https://web.ifzq.gtimg.cn/", status: "ok", detail: "不复权，截止 \(day)，\(history.count) 根日线"))
                        } catch { snapshot.sources.append(StockSource(name: "日 K · " + item.symbol, url: "https://web.ifzq.gtimg.cn/", status: "missing", detail: error.localizedDescription)) }
                    }
                    try Task.checkCancellation(); guard self.generation == token, !self.stopped else { return }
                    let capturedSnapshot = snapshot, capturedBars = collectedBars
                    let saved: StockDataset = try await withCheckedThrowingContinuation { continuation in
                        self.queue.async {
                            do {
                                let repo = try self.repo(); _ = try repo.saveSnapshot(capturedSnapshot)
                                continuation.resume(returning: try repo.saveBars(capturedBars))
                            }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                    guard self.generation == token, !self.stopped else { return }
                    self.apply(saved)
                    let missing = snapshot.sources.filter { $0.status != "ok" }.count
                    self.collectionStatus = "\(day) 已保存" + (missing > 0 ? " · \(missing) 项缺失，可稍后重试" : " · 采集完成")
                }
            } catch { if !Task.isCancelled { self.collectionStatus = error.localizedDescription } }
        }
    }
}
