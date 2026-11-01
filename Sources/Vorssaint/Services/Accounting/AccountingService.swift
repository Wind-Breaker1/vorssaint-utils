// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

/// Owns presentation state; all database work runs on one serial queue.
/// The service is lazy and may be discarded when the accounting feature is
/// disabled. The SQLite connection is also released whenever the ledger view
/// is no longer presented.
final class AccountingService: ObservableObject {
    private static var instance: AccountingService?
    static var shared: AccountingService {
        if let instance { return instance }
        let service = AccountingService(); instance = service; return service
    }
    static func stopIfLoaded() {
        instance?.generation += 1
        instance?.queue.async { [weak service = instance] in service?.repository = nil }
        instance = nil
    }
    @Published var showingLedger = false {
        didSet {
            if !showingLedger { releaseDatabase() }
        }
    }
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

    private init() { refresh() }
    private func database() throws -> AccountingRepository {
        if let repository { return repository }
        guard let root = PrivateFileStore.containerURL?.appendingPathComponent("Accounting", isDirectory: true),
              PrivateFileStore.createDirectory(at: root) else {
            throw NSError(domain: "Accounting", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建记账存储目录"])
        }
        let repository = try AccountingRepository(url: root.appendingPathComponent("ledger.sqlite"))
        self.repository = repository
        return repository
    }
    private func releaseDatabase() {
        generation += 1
        queue.async { [weak self] in self?.repository = nil }
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
            let result = Result { try self.database().snapshot(month: month, limit: limit, kind: kind, category: category) }
            DispatchQueue.main.async {
                guard token == self.generation else { return }
                self.loading = false
                switch result {
                case .success(let snapshot): self.snapshot = snapshot; self.errorMessage = nil
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    private func write(_ operation: @escaping (AccountingRepository) throws -> Void, completion: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try operation(self.database()) }
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
