import Foundation
import Combine
import AppKit

final class WorkspaceQuickHotkey: ObservableObject {
    static let shared = WorkspaceQuickHotkey()
    @Published private(set) var registrationFailed = false
    private let hotkey = QuickToolHotkey(id: 91)

    private init() {
        hotkey.onPress = {
            guard !ShortcutCapture.isCapturing else { return }
            (NSApp.delegate as? AppDelegate)?.openWorkspaceTaskComposer()
        }
    }

    func start() {
        syncWithPreferences()
    }

    func syncAfterCapture() {
        syncWithPreferences()
    }

    func stop() {
        _ = hotkey.sync(enabled: false, shortcut: .remindersDefault,
                        storageKey: DefaultsKey.remindersShortcut)
        registrationFailed = false
    }

    func syncWithPreferences() {
        let enabled = AppFeature.reminders.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.remindersShortcutEnabled)
            && !ShortcutCapture.isCapturing
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.remindersShortcut, fallback: .remindersDefault)
        registrationFailed = !hotkey.sync(enabled: enabled, shortcut: shortcut,
                                          storageKey: DefaultsKey.remindersShortcut)
    }
}
