// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI
import AppKit

extension AppDelegate {
    static var workspaceTaskWindow: NSWindow?

    func openWorkspaceTaskComposer() {
        guard AppFeature.reminders.isAvailable else { return }
        if let window = Self.workspaceTaskWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: WorkspaceTaskComposer()))
        window.level = NSWindow.Level(rawValue: NotchPanel.normalLevel.rawValue + 1)
        window.title = "新建待办"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 250))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = WorkspaceTaskWindowDelegate.shared
        Self.workspaceTaskWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

}

private final class WorkspaceTaskWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = WorkspaceTaskWindowDelegate()

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak window] in
            guard let window, !window.isKeyWindow else { return }
            // A calendar popover is part of the composer, not an outside window.
            var keyWindow = NSApp.keyWindow
            while let current = keyWindow {
                if current === window { return }
                keyWindow = current.parent
            }
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async {
            window.contentViewController = nil
            if AppDelegate.workspaceTaskWindow === window { AppDelegate.workspaceTaskWindow = nil }
        }
    }
}
