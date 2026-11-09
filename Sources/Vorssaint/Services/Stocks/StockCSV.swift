// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation
import CoreFoundation

struct StockImportRow: Identifiable {
    var line: Int
    var trade: StockTrade?
    var message: String
    var duplicate: Bool
    var selected: Bool
    var id: Int { line }
}
enum StockCSV {
    static let headers = ["记录ID","证券代码","证券名称","市场","类型","成交日期","成交时间","买卖方向","成交价格","成交数量","佣金","印花税","其他费用","成交编号","策略","备注","计划ID"]
    static func decode(_ data: Data) throws -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: encoding)) { return s }
        throw StockError("无法读取文件编码，请导出 UTF-8 或 GB18030 CSV/TSV")
    }
    static func parse(_ input: String) throws -> [[String]] {
        let text = input.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let first = String(text.prefix { $0 != "\n" }), separator: Character = first.contains("\t") ? "\t" : ","
        let chars = Array(text); var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, closed = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" { cell.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { cell.append(c) }
            } else if c == separator || c == "\n" {
                row.append(cell); cell = ""; closed = false
                if c == "\n" { if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = [] }
            } else if c == "\"" && cell.isEmpty && !closed { quoted = true }
            else { guard !closed else { throw StockError("CSV 引号后的内容无效") }; cell.append(c) }
            i += 1
        }
        guard !quoted else { throw StockError("CSV 引号未闭合") }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }
    static func preview(_ text: String, existing: [StockTrade]) throws -> [StockImportRow] {
        let rows = try parse(text)
        guard let header = rows.first, rows.count > 1 else { throw StockError("文件需要包含表头和成交记录") }
        let normalized = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func index(_ aliases: [String]) -> Int? { aliases.compactMap { normalized.firstIndex(of: $0.lowercased()) }.first }
        guard index(["证券代码","股票代码","代码","symbol"]) != nil,
              index(["成交日期","交易日期","业务日期","日期","date"]) != nil,
              index(["买卖方向","操作","买卖标志","业务名称","交易类别","方向","side"]) != nil else { throw StockError("未找到证券代码、成交日期或买卖方向列。请参考导出的 CSV 模板") }
        var known = existing.filter { $0.deletedAt == nil }
        return rows.dropFirst().enumerated().map { offset, cells in
            func get(_ aliases: [String], fallback: String = "") -> String {
                guard let i = index(aliases), i < cells.count else { return fallback }
                var s = cells[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if s.hasPrefix("'") { s.removeFirst() }
                if s.hasPrefix("=\""), s.hasSuffix("\"") { s = String(s.dropFirst(2).dropLast()) }
                return s.isEmpty ? fallback : s
            }
            do {
                guard cells.count == header.count else { throw StockError("列数与表头不一致") }
                var symbol = get(["证券代码","股票代码","代码","symbol"]).uppercased()
                var market = get(["市场","交易市场","exchange"]).uppercased()
                for exchange in ["SH","SZ","BJ"] {
                    if symbol.hasPrefix(exchange) { market = exchange; symbol = String(symbol.dropFirst(2)) }
                    if symbol.hasSuffix("." + exchange) { market = exchange; symbol = String(symbol.dropLast(3)) }
                }
                guard symbol.count == 6, symbol.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw StockError("证券代码须保留完整六位，不能自动补零猜测") }
                var instrument = StockInstrument.inferred(symbol, name: get(["证券名称","股票名称","名称","name"], fallback: symbol))
                if ["SH","沪A","上海","沪市","沪Ａ"].contains(market) { instrument.exchange = "SH" }
                else if ["SZ","深A","深圳","深市","深Ａ"].contains(market) { instrument.exchange = "SZ" }
                else if ["BJ","北A","北京","北交所"].contains(market) { instrument.exchange = "BJ" }
                else if !market.isEmpty { throw StockError("不支持的市场：\(market)") }
                let kind = get(["类型","证券类型","kind"])
                if !kind.isEmpty {
                    if ["ETF","etf","基金"].contains(kind) { instrument.kind = "etf" }
                    else if ["stock","股票","A股"].contains(kind) { instrument.kind = "stock" }
                    else { throw StockError("仅支持 A 股股票及场内 ETF") }
                }
                var day = get(["成交日期","交易日期","业务日期","日期","date"]).replacingOccurrences(of: "/", with: "-")
                if day.count == 8 && day.allSatisfy(\.isNumber) { day = String(day.prefix(4)) + "-" + String(day.dropFirst(4).prefix(2)) + "-" + String(day.suffix(2)) }
                let pieces = day.split(separator: "-")
                if pieces.count == 3, let month = Int(pieces[1]), let d = Int(pieces[2]) { day = "\(pieces[0])-" + String(format: "%02d-%02d", month,d) }
                let direction = get(["买卖方向","操作","买卖标志","业务名称","交易类别","方向","side"])
                let action: StockAction
                switch direction.lowercased() {
                case "买入","证券买入","买","buy": action = .buy
                case "卖出","证券卖出","卖","sell": action = .sell
                case "现金分红","红利入账","dividend": action = .dividend
                case "份额调整","shares": action = .shares
                default: throw StockError("不支持的业务类型：\(direction)，请手动核对")
                }
                var time = get(["成交时间","交易时间","时间","time"], fallback: "09:30:00")
                if time.count == 6 && time.allSatisfy(\.isNumber) { time = String(time.prefix(2)) + ":" + String(time.dropFirst(2).prefix(2)) + ":" + String(time.suffix(2)) }
                if time.count == 5 { time += ":00" }
                func number(_ aliases: [String], fallback: String = "0", signed: Bool = false) throws -> String {
                    let raw = get(aliases, fallback: fallback).replacingOccurrences(of: ",", with: "")
                    return StockDecimal.text(try StockDecimal.parse(raw, signed: signed))
                }
                var trade = StockTrade(instrument: instrument, date: day, time: time, action: action,
                    price: try number(["成交价格","成交均价","价格","price"], fallback: action == .shares ? "0" : ""),
                    quantity: try number(["成交数量","数量","quantity"], fallback: action == .dividend ? "0" : "", signed: action == .shares),
                    commission: try number(["佣金","手续费","commission"]), tax: try number(["印花税","税费","tax"]),
                    otherFees: try number(["其他费用","otherfees"]), brokerID: get(["成交编号","成交序号","brokerid"]),
                    strategy: get(["策略","strategy"]), note: get(["备注","说明","note"]))
                // Some brokers expose transfer fees separately from other fees.
                trade.otherFees = StockDecimal.text(try StockDecimal.parse(trade.otherFees) + StockDecimal.parse(number(["过户费"])))
                let identifier = get(["记录ID"]); if !identifier.isEmpty { trade.id = identifier }
                let plan = get(["计划ID"]); trade.planID = plan.isEmpty ? nil : plan
                // Preserve CSV row order when fills have the same execution timestamp.
                trade.createdAt = StockDay.timestamp() + String(format: "-%08d", offset)
                try trade.validate()
                let duplicate = known.contains { $0.id == trade.id || (!$0.brokerID.isEmpty && $0.brokerID == trade.brokerID && $0.date == trade.date && $0.instrument.id == trade.instrument.id) }
                let possible = known.contains { $0.fingerprint == trade.fingerprint }
                known.append(trade)
                let missingFees = index(["佣金","手续费","commission"]) == nil && index(["印花税","税费","tax"]) == nil
                let message = duplicate ? "成交编号或记录 ID 重复，禁止重复导入" : possible ? "疑似重复：时间、价格、数量相同，请核对后勾选" : (missingFees ? "缺少费用列，暂按 0；请补录实际费用" : "可导入")
                return StockImportRow(line: offset + 2, trade: trade, message: message, duplicate: duplicate, selected: !duplicate && !possible)
            } catch { return StockImportRow(line: offset + 2, trade: nil, message: error.localizedDescription, duplicate: false, selected: false) }
        }
    }
    private static func quote(_ text: String) -> String {
        var s = text
        if let first = s.first, ["=","+","-","@","\t","\r"].contains(first) { s = "'" + s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func export(_ trades: [StockTrade]) -> String {
        var rows = [headers.map(quote).joined(separator: ",")]
        for t in trades.filter({ $0.deletedAt == nil }).sorted(by: { $0.sortKey < $1.sortKey }) {
            let values = [t.id,t.instrument.symbol,t.instrument.name,t.instrument.exchange,t.instrument.kind,t.date,t.time,t.action.title,t.price,t.quantity,t.commission,t.tax,t.otherFees,t.brokerID,t.strategy,t.note,t.planID ?? ""]
            rows.append(values.map(quote).joined(separator: ","))
        }
        return "\u{feff}" + rows.joined(separator: "\r\n") + "\r\n"
    }
}
