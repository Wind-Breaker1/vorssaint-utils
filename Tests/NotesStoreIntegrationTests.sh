#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
notes_test_dir=$(mktemp -d)
trap 'rm -rf "$notes_test_dir"' EXIT
# Isolate the singleton's storage without reading or writing application data.
python3 - "$notes_test_dir/NotesStore.swift" <<'PY'
from pathlib import Path
import sys
s = Path('Sources/Vorssaint/Services/Notes/NotesStore.swift').read_text()
a = s.index('    private static let defaultRoot =')
b = s.index('    static var root:', a)
s = s[:a] + '    private static let defaultRoot = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Notes")\n' + s[b:]
s = s.replace('UserDefaults.standard', 'UserDefaults(suiteName: "notes-test-" + URL(fileURLWithPath: CommandLine.arguments[1]).lastPathComponent)!')
Path(sys.argv[1]).write_text(s)
r = Path('Sources/Vorssaint/Services/Notes/NotesFileRepository.swift').read_text()
a = r.index('indexRoot ?? FileManager.default.urls')
b = r.index('\n    }', a)
r = r[:a] + 'indexRoot ?? URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("LocalIndexes")' + r[b:]
Path(sys.argv[1]).with_name('NotesFileRepository.swift').write_text(r)
h = Path('Sources/Vorssaint/Services/MigratedStorageSource.swift').read_text().replace('UserDefaults.standard', 'UserDefaults(suiteName: "notes-test-" + URL(fileURLWithPath: CommandLine.arguments[1]).lastPathComponent)!')
Path(sys.argv[1]).with_name('MigratedStorageSource.swift').write_text(h)
PY
cat > "$notes_test_dir/main.swift" <<'SWIFT'
import Foundation
extension Notification.Name { static let notesFlush = Notification.Name("test.notes.flush") }
func check(_ condition: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) rethrows { let value = try condition(); assert(value, file: file, line: line) }
let store = NotesStore.shared
let repository = NotesFileRepository(root: NotesStore.root)
check(!store.storagePath.isEmpty)
let plainBookmark = try repository.root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
var bookmarkStale = false
let resolved = try MigratedStorageSource.resolveBookmark(plainBookmark, isStale: &bookmarkStale)
check(resolved.resolvingSymlinksInPath().standardizedFileURL.path == repository.root.resolvingSymlinksInPath().standardizedFileURL.path)
let first = store.addNote("first")!
let second = store.addNote("second")!
check(first.id != second.id)
check(store.document(first.id)?.title == "first")
check(store.document(second.id)?.title == "second")
check(store.notes.count == 2)
var older = first
older.body = "older autosave"
var pendingCallbacks = 0
store.updateNote(older, wait: false) { success in
    check(success)
    pendingCallbacks += 1
    check(store.document(first.id)?.body == "final flush")
}
var latest = first
latest.body = "final flush"
var flushed = false
store.updateNote(latest) { flushed = $0 }
check(flushed)
try check(try repository.read(repository.url(for: latest)).body == "final flush")
var deleted = second
deleted.body = "pending before deletion"
store.updateNote(deleted, wait: false) { success in
    check(success)
    pendingCallbacks += 1
    check(!store.notes.contains { $0.id == deleted.id })
}
store.removeNote(deleted)
check(!FileManager.default.fileExists(atPath: repository.url(for: deleted).path))
// A failed write must report failure, leaving the existing file intact.
let documents = repository.documents
let backup = documents.appendingPathExtension("held")
try FileManager.default.moveItem(at: documents, to: backup)
var rejected = false
store.updateNote(latest) { rejected = !$0 }
check(rejected)
check(store.saveError != nil)
try FileManager.default.moveItem(at: backup, to: documents)
let deadline = Date().addingTimeInterval(10)
while pendingCallbacks < 2 && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
check(pendingCallbacks == 2)
check(store.document(first.id)?.body == "final flush")
check(!store.notes.contains { $0.id == deleted.id })
check(store.saveError != nil) // Old success callbacks cannot hide the new failure.
var recovered = false
store.updateNote(latest) { recovered = $0 }
check(recovered && store.saveError == nil)
// External edits and cloud placeholders are reconciled without replacing local metadata blindly.
func waitFor(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(predicate())
}
var external = latest
external.body = "external content"
try repository.write(external)
var refreshed = false
store.refreshFromDisk { refreshed = $0 }
waitFor { refreshed }
check(store.notes.first(where: { $0.id == first.id })?.body == "external content")
var found = false
store.search("external") { result in found = (try? result.get().contains(first.id.uuidString.lowercased())) == true }
waitFor { found }
store.releaseSearchResources()
found = false
store.search("external") { result in found = (try? result.get().contains(first.id.uuidString.lowercased())) == true }
waitFor { found }
let file = repository.url(for: first)
let placeholder = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".icloud")
let savedBytes = try Data(contentsOf: file)
try FileManager.default.removeItem(at: file)
try Data().write(to: placeholder)
var checkedPlaceholder = false
store.refreshFromDisk { complete in check(!complete); checkedPlaceholder = true }
waitFor { checkedPlaceholder }
check(store.notes.contains { $0.id == first.id })
check(!store.indexStatus.isEmpty)
check(store.document(first.id) == nil)
try FileManager.default.removeItem(at: placeholder)
try savedBytes.write(to: file)
// Relocation returns immediately and keeps the source until explicit cleanup.
let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Relocated")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
store.changeDirectory(to: destination)
check(store.movingStorage)
check(NotesStore.root == repository.root)
check(FileManager.default.fileExists(atPath: file.path))
waitFor { !store.movingStorage }
check(store.saveError == nil)
check(NotesStore.root.standardizedFileURL == destination.standardizedFileURL)
check(store.document(first.id)?.body == "external content")
check(FileManager.default.fileExists(atPath: repository.root.path))
check(store.previousStorage.count == 1)
let history = MigratedStorageSource.load(key: "notes.previousStorage")
check(history == store.previousStorage)
do {
    _ = try history[0].resolve(excluding: repository.root)
    fatalError("active storage must not be removable")
} catch {}
store.removeOldStorage(history[0])
waitFor { !store.removingOldStorage }
check(store.saveError == nil)
check(!FileManager.default.fileExists(atPath: repository.root.path))
check(store.previousStorage.isEmpty)
check(store.document(first.id)?.body == "external content")
check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("index.sqlite").path))
UserDefaults.standard.removePersistentDomain(forName: "notes-test-" + URL(fileURLWithPath: CommandLine.arguments[1]).lastPathComponent)
print("PASS: save ordering, failure recovery, external refresh, cloud placeholders, reopened search and asynchronous relocation")
SWIFT
xcrun swiftc Sources/Vorssaint/Core/Notes/NoteModels.swift \
 "$notes_test_dir/NotesFileRepository.swift" \
 Sources/Vorssaint/Services/Notes/NotesIndex.swift \
 Sources/Vorssaint/Services/Notes/NotesIndexCoordinator.swift \
 Sources/Vorssaint/Services/Notes/NotesIndexQueryService.swift \
 Sources/Vorssaint/Services/Notes/NotesDirectoryMigration.swift \
 Sources/Vorssaint/Services/Notes/NotesFlushRequest.swift \
 "$notes_test_dir/MigratedStorageSource.swift" "$notes_test_dir/NotesStore.swift" "$notes_test_dir/main.swift" -o "$notes_test_dir/test"
"$notes_test_dir/test" "$notes_test_dir"
