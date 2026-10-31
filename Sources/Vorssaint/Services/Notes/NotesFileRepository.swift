// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// Files are authoritative; the SQLite database can always be discarded.
struct NotesFileRepository {
    let root: URL
    var documents: URL { root.appendingPathComponent("笔记", isDirectory: true) }
    var drawings: URL { root.appendingPathComponent("画板", isDirectory: true) }
    var attachments: URL { root.appendingPathComponent("附件", isDirectory: true) }
    var indexURL: URL { root.appendingPathComponent("index.sqlite") }
    private let separator = "\n---\n"
    func prepare() throws {
        for url in [root, documents, drawings, attachments] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    func url(for note: NoteDocument) -> URL {
        (note.type == "excalidraw" ? drawings : documents).appendingPathComponent(note.id.uuidString.lowercased()).appendingPathExtension(note.type == "excalidraw" ? "excalidraw" : "md")
    }
    func write(_ note: NoteDocument) throws {
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
                        let bytes = try Data(contentsOf:attachments.appendingPathComponent(filename))
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
    func files() throws -> [URL] {
        try [documents,drawings].flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { ["md", "excalidraw"].contains($0.pathExtension) }.sorted { $0.path < $1.path }
    }
    func migrate(from legacy: URL) throws {
        let marker = root.appendingPathComponent(".migration-complete")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        struct Snapshot: Decodable { var notes: [NoteDocument]? }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let source = ["notes.json", "workspace.json"].map { legacy.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        if let source {
            let data = try Data(contentsOf: source)
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            let backup = root.appendingPathComponent("Migration", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try data.write(to: backup.appendingPathComponent(source.lastPathComponent), options: .atomic)
            for note in snapshot.notes ?? [] {
                if !FileManager.default.fileExists(atPath: url(for: note).path) { try write(note) }
                _ = try read(url(for: note))
            }
        }
        let oldAttachments = legacy.appendingPathComponent("Attachments")
        if FileManager.default.fileExists(atPath: oldAttachments.path) {
            for file in try FileManager.default.contentsOfDirectory(at: oldAttachments, includingPropertiesForKeys: nil) {
                let target = attachments.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: file, to: target) }
            }
        }
        try Data("1".utf8).write(to: marker, options: .atomic)
    }
}
