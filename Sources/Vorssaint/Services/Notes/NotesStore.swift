// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    private static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Vorssaint/Notes", isDirectory: true)
    static var root: URL { shared.repository.root }
    @Published private(set) var storagePath = UserDefaults.standard.string(forKey: "notes.storagePath") ?? NotesStore.defaultRoot.path
    private var scopedRoot: URL?
    /// Lightweight metadata and excerpts only. Read a document when opening it.
    @Published private(set) var notes: [NoteDocument] = []
    @Published private(set) var saveError: String?
    @Published private(set) var rebuilding = false
    @Published private(set) var movingStorage = false
    @Published private(set) var previousStorage = MigratedStorageSource.load(key: "notes.previousStorage")
    @Published private(set) var removingOldStorage = false
    private var refreshing = false
    private var refreshCompletions: [(Bool) -> Void] = []
    private var storageGeneration = 0
    private var noteGenerations: [UUID: Int] = [:]
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
                location = try MigratedStorageSource.resolveBookmark(bookmark, isStale: &stale)
            } catch {
                repository = NotesFileRepository(root: URL(fileURLWithPath: UserDefaults.standard.string(forKey: "notes.storagePath") ?? Self.defaultRoot.path))
                saveError = "无法访问已配置的笔记目录，请重新选择目录：" + error.localizedDescription
                return
            }
        }
        repository = NotesFileRepository(root:location)
        if location.startAccessingSecurityScopedResource() { scopedRoot = location }
        storagePath = location.path
        UserDefaults.standard.set(location.path, forKey: "notes.storagePath")
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

        } catch { saveError = error.localizedDescription }
    }
    /// Refresh on opening/activation, preserving unloaded cloud documents in the index.
    func refreshFromDisk(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !movingStorage, !rebuilding, let index else { completion(false); return }
        refreshCompletions.append(completion)
        guard !refreshing else { return }
        let request = NotesFlushRequest()
        NotificationCenter.default.post(name: .notesFlush, object: request)
        guard !request.failed else { finishRefresh(false); return }
        refreshing = true
        let generation = storageGeneration
        indexCoordinator.reconcile(repository: repository, index: index) { [weak self] result in
            guard let self else { return }
            guard generation == self.storageGeneration, !self.movingStorage else { self.finishRefresh(false); return }
            do {
                let pending = try result.get()
                try self.refresh()
                self.indexStatus = pending > 0 ? "正在下载 \(pending) 篇 iCloud 笔记，请稍后重新打开或刷新" : ""
                self.saveError = nil
                NotificationCenter.default.post(name: .notesIndexChanged, object: nil)
                // Do not create an empty note while existing cloud content is downloading.
                self.finishRefresh(pending == 0)
            } catch { self.saveError = error.localizedDescription; self.finishRefresh(false) }
        }
    }
    private func finishRefresh(_ success: Bool) {
        refreshing = false
        let completions = refreshCompletions
        refreshCompletions.removeAll()
        completions.forEach { $0(success) }
    }

    /// Copy and verify in the background; old files remain until explicit cleanup.
    func changeDirectory(to selected: URL) {
        guard !rebuilding, !movingStorage, !removingOldStorage else { return }
        let target = selected.resolvingSymlinksInPath().standardizedFileURL
        let source = repository.root.resolvingSymlinksInPath().standardizedFileURL
        guard target != source else { return }
        guard !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/") else {
            saveError = "新旧目录不能互相包含"; return
        }
        let request = NotesFlushRequest()
        NotificationCenter.default.post(name: .notesFlush, object: request)
        guard !request.failed else { return }
        let migrating = index != nil
        let indexRoot = repository.indexRoot
        let accessed = selected.startAccessingSecurityScopedResource()
        movingStorage = true
        storageGeneration += 1
        writeGeneration += 1; publishedGeneration = writeGeneration
        saveError = nil
        indexStatus = "正在迁移并校验笔记…"
        queue.async { [self] in
            let result = Result { () -> (NotesFileRepository, NotesIndex, Data, [NoteDocument], [String: [String]], MigratedStorageSource?) in
                let fm = FileManager.default
                guard try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).isEmpty else {
                    throw NSError(domain: "NotesStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择空目录，避免覆盖已有文件"])
                }
                let bookmark = try selected.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                let oldSource = migrating ? try MigratedStorageSource(url: source) : nil
                let prepared: (repository: NotesFileRepository, index: NotesIndex)
                if migrating { prepared = try NotesDirectoryMigration.prepare(from: source, to: target, indexRoot: indexRoot) }
                else {
                    let next = NotesFileRepository(root: target, indexRoot: indexRoot)
                    try next.prepare()
                    prepared = (next, try NotesIndex(url: next.indexURL))
                }
                return (prepared.repository, prepared.index, bookmark, try prepared.index.catalog(), try prepared.index.relationships(), oldSource)
            }
            DispatchQueue.main.async { [self] in
                switch result {
                case .failure(let error):
                    if accessed { selected.stopAccessingSecurityScopedResource() }
                    movingStorage = false
                    saveError = "目录迁移失败：" + error.localizedDescription
                case .success(let (next, nextIndex, bookmark, catalog, relationships, oldSource)):
                    do {
                        var sources = previousStorage
                        if let oldSource { sources.removeAll { $0.id == oldSource.id }; sources.append(oldSource) }
                        try MigratedStorageSource.save(sources, key: "notes.previousStorage")
                        UserDefaults.standard.set(bookmark, forKey: "notes.storageBookmark")
                        let previousScope = scopedRoot
                        repository = next; index = nextIndex
                        queryService.configure(url: next.indexURL)
                        scopedRoot = accessed ? selected : nil
                        storagePath = target.path
                        UserDefaults.standard.set(target.path, forKey: "notes.storagePath")
                        notes = catalog; links = relationships
                        noteGenerations.removeAll()
                        previousStorage = sources
                        previousScope?.stopAccessingSecurityScopedResource()
                        movingStorage = false
                        indexStatus = migrating ? "迁移完成，原文件已保留，可在下方手动删除" : "笔记保存目录已设置"
                        NotificationCenter.default.post(name: .notesIndexChanged, object: nil)
                    } catch {
                        if accessed { selected.stopAccessingSecurityScopedResource() }
                        movingStorage = false
                        saveError = "保存新目录配置失败，原文件已保留：" + error.localizedDescription
                    }
                }
            }
        }
    }
    func removeOldStorage(_ source: MigratedStorageSource) {
        guard !movingStorage, !removingOldStorage else { return }
        let active = repository.root
        removingOldStorage = true
        queue.async { [self] in
            let result = Result { () -> Void in
                let url = try source.resolve(excluding: active)
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                var sources = MigratedStorageSource.load(key: "notes.previousStorage")
                sources.removeAll { $0.id == source.id }
                try MigratedStorageSource.save(sources, key: "notes.previousStorage")
            }
            DispatchQueue.main.async { [self] in
                removingOldStorage = false
                switch result {
                case .success: previousStorage = MigratedStorageSource.load(key: "notes.previousStorage"); saveError = nil
                case .failure(let error): saveError = error.localizedDescription
                }
            }
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
        guard !movingStorage, let index else {
            saveError = movingStorage ? "正在迁移笔记，请稍后保存" : "笔记存储尚未就绪，无法保存"
            completion(false)
            return
        }
        let repository = repository
        writeGeneration += 1
        let generation = writeGeneration
        let storage = storageGeneration
        noteGenerations[note.id] = generation
        let write = {
            Result { () -> [String] in
                try repository.write(note)
                try index.transaction {
                    try index.update(note)
                    try index.recordSignature(repository.signature(repository.url(for: note)), id: note.id)
                }
                return try index.outgoing(note.id)
            }
        }
        let finish: (Result<[String], Error>) -> Void = { [self] result in
            if storage == storageGeneration, noteGenerations[note.id] == generation,
               case .success(let outgoing) = result {
                var summary = note
                summary.body = note.type == "markdown" ? String(note.body.prefix(160)) : ""
                notes.removeAll { $0.id == note.id }
                notes.append(summary)
                notes.sort { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
                links[note.id.uuidString.lowercased()] = outgoing
            }
            if storage == storageGeneration, generation >= publishedGeneration {
                publishedGeneration = generation
                switch result {
                case .success: saveError = nil
                case .failure(let error): saveError = error.localizedDescription
                }
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
        guard !movingStorage else { saveError = "正在迁移笔记，请稍后删除"; return }
        do {
            guard let metadata = notes.first(where:{$0.id == note.id}), let index else { return }
            let file = repository.url(for:metadata)
            let backup = file.deletingLastPathComponent().appendingPathComponent(".delete-\(UUID().uuidString).tmp")
            // Rename within the same directory instead of loading a large
            // Markdown/Excalidraw file into memory for rollback.
            try queue.sync {
                try repository.requireDownloaded(file)
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
            noteGenerations.removeValue(forKey: note.id)
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
        guard !rebuilding, !movingStorage else { return }
        let request = NotesFlushRequest()
        NotificationCenter.default.post(name:.notesFlush,object:request)
        guard !request.failed else { return }
        rebuilding = true; indexStatus = "正在重建索引…"
        let repository = self.repository
        queue.async { [self] in
            let result = Result { () -> Int in
                let worker = try NotesIndex(url:repository.indexURL)
                let files = try repository.files()
                for file in files { try repository.requireDownloaded(file) }
                try worker.transaction {
                    try worker.clear()
                    for file in files {
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
