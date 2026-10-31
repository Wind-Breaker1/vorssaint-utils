// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct AccountingSettings: View {
    @ObservedObject private var service = AccountingService.shared
    @ObservedObject private var shortcut = AccountingShortcutService.shared
    @AppStorage(DefaultsKey.accountingShortcutEnabled) private var shortcutEnabled = false
    @State private var kind = LedgerKind.expense
    @State private var editing: LedgerCategory?
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        Form {
            Section("记账") {
                LabeledContent("存储方式", value: "本地 SQLite · 人民币")
                Text("记录收入与支出，不管理账户。停用功能保留数据，重新安装后可继续使用。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("打开账本") { AccountingService.shared.present(ledger: true) }
                    Button("记一笔") { AccountingService.shared.present(ledger: false) }
                }
            }
            Section("快捷新增") {
                Toggle("启用全局快捷键", isOn: $shortcutEnabled)
                    .onChange(of: shortcutEnabled) { _, _ in shortcut.syncWithPreferences() }
                ShortcutPreferenceRow(role: .accounting, isEnabled: shortcutEnabled) { shortcut.syncWithPreferences() }
                if shortcutEnabled && shortcut.registrationFailed {
                    Text("快捷键已被占用，请更换组合").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("分类管理") {
                Picker("类型", selection: $kind) { ForEach(LedgerKind.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).onChange(of: kind) { _, _ in reset() }
                ForEach(service.snapshot.categories.filter { $0.kind == kind }) { category in
                    HStack {
                        Text(category.name).foregroundStyle(category.archived ? .secondary : .primary)
                        if category.archived { Text("已停用").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("重命名") { editing = category; name = category.name; error = nil }
                        Button(category.archived ? "启用" : "停用") { service.archive(category) }
                    }
                }
                HStack {
                    TextField(editing == nil ? "新分类名称" : "分类名称", text: $name)
                    if editing != nil { Button("取消", action: reset) }
                    Button(editing == nil ? "添加分类" : "保存名称") { save() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("停用分类后，新账目不再显示该分类，已有记录和统计不受影响。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = error ?? service.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }.formStyle(.grouped)
    }
    private func reset() { editing = nil; name = ""; error = nil }
    private func save() {
        saving = true
        service.saveCategory(editing, name: name, kind: kind) { message in
            saving = false
            if let message { error = message } else { reset() }
        }
    }
}
