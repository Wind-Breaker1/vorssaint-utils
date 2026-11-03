// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import EventKit
import AppKit
import Combine

struct ReminderSettings: View {
    @ObservedObject private var reminders = ReminderService.shared
    @ObservedObject private var shortcut = WorkspaceQuickHotkey.shared
    @AppStorage(DefaultsKey.remindersShortcutEnabled) private var shortcutEnabled = true
    @AppStorage("reminders.defaultListID") private var defaultListID = ""
    var body: some View {
        Form {
            Section("系统权限") {
                LabeledContent("提醒事项访问") { Text(reminders.access == .fullAccess ? "已授权" : "未授权").foregroundStyle(reminders.access == .fullAccess ? .green : .secondary) }
                if reminders.access != .fullAccess {
                    Button("授权提醒事项") { reminders.requestAccessAndRefresh() }
                    Text("待办由 macOS 提醒事项保存，Vorssaint 不保存副本。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("默认行为") {
                Picker("默认列表", selection: $defaultListID) {
                    Text("系统默认列表").tag("")
                    ForEach(reminders.lists) { list in Text(list.title).tag(list.id) }
                }
            }
            Section("快捷操作") {
                Toggle("启用全局快捷键", isOn: $shortcutEnabled)
                    .onChange(of: shortcutEnabled) { _, _ in shortcut.syncWithPreferences() }
                ShortcutPreferenceRow(role: .reminders, isEnabled: shortcutEnabled) { shortcut.syncWithPreferences() }
                if shortcutEnabled && shortcut.registrationFailed {
                    Text("快捷键已被占用，请更换组合").font(.caption).foregroundStyle(.orange)
                }
                Text("灵动岛中的新增按钮会使用提醒事项原生列表。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开系统提醒事项") {
                    let configuration = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Reminders.app"), configuration: configuration)
                }
            }
            if let error = reminders.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }.formStyle(.grouped)
    }

}
