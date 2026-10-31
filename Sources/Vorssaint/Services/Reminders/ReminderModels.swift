// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let completed: Bool
    /// EventKit priority: 1–4 high, 5 medium, 6–9 low, 0 unspecified.
    let priority: Int
    let dueDate: Date?
    let listTitle: String
    let listID: String
}

enum ReminderStatusFilter: String, CaseIterable { case pending, completed, all }
enum ReminderDateFilter: String, CaseIterable { case all, today, tomorrow, week, overdue, noDate }
enum ReminderSortOrder: String, CaseIterable { case dueDate, priority, title }

struct ReminderList: Identifiable, Equatable {
    let id: String
    let title: String
}

