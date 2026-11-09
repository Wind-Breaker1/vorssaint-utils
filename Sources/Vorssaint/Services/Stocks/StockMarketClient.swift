// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation
import CoreFoundation

/// Free public sources, using the same upstream families documented by AKShare.
/// Every source has an explicit date/status; absence is never a zero reading.
enum StockMarketClient {
    static func request(_ url: String) async throws -> Data {
        guard let address = URL(string: url) else { throw StockError("行情地址无效") }
        var last: Error = StockError("网络请求失败")
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var req = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.setValue("Mozilla/5.0 Vorssaint", forHTTPHeaderField: "User-Agent")
            req.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count < 12_000_000 else { throw StockError("上游响应异常") }
                return data
            } catch { last = error; if attempt == 0 { try await Task.sleep(nanoseconds: 500_000_000) } }
        }
        throw last
    }
    static func json(_ url: String) async throws -> [String: Any] {
        let bytes = try await request(url)
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              (root["rc"] as? Int ?? root["code"] as? Int ?? 0) == 0 else { throw StockError("上游返回错误或格式已变化") }; return root
    }
    static func searchInstruments(_ name: String) async throws -> [StockInstrument] {
        var url = URLComponents(string: "https://searchapi.eastmoney.com/api/suggest/get")!
        url.queryItems = [URLQueryItem(name: "input", value: name), URLQueryItem(name: "type", value: "14"), URLQueryItem(name: "count", value: "30")]
        let root = try await json(url.url!.absoluteString)
        return try parseInstruments(root)
    }
    static func parseInstruments(_ root: [String: Any]) throws -> [StockInstrument] {
        guard let table = root["QuotationCodeTable"] as? [String: Any], let rows = table["Data"] as? [[String: Any]], (table["Status"] as? Int ?? -1) == 0 else { throw StockError("证券搜索暂不可用") }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let code = row["Code"] as? String, let name = row["Name"] as? String,
                  let market = row["MktNum"] as? String, ["0", "1", "116"].contains(market) else { return nil }
            let item = StockInstrument.inferred(code, name: name)
            guard (try? item.validate()) != nil, seen.insert(item.id).inserted else { return nil }
            return item
        }
    }
    static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let n = value as? NSNumber { result = n.doubleValue } else if let s = value as? String { result = Double(s) } else { result = nil }
        guard let result, result.isFinite else { return nil }; return result
    }
    static func parseQuotes(_ data: Data) throws -> [StockQuote] {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) else { throw StockError("行情编码无法读取") }
        var quotes: [StockQuote] = []
        for line in text.components(separatedBy: ";") {
            guard let marker = line.range(of: "=\"") else { continue }
            let prefix = String(line[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = line[marker.upperBound...].split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > 37, let price = Double(fields[3]), price > 0, let change = Double(fields[32]), fields[30].count >= 8 else { continue }
            let raw = fields[30], day = String(raw.prefix(4)) + "-" + String(raw.dropFirst(4).prefix(2)) + "-" + String(raw.dropFirst(6).prefix(2))
            guard StockDay.date(day) != nil else { continue }
            quotes.append(StockQuote(code: prefix.replacingOccurrences(of: "v_", with: ""), name: fields[1], price: price, change: change, amount: (Double(fields[37]) ?? 0) * 10_000, date: day))
        }
        guard !quotes.isEmpty else { throw StockError("行情暂无有效读数") }; return quotes
    }
    static func quotes(_ codes: [String]) async throws -> [StockQuote] {
        let unique = Array(Set(codes)).sorted()
        guard unique.allSatisfy({ $0.range(of: #"^(sh|sz|bj)[0-9]{6}$"#, options: .regularExpression) != nil }) else { throw StockError("行情代码无效") }
        var output: [StockQuote] = []
        for start in stride(from: 0, to: unique.count, by: 60) {
            let chunk = unique[start..<min(start + 60, unique.count)]
            output += try parseQuotes(await request("https://qt.gtimg.cn/q=" + chunk.joined(separator: ",")))
        }
        return output
    }
    static func bars(_ code: String, count: Int = 240) async throws -> [StockBar] {
        guard code.range(of: #"^(sh|sz|bj)[0-9]{6}$"#, options: .regularExpression) != nil else { throw StockError("证券代码无效") }
        let root = try await json("https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(code),day,,,\(count),")
        guard let data = root["data"] as? [String: Any], let stock = data[code] as? [String: Any], let rows = stock["day"] as? [[Any]] else { throw StockError("日 K 暂不可用（部分北交所证券可能不受此来源支持）") }
        let bars = rows.compactMap { row -> StockBar? in
            guard row.count >= 6, let date = row[0] as? String, StockDay.date(date) != nil,
                  let o = number(row[1]), let c = number(row[2]), let h = number(row[3]), let l = number(row[4]), let v = number(row[5]), o > 0, c > 0, h >= l else { return nil }
            return StockBar(date: date, open: o, close: c, high: h, low: l, volume: v)
        }
        guard bars.count == rows.count, !bars.isEmpty else { throw StockError("日 K 数据不完整") }; return bars.sorted { $0.date < $1.date }
    }
    static func eligibleDays(now: Date = Date()) async throws -> [String] {
        let history = try await bars("sh000001", count: 90)
        let today = StockDay.string(now), c = StockDay.calendar.dateComponents([.hour,.minute], from: now)
        let closed = (c.hour ?? 0) * 60 + (c.minute ?? 0) >= 15 * 60 + 30
        return history.map(\.date).filter { $0 < today || ($0 == today && closed) }
    }
    static func poolURL(_ kind: String, day: String) -> String {
        let endpoint = kind == "YESTERDAY" ? "getYesterdayZTPool" : "getTopic\(kind)Pool"
        let sort = kind == "DT" ? "fund:asc" : kind == "YESTERDAY" ? "zs:desc" : "fbt:asc"
        return "https://push2ex.eastmoney.com/\(endpoint)?ut=7eea3edcaed734bea9cbfc24409ed989&dpt=wz.ztzt&Pageindex=0&pagesize=1000&sort=\(sort)&date=" + day.replacingOccurrences(of: "-", with: "")
    }
    static func pool(_ kind: String, day: String) async throws -> [[String: Any]] {
        let root = try await json(poolURL(kind, day: day))
        guard let data = root["data"] as? [String: Any], let date = number(data["qdate"]),
              Int(date) == Int(day.replacingOccurrences(of: "-", with: "")), let rows = data["pool"] as? [[String: Any]],
              let total = number(data["tc"]), Int(total) == rows.count else { throw StockError("该日期股票池缺失、日期不匹配或返回不完整；历史接口覆盖有限") }; return rows
    }
    static func limits(_ rows: [[String: Any]]) throws -> [StockLimit] {
        try rows.map { row in
            guard let code = row["c"] as? String, let name = row["n"] as? String, let boards = number(row["lbc"]), let change = number(row["zdp"]) else { throw StockError("涨停池字段缺失") }
            return StockLimit(code: code, name: name, boards: Int(boards), industry: row["hybk"] as? String ?? "未分类", firstTime: String(format: "%06d", Int(number(row["fbt"]) ?? 0)), breaks: Int(number(row["zbc"]) ?? 0), change: change)
        }.sorted { $0.boards == $1.boards ? $0.firstTime < $1.firstTime : $0.boards > $1.boards }
    }
    static let breadthURL = "https://push2.eastmoney.com/api/qt/ulist.np/get?secids=1.000001,0.399001,0.899050&fields=f12,f14,f104,f105,f106,f6,f3,f2,f124&fltt=2"
    static func breadth(day: String) async throws -> [String: Double] {
        let root = try await json(breadthURL)
        guard let data = root["data"] as? [String: Any], let rows = data["diff"] as? [[String: Any]], rows.count == 3 else { throw StockError("市场广度数据缺失") }
        var output: [String: Double] = ["上涨家数":0,"下跌家数":0,"平盘家数":0,"沪深成交额":0,"北交所成交额":0]
        for row in rows {
            guard let timestamp = number(row["f124"]), StockDay.string(Date(timeIntervalSince1970: timestamp)) == day,
                  let up = number(row["f104"]), let down = number(row["f105"]), let flat = number(row["f106"]), let amount = number(row["f6"]) else { throw StockError("市场广度仅提供最新行情，无法补回该日读数") }
            output["上涨家数"]! += up; output["下跌家数"]! += down; output["平盘家数"]! += flat
            output[(row["f12"] as? String) == "899050" ? "北交所成交额" : "沪深成交额"]! += amount
        }; return output
    }
    static func sectorURL(_ kind: String, ascending: Bool = false) -> String {
        "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=100&po=\(ascending ? 0 : 1)&np=1&fltt=2&invt=2&fid=f3&fs=m:90+t:\(kind == "行业" ? "2" : "3")&fields=f12,f14,f2,f3,f6,f124"
    }
    static func sectors(_ kind: String, day: String, ascending: Bool = false) async throws -> [StockSector] {
        let root = try await json(sectorURL(kind, ascending: ascending))
        guard let data = root["data"] as? [String: Any], let rows = data["diff"] as? [[String: Any]], !rows.isEmpty else { throw StockError("板块行情暂无数据") }
        return try rows.enumerated().map { index, row in
            guard let code = row["f12"] as? String, let name = row["f14"] as? String, let change = number(row["f3"]), let amount = number(row["f6"]), let stamp = number(row["f124"]), StockDay.string(Date(timeIntervalSince1970: stamp)) == day else { throw StockError("板块排名仅提供最新行情，无法补回该日排名") }
            return StockSector(code: code, name: name, kind: kind, change: change, amount: amount, rank: index + 1)
        }
    }
    private static func result<T>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }
    static func collect(day: String, previous: String?, instruments: [StockInstrument]) async throws -> StockMarketSnapshot {
        _ = try StockDay.year(day)
        async let up = result { try await pool("ZT", day: day) }
        async let down = result { try await pool("DT", day: day) }
        async let broken = result { try await pool("ZB", day: day) }
        async let broad = result { try await breadth(day: day) }
        async let industry = result { try await sectors("行业", day: day) }
        async let decliners = result { try await sectors("行业", day: day, ascending: true) }
        async let concept = result { try await sectors("概念", day: day) }
        async let quoteResult = result { try await quotes(["sh000001","sz399001","sz399006"] + instruments.map(\.quoteCode)) }
        var snapshot = StockMarketSnapshot(date: day)
        snapshot.previousTradingDay = previous
        func accept<T>(_ result: Result<T, Error>, name: String, url: String, consume: (T) throws -> Void) {
            do { try consume(result.get()); snapshot.sources.append(StockSource(name: name, url: url, status: "ok", detail: "按交易日 \(day) 校验")) }
            catch { snapshot.sources.append(StockSource(name: name, url: url, status: "missing", detail: error.localizedDescription)) }
        }
        accept(await up, name: "涨停池", url: poolURL("ZT", day: day)) { rows in
            snapshot.limits = try limits(rows); snapshot.metrics["涨停家数"] = Double(rows.count)
            snapshot.metrics["最高连板"] = Double(snapshot.limits.map(\.boards).max() ?? 0)
            snapshot.metrics["首板家数"] = Double(snapshot.limits.filter { $0.boards == 1 }.count)
        }
        accept(await down, name: "跌停池", url: poolURL("DT", day: day)) { snapshot.metrics["跌停家数"] = Double($0.count) }
        accept(await broken, name: "炸板池", url: poolURL("ZB", day: day)) { snapshot.metrics["炸板家数"] = Double($0.count) }
        accept(await broad, name: "市场广度", url: breadthURL) { snapshot.metrics.merge($0) { _, n in n } }
        accept(await industry, name: "行业涨幅前100", url: sectorURL("行业")) { snapshot.sectors += $0 }
        accept(await decliners, name: "行业跌幅前100", url: sectorURL("行业", ascending: true)) { snapshot.industryDecliners = $0 }
        accept(await concept, name: "概念涨幅前100", url: sectorURL("概念")) { snapshot.sectors += $0 }
        accept(await quoteResult, name: "指数与关注证券", url: "https://qt.gtimg.cn/") { rows in
            let valid = rows.filter { $0.date == day }
            guard !valid.isEmpty else { throw StockError("实时行情日期与复盘日期不符；不会将今日行情写入历史复盘") }
            snapshot.indices = valid.filter { ["sh000001","sz399001","sz399006"].contains($0.code) }
            snapshot.quotes = valid.filter { !["sh000001","sz399001","sz399006"].contains($0.code) }
            let missing = instruments.map(\.quoteCode).filter { !valid.map(\.code).contains($0) }
            if !missing.isEmpty { throw StockError("部分证券行情缺失或日期过期：" + missing.joined(separator: "、")) }
        }
        if let n = snapshot.metrics["炸板家数"], let up = snapshot.metrics["涨停家数"], n + up > 0 { snapshot.metrics["炸板率"] = n / (n + up) * 100 }
        if let previous {
            do {
                let previousRows = try await pool("YESTERDAY", day: day), names = Set(previousRows.compactMap { $0["c"] as? String })
                guard !names.isEmpty, names.count == previousRows.count else { throw StockError("上一交易日涨停样本缺失或重复") }
                let feedback = previousRows.compactMap { number($0["zdp"]) }
                guard feedback.count == names.count else { throw StockError("昨日涨停反馈字段不完整") }
                if snapshot.metrics["涨停家数"] != nil { snapshot.metrics["涨停晋级率"] = Double(snapshot.limits.filter { names.contains($0.code) }.count) / Double(names.count) * 100 }
                snapshot.metrics["昨日涨停平均涨幅"] = feedback.reduce(0,+) / Double(feedback.count)
                snapshot.sources.append(StockSource(name: "昨日涨停反馈", url: poolURL("YESTERDAY", day: day), status: "ok", detail: "\(previous) 收盘涨停样本 \(names.count) 只在 \(day) 的等权平均涨幅；晋级=今日仍涨停/昨日涨停"))
            } catch { snapshot.sources.append(StockSource(name: "昨日涨停反馈", url: poolURL("YESTERDAY", day: day), status: "missing", detail: error.localizedDescription)) }
        }
        try Task.checkCancellation()
        return snapshot
    }
}
