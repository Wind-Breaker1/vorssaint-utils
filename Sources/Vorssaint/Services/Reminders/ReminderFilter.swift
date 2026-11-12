// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Pure presentation filtering; EventKit access and preferences stay with their owners.
enum ReminderFilter {
    static func apply(_ reminders: [ReminderItem], status: ReminderStatusFilter,
                      date: ReminderDateFilter, listID: String,
                      order: ReminderSortOrder, query: String = "", now: Date = Date(),
                      calendar: Calendar = .current) -> [ReminderItem] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return reminders.filter { item in
            if !query.isEmpty && !item.title.localizedCaseInsensitiveContains(query) { return false }
            switch status { case .pending where item.completed, .completed where !item.completed: return false; default: break }
            if !listID.isEmpty && item.listID != listID { return false }
            switch date {
            case .all: return true
            case .noDate: return item.dueDate == nil
            case .overdue: return !item.completed && item.dueDate.map { $0 < today } == true
            case .today: return item.dueDate.map { calendar.isDate($0, inSameDayAs: today) } == true
            case .tomorrow: return item.dueDate.map { calendar.isDate($0, inSameDayAs: tomorrow) } == true
            case .week: return item.dueDate.map { $0 >= today && $0 < week } == true
            }
        }.sorted {
            switch order {
            case .priority:
                let lhs = $0.priority == 0 ? 10 : $0.priority
                let rhs = $1.priority == 0 ? 10 : $1.priority
                if lhs != rhs { return lhs < rhs }
            case .dueDate:
                if $0.dueDate != $1.dueDate { return ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            case .title: break
            }
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}
