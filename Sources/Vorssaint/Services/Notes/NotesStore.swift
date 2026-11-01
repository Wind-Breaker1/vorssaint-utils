// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    private static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Vorssaint/Notes", isDirectory: true)
    static var root: URL { shared.repository.root }
    @Published private(set) var storagePath = ""
    private var scopedRoot: URL?
    /// Lightweight metadata and excerpts only. Read a document when opening it.
    @Published private(set) var notes: [NoteDocument] = []
    @Published private(set) var saveError: String?
    @Published private(set) var rebuilding = false
    @Published private(set) var indexStatus = ""
    private var repository: NotesFileRepository
    private var index: NotesIndex?
    private let queryService = NotesIndexQueryService()
    private lazy var indexCoordinator = NotesIndexCoordinator(queue: queue)
    private var links: [String:[String]] = [:]
    private let queue = DispatchQueue(label:"com.vorssaint.notes.index",qos:.userInitiated)
    private var writeGeneration = 0
    private var publishedGeneration = 0
    private init() {
        var location = Self.defaultRoot
        if let bookmark = UserDefaults.standard.data(forKey:"notes.storageBookmark") {
            var stale = false
            do {
                location = try URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
            } catch {
                repository = NotesFileRepository(root:Self.defaultRoot)
                saveError = "无法访问已配置的笔记目录，请重新选择目录：" + error.localizedDescription
                return
            }
        }
        repository = NotesFileRepository(root:location)
        if location.startAccessingSecurityScopedResource() { scopedRoot = location }
        storagePath = location.path
        do {
            // Only create our subdirectories; never fabricate an unavailable iCloud Drive.
            if UserDefaults.standard.data(forKey: "notes.storageBookmark") == nil {
                let drive = Self.defaultRoot.deletingLastPathComponent().deletingLastPathComponent()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw NSError(domain: "NotesStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "iCloud Drive 不可用，请启用 iCloud Drive 或选择其他保存目录"])
                }
            }
            try repository.prepare()
            let index = try NotesIndex(url:repository.indexURL)
            self.index = index
            queryService.configure(url: repository.indexURL)
            try refresh()
            // The existing index makes the UI available immediately. Reconcile
            // external file changes off the main thread after first render.
            indexCoordinator.reconcile(repository: repository, index: index) { [weak self] error in
                if let error { self?.saveError = error.localizedDescription }
                else { try? self?.refresh() }
            }
        } catch { saveError = error.localizedDescription }
    }
    /// Copy and verify before switching. Never merge with an existing directory.
    func changeDirectory(to selected: URL) {
        guard !rebuilding else { return }
        let target = selected.resolvingSymlinksInPath().standardizedFileURL
        let source = repository.root.resolvingSymlinksInPath().standardizedFileURL
        guard target != source else { return }
        guard !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/") else {
            saveError = "新旧目录不能互相包含"; return
        }
        let request = NotesFlushRequest()
        NotificationCenter.default.post(name:.notesFlush,object:request)
        guard !request.failed else { return }
        queue.sync {}
        writeGeneration += 1; publishedGeneration = writeGeneration
        let migrating = index != nil
        let fm = FileManager.default
        let accessed = selected.startAccessingSecurityScopedResource()
        var committed = false
        defer { if accessed && !committed { selected.stopAccessingSecurityScopedResource() } }
        do {
            guard try fm.contentsOfDirectory(at:target,includingPropertiesForKeys:nil).isEmpty else {
                throw NSError(domain:"NotesStorage",code:1,userInfo:[NSLocalizedDescriptionKey:"请选择空目录，避免覆盖已有文件"])
            }
            let bookmark = try selected.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            let prepared: (repository: NotesFileRepository, index: NotesIndex)
            if index != nil {
                prepared = try NotesDirectoryMigration.prepare(from: source, to: target)
            } else {
                let next = NotesFileRepository(root: target)
                try next.prepare()
                prepared = (next, try NotesIndex(url: next.indexURL))
            }
            let next = prepared.repository
            let nextIndex = prepared.index
            UserDefaults.standard.set(bookmark,forKey:"notes.storageBookmark")
            index = nextIndex
            repository = next
            queryService.configure(url: next.indexURL)
            let previousScope = scopedRoot
            defer { previousScope?.stopAccessingSecurityScopedResource() }
            scopedRoot = accessed ? selected : nil
            committed = true
            storagePath = target.path
            try refresh()
            NotificationCenter.default.post(name:.notesIndexChanged,object:nil)
            do {
                if migrating { try fm.removeItem(at:source) }
                indexStatus = migrating ? "笔记目录已迁移，原目录已删除" : "笔记保存目录已设置"
                saveError = nil
            } catch {
                saveError = "已切换至新目录，但原目录未能删除：" + error.localizedDescription
            }
        } catch {
            saveError = "目录迁移失败：" + error.localizedDescription
        }
    }
    private func refresh() throws {
        guard let index else { return }
        let snapshot = try queue.sync { (try index.catalog(), try index.relationships()) }
        notes = snapshot.0; links = snapshot.1
    }
    func outgoing(_ id: UUID) -> [String] { links[id.uuidString.lowercased()] ?? [] }
    func document(_ id: UUID) -> NoteDocument? {
        guard let metadata = notes.first(where:{$0.id == id}) else { return nil }
        do { return try queue.sync { try repository.read(repository.url(for:metadata)) } }
        catch { saveError = error.localizedDescription; return nil }
    }
    @discardableResult
    func addNote(_ title: String, type: String = "markdown") -> NoteDocument? {
        let title = title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var note = NoteDocument(id:UUID(),title:title,body:"",updatedAt:Date())
        note.type = type == "excalidraw" ? "excalidraw" : "markdown"
        if note.type == "excalidraw" { note.body = #"{"type":"excalidraw","version":2,"elements":[],"appState":{},"files":{}}"# }
        var saved = false
        persist(note, wait: true) { saved = $0 }
        return saved ? note : nil
    }
    func updateNote(_ note: NoteDocument, wait: Bool = true, completion: @escaping (Bool) -> Void) {
        guard notes.contains(where:{$0.id == note.id}) else {
            saveError = "笔记不存在，无法保存"
            completion(false)
            return
        }
        persist(note, wait: wait, completion: completion)
    }
    private func persist(_ note: NoteDocument, wait: Bool, completion: @escaping (Bool) -> Void) {
        guard let index else {
            saveError = "笔记存储尚未就绪，无法保存"
            completion(false)
            return
        }
        let repository = repository
        writeGeneration += 1
        let generation = writeGeneration
        let write = {
            Result { () -> Void in
                try repository.write(note)
                try index.transaction {
                    try index.update(note)
                    try index.recordSignature(repository.signature(repository.url(for: note)), id: note.id)
                }
            }
        }
        let finish: (Result<Void, Error>) -> Void = { [self] result in
            // A synchronous flush may already have published a newer write.
            if generation >= publishedGeneration {
                publishedGeneration = generation
                do { try result.get(); try refresh(); saveError = nil }
                catch { saveError = error.localizedDescription; completion(false); return }
            }
            completion((try? result.get()) != nil)
        }
        if wait { finish(queue.sync(execute: write)) }
        else {
            queue.async {
                let result = write()
                DispatchQueue.main.async { finish(result) }
            }
        }
    }
    func removeNote(_ note: NoteDocument) {
        do {
            guard let metadata = notes.first(where:{$0.id == note.id}), let index else { return }
            let file = repository.url(for:metadata)
            let backup = file.deletingLastPathComponent().appendingPathComponent(".delete-\(UUID().uuidString).tmp")
            // Rename within the same directory instead of loading a large
            // Markdown/Excalidraw file into memory for rollback.
            try queue.sync {
                try FileManager.default.moveItem(at:file, to:backup)
                do {
                    try index.transaction { try index.remove(note.id) }
                    try FileManager.default.removeItem(at:backup)
                } catch {
                    try? FileManager.default.moveItem(at:backup, to:file)
                    throw error
                }
            }
            // Invalidate queued UI publications from saves preceding deletion.
            writeGeneration += 1; publishedGeneration = writeGeneration
            links.removeValue(forKey:note.id.uuidString.lowercased())
            notes.removeAll { $0.id == note.id }
            saveError = nil
        } catch { saveError = error.localizedDescription }
    }
    func search(_ query:String, completion:@escaping(Result<[String],Error>)->Void) {
        queryService.search(query, completion: completion)
    }

    func releaseSearchResources() {
        queryService.release()
    }
    func rebuildIndex() {
        guard !rebuilding else { return }
        let request = NotesFlushRequest()
        NotificationCenter.default.post(name:.notesFlush,object:request)
        guard !request.failed else { return }
        rebuilding = true; indexStatus = "正在重建索引…"
        let repository = self.repository
        queue.async { [self] in
            let result = Result { () -> Int in
                let worker = try NotesIndex(url:repository.indexURL)
                try worker.transaction {
                    try worker.clear()
                    for file in try repository.files() {
                        let note = try repository.read(file,loadAttachments:false)
                        try worker.update(note)
                        try worker.recordSignature(repository.signature(file),id:note.id)
                    }
                    try worker.optimizeSearch()
                }
                return try worker.catalog().count
            }
            DispatchQueue.main.async { [self] in
                rebuilding = false
                switch result {
                case .success(let count):
                    do { try refresh(); indexStatus = "已重建 \(count) 篇笔记的索引"; saveError = nil
                        NotificationCenter.default.post(name:.notesIndexChanged,object:nil)
                    } catch { saveError = error.localizedDescription; indexStatus = "重建后读取失败" }
                case .failure(let error): saveError = error.localizedDescription; indexStatus = "重建失败，原索引已保留"
                }
            }
        }
    }
}

extension Notification.Name { static let notesIndexChanged = Notification.Name("vorssaint.notes.indexChanged") }
