// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

/// Reuses the app's shared shortcut routing and recording/conflict handling.
final class AccountingShortcutService: ObservableObject {
    static let shared = AccountingShortcutService()
    @Published private(set) var registrationFailed = false
    private let hotkey = QuickToolHotkey(id: 90)
    private init() {
        hotkey.onPress = {
            guard !ShortcutCapture.isCapturing else { return }
            AccountingService.shared.present(ledger: false)
        }
    }
    func syncWithPreferences() {
        let enabled = AppFeature.accounting.isAvailable && !ShortcutCapture.isCapturing
            && UserDefaults.standard.bool(forKey: DefaultsKey.accountingShortcutEnabled)
        registrationFailed = !hotkey.sync(enabled: enabled,
            shortcut: GlobalShortcut.saved(for: DefaultsKey.accountingShortcut, fallback: .accountingDefault),
            storageKey: DefaultsKey.accountingShortcut)
    }
}
