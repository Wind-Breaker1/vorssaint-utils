// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum LedgerKind: String, Codable, CaseIterable, Identifiable {
    case expense, income
    var id: String { rawValue }
    var title: String { self == .expense ? "支出" : "收入" }
}

struct LedgerCategory: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let kind: LedgerKind
    let archived: Bool
}

struct LedgerEntry: Codable, Identifiable, Equatable {
    let id: String
    let amount: Int64
    let categoryID: String
    let categoryName: String
    let kind: LedgerKind
    let date: Date
    let note: String
}

struct LedgerCategoryTotal: Identifiable {
    let id: String
    let name: String
    let kind: LedgerKind
    let amount: Int64
}

struct LedgerDailyTotal: Identifiable {
    var id: String { "\(day)-\(kind.rawValue)" }
    let day: Int
    let kind: LedgerKind
    let amount: Int64
}

struct LedgerSnapshot {
    var dailyTotals: [LedgerDailyTotal] = []
    var categories: [LedgerCategory] = []
    var entries: [LedgerEntry] = []
    var totals: [LedgerCategoryTotal] = []
    var count = 0
    var income: Int64 { totals.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount } }
    var expense: Int64 { totals.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount } }
}

enum LedgerMoney {
    // Integer parsing avoids binary floating point and rejects fractional cents.
    static func parse(_ text: String) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              parts.count == 1 || (1...2).contains(parts[1].count),
              let whole = Int64(parts[0]), whole <= 9_999_999_999 else { return nil }
        let fraction = parts.count == 2 ? Int64(parts[1])! * (parts[1].count == 1 ? 10 : 1) : 0
        let cents = whole * 100 + fraction
        return cents > 0 ? cents : nil
    }
    static func decimal(_ cents: Int64) -> String {
        "\(cents / 100).\(String(format: "%02lld", cents % 100))"
    }
    static func display(_ cents: Int64) -> String { "¥" + decimal(cents) }
}
