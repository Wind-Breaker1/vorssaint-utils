import Foundation

/// Coordinates filesystem reconciliation without owning UI state.
final class NotesIndexCoordinator {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    func reconcile(repository: NotesFileRepository, index: NotesIndex, completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async {
            do {
                var pendingDownloads = 0
                try index.transaction {
                    let signatures = try index.signatures()
                    let files = try repository.files()
                    let present = Set(files.map { $0.deletingPathExtension().lastPathComponent.lowercased() })
                    for old in try index.catalog() where !present.contains(old.id.uuidString.lowercased()) {
                        try index.remove(old.id)
                    }
                    for file in files {
                        guard try repository.isDownloaded(file) else { pendingDownloads += 1; continue }
                        let signature = try repository.signature(file)
                        let id = file.deletingPathExtension().lastPathComponent.lowercased()
                        if signatures[id] != signature {
                            let document = try repository.read(file, loadAttachments: false)
                            try index.update(document)
                            try index.recordSignature(signature, id: document.id)
                        }
                    }
                }
                let pending = pendingDownloads
                DispatchQueue.main.async { completion(.success(pending)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
