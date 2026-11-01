// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// Files are authoritative; the SQLite database can always be discarded.
struct NotesFileRepository {
    let root: URL
    let indexRoot: URL
    init(root: URL, indexRoot: URL? = nil) {
        self.root = root
        self.indexRoot = indexRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.vorssaint.utils")
            .appendingPathComponent("NotesIndexes", isDirectory: true)
    }
    var documents: URL { root.appendingPathComponent("笔记", isDirectory: true) }
    var drawings: URL { root.appendingPathComponent("画板", isDirectory: true) }
    var attachments: URL { root.appendingPathComponent("附件", isDirectory: true) }
    var indexURL: URL {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return indexRoot.appendingPathComponent(key).appendingPathExtension("sqlite")
    }
    private let separator = "\n---\n"
    func prepare() throws {
        for url in [root, documents, drawings, attachments, indexRoot] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    func url(for note: NoteDocument) -> URL {
        (note.type == "excalidraw" ? drawings : documents).appendingPathComponent(note.id.uuidString.lowercased()).appendingPathExtension(note.type == "excalidraw" ? "excalidraw" : "md")
    }
    func write(_ note: NoteDocument) throws {
        try requireDownloaded(url(for: note))
        var metadata = note
        metadata.body = ""
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        if note.type == "excalidraw" {
            guard var scene = try JSONSerialization.jsonObject(with: Data(note.body.utf8)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            if var files = scene["files"] as? [String:[String:Any]] {
                for (key,var image) in files {
                    if let value = image["dataURL"] as? String, value.hasPrefix("data:"), let comma = value.firstIndex(of:",") {
                        let header = String(value[value.index(value.startIndex,offsetBy:5)..<comma])
                        let mime = header.components(separatedBy:";")[0]
                        let raw = String(value[value.index(after:comma)...])
                        let bytes = header.contains(";base64") ? Data(base64Encoded:raw) : raw.removingPercentEncoding.map { Data($0.utf8) }
                        guard let bytes else { throw CocoaError(.fileReadCorruptFile) }
                        let digest = SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
                        let ext = ["image/png":"png","image/jpeg":"jpg","image/svg+xml":"svg","image/webp":"webp","image/gif":"gif"][mime] ?? "bin"
                        let filename = digest + "." + ext
                        let target = attachments.appendingPathComponent(filename)
                        try requireDownloaded(target)
                        if !FileManager.default.fileExists(atPath:target.path) { try bytes.write(to:target,options:.atomic) }
                        image["dataURL"] = "assets/" + filename
                        image["mimeType"] = mime
                        files[key] = image
                    }
                }
                scene["files"] = files
            }
            scene["vorssaint"] = try JSONSerialization.jsonObject(with: encoder.encode(metadata))
            data = try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys])
        } else {
            let header = String(decoding: try encoder.encode(metadata), as: UTF8.self)
            data = Data(("---\n" + header + separator + note.body).utf8)
        }
        try data.write(to: url(for: note), options: .atomic)
    }
    func read(_ url: URL, loadAttachments: Bool = true) throws -> NoteDocument {
        try requireDownloaded(url)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var note: NoteDocument
        if url.pathExtension == "excalidraw" {
            guard var scene = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let metadata = scene.removeValue(forKey: "vorssaint") else { throw CocoaError(.fileReadCorruptFile) }
            note = try decoder.decode(NoteDocument.self, from: JSONSerialization.data(withJSONObject: metadata))
            note.type = "excalidraw"
            if loadAttachments, var files = scene["files"] as? [String:[String:Any]] {
                for (key,var image) in files {
                    if let value = image["dataURL"] as? String, value.hasPrefix("assets/") {
                        let filename = String(value.dropFirst(7))
                        guard !filename.isEmpty, filename == (filename as NSString).lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
                        let attachment = attachments.appendingPathComponent(filename)
                        try requireDownloaded(attachment)
                        let bytes = try Data(contentsOf: attachment)
                        image["dataURL"] = "data:" + (image["mimeType"] as? String ?? "application/octet-stream") + ";base64," + bytes.base64EncodedString()
                        files[key] = image
                    }
                }
                scene["files"] = files
            }
            note.body = String(decoding: try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys]), as: UTF8.self)
        } else {
            let text = String(decoding: data, as: UTF8.self)
            guard text.hasPrefix("---\n"), let range = text.range(of: separator, range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else { throw CocoaError(.fileReadCorruptFile) }
            note = try decoder.decode(NoteDocument.self, from: Data(text[text.index(text.startIndex, offsetBy: 4)..<range.lowerBound].utf8))
            note.type = "markdown"
            note.body = String(text[range.upperBound...])
        }
        guard url.deletingPathExtension().lastPathComponent.lowercased() == note.id.uuidString.lowercased() else { throw CocoaError(.fileReadCorruptFile) }
        return note
    }
    func signature(_ url:URL) throws -> String {
        let values = try url.resourceValues(forKeys:[.contentModificationDateKey,.fileSizeKey])
        return "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
    }
    /// Include cloud placeholders in the inventory so eviction is never treated as deletion.
    func files() throws -> [URL] {
        let entries = try [documents, drawings].flatMap {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
        return Array(Set(entries.map(Self.materializedURL).filter { ["md", "excalidraw"].contains($0.pathExtension) }))
            .sorted { $0.path < $1.path }
    }
    static func materializedURL(_ file: URL) -> URL {
        let name = file.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return file }
        return file.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
    }
    func isDownloaded(_ file: URL) throws -> Bool {
        let fm = FileManager.default
        let placeholder = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".icloud")
        if fm.fileExists(atPath: placeholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: file)
            return false
        }
        guard fm.fileExists(atPath: file.path) else { return true }
        let values = try file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try fm.startDownloadingUbiquitousItem(at: file)
            return false
        }
        return true
    }
    func requireDownloaded(_ file: URL) throws {
        guard try isDownloaded(file) else {
            throw NSError(domain: "NotesStorage", code: 2, userInfo: [NSLocalizedDescriptionKey: "iCloud 文件正在下载，请稍后重试：" + file.lastPathComponent])
        }
        if !(NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []).isEmpty {
            throw NSError(domain: "NotesStorage", code: 3, userInfo: [NSLocalizedDescriptionKey: "文件存在 iCloud 冲突，请先处理文件版本：" + file.lastPathComponent])
        }
    }
}
