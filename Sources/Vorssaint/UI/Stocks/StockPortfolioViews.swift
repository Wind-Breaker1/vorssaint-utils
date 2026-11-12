// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI

struct StockDisciplineEditor: View {
    @ObservedObject var service: StockService
    @State private var text = ""
    @State private var original: StockRuleBook?
    @State private var pendingSave: Task<Void, Never>?
    @State private var saving = false
    @State private var error: String?
    @State private var isEditing = false
    @State private var loaded = false
    private var changed: Bool { text != (original?.tradingDiscipline ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("交易纪律").font(.headline)
                Spacer()
                Button {
                    if isEditing { pendingSave?.cancel(); save() }
                    isEditing.toggle()
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(isEditing ? "完成编辑" : "编辑交易纪律")
                .accessibilityLabel(isEditing ? "完成编辑交易纪律" : "编辑交易纪律")
                .disabled(!loaded || service.busy)
            }
            if isEditing {
                TextEditor(text: $text)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 130, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .disabled(!loaded || service.busy)
            } else {
                TextEditor(text: .constant(text))
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 130, maxHeight: .infinity)
                    .disabled(true)
                    .textSelection(.enabled)
                    .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 7))
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { loadIfReady() }
        .onChange(of: service.data.revision) { _, _ in
            if !loaded || (!isEditing && !changed && !saving) { loadIfReady() }
        }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: service.busy) { _, busy in
            if !busy {
                if !loaded { loadIfReady() }
                else if !saving && error == nil { scheduleSave() }
            }
        }
        .onDisappear {
            if changed { scheduleSave() }
        }
    }

    private func loadIfReady() {
        guard !loaded, !service.busy, !service.data.revision.isEmpty else { return }
        original = service.data.rules
        text = service.data.rules.tradingDiscipline ?? ""
        loaded = true
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        guard loaded, original != nil, changed else { return }
        pendingSave = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(600)) }
            catch { return }
            while service.busy {
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
            }
            guard changed, error == nil else { return }
            save()
        }
    }

    private func save() {
        guard loaded, let original, changed, !saving, !service.busy else { return }
        var updated = original
        updated.tradingDiscipline = text
        saving = true
        service.saveRules(updated, original: original) { ok in
            saving = false
            if ok {
                self.original = updated
                error = nil
                if changed { save() }
            } else { error = service.message }
        }
    }
}
