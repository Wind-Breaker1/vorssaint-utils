import Foundation

/// Coordinates filesystem reconciliation without owning UI state.
final class NotesIndexCoordinator {
    private let queue = DispatchQueue(label: "com.vorssaint.notes.reconcile", qos: .userInitiated)

    func reconcile(repository: NotesFileRepository, index: NotesIndex, completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                try index.transaction {
                    let signatures = try index.signatures()
                    let files = try repository.files()
                    let present = Set(files.map { $0.deletingPathExtension().lastPathComponent.lowercased() })
                    for old in try index.catalog() where !present.contains(old.id.uuidString.lowercased()) {
                        try index.remove(old.id)
                    }
                    for file in files {
                        let signature = try repository.signature(file)
                        let id = file.deletingPathExtension().lastPathComponent.lowercased()
                        if signatures[id] != signature {
                            let document = try repository.read(file, loadAttachments: false)
                            try index.update(document)
                            try index.recordSignature(signature, id: document.id)
                        }
                    }
                }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }
}
