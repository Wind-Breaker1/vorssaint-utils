// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

struct StockError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum StockDay {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c
    }
    static func string(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    static func date(_ text: String) -> Date? {
        let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let d = f.date(from: text), string(d) == text else { return nil }; return d
    }
    static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }
    static func year(_ day: String) throws -> Int {
        guard date(day) != nil, let n = Int(day.prefix(4)), (1990...2199).contains(n) else { throw StockError("日期无效：\(day)") }; return n
    }
}

enum StockDecimal {
    static let locale = Locale(identifier: "en_US_POSIX")
    static func parse(_ value: String, signed: Bool = false) throws -> Decimal {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = signed ? #"^-?[0-9]{1,12}(\.[0-9]{1,6})?$"# : #"^[0-9]{1,12}(\.[0-9]{1,6})?$"#
        guard text.range(of: pattern, options: .regularExpression) != nil,
              let n = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { throw StockError("无效数字：\(value)，最多保留 6 位小数") }
        return n
    }
    static func text(_ n: Decimal) -> String { NSDecimalNumber(decimal: n).stringValue }
    static func display(_ n: Decimal, digits: Int = 2) -> String {
        let f = NumberFormatter(); f.locale = Locale(identifier: "zh_CN"); f.numberStyle = .decimal
        f.minimumFractionDigits = digits; f.maximumFractionDigits = digits
        return f.string(from: NSDecimalNumber(decimal: n)) ?? text(n)
    }
}

struct StockInstrument: Codable, Equatable, Identifiable {
    var symbol: String
    var name: String
    var exchange: String = "SH"
    var kind: String = "stock"
    var id: String { exchange + symbol }
    var quoteCode: String { exchange.lowercased() + symbol }
    func validate() throws {
        guard symbol.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil,
              ["SH", "SZ", "BJ"].contains(exchange), ["stock", "etf"].contains(kind), !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw StockError("请填写六位证券代码、名称、市场和股票/ETF 类型") }
        let validStock = (exchange == "SH" && symbol.hasPrefix("6")) || (exchange == "SZ" && (symbol.hasPrefix("00") || symbol.hasPrefix("30"))) || (exchange == "BJ" && ["4","8","9"].contains(String(symbol.prefix(1))))
        let validETF = (exchange == "SH" && symbol.hasPrefix("5")) || (exchange == "SZ" && (symbol.hasPrefix("15") || symbol.hasPrefix("16")))
        guard kind == "stock" ? validStock : validETF else { throw StockError("证券代码与市场、股票/场内基金类型不匹配；暂不支持债券、港美股") }
    }
    static func inferred(_ symbol: String, name: String = "") -> StockInstrument {
        let exchange = symbol.hasPrefix("6") || symbol.hasPrefix("5") ? "SH" : (["4","8","9"].contains(String(symbol.prefix(1))) ? "BJ" : "SZ")
        let kind = symbol.hasPrefix("5") || symbol.hasPrefix("15") || symbol.hasPrefix("16") ? "etf" : "stock"
        return StockInstrument(symbol: symbol, name: name.isEmpty ? symbol : name, exchange: exchange, kind: kind)
    }
}

enum StockAction: String, Codable, CaseIterable, Identifiable {
    case buy, sell, dividend, shares
    var id: String { rawValue }
    var title: String { switch self { case .buy: return "买入"; case .sell: return "卖出"; case .dividend: return "现金分红"; case .shares: return "份额调整" } }
}

struct StockTrade: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var instrument: StockInstrument
    var date: String = StockDay.string()
    var time: String = "09:30:00"
    var action: StockAction = .buy
    var price: String = ""
    var quantity: String = ""
    var commission: String = "0"
    var tax: String = "0"
    var otherFees: String = "0"
    var brokerID: String = ""
    var strategy: String = ""
    var note: String = ""
    var planID: String? = nil
    var createdAt: String = StockDay.timestamp()
    var updatedAt: String = StockDay.timestamp()
    var deletedAt: String? = nil
    var sortKey: String { date + "T" + time + createdAt + id }
    var fingerprint: String { [instrument.id,date,time,action.rawValue,price,quantity,commission,tax,otherFees].joined(separator: "|") }
    var fee: Decimal { (try? StockDecimal.parse(commission))! + (try? StockDecimal.parse(tax))! + (try? StockDecimal.parse(otherFees))! }
    func validate() throws {
        try instrument.validate(); _ = try StockDay.year(date)
        guard UUID(uuidString: id) != nil, time.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$"#, options: .regularExpression) != nil else { throw StockError("成交 ID 或时间无效") }
        let p = try StockDecimal.parse(price), q = try StockDecimal.parse(quantity, signed: action == .shares)
        _ = try StockDecimal.parse(commission); _ = try StockDecimal.parse(tax); _ = try StockDecimal.parse(otherFees)
        if action == .buy || action == .sell {
            guard p > 0, q > 0 else { throw StockError("成交价格和数量必须大于零") }
        } else if action == .dividend {
            guard p > 0, q == 0 else { throw StockError("现金分红：价格栏填写税前总额，数量填 0，税费按实际填写") }
        } else { guard q != 0, p == 0 else { throw StockError("份额调整：数量填增减份额，价格填 0；总成本保持不变") } }
    }
}

struct StockPlan: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var symbol = ""
    var condition = ""
    var position = ""
    var stopLoss = ""
    var status = "待验证"
    var outcome = ""
    var createdAt = StockDay.timestamp()
    var updatedAt = StockDay.timestamp()
    var versions: [StockPlanVersion]? = nil
    var changeReason: String? = nil
}
struct StockReview: Codable, Equatable, Identifiable {
    var date: String
    var id: String { date }
    var summary = ""
    var execution = ""
    var lesson = ""
    var emotion = ""
    var plans: [StockPlan] = []
    var tradeIDs: [String] = []
    var updatedAt = StockDay.timestamp()
    var journal: StockReviewJournal? = nil
}
struct StockQuote: Codable, Equatable, Identifiable {
    var code: String
    var name: String
    var price: Double
    var change: Double
    var amount: Double
    var date: String
    var id: String { code }
}
struct StockBar: Codable, Equatable, Identifiable {
    var date: String
    var open: Double
    var close: Double
    var high: Double
    var low: Double
    var volume: Double
    var id: String { date }
}
struct StockLimit: Codable, Equatable, Identifiable {
    var code: String
    var name: String
    var boards: Int
    var industry: String
    var firstTime: String
    var breaks: Int
    var change: Double
    var id: String { code }
}
struct StockSector: Codable, Equatable, Identifiable {
    var code: String
    var name: String
    var kind: String
    var change: Double
    var amount: Double
    var rank: Int
    var id: String { kind + code }
}
struct StockSource: Codable, Equatable, Identifiable {
    var name: String
    var url: String
    var fetchedAt: String = StockDay.timestamp()
    var status: String
    var detail: String
    var id: String { name }
}
struct StockMarketSnapshot: Codable, Equatable, Identifiable {
    var date: String
    var id: String { date }
    var fetchedAt = StockDay.timestamp()
    var indices: [StockQuote] = []
    var quotes: [StockQuote] = []
    var limits: [StockLimit] = []
    var sectors: [StockSector] = []
    var metrics: [String: Double] = [:]
    var sources: [StockSource] = []
    var industryDecliners: [StockSector]? = nil
    var previousTradingDay: String? = nil
    var formulaVersion = 1

}
struct StockYear<T: Codable>: Codable {
    var schemaVersion = 1
    var year: Int
    var entries: [T]
}
struct StockChartRecord: Codable {
    var code: String
    var bars: [StockBar]
}
struct StockDataset {
    var rules = StockRuleBook.defaults
    var charts: [String: [StockBar]] = [:]
    var trades: [StockTrade] = []
    var reviews: [StockReview] = []
    var snapshots: [StockMarketSnapshot] = []
    var watchlist: [StockInstrument] = []
    var revision = ""
}

struct StockPosition: Identifiable {
    var instrument: StockInstrument
    var quantity: Decimal = 0
    var cost: Decimal = 0
    var realized: Decimal = 0
    var dividends: Decimal = 0
    var id: String { instrument.id }
    var average: Decimal { quantity > 0 ? cost / quantity : 0 }
}
struct StockLedger {
    var positions: [StockPosition]
    var saleProfit: [String: Decimal]
    var fees: Decimal
    var realized: Decimal { positions.reduce(0) { $0 + $1.realized } }
    static func calculate(_ trades: [StockTrade]) throws -> StockLedger {
        var positions: [String: StockPosition] = [:], profits: [String: Decimal] = [:]
        var fees: Decimal = 0
        for t in trades.filter({ $0.deletedAt == nil }).sorted(by: { $0.sortKey < $1.sortKey }) {
            try t.validate()
            let q = try StockDecimal.parse(t.quantity, signed: t.action == .shares), p = try StockDecimal.parse(t.price)
            var s = positions[t.instrument.id] ?? StockPosition(instrument: t.instrument)
            s.instrument = t.instrument
            switch t.action {
            case .buy: s.quantity += q; s.cost += p * q + t.fee
            case .sell:
                guard s.quantity >= q else { throw StockError("\(t.date) \(t.instrument.name)：卖出 \(t.quantity) 超过当时持仓 \(StockDecimal.text(s.quantity))，请补齐更早的成交") }
                let removed = q == s.quantity ? s.cost : s.cost * q / s.quantity
                let profit = p * q - t.fee - removed
                s.cost -= removed; s.quantity -= q; s.realized += profit; profits[t.id] = profit
            case .dividend:
                guard s.quantity > 0 else { throw StockError("\(t.date) \(t.instrument.name)：分红前没有持仓") }
                s.dividends += p - t.fee; s.realized += p - t.fee
            case .shares:
                guard s.quantity > 0, s.quantity + q > 0 else { throw StockError("份额调整后必须保留正数持仓；清仓请记录卖出") }
                s.quantity += q; s.cost += t.fee
            }
            fees += t.fee; positions[t.instrument.id] = s
        }
        return StockLedger(positions: positions.values.sorted { $0.id < $1.id }, saleProfit: profits, fees: fees)
    }
}
