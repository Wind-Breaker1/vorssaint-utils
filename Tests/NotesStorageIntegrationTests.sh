#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
notes_test_dir=$(mktemp -d)
trap 'rm -rf "$notes_test_dir"' EXIT
cat > "$notes_test_dir/main.swift" <<'SWIFT'
import Foundation
let root = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Notes")
let repository = NotesFileRepository(root:root)
try repository.prepare()
let id = UUID(), drawingID = UUID()
var note = NoteDocument(id:id,title:"中文搜索 migration",body:"# 标题\n\n跨行内容\n---\n[[画板|\(drawingID.uuidString)]]\nsearchable long phrase",updatedAt:Date(timeIntervalSince1970:1700000000))
note.tags = ["学习"]
note.properties = [NoteProperty(name:"状态",kind:"文本",value:"完成")]
var drawing = NoteDocument(id:drawingID,title:"画板",body:#"{"elements":[{"type":"text","text":"画板文字 searchable"}],"files":{"image":{"dataURL":"data:image/png;base64,test"}},"appState":{}}"#,updatedAt:note.updatedAt)
drawing.type = "excalidraw"
try repository.write(note)
try repository.write(drawing)
try Data("attachment".utf8).write(to:repository.attachments.appendingPathComponent("image.png"))
assert(try repository.files().count == 2)
assert(try repository.read(repository.url(for:note)) == note)
let readDrawing = try repository.read(repository.url(for:drawing))
assert(readDrawing.title == drawing.title)
let storedScene = try JSONSerialization.jsonObject(with:Data(contentsOf:repository.url(for:drawing))) as! [String:Any]
let storedFiles = storedScene["files"] as! [String:[String:Any]]
assert((storedFiles["image"]?["dataURL"] as? String)?.hasPrefix("assets/") == true)
let scene = try JSONSerialization.jsonObject(with:Data(readDrawing.body.utf8)) as! [String:Any]
assert(scene["files"] != nil && scene["vorssaint"] == nil)
assert(FileManager.default.fileExists(atPath:repository.attachments.appendingPathComponent("image.png").path))
note.body += "\nmodified after initial write"
try repository.write(note)
assert(try repository.read(repository.url(for:note)).body == note.body)
// Current files require the complete metadata format; no legacy defaults.
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let encoded = try encoder.encode(note)
assert(try decoder.decode(NoteDocument.self, from: encoded) == note)
for field in ["tags", "properties", "type"] {
 var incomplete = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
 incomplete.removeValue(forKey: field)
 let data = try JSONSerialization.data(withJSONObject: incomplete)
 do {
  _ = try decoder.decode(NoteDocument.self, from: data)
  assertionFailure("incomplete legacy metadata must not be accepted")
 } catch {}
}
let index = try NotesIndex(url:repository.indexURL)
try index.transaction {
 try index.clear()
 for file in try repository.files() { try index.update(repository.read(file)) }
}
assert(try index.catalog().count == 2)
assert(try index.catalog().first(where:{$0.id == drawingID})!.body.isEmpty)
assert(try index.search("中文").contains(id.uuidString.lowercased()))
assert(try index.search("migration").contains(id.uuidString.lowercased()))
assert(try index.search("searchable").count == 2)
assert(try index.search("学习").contains(id.uuidString.lowercased()))
assert(try index.search("%_").isEmpty)
assert(try index.relationships()[id.uuidString.lowercased()] == [drawingID.uuidString.lowercased()])
enum Failure:Error {case corrupt}
do {try index.transaction { try index.clear(); throw Failure.corrupt }} catch {}
assert(try index.catalog().count == 2)
try index.transaction { try index.remove(drawingID) }
assert(try index.catalog().count == 1)
try index.transaction {try index.clear();for file in try repository.files(){try index.update(repository.read(file))}}
assert(try index.catalog().count == 2)
let corrupt = repository.documents.appendingPathComponent(UUID().uuidString.lowercased()+".md")
try Data("broken frontmatter".utf8).write(to:corrupt)
do {
 try index.transaction { try index.clear(); for file in try repository.files() {try index.update(repository.read(file))} }
 assertionFailure("corrupt note must fail rebuilding")
} catch {}
assert(try index.catalog().count == 2)
// A read-only search connection sees subsequent committed writes.
let reader = try NotesIndex(url:repository.indexURL,readOnly:true)
assert(try reader.search("searchable").count == 2)
try FileManager.default.removeItem(at:corrupt)
let target = root.deletingLastPathComponent().appendingPathComponent("Relocated")
try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
let largeAttachment = repository.attachments.appendingPathComponent("large.bin")
try Data(repeating:42,count:2_500_001).write(to:largeAttachment)
let moved = try NotesDirectoryMigration.prepare(from:root,to:target)
assert(try moved.index.catalog().count == 2)
assert(try Data(contentsOf:moved.repository.attachments.appendingPathComponent("large.bin")) == Data(contentsOf:largeAttachment))
assert(FileManager.default.fileExists(atPath:root.path))
do {
 _ = try NotesDirectoryMigration.prepare(from:root,to:target)
 assertionFailure("non-empty target must be rejected")
} catch {}
let brokenTarget = root.deletingLastPathComponent().appendingPathComponent("BrokenTarget")
try FileManager.default.createDirectory(at:brokenTarget,withIntermediateDirectories:true)
try Data("corrupt".utf8).write(to:corrupt)
do {
 _ = try NotesDirectoryMigration.prepare(from:root,to:brokenTarget)
 assertionFailure("corrupt note must abort relocation")
} catch {}
assert(try FileManager.default.contentsOfDirectory(atPath:brokenTarget.path).isEmpty)
assert(FileManager.default.fileExists(atPath:largeAttachment.path))
print("PASS: storage, search, links, rebuild rollback, read-only queries, directory relocation and relocation rollback")
SWIFT
# Swift assert autoclosures cannot throw: evaluate throwing assertions explicitly.
python3 - "$notes_test_dir/main.swift" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text();lines=[]
for i,line in enumerate(s.splitlines()):
 if line.startswith('assert(try '):
  expr=line[len('assert(try '):-1]
  lines.append(f'let check{i} = try {expr}')
  lines.append(f'assert(check{i})')
 else:lines.append(line)
p.write_text('\n'.join(lines)+'\n')
PY
xcrun swiftc Sources/Vorssaint/Core/Notes/NoteModels.swift Sources/Vorssaint/Services/Notes/NotesFileRepository.swift Sources/Vorssaint/Services/Notes/NotesIndex.swift Sources/Vorssaint/Services/Notes/NotesDirectoryMigration.swift "$notes_test_dir/main.swift" -o "$notes_test_dir/test"
"$notes_test_dir/test" "$notes_test_dir"
