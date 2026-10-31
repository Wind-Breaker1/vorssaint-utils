// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI
import AppKit

struct WorkspaceTaskComposer: View {
    @ObservedObject private var reminders = ReminderService.shared
    @State private var saveError: String?
    @State private var title = ""
    @State private var listID: String?
    @State private var priority = 2
    @State private var dueDate: Date?
    @State private var showingCustomDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if reminders.access != .fullAccess {
                Text("需要授权 macOS 提醒事项后才能保存")
                    .font(.caption).foregroundStyle(.secondary)
                Button("授权提醒事项") { reminders.requestAccessAndRefresh() }
                    .buttonStyle(.borderless)
            }
            TextField("待办内容", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack(spacing: 10) {
                Text("优先级")
                    .foregroundStyle(.secondary)
                ForEach([( "低", 1), ("中", 2), ("高", 3)], id: \.1) { item in
                    Button {
                        priority = item.1
                    } label: {
                        Label(item.0, systemImage: priority == item.1 ? "circle.inset.filled" : "circle")
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("截止日期")
                    .foregroundStyle(.secondary)
                Menu {
                    Button("今天") { dueDate = Calendar.current.startOfDay(for: Date()) }
                    Button("明天") { dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) }
                    Button("下周末") { dueDate = nextWeekend() }
                    Button("下周") { dueDate = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: Date())) }
                    Divider()
                    Button("自定义…") { showingCustomDatePicker = true }
                } label: {
                    Label(dueDate.map { shortDate($0) } ?? "选择日期", systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .popover(isPresented: $showingCustomDatePicker, arrowEdge: .bottom) {
                    DatePicker("截止日期", selection: Binding(get: { dueDate ?? Date() }, set: { dueDate = $0 }), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .focusable(false)
                        .focusEffectDisabled()
                        .blur(radius: 0.001)
                        .background(DatePickerChromeSuppressor())
                        .padding(12)
                        .background(PopoverWindowConfigurator())
                }
            }
            HStack(spacing: 10) {
                Text("列表")
                    .foregroundStyle(.secondary)
                Picker("列表", selection: $listID) {
                    Text("默认列表").tag(Optional<String>.none)
                    ForEach(reminders.lists) { list in
                        Text(list.title).tag(Optional(list.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { AppDelegate.workspaceTaskWindow?.close() }
                Button("添加") { save() }
                    .keyboardShortcut(.return)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reminders.access != .fullAccess)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onExitCommand { AppDelegate.workspaceTaskWindow?.close() }
    }

    private func save() {
        if reminders.add(title: title, listID: listID, priority: priority, dueDate: dueDate) {
            AppDelegate.workspaceTaskWindow?.close()
        } else {
            saveError = reminders.errorMessage
        }
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    private func nextWeekend() -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: start)
        let days = (7 - weekday + 7) % 7 + 7
        return calendar.date(byAdding: .day, value: days, to: start) ?? start
    }
}

struct DatePickerChromeSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SuppressorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SuppressorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var node: NSView? = self.superview
                while let current = node {
                    Self.suppress(in: current)
                    node = current.superview
                }
            }
        }

        private static func suppress(in view: NSView) {
            if let control = view as? NSControl {
                control.focusRingType = .none
                if let picker = control as? NSDatePicker {
                    picker.isBordered = false
                    picker.drawsBackground = false
                }
            }
            view.subviews.forEach { suppress(in: $0) }
        }
    }
}

private struct PopoverWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguratorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
        }
    }
}

