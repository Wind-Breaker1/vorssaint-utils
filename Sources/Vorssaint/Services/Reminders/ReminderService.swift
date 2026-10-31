// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import EventKit

/// System-backed task access for Reminders. No reminder data is persisted
/// by Vorssaint; Reminders/iCloud remain the source of truth.
final class ReminderService: ObservableObject {
    static let shared = ReminderService()
    @Published private(set) var reminders: [ReminderItem] = []
    @Published private(set) var lists: [ReminderList] = []
    @Published private(set) var access = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var errorMessage: String?
    private let store = EKEventStore()
    private var refreshGeneration = 0
    private var observer: NSObjectProtocol?
    private var refreshWorkItem: DispatchWorkItem?

    func suspend() {
        refreshGeneration += 1
        reminders = []
        lists = []
    }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        }
        refresh()
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func requestAccessAndRefresh() {
        store.requestFullAccessToReminders { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.access = EKEventStore.authorizationStatus(for: .reminder)
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        guard AppFeature.reminders.isAvailable else { suspend(); return }
        access = EKEventStore.authorizationStatus(for: .reminder)
        guard access == .fullAccess else { reminders = []; lists = []; return }
        lists = store.calendars(for: .reminder)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let predicate = store.predicateForReminders(in: nil)
        store.fetchReminders(matching: predicate) { [weak self] items in
            let mapped = (items ?? []).compactMap { item -> ReminderItem? in
                let id = item.calendarItemIdentifier
                guard !id.isEmpty, let title = item.title, !title.isEmpty else { return nil }
                return ReminderItem(id: id, title: title, completed: item.isCompleted,
                                        priority: item.priority, dueDate: item.dueDateComponents?.date,
                                        listTitle: item.calendar.title, listID: item.calendar.calendarIdentifier)
            }
            DispatchQueue.main.async {
                guard let self, generation == self.refreshGeneration else { return }
                guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                    self.refresh()
                    return
                }
                self.reminders = mapped
            }
        }
    }

    @discardableResult
    func add(title: String, listID: String? = nil, priority: Int = 2, dueDate: Date? = nil) -> Bool {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            errorMessage = "请先授权提醒事项访问权限"
            refresh()
            return false
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入待办内容"
            return false
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.priority = priority == 3 ? 1 : priority == 2 ? 5 : 9
        reminder.dueDateComponents = dueDate.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) }
        if let listID, store.calendar(withIdentifier: listID) == nil {
            errorMessage = "所选列表已不存在，请重新选择"
            return false
        }
        let configuredList = UserDefaults.standard.string(forKey: "reminders.defaultListID")
        reminder.calendar = listID.flatMap { id in store.calendar(withIdentifier: id) }
            ?? configuredList.flatMap { id in store.calendar(withIdentifier: id) }
            ?? store.defaultCalendarForNewReminders()
        guard let calendar = reminder.calendar, calendar.allowsContentModifications else {
            errorMessage = "所选列表不可写，请选择其他列表"
            return false
        }
        do { try store.save(reminder, commit: true); errorMessage = nil }
        catch { errorMessage = error.localizedDescription; return false }
        refresh()
        return true
    }

    func toggle(_ reminder: ReminderItem) {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            errorMessage = "请先授权提醒事项访问权限"
            refresh()
            return
        }
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted.toggle()
        do { try store.save(item, commit: true); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        refresh()
    }

    func remove(_ reminder: ReminderItem) {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            errorMessage = "请先授权提醒事项访问权限"
            refresh()
            return
        }
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        do { try store.remove(item, commit: true); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        refresh()
    }
}
