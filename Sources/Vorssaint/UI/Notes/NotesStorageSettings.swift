// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

struct NotesStorageSettings: View {
    @ObservedObject private var store = NotesStore.shared
    @State private var cleanupSources: [MigratedStorageSource] = []

    var body: some View {
        Form {
            Section("存储位置") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("笔记目录")
                    Text(store.storagePath)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(store.movingStorage ? "正在迁移…" : "更改目录", action: chooseDirectory)
                        .disabled(store.rebuilding || store.movingStorage || store.removingOldStorage)
                    Button("删除旧数据", role: .destructive) { cleanupSources = store.previousStorage }
                        .disabled(store.previousStorage.isEmpty || store.rebuilding || store.movingStorage || store.removingOldStorage)
                    Button("在 Finder 中打开") { NSWorkspace.shared.open(NotesStore.root) }
                }
                Text("笔记、画板和附件分别存放在三个子目录中。更改位置时会迁移并校验所有文件，成功后保留原目录，可手动删除。请选择一个空目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("笔记索引") {
                LabeledContent("搜索与链接索引") {
                    HStack(spacing: 8) {
                        if store.rebuilding { ProgressView().controlSize(.small) }
                        Button("重建笔记索引") { store.rebuildIndex() }
                            .disabled(store.rebuilding || store.movingStorage || store.removingOldStorage)
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
        .confirmationDialog("删除旧笔记目录及其中的全部文件？", isPresented: Binding(get: { !cleanupSources.isEmpty }, set: { if !$0 { cleanupSources = [] } })) {
            ForEach(cleanupSources) { source in
                Button(cleanupSources.count == 1 ? "删除旧数据" : source.path, role: .destructive) {
                    store.removeOldStorage(source); cleanupSources = []
                }
            }
        } message: {
            Text(cleanupSources.count == 1 ? cleanupSources[0].path : "选择要删除的旧目录。当前保存目录不受影响。")
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "迁移至此目录"
        panel.message = "请选择空目录。迁移并校验成功后保留原目录，可在设置页手动删除。"
        if panel.runModal() == .OK, let url = panel.url { store.changeDirectory(to: url) }
    }
}
