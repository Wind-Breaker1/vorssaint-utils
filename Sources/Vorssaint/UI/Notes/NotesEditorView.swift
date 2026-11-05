// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

struct NotesEditorView: View {
    let note: NoteDocument
    @ObservedObject private var store = NotesStore.shared
    var body: some View {
        NoteWebEditor(note: note)
            .allowsHitTesting(!store.movingStorage)
            .overlay {
                if store.movingStorage {
                    ZStack {
                        Color.black.opacity(0.35)
                        ProgressView("正在迁移笔记…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
    }
}
private struct NoteWebEditor: NSViewRepresentable {
    let note: NoteDocument
    func makeCoordinator() -> Coordinator { Coordinator(note: note) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "notes")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "noteClipboard")
        config.setURLSchemeHandler(NoteAssets(), forURLScheme: "note-asset")
        let web = WKWebView(frame: .zero, configuration: config)
        web.appearance = NSAppearance(named: .darkAqua)
        web.underPageBackgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        web.alphaValue = 0
        web.navigationDelegate = context.coordinator; context.coordinator.web = web
        if let root = Bundle.main.resourceURL?.appendingPathComponent("NoteWeb") { web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root) }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        if NotesStore.shared.movingStorage { web.window?.makeFirstResponder(nil) }
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.save(); web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "notes"); web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "noteClipboard", contentWorld: .page)
        web.evaluateJavaScript("window.notesApp?.dispose()", completionHandler: nil)
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        var note: NoteDocument
        weak var web: WKWebView?
        private var saveWork: DispatchWorkItem?
        private var dirty = false
        private var saveGeneration = 0
        private var loadedSignature: String?
        private var loadGeneration = 0
        init(note: NoteDocument) {
            self.note = note
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(openDocument(_:)), name: .notesOpenDocument, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(flush(_:)), name: .notesFlush, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(indexChanged), name: .notesIndexChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(flush(_:)), name: NSApplication.willTerminateNotification, object: nil)
        }
        deinit { saveWork?.cancel(); NotificationCenter.default.removeObserver(self) }
        @objc private func openDocument(_ notification: Notification) {
            guard let target = notification.object as? NoteDocument else { return }
            save()
            guard !dirty else { return }
            guard let document = NotesStore.shared.document(target.id) else { return }
            note = document
            if ready { load() }
        }
        private var ready = false
        @objc private func activated() { NotesStore.shared.refreshFromDisk() }
        @objc private func indexChanged() {
            guard ready, !dirty else { return }
            let store = NotesStore.shared
            call("window.notesApp.catalog(notes)", ["notes": catalog])
            if !store.notes.contains(where: { $0.id == note.id }) {
                if let next = store.notes.first, let document = store.document(next.id) { note = document; load() }
                else { call("window.notesApp.clear()") }
                return
            }
            guard store.documentSignature(note) != loadedSignature else { return }
            guard let document = store.document(note.id) else { return }
            let changed = document.title != note.title || document.body != note.body || document.tags != note.tags || document.properties != note.properties || document.type != note.type
            note = document
            if changed { load() }
        }
        @objc private func flush(_ notification: Notification) {
            save()
            if dirty { (notification.object as? NotesFlushRequest)?.failed = true }
        }
        func save(wait: Bool = true) {
            saveWork?.cancel(); saveWork = nil
            guard dirty else { return }
            saveGeneration += 1
            let generation = saveGeneration
            let savedID = note.id.uuidString
            let savedFiles = note.type == "excalidraw" ? (((try? JSONSerialization.jsonObject(with: Data(note.body.utf8))) as? [String: Any])?["files"] as? [String: Any] ?? [:]) : [:]
            note.updatedAt = Date()
            NotesStore.shared.updateNote(note, wait: wait) { [weak self] success in
                guard let self, generation == self.saveGeneration else { return }
                if success {
                    self.loadedSignature = NotesStore.shared.documentSignature(self.note)
                    self.call("window.notesApp.saved(id, files)", ["id": savedID, "files": Array(savedFiles.keys)])
                    self.dirty = false
                    self.call("window.notesApp.status(text)", ["text": "已保存"])
                } else {
                    self.call("window.notesApp.status(text)", ["text": NotesStore.shared.saveError ?? "保存失败"])
                }
            }
        }
        func scheduleSave() {
            dirty = true; saveGeneration += 1; saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.save(wait: false) }
            saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now()+0.35, execute: work)
        }
        func call(_ script: String, _ arguments: [String: Any] = [:]) {
            guard let web else { return }
            Task { @MainActor in do { _ = try await web.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page) } catch { NSLog("Note editor: %@", error.localizedDescription) } }
        }
        private var catalog: [[String: Any]] {
            NotesStore.shared.notes.map { ["id": $0.id.uuidString, "title": $0.title, "body": $0.body, "type": $0.type, "tags": $0.tags, "outgoingIDs": NotesStore.shared.outgoing($0.id)] }
        }
        func load(heading: String = "", editing: Bool = false) {
            loadedSignature = NotesStore.shared.documentSignature(note)
            loadGeneration += 1
            let generation = loadGeneration
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(note), let value = try? JSONSerialization.jsonObject(with: data) else { return }
            let arguments: [String: Any] = ["note": value, "heading": heading, "notes": catalog, "editing": editing]
            Task { @MainActor [weak self] in
                guard let self, generation == self.loadGeneration, let web = self.web else { return }
                do {
                    _ = try await web.callAsyncJavaScript("window.notesApp.load(note, notes, heading, editing); requestAnimationFrame(() => window.webkit.messageHandlers.notes.postMessage({type: 'presented'}))", arguments: arguments, in: nil, contentWorld: .page)
                } catch { NSLog("Note editor: %@", error.localizedDescription) }
            }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
            guard message.name == "noteClipboard", message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.isFileURL == true,
                  let body = message.body as? [String: Any] else {
                replyHandler(nil, "无法访问剪贴板")
                return
            }
            switch body["action"] as? String {
            case "read":
                replyHandler(NSPasteboard.general.string(forType: .string) ?? "", nil)
            case "write":
                guard let text = body["text"] as? String else {
                    replyHandler(nil, "剪贴板内容无效")
                    return
                }
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(text, forType: .string) { replyHandler(true, nil) }
                else { replyHandler(nil, "无法写入剪贴板") }
            default:
                replyHandler(nil, "不支持的剪贴板操作")
            }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !NotesStore.shared.movingStorage, message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready": ready = true; load()
            case "searchNotes":
                guard let query = body["query"] as? String, let request = body["request"] as? String else { return }
                NotesStore.shared.search(query) { [weak self] result in
                    switch result {
                    case .success(let ids): self?.call("window.notesApp.searchResult(request, ids)", ["request":request,"ids":ids])
                    case .failure(let error): self?.call("window.notesApp.searchResult(request, null)", ["request":request]); self?.status(error)
                    }
                }
            case "presented": web?.alphaValue = 1
            case "deleteNote":
                save()
                guard !dirty else { return }
                let store = NotesStore.shared
                store.removeNote(note)
                if let error = store.saveError { call("window.notesApp.status(text)", ["text": error]); return }
                if let next = store.notes.first, let document = store.document(next.id) { note = document; load() }
                else { call("window.notesApp.clear()") }
            case "createNote":
                save()
                guard !dirty else { return }
                let store = NotesStore.shared
                let kind = body["noteType"] as? String == "excalidraw" ? "excalidraw" : "markdown"
                guard let created = store.addNote(kind == "excalidraw" ? "未命名画板" : "未命名笔记", type: kind) else {
                    call("window.notesApp.status(text)", ["text": store.saveError ?? "新建笔记失败"])
                    return
                }
                note = created
                load(editing: true)
                if let error = store.saveError { call("window.notesApp.status(text)", ["text": error]) }
            case "change":
                guard let value = body["note"] as? [String: Any], let id = value["id"] as? String, UUID(uuidString: id) == note.id, let title = value["title"] as? String, let text = value["body"] as? String else { return }
                note.title = title; note.body = text; note.tags = value["tags"] as? [String] ?? []
                if let properties = value["properties"], let data = try? JSONSerialization.data(withJSONObject: properties), let values = try? JSONDecoder().decode([NoteProperty].self, from: data) { note.properties = values }
                scheduleSave()
            case "attachments":
                guard let request = body["request"] as? String, let files = body["files"] as? [[String: Any]] else { return }
                do {
                    let text = try files.map { file -> String in
                        guard let name = file["name"] as? String, let raw = file["data"] as? String, let data = Data(base64Encoded: raw), data.count < 100_000_000 else { throw CocoaError(.fileReadTooLarge) }
                        return try attachment(data, name)
                    }.joined(separator: "\n")
                    call("window.notesApp.attachmentResult(id, text)", ["id": request, "text": text])
                } catch { call("window.notesApp.attachmentResult(id, '', error)", ["id": request, "error": error.localizedDescription]) }
            case "openNote": if let id = body["id"] as? String { openNote(id) }
            case "openLink": if let value = body["url"] as? String {
                if value.hasPrefix("station-note:") { openNote(String(value.dropFirst(13))) }
                else if let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                else if let url = URL(string: value), url.scheme == "note-asset", let local = NoteAssets.localURL(url) { NSWorkspace.shared.open(local) }
            }
            default: break
            }
        }
        func status(_ error: Error) { call("window.notesApp.status(text)", ["text": error.localizedDescription]) }
        func openNote(_ identifier: String) {
            let parts = identifier.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, let id = UUID(uuidString: String(first)) else { return }
            save()
            guard !dirty else { return }
            guard let target = NotesStore.shared.notes.first(where: { $0.id == id }) else { call("window.notesApp.status(text)", ["text": "目标笔记不存在或已删除"]); return }
            guard let document = NotesStore.shared.document(target.id) else { return }; note = document; load(heading: parts.count == 2 ? String(parts[1]) : "")
        }
        func attachment(_ data: Data, _ name: String) throws -> String {
            let ext = (name as NSString).pathExtension.lowercased()
            guard let type = UTType(filenameExtension: ext), [.image, .pdf, .audio, .movie].contains(where: { type.conforms(to: $0) }) else { throw CocoaError(.fileReadUnsupportedScheme) }
            try FileManager.default.createDirectory(at: NoteAssets.root, withIntermediateDirectories: true)
            let filename = UUID().uuidString+"."+ext
            try data.write(to: NoteAssets.root.appendingPathComponent(filename), options: .atomic)
            let label = name.replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
            return "\(type.conforms(to: .image) ? "!" : "")[\(label)](assets/\(filename))"
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(action.request.url?.isFileURL == true && action.navigationType != .linkActivated ? .allow : .cancel) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    }
}
private final class NoteAssets: NSObject, WKURLSchemeHandler {
    static var root: URL { NotesStore.root.appendingPathComponent("附件") }
    static func localURL(_ url: URL) -> URL? {
        guard url.host == "local" else { return nil }
        let file = root.appendingPathComponent(url.lastPathComponent).resolvingSymlinksInPath()
        return file.deletingLastPathComponent() == root.resolvingSymlinksInPath() ? file : nil
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.localURL(url), let data = try? Data(contentsOf: file) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        task.didReceive(URLResponse(url: url, mimeType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream", expectedContentLength: data.count, textEncodingName: nil)); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
