// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct AccountingEntryView: View {
    @ObservedObject private var service = AccountingService.shared
    let inline: Bool
    let entry: LedgerEntry?
    let onClose: () -> Void
    @State private var amount: String
    @State private var kind: LedgerKind
    @State private var category: String
    @State private var date: Date
    @State private var note: String
    @State private var error: String?
    @State private var saving = false
    @State private var showingDatePicker = false
    @FocusState private var amountFocused: Bool

    init(entry: LedgerEntry? = nil, inline: Bool = false, onClose: @escaping () -> Void) {
        self.inline = inline; self.entry = entry; self.onClose = onClose
        _amount = State(initialValue: entry.map { LedgerMoney.decimal($0.amount) } ?? "")
        _kind = State(initialValue: entry?.kind ?? .expense)
        _category = State(initialValue: entry?.categoryID ?? "")
        _date = State(initialValue: entry?.date ?? Date())
        _note = State(initialValue: entry?.note ?? "")
    }
    private var categories: [LedgerCategory] {
        service.snapshot.categories.filter { $0.kind == kind && (!$0.archived || $0.id == entry?.categoryID) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: inline ? 12 : 18) {
            HStack(spacing: 12) {
                Picker("收支类型", selection: $kind) {
                    ForEach(LedgerKind.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if inline {
                    Spacer(minLength: 0)
                    Button { AccountingService.shared.present(ledger: true) } label: {
                        Label("账本", systemImage: "chart.bar")
                    }.buttonStyle(.borderless).fixedSize()
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("¥").font(.title).foregroundStyle(.secondary)
                TextField("0.00", text: $amount)
                    .font(.system(size: inline ? 28 : 36, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain).focused($amountFocused)
            }
            Divider()
            if inline {
                HStack(spacing: 20) {
                    categoryPicker
                    datePicker.fixedSize()
                }
            } else {
                categoryPicker
                datePicker
            }
            TextField("备注（选填）", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...3)
                .padding(8)
                .frame(height: 72, alignment: .topLeading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if !inline { Button("取消", action: onClose).keyboardShortcut(.cancelAction).disabled(saving) }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(entry == nil ? "保存" : "保存修改", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || LedgerMoney.parse(amount) == nil || category.isEmpty)
            }
        }
        .padding(inline ? 12 : 24).frame(maxWidth: .infinity).frame(width: inline ? nil : 428)
        .frame(maxHeight: inline ? .infinity : nil, alignment: .top)
        .onAppear { chooseCategory(); amountFocused = !inline }
        .onChange(of: kind) { _, _ in category = ""; chooseCategory() }
        .onChange(of: service.snapshot.categories) { _, _ in chooseCategory() }
    }
    private var datePicker: some View {
        HStack(spacing: 6) {
            Text("日期").font(.body).foregroundStyle(.secondary)
            Button { showingDatePicker.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
                CalendarDatePicker(selection: $date)
            }
        }
    }
    private var categoryPicker: some View {
        HStack(spacing: 8) {
            Text("分类").font(.body).foregroundStyle(.secondary)
            Picker("分类", selection: $category) {
                Text("请选择分类").tag("")
                ForEach(categories) { Text($0.name + ($0.archived ? "（已停用）" : "")).tag($0.id) }
            }.labelsHidden().frame(width: 112)
            Spacer(minLength: 0)
        }
    }
    private func chooseCategory() {
        if !categories.contains(where: { $0.id == category }) { category = categories.first?.id ?? "" }
    }
    private func save() {
        guard !saving, let cents = LedgerMoney.parse(amount), !category.isEmpty else { return }
        saving = true; error = nil
        service.save(entryID: entry?.id, amount: cents, category: category, date: date, note: note) { message in
            saving = false
            if let message { error = message } else {
                if inline { amount = ""; note = ""; date = Date(); amountFocused = true }
                onClose()
            }
        }
    }
}
