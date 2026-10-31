// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum AccountingTests {
    static func run(_ suite: TestSuite) {
        for (text, expected): (String, Int64) in [("12.34",1234), ("0.01",1), ("2.5",250), (" 10 ",1000), ("9999999999.99",999999999999)] {
            suite.expect(LedgerMoney.parse(text) == expected, "exact integer parsing: \(text)")
        }
        for text in ["", "0", "-1", "1.234", "1.", "1e3", "NaN", "10000000000", "1,234", "１２"] {
            suite.expect(LedgerMoney.parse(text) == nil, "invalid amount rejected: \(text)")
        }
        suite.expect(LedgerMoney.decimal(1201) == "12.01", "money display retains cents")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("ledger.sqlite")
            let month = Date()
            let range = Calendar.current.dateInterval(of: .month, for: month)!
            var repository: AccountingRepository? = try AccountingRepository(url: url)
            let initial = try repository!.snapshot(month: month, limit: 100, kind: nil, category: "")
            suite.expect(initial.categories.count == 11 && initial.count == 0, "new ledger seeds categories without sample transactions")
            let expense = initial.categories.first { $0.kind == .expense }!
            let income = initial.categories.first { $0.kind == .income }!
            try repository!.saveEntry(id: "expense", amount: 1234, category: expense.id, date: range.start, note: " food ")
            try repository!.saveEntry(id: "income", amount: 5000, category: income.id, date: month, note: "salary")
            try repository!.saveEntry(id: "outside", amount: 100, category: expense.id, date: range.end, note: "next month")
            var data = try repository!.snapshot(month: month, limit: 1, kind: nil, category: "")
            suite.expect(data.count == 2 && data.entries.count == 1, "pagination limits records but preserves total count")
            suite.expect(data.expense == 1234 && data.income == 5000, "SQL aggregation covers entire month, excluding end boundary")
            data = try repository!.snapshot(month: month, limit: 100, kind: .expense, category: expense.id)
            suite.expect(data.count == 1 && data.entries.first?.note == "food" && data.income == 0, "kind and category filters combine")
            suite.expect(data.dailyTotals.reduce(Int64(0)) { $0 + $1.amount } == data.expense + data.income, "daily chart aggregation respects filters")
            try repository!.saveCategory(id: expense.id, name: "改名'测试", kind: .income)
            data = try repository!.snapshot(month: month, limit: 100, kind: nil, category: expense.id)
            suite.expect(data.entries.first?.categoryName == "改名'测试" && data.entries.first?.kind == .expense, "rename preserves historical type and safely binds quotes")
            try repository!.archiveCategory(expense.id, archived: true)
            do {
                try repository!.saveEntry(id: "new", amount: 100, category: expense.id, date: month, note: "")
                suite.expect(false, "archived category must reject new entries")
            } catch { suite.expect(true, "archived category rejects new entries") }
            try repository!.saveEntry(id: "expense", amount: 2000, category: expense.id, date: range.start, note: "updated")
            data = try repository!.snapshot(month: month, limit: 100, kind: nil, category: "")
            suite.expect(data.expense == 2000 && data.count == 2, "editing existing archived-category entry updates without duplication")
            suite.expect(data.dailyTotals.first(where: { $0.kind == .expense })?.day == 1, "daily chart aggregation uses local calendar date")
            let paged = try repository!.snapshot(month: month, limit: 1, kind: nil, category: "")
            suite.expect(paged.dailyTotals.reduce(Int64(0)) { $0 + $1.amount } == data.income + data.expense, "chart totals are independent of entry pagination")
            do {
                try repository!.saveCategory(id: "duplicate", name: income.name, kind: .income)
                suite.expect(false, "duplicate category must fail")
            } catch { suite.expect(true, "duplicate category fails") }
            do {
                try repository!.saveEntry(id: "missing", amount: 100, category: "unknown", date: month, note: "")
                suite.expect(false, "missing category must fail")
            } catch { suite.expect(true, "missing category fails") }
            repository = nil
            repository = try AccountingRepository(url: url)
            data = try repository!.snapshot(month: month, limit: 100, kind: nil, category: "")
            suite.expect(data.count == 2 && data.expense == 2000, "entries persist after closing and reopening database")
            try repository!.deleteEntry("expense")
            data = try repository!.snapshot(month: month, limit: 100, kind: nil, category: "")
            suite.expect(data.count == 1 && data.expense == 0, "deletion updates monthly totals")
            try repository!.archiveCategory(expense.id, archived: false)
            try repository!.saveEntry(id: "restored", amount: 100, category: expense.id, date: month, note: "")
            suite.expect(true, "reactivated category accepts new entries")
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            suite.expect(permissions?.intValue == 0o600, "database is owner-only")
        } catch { suite.expect(false, "database test failed: \(error)") }
    }
}
