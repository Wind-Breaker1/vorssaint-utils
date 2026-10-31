// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct WorkspaceLegacyTask: Decodable {
    let id: UUID
    let title: String
    let completed: Bool
    let createdAt: Date
    let projectID: UUID?
    let priority: Int?
    let dueDate: Date?
}

/// Compatibility reader for the retired local task module. It does not load notes.
final class LegacyTaskMigrationStore {
    static let shared = LegacyTaskMigrationStore()
    private(set) var legacyTaskSnapshot: [WorkspaceLegacyTask] = []
    var legacyTaskCount: Int { legacyTaskSnapshot.count }
    private struct Snapshot: Decodable { var tasks: [WorkspaceLegacyTask]? }
    private init() {
        guard !UserDefaults.standard.bool(forKey: "workspace.legacyTasksHandled") else { return }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vorssaint.utils/Workspace")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: folder.appendingPathComponent("workspace.json")),
           let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            legacyTaskSnapshot = snapshot.tasks ?? []
        }
        if legacyTaskSnapshot.isEmpty,
           let data = try? Data(contentsOf: folder.appendingPathComponent("quick-tasks.json")),
           let tasks = try? decoder.decode([WorkspaceLegacyTask].self, from: data) {
            legacyTaskSnapshot = tasks
        }
    }
    func clearLegacyTasks() { legacyTaskSnapshot.removeAll() }
}
