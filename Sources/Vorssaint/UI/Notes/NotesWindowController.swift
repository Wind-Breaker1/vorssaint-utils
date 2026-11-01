// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

enum NotesWindowLayout {
    static let minimumSize = NSSize(width: 1440, height: 900)
}

/// Hosting controllers can publish new minimums after layout or content changes.
/// Keep the product's minimum at the window boundary for every such update.
private final class NotesWindow: NSWindow {
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set {
            super.contentMinSize = NSSize(width: max(newValue.width, NotesWindowLayout.minimumSize.width),
                                          height: max(newValue.height, NotesWindowLayout.minimumSize.height))
        }
    }
}

extension AppDelegate {
    static var workspaceNoteWindow: NSWindow?
    func openNotesWindow() {
        guard AppFeature.notes.isAvailable else { return }
        if let window = Self.workspaceNoteWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let store = NotesStore.shared
        if store.notes.isEmpty { store.addNote("未命名笔记") }
        if let note = store.notes.first { openWorkspaceNote(note) }
    }

    func openWorkspaceNote(_ requested: NoteDocument) {
        guard AppFeature.notes.isAvailable else { return }
        if let window = Self.workspaceNoteWindow {
            NotificationCenter.default.post(name: .notesOpenDocument, object: requested)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let note = NotesStore.shared.document(requested.id) ?? (CommandLine.arguments.contains("--probe-markdown-editor") ? requested : nil) else { return }
        let host = NSHostingController(rootView: NotesEditorView(note: note))
        host.sizingOptions = []
        let window = NotesWindow(contentViewController: host)
        window.title = "笔记"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        window.isRestorable = false
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NotesWindowLayout.minimumSize
        window.setContentSize(NotesWindowLayout.minimumSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = WorkspaceNoteWindowDelegate.shared
        Self.workspaceNoteWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class WorkspaceNoteWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = WorkspaceNoteWindowDelegate()
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let request = NotesFlushRequest()
        NotificationCenter.default.post(name: .notesFlush, object: request)
        // A failed final save must not destroy the only in-memory copy.
        return !request.failed
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Release the hosting controller and WKWebView after the close callback.
        DispatchQueue.main.async {
            window.contentViewController = nil
            NotesStore.shared.releaseSearchResources()
            if AppDelegate.workspaceNoteWindow === window {
                AppDelegate.workspaceNoteWindow = nil
            }
        }
    }
}

extension Notification.Name {
    static let notesOpenDocument = Notification.Name("vorssaint.notes.openDocument")
    static let notesFlush = Notification.Name("vorssaint.notes.flush")
}
