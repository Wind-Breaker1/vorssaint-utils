// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI
import AppKit

struct NotchRemindersView: View {
    @ObservedObject private var reminders = ReminderService.shared
    @State private var searchText = ""
    @AppStorage("reminders.statusFilter") private var statusFilter = ReminderStatusFilter.pending.rawValue
    @AppStorage("reminders.listFilter") private var listFilter = ""
    @AppStorage("reminders.dateFilter") private var dateFilter = ReminderDateFilter.all.rawValue
    @AppStorage("reminders.sortOrder") private var sortOrder = ReminderSortOrder.dueDate.rawValue

    var body: some View {
        let tasks = ReminderFilter.apply(reminders.reminders,
            status: ReminderStatusFilter(rawValue: statusFilter) ?? .pending,
            date: ReminderDateFilter(rawValue: dateFilter) ?? .all,
            listID: listFilter, order: ReminderSortOrder(rawValue: sortOrder) ?? .dueDate,
            query: searchText)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Label("待办", systemImage: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(pendingTaskCount)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                filterControls
            }

            HStack(spacing: 6) {
                TextField("搜索待办…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    (NSApp.delegate as? AppDelegate)?.openWorkspaceTaskComposer()
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("新建待办")
            }

            if let error = reminders.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            ScrollView {
                Group {
                    if reminders.access != .fullAccess {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("连接 macOS 提醒事项以查看和添加待办")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("授权提醒事项") { reminders.requestAccessAndRefresh() }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
                            taskRows(tasks)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var filterControls: some View {
        filterPicker("状态", width: 78, selection: $statusFilter) {
            Text("未完成").tag(ReminderStatusFilter.pending.rawValue)
            Text("已完成").tag(ReminderStatusFilter.completed.rawValue)
            Text("全部").tag(ReminderStatusFilter.all.rawValue)
        }
        filterPicker("列表", width: 100, selection: $listFilter) {
            Text("所有列表").tag("")
            ForEach(reminders.lists) { list in Text(list.title).tag(list.id) }
        }
        filterPicker("日期", width: 82, selection: $dateFilter) {
            Text("全部日期").tag(ReminderDateFilter.all.rawValue)
            Text("今天").tag(ReminderDateFilter.today.rawValue)
            Text("明天").tag(ReminderDateFilter.tomorrow.rawValue)
            Text("未来 7 天").tag(ReminderDateFilter.week.rawValue)
            Text("已逾期").tag(ReminderDateFilter.overdue.rawValue)
            Text("无截止日期").tag(ReminderDateFilter.noDate.rawValue)
        }
        filterPicker("排序", width: 82, selection: $sortOrder) {
            Text("截止日期").tag(ReminderSortOrder.dueDate.rawValue)
            Text("优先级").tag(ReminderSortOrder.priority.rawValue)
            Text("标题").tag(ReminderSortOrder.title.rawValue)
        }
    }

    @ViewBuilder
    private func taskRows(_ tasks: [ReminderItem]) -> some View {
        ForEach(tasks) { task in
            Button { reminders.toggle(task) } label: {
                HStack(spacing: 6) {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.completed ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .strikethrough(task.completed)
                            .foregroundStyle(task.completed ? .secondary : .primary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if task.priority > 0 {
                                Text(priorityShortName(task.priority))
                                    .foregroundStyle(priorityColor(task.priority))
                            }
                            Spacer(minLength: 0)
                            if let days = overdueDays(for: task), days > 0 { Text("逾期 \(days) 天").foregroundStyle(.red) }
                            Text(task.listTitle).lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contextMenu { Button("删除提醒事项", role: .destructive) { reminders.remove(task) } }
        }
        if tasks.isEmpty {
            Text("没有待办")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func filterPicker<SelectionValue: Hashable, Options: View>(
        _ title: String,
        width: CGFloat,
        selection: Binding<SelectionValue>,
        @ViewBuilder options: () -> Options
    ) -> some View {
        Picker(title, selection: selection, content: options)
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: width)
    }

    private var pendingTaskCount: Int {
        reminders.reminders.reduce(into: 0) { count, task in
            if !task.completed { count += 1 }
        }
    }

    private func priorityShortName(_ priority: Int) -> String {
        switch priority { case 1...4: return "高"; case 5: return "中"; default: return "低" }
    }

    private func priorityColor(_ priority: Int) -> Color {
        switch priority { case 1...4: return .red; case 5: return .orange; default: return .secondary }
    }

    private func overdueDays(for task: ReminderItem) -> Int? {
        guard !task.completed, let dueDate = task.dueDate else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let due = calendar.startOfDay(for: dueDate)
        guard due < today else { return nil }
        return calendar.dateComponents([.day], from: due, to: today).day
    }

}
