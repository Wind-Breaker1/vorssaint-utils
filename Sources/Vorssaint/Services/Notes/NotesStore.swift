// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    private static let defaultRoot = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("com.vorssaint.utils/Notes",isDirectory:true)
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
    private let indexCoordinator = NotesIndexCoordinator()
    private var links: [String:[String]] = [:]
    private let queue = DispatchQueue(label:"com.vorssaint.notes.index",qos:.userInitiated)
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
            try repository.prepare()
            try repository.migrate(from:Self.defaultRoot.deletingLastPathComponent().appendingPathComponent("Workspace"))
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
        guard !request.failed, index != nil else { return }
        let fm = FileManager.default
        let accessed = selected.startAccessingSecurityScopedResource()
        var committed = false
        defer { if accessed && !committed { selected.stopAccessingSecurityScopedResource() } }
        do {
            guard try fm.contentsOfDirectory(at:target,includingPropertiesForKeys:nil).isEmpty else {
                throw NSError(domain:"NotesStorage",code:1,userInfo:[NSLocalizedDescriptionKey:"请选择空目录，避免覆盖已有文件"])
            }
            let bookmark = try selected.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            let prepared = try NotesDirectoryMigration.prepare(from:source,to:target)
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
                try fm.removeItem(at:source)
                indexStatus = "笔记目录已迁移，原目录已删除"
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
        notes = try index.catalog(); links = try index.relationships()
    }
    func outgoing(_ id: UUID) -> [String] { links[id.uuidString.lowercased()] ?? [] }
    func document(_ id: UUID) -> NoteDocument? {
        guard let metadata = notes.first(where:{$0.id == id}) else { return nil }
        do { return try repository.read(repository.url(for:metadata)) }
        catch { saveError = error.localizedDescription; return nil }
    }
    func addNote(_ title: String, type: String = "markdown") {
        let title = title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var note = NoteDocument(id:UUID(),title:title,body:"",updatedAt:Date())
        note.type = type == "excalidraw" ? "excalidraw" : "markdown"
        if note.type == "excalidraw" { note.body = #"{"type":"excalidraw","version":2,"elements":[],"appState":{},"files":{}}"# }
        persist(note)
    }
    func updateNote(_ note: NoteDocument) {
        guard notes.contains(where:{$0.id == note.id}) else { return }
        persist(note)
    }
    private func persist(_ note: NoteDocument) {
        guard index != nil else { saveError = "笔记存储尚未就绪，无法保存"; return }
        let repository = repository
        let index = index
        queue.async { [weak self] in
            guard let self, let index else { return }
            do {
                try repository.write(note)
                try index.transaction {
                    try index.update(note)
                    try index.recordSignature(repository.signature(repository.url(for: note)), id: note.id)
                }
                let outgoing = try index.outgoing(note.id)
                DispatchQueue.main.async {
                    var summary = note
                    summary.body = note.type == "markdown" ? String(note.body.prefix(160)) : ""
                    var catalog = self.notes.filter { $0.id != note.id }
                    catalog.append(summary)
                    catalog.sort { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
                    self.links[note.id.uuidString.lowercased()] = outgoing
                    self.notes = catalog
                    self.saveError = nil
                }
            } catch {
                DispatchQueue.main.async { self.saveError = error.localizedDescription }
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
            try FileManager.default.moveItem(at:file, to:backup)
            do {
                try index.transaction { try index.remove(note.id) }
                try FileManager.default.removeItem(at:backup)
            } catch {
                try? FileManager.default.moveItem(at:backup, to:file)
                throw error
            }
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
