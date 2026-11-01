// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine
import AppKit

/// Owns presentation and sync state; JSON reads and writes use one serial queue.
final class AccountingService: ObservableObject {
    private static var instance: AccountingService?
    static var shared: AccountingService {
        if let instance { return instance }
        let service = AccountingService(); instance = service; return service
    }
    static func stopIfLoaded() {
        instance?.refreshTimer?.invalidate()
        instance?.generation += 1
        instance?.queue.async { [weak service = instance] in service?.repository = nil }
        instance = nil
    }
    @Published var showingLedger = false
    func present(ledger: Bool) {
        guard AppFeature.accounting.isAvailable else { return }
        showingLedger = ledger
        NotchService.shared.select(.accounting)
    }
    @Published private(set) var snapshot = LedgerSnapshot()
    @Published private(set) var errorMessage: String?
    @Published private(set) var loading = false
    private(set) var month = Date()
    private(set) var kind: LedgerKind?
    private(set) var category = ""
    private var limit = 100
    private var generation = 0
    private let queue = DispatchQueue(label: "com.vorssaint.accounting", qos: .userInitiated)
    private var repository: AccountingRepository?

    private var refreshTimer: Timer?
    private init() {
        refresh()
        // The selected folder is the only source of truth. iCloud transports
        // files; periodically reread to show changes made on other devices.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { refreshTimer?.invalidate() }
    private func openRepository() throws -> AccountingRepository {
        if let repository { return repository }
        let root = try storageURL()
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        let repository = try AccountingRepository(url: root)
        self.repository = repository
        return repository
    }
    private static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Vorssaint/Accounting", isDirectory: true)
    @Published private(set) var storagePath = UserDefaults.standard.string(forKey: "accounting.storagePath") ?? AccountingService.defaultRoot.path
    @Published private(set) var movingStorage = false
    @Published private(set) var previousStorage = MigratedStorageSource.load(key: "accounting.previousStorage")
    @Published private(set) var removingOldStorage = false
    private func storageURL() throws -> URL {
        if let bookmark = UserDefaults.standard.data(forKey: "accounting.storageBookmark") {
            var stale = false
            let url = try MigratedStorageSource.resolveBookmark(bookmark, isStale: &stale)
            guard !stale else { throw NSError(domain: "Accounting", code: 1, userInfo: [NSLocalizedDescriptionKey: "存储目录授权已变化，请重新选择目录"]) }
            return url
        }
        let drive = Self.defaultRoot.deletingLastPathComponent().deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "Accounting", code: 1, userInfo: [NSLocalizedDescriptionKey: "iCloud Drive 不可用，请启用 iCloud Drive 或选择其他保存目录"])
        }
        return Self.defaultRoot
    }
    func chooseStorageFolder() {
        guard !movingStorage, !removingOldStorage else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "选择空文件夹存放年度 JSON。现有 JSON 文件将校验后迁移到新位置，成功后保留原 JSON，可在设置页手动删除。可直接选择 iCloud Drive 中的文件夹，各设备选择同一目录。"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        movingStorage = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { () -> Void in
                let access = destination.startAccessingSecurityScopedResource()
                defer { if access { destination.stopAccessingSecurityScopedResource() } }
                let bookmark = try destination.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                let current: AccountingRepository?
                do { current = try self.openRepository() }
                catch {
                    // Allow choosing a folder when iCloud has never initialized.
                    guard UserDefaults.standard.data(forKey: "accounting.storageBookmark") == nil,
                          !FileManager.default.fileExists(atPath: Self.defaultRoot.path) else { throw error }
                    current = nil
                }
                let source = try current.map { try MigratedStorageSource(url: $0.root) }
                let verified: AccountingRepository
                if let current { verified = try current.moveStorage(to: destination) }
                else {
                    guard try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty else {
                        throw NSError(domain: "Accounting", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择空目录，迁移不会覆盖已有文件"])
                    }
                    verified = try AccountingRepository(url: destination)
                }
                if let source {
                    var sources = MigratedStorageSource.load(key: "accounting.previousStorage")
                    sources.removeAll { $0.id == source.id }
                    sources.append(source)
                    try MigratedStorageSource.save(sources, key: "accounting.previousStorage")
                }
                UserDefaults.standard.set(bookmark, forKey: "accounting.storageBookmark")
                UserDefaults.standard.set(destination.path, forKey: "accounting.storagePath")
                self.repository = verified
            }
            DispatchQueue.main.async {
                self.movingStorage = false
                switch result {
                case .success:
                    self.storagePath = destination.path
                    self.previousStorage = MigratedStorageSource.load(key: "accounting.previousStorage")
                    self.errorMessage = nil; self.refresh()
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    func removeOldStorage(_ source: MigratedStorageSource) {
        guard !movingStorage, !removingOldStorage else { return }
        removingOldStorage = true
        queue.async { [self] in
            let result = Result { () -> Void in
                let url = try source.resolve(excluding: storageURL())
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try AccountingRepository.removeMigratedJSON(at: url)
                var sources = MigratedStorageSource.load(key: "accounting.previousStorage")
                sources.removeAll { $0.id == source.id }
                try MigratedStorageSource.save(sources, key: "accounting.previousStorage")
            }
            DispatchQueue.main.async { [self] in
                removingOldStorage = false
                switch result {
                case .success: previousStorage = MigratedStorageSource.load(key: "accounting.previousStorage"); errorMessage = nil
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
        }
    }

    func select(month: Date, kind: LedgerKind?, category: String) {
        self.month = month; self.kind = kind; self.category = category; limit = 100
        refresh()
    }
    func loadMore() { limit += 100; refresh() }
    func refresh() {
        generation += 1
        let token = generation, month = month, kind = kind, category = category, limit = limit
        loading = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { () -> LedgerSnapshot in
                let repository = try self.openRepository()
                let snapshot = try repository.snapshot(month: month, limit: limit, kind: kind, category: category)
                return snapshot
            }
            DispatchQueue.main.async {
                guard token == self.generation else { return }
                self.loading = false
                switch result {
                case .success(let value): self.snapshot = value; self.errorMessage = nil
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    private func write(_ operation: @escaping (AccountingRepository) throws -> Void, completion: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try operation(self.openRepository()) }
            DispatchQueue.main.async {
                switch result {
                case .success: self.refresh(); completion(nil)
                case .failure(let error): self.errorMessage = error.localizedDescription; completion(error.localizedDescription)
                }
            }
        }
    }
    func save(entryID: String?, amount: Int64, category: String, date: Date, note: String, completion: @escaping (String?) -> Void) {
        write({ try $0.saveEntry(id: entryID ?? UUID().uuidString, amount: amount, category: category, date: date, note: note) }, completion: completion)
    }
    func delete(_ entry: LedgerEntry, completion: @escaping (String?) -> Void) {
        write({ try $0.deleteEntry(entry.id) }, completion: completion)
    }
    func saveCategory(_ existing: LedgerCategory?, name: String, kind: LedgerKind, completion: @escaping (String?) -> Void) {
        write({ try $0.saveCategory(id: existing?.id ?? UUID().uuidString, name: name, kind: kind) }, completion: completion)
    }
    func archive(_ category: LedgerCategory) {
        write({ try $0.archiveCategory(category.id, archived: !category.archived) }, completion: { _ in })
    }
}
