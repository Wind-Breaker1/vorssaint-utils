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
Path(sys.argv[1]).write_text(s)
PY
cat > "$notes_test_dir/main.swift" <<'SWIFT'
import Foundation
extension Notification.Name { static let notesFlush = Notification.Name("test.notes.flush") }
func check(_ condition: @autoclosure () throws -> Bool) rethrows { let value = try condition(); assert(value) }
let store = NotesStore.shared
let repository = NotesFileRepository(root: NotesStore.root)
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
print("PASS: creation, async save + synchronous flush, pending save + delete, failure reporting and recovery")
SWIFT
xcrun swiftc Sources/Vorssaint/Core/Notes/NoteModels.swift \
 Sources/Vorssaint/Services/Notes/NotesFileRepository.swift \
 Sources/Vorssaint/Services/Notes/NotesIndex.swift \
 Sources/Vorssaint/Services/Notes/NotesIndexCoordinator.swift \
 Sources/Vorssaint/Services/Notes/NotesIndexQueryService.swift \
 Sources/Vorssaint/Services/Notes/NotesDirectoryMigration.swift \
 Sources/Vorssaint/Services/Notes/NotesFlushRequest.swift \
 "$notes_test_dir/NotesStore.swift" "$notes_test_dir/main.swift" -o "$notes_test_dir/test"
"$notes_test_dir/test" "$notes_test_dir"
