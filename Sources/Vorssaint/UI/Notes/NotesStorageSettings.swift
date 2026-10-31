// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

struct NotesStorageSettings: View {
    @ObservedObject private var store = NotesStore.shared

    var body: some View {
        Form {
            Section("存储位置") {
                LabeledContent("笔记目录") {
                    Text(store.storagePath)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("更改目录", action: chooseDirectory)
                        .disabled(store.rebuilding)
                    Button("在 Finder 中打开") { NSWorkspace.shared.open(NotesStore.root) }
                }
                Text("笔记、画板和附件分别存放在三个子目录中。更改位置时会迁移并校验所有文件，成功后删除原目录。请选择一个空目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("笔记索引") {
                LabeledContent("搜索与链接索引") {
                    HStack(spacing: 8) {
                        if store.rebuilding { ProgressView().controlSize(.small) }
                        Button("重建笔记索引") { store.rebuildIndex() }
                            .disabled(store.rebuilding)
                    }
                }
                Text("重新扫描本地文件，重建搜索、元数据和链接索引，不修改笔记正文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !store.indexStatus.isEmpty || store.saveError != nil {
                Section {
                    if let error = store.saveError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    } else if !store.indexStatus.isEmpty {
                        Label(store.indexStatus, systemImage: store.rebuilding ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "迁移至此目录"
        panel.message = "请选择空目录。迁移并校验成功后，将删除原笔记目录。"
        if panel.runModal() == .OK, let url = panel.url { store.changeDirectory(to: url) }
    }
}
