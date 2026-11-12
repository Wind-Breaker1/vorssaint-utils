// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum ReminderFilterTests {
    static func run(_ suite: TestSuite) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = Date(timeIntervalSince1970: 1_735_689_600)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        func item(_ id: String, completed: Bool = false, priority: Int = 5, due: Date? = nil, list: String = "a") -> ReminderItem {
            ReminderItem(id: id, title: id, completed: completed, priority: priority, dueDate: due, listTitle: list, listID: list)
        }
        let items = [item("past", due: day(-1)), item("today", due: today), item("tomorrow", due: day(1)), item("six", due: day(6)), item("seven", due: day(7)), item("none", list: "b"), item("done", completed: true, due: day(-1))]
        func filter(status: ReminderStatusFilter = .all, date: ReminderDateFilter = .all, list: String = "", query: String = "") -> [String] {
            ReminderFilter.apply(items, status: status, date: date, listID: list, order: .title, query: query, now: today, calendar: calendar).map(\.id)
        }
        suite.expect(filter(status: .pending).count == 6, "pending status excludes completed items")
        suite.expect(filter(status: .completed) == ["done"], "completed status selects completed items")
        suite.expect(filter(date: .today) == ["today"], "today excludes adjacent days")
        suite.expect(filter(date: .tomorrow) == ["tomorrow"], "tomorrow selects next day")
        suite.expect(Set(filter(date: .week)) == Set(["today", "tomorrow", "six"]), "seven-day range excludes day seven and overdue items")
        suite.expect(filter(date: .overdue) == ["past"], "overdue excludes completed items")
        suite.expect(filter(date: .noDate) == ["none"], "no date selects undated items")
        suite.expect(filter(list: "b", query: " NONE ") == ["none"], "list and trimmed case-insensitive search combine")
        let priorities = [item("unspecified", priority: 0), item("low", priority: 9), item("medium", priority: 5), item("high", priority: 1)]
        let sorted = ReminderFilter.apply(priorities, status: .pending, date: .all, listID: "", order: .priority)
        suite.expect(sorted.map(\.id) == ["high", "medium", "low", "unspecified"], "EventKit priorities sort high first and unspecified last")
        let tied = [item("b"), item("a")]
        let ordered = ReminderFilter.apply(tied, status: .pending, date: .all, listID: "", order: .dueDate)
        suite.expect(ordered.map(\.id) == ["a", "b"], "equal dates have stable title ordering")
    }
}
