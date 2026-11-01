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
            let url = root.appendingPathComponent("Years", isDirectory: true)
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
            suite.expect(data.expense == 1234 && data.income == 5000, "JSON aggregation covers entire month, excluding end boundary")
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
            suite.expect(data.count == 2 && data.expense == 2000, "entries persist after reopening annual JSON storage")
            try repository!.deleteEntry("expense")
            data = try repository!.snapshot(month: month, limit: 100, kind: nil, category: "")
            suite.expect(data.count == 1 && data.expense == 0, "deletion updates monthly totals")
            try repository!.archiveCategory(expense.id, archived: false)
            try repository!.saveEntry(id: "restored", amount: 100, category: expense.id, date: month, note: "")
            suite.expect(true, "reactivated category accepts new entries")
            let permissions = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("categories.json").path)[.posixPermissions] as? NSNumber
            suite.expect(permissions?.intValue == 0o600, "JSON is owner-only")
            try storageMove(suite, root: root)
            try sharedDirectory(suite, root: root)
            try simpleAnnualFiles(suite, root: root)
        } catch { suite.expect(false, "JSON repository test failed: \(error)") }
    }
    private static func storageMove(_ suite: TestSuite, root: URL) throws {
        let source = root.appendingPathComponent("MoveSource")
        let repository = try AccountingRepository(url: source)
        let category = try repository.snapshot(month: .now, limit: 100, kind: nil, category: "").categories.first!.id
        try repository.saveEntry(id: "entry", amount: 1234, category: category, date: .now, note: "原始内容")
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        let original = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let destination = root.appendingPathComponent("MoveTarget")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let moved = try repository.moveStorage(to: destination)
        suite.expect(try moved.snapshot(month: .now, limit: 100, kind: nil, category: "").expense == 1234, "moving JSON preserves financial data")
        suite.expect(try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).isEmpty, "successful migration removes source JSON")
        for (name, data) in original { suite.expect(try Data(contentsOf: destination.appendingPathComponent(name)) == data, "migration preserves JSON bytes: \(name)") }
        let nonempty = root.appendingPathComponent("Nonempty")
        try FileManager.default.createDirectory(at: nonempty, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: nonempty.appendingPathComponent("2026.json"))
        do { _ = try moved.moveStorage(to: nonempty); suite.expect(false, "nonempty destination rejected") }
        catch { suite.expect(try moved.snapshot(month: .now, limit: 100, kind: nil, category: "").expense == 1234, "rejected migration retains active data") }
        do { _ = try moved.moveStorage(to: destination); suite.expect(false, "same path rejected") }
        catch { suite.expect(true, "migration rejects same path") }
    }

    private static func sharedDirectory(_ suite: TestSuite, root: URL) throws {
        let folder = root.appendingPathComponent("SharedDirect")
        let a = try AccountingRepository(url: folder)
        let b = try AccountingRepository(url: folder)
        let month = Date()
        try a.saveCategory(id: "shared-category", name: "旅行", kind: .expense)
        try b.saveEntry(id: "from-b", amount: 123, category: "shared-category", date: month, note: "")
        try a.archiveCategory("shared-category", archived: true)
        let view = try b.snapshot(month: month, limit: 100, kind: nil, category: "")
        suite.expect(view.categories.first(where: { $0.id == "shared-category" })?.archived == true, "shared categories JSON refreshes across repository instances")
        suite.expect(view.expense == 123, "shared directory preserves entry category and amount")
        try b.saveCategory(id: "shared-category", name: "出行", kind: .expense)
        suite.expect(try a.snapshot(month: month, limit: 100, kind: nil, category: "").entries.first?.categoryName == "出行", "category rename is read from shared categories JSON")
        let originalDefault = try a.snapshot(month: month, limit: 100, kind: nil, category: "").categories.first { $0.id.hasPrefix("default-") }!
        try a.saveCategory(id: originalDefault.id, name: "自定分类名称", kind: originalDefault.kind)
        let destination = root.appendingPathComponent("CopiedShared")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let moved = try a.moveStorage(to: destination)
        suite.expect(try moved.snapshot(month: month, limit: 100, kind: nil, category: "").categories.contains(where: { $0.id == originalDefault.id && $0.name == "自定分类名称" }), "new storage preserves renamed default categories")
        let categoryData = try Data(contentsOf: destination.appendingPathComponent("categories.json"))
        let categories = try JSONDecoder().decode([LedgerCategory].self, from: categoryData)
        suite.expect(categories.contains(where: { $0.id == "shared-category" && $0.archived && $0.name == "出行" }), "JSON persists category name and disabled state")
        let yearFile = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).first { $0.lastPathComponent != "categories.json" }!
        let oldDate = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: yearFile.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: destination.appendingPathComponent("categories.json").path)
        _ = try moved.snapshot(month: month, limit: 100, kind: nil, category: "")
        suite.expect(try FileManager.default.attributesOfItem(atPath: yearFile.path)[.modificationDate] as? Date == oldDate, "refresh does not rewrite annual JSON")
        suite.expect(try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("categories.json").path)[.modificationDate] as? Date == oldDate, "refresh does not rewrite unchanged categories")
    }

    private static func simpleAnnualFiles(_ suite: TestSuite, root: URL) throws {
        let folder = root.appendingPathComponent("SimpleAnnual")
        let repository = try AccountingRepository(url: folder)
        let month = Date()
        let category = try repository.snapshot(month: month, limit: 100, kind: nil, category: "").categories.first!.id
        try repository.saveEntry(id: "move", amount: 1234, category: category, date: month, note: "original")
        let next = Calendar.current.date(byAdding: .year, value: 1, to: month)!
        try repository.saveEntry(id: "move", amount: 4321, category: category, date: next, note: "new year")
        suite.expect(try repository.snapshot(month: month, limit: 100, kind: nil, category: "").count == 0, "cross-year edit removes old row")
        suite.expect(try repository.snapshot(month: next, limit: 100, kind: nil, category: "").entries.first?.amount == 4321, "cross-year edit preserves updated row")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != "categories.json" }
        let populated = try files.first { url in
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            return !(json["entries"] as! [Any]).isEmpty
        }!
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: populated)) as! [String: Any]
        suite.expect(json["revisions"] == nil && (json["entries"] as? [Any])?.count == 1, "annual JSON stores plain entries without revision chains")
        try repository.deleteEntry("move")
        suite.expect(try repository.snapshot(month: next, limit: 100, kind: nil, category: "").count == 0, "delete removes row from simple annual file")
        try Data("broken".utf8).write(to: populated)
        do { try repository.saveEntry(id: "new", amount: 100, category: category, date: next, note: ""); suite.expect(false, "corrupt annual file must reject writes") }
        catch { suite.expect(try Data(contentsOf: populated) == Data("broken".utf8), "corrupt JSON stays intact instead of being replaced") }
    }

}
