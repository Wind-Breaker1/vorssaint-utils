// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Handles filesystem work only. NotesStore owns switching preferences and
/// remembering the source for optional, explicit cleanup in Settings.
enum NotesDirectoryMigration {
    static func prepare(from source: URL, to target: URL, indexRoot: URL? = nil) throws -> (repository: NotesFileRepository, index: NotesIndex) {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let target = target.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        guard try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).isEmpty else {
            throw NSError(domain: "NotesStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择空目录，避免覆盖已有文件"])
        }
        let original = NotesFileRepository(root: source, indexRoot: indexRoot)
        // Materialize all cloud files before copying the source.
        if let walker = fm.enumerator(at: source, includingPropertiesForKeys: nil) {
            for case let file as URL in walker {
                try original.requireDownloaded(NotesFileRepository.materializedURL(file))
            }
        }
        var succeeded = false
        defer {
            if !succeeded {
                // Target was empty and is exclusively owned by this operation.
                // Keep the user-selected root, remove only our migrated contents.
                for item in (try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: item)
                }
            }
        }
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            where !["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"].contains(item.lastPathComponent) {
            try fm.copyItem(at: item, to: target.appendingPathComponent(item.lastPathComponent))
            let enumerator = fm.enumerator(at: item, includingPropertiesForKeys: [.isRegularFileKey])
            // Walk lazily rather than collecting every attachment path in memory.
            try verify(item, source: source, target: target)
            while let entry = enumerator?.nextObject() as? URL { try verify(entry, source: source, target: target) }
        }
        let repository = NotesFileRepository(root: target, indexRoot: indexRoot)
        try repository.prepare()
        let database = try NotesIndex(url: repository.indexURL)
        try database.transaction {
            try database.clear()
            for file in try repository.files() {
                let note = try repository.read(file, loadAttachments: false)
                try database.update(note)
                try database.recordSignature(repository.signature(file), id: note.id)
            }
        }
        succeeded = true
        return (repository, database)
    }

    private static func verify(_ file: URL, source: URL, target: URL) throws {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return }
        let file = file.resolvingSymlinksInPath().standardizedFileURL
        let relative = file.pathComponents.dropFirst(source.pathComponents.count).joined(separator: "/")
        let original = try FileHandle(forReadingFrom: file)
        defer { try? original.close() }
        let copy = try FileHandle(forReadingFrom: target.appendingPathComponent(relative))
        defer { try? copy.close() }
        // Bounded memory even for large videos and PDFs.
        while true {
            let left = try original.read(upToCount: 1_048_576) ?? Data()
            let right = try copy.read(upToCount: 1_048_576) ?? Data()
            guard left == right else { throw CocoaError(.fileReadCorruptFile) }
            if left.isEmpty { return }
        }
    }
}
