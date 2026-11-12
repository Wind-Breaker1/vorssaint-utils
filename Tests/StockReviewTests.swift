// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

enum StockReviewTests {
    static func run(_ suite: TestSuite) {
        for language in AppLanguage.allCases { suite.expect(!StockStrings.title(language).isEmpty && !StockStrings.description(language).isEmpty, "stock catalog available in \(language.rawValue)") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stock-review-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func expectFailure(_ label: String, _ action: () throws -> Void) {
            do { try action(); suite.expect(false, label) } catch { suite.expect(true, label) }
        }
        do {
            let legacyReview = StockReview(date: "2026-11-06", summary: "保留复盘正文")
            var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyReview)) as! [String: Any]
            legacyJSON["plans"] = [["condition": "已移除的计划"]]
            legacyJSON["journal"] = ["assessments": [["kind": "已移除的评价"]]]
            let decodedReview = try JSONDecoder().decode(StockReview.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
            suite.expect(decodedReview == legacyReview, "removed review features do not affect current review data")
            let savedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decodedReview)) as! [String: Any]
            suite.expect(savedJSON["plans"] == nil && savedJSON["journal"] == nil, "saved reviews contain only current fields")
            let blankReview = StockReview(date: "2026-11-06")
            var plannedReview = blankReview
            plannedReview.tomorrowPlan = "观察开盘量能"
            suite.expect(!blankReview.hasUserContent && plannedReview.hasUserContent, "tomorrow plan is treated as user-authored review content")
            let monday = StockDay.date("2026-11-09")!
            suite.expect(StockMarketClient.isTradingHours(now: monday.addingTimeInterval(9 * 3600 + 30 * 60)), "A-share session opens at 09:30 China time")
            suite.expect(StockMarketClient.isTradingHours(now: monday.addingTimeInterval(11 * 3600 + 30 * 60)), "A-share morning session includes 11:30")
            suite.expect(!StockMarketClient.isTradingHours(now: monday.addingTimeInterval(11 * 3600 + 31 * 60)), "A-share lunch break is outside trading hours")
            suite.expect(StockMarketClient.isTradingHours(now: monday.addingTimeInterval(13 * 3600)), "A-share afternoon session opens at 13:00")
            suite.expect(StockMarketClient.isTradingHours(now: monday.addingTimeInterval(15 * 3600)), "A-share afternoon session includes 15:00")
            suite.expect(!StockMarketClient.isTradingHours(now: monday.addingTimeInterval(15 * 3600 + 60)), "A-share session closes after 15:00")
            suite.expect(StockMarketClient.isCurrentTradingDay(now: monday.addingTimeInterval(10 * 3600), quoteDate: "2026-11-09"), "current index quote confirms an open weekday")
            suite.expect(!StockMarketClient.isCurrentTradingDay(now: monday.addingTimeInterval(10 * 3600), quoteDate: "2026-11-06"), "stale index quote prevents collection on a weekday market holiday")
            let sunday = StockDay.date("2026-11-08")!
            suite.expect(!StockMarketClient.isTradingHours(now: sunday.addingTimeInterval(10 * 3600)), "weekend is outside trading hours")
            suite.expect(!StockMarketClient.isCurrentTradingDay(now: sunday.addingTimeInterval(10 * 3600), quoteDate: "2026-11-08"), "weekend is never treated as a trading day")
            let suggestions: [String: Any] = ["QuotationCodeTable": ["Status": 0, "Data": [
                ["Code": "600519", "Name": "贵州茅台", "MktNum": "1"],
                ["Code": "510300", "Name": "沪深300ETF", "MktNum": "1"],
                ["Code": "00700", "Name": "腾讯控股", "MktNum": "116"],
                ["Code": "600519", "Name": "贵州茅台", "MktNum": "1"]
            ]]]
            let suggested = try StockMarketClient.parseInstruments(suggestions)
            suite.expect(suggested.map(\.symbol) == ["600519", "510300"], "name search excludes unsupported securities and duplicates")
            suite.expect(suggested.last?.kind == "etf", "name search infers ETF kind")
            suite.expect(StockMarketClient.sectorURL().contains("pz=5") && StockMarketClient.sectorURL().contains("fs=m:90+t:2"), "market collection requests only five industry sectors")
            let stock = StockInstrument(symbol: "600519", name: "测试证券")
            var buy = StockTrade(instrument: stock, date: "2025-12-30", price: "10", quantity: "100", commission: "5")
            var add = StockTrade(instrument: stock, date: "2026-01-05", price: "20", quantity: "100", commission: "5")
            let sell = StockTrade(instrument: stock, date: "2026-01-06", action: .sell, price: "18", quantity: "50", commission: "5", tax: "0.45")
            let ledger = try StockLedger.calculate([sell,add,buy])
            suite.expect(ledger.positions[0].quantity == 150, "cross-year positions combine, regardless of input order")
            suite.expect(ledger.positions[0].cost == Decimal(string: "2257.5"), "partial sale removes proportional weighted cost")
            suite.expect(ledger.saleProfit[sell.id] == Decimal(string: "142.05"), "sell profit deducts cost, commission and tax exactly")
            suite.expect(try StockDecimal.parse("0.1") + StockDecimal.parse("0.2") == StockDecimal.parse("0.3"), "decimal calculations are exact")
            for invalid in ["NaN","1e5","-1","1.1234567","１２","", "1,000"] { expectFailure("invalid decimal \(invalid)") { _ = try StockDecimal.parse(invalid) } }
            expectFailure("invalid calendar day") { _ = try StockDay.year("2026-02-30") }
            expectFailure("selling without history") { _ = try StockLedger.calculate([sell]) }
            let div = StockTrade(instrument: stock, date: "2026-01-07", action: .dividend, price: "30", quantity: "0", tax: "3")
            let split = StockTrade(instrument: stock, date: "2026-01-08", action: .shares, price: "0", quantity: "150")
            let adjusted = try StockLedger.calculate([buy,add,sell,div,split])
            suite.expect(adjusted.positions[0].quantity == 300 && adjusted.positions[0].cost == Decimal(string: "2257.5"), "corporate action changes shares without changing total cost")
            suite.expect(adjusted.realized == Decimal(string: "169.05"), "dividend adds net cash to realized income")
            let exit = StockTrade(instrument: stock, date: "2026-01-09", action: .sell, price: "10", quantity: "300")
            let closed = try StockLedger.calculate([buy,add,sell,div,split,exit])
            suite.expect(closed.positions[0].cost == 0 && closed.positions[0].quantity == 0, "full exit leaves no rounding residue")
            buy.deletedAt = StockDay.timestamp()
            expectFailure("deleting historical buy cannot make later trades invalid") { _ = try StockLedger.calculate([buy,add,sell,div,split,exit]) }
            buy.deletedAt = nil

            let repo = try StockRepository(root: root.appendingPathComponent("store"))
            var data = try repo.load()
            suite.expect(data.trades.isEmpty, "empty directory has no sample trades")
            data.rules.tradingDiscipline = "先确认风险边界"
            data = try repo.saveRules(data.rules, expected: data.revision)
            let legacyRules = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 2,
                "tradingDiscipline": "先确认风险边界",
                "rules": [["id": "retired-rule"]],
                "reasonTags": [],
                "emotions": [],
                "mistakes": []
            ])
            try legacyRules.write(to: repo.root.appendingPathComponent("rules.json"), options: .atomic)
            data = try repo.load()
            suite.expect(data.rules.tradingDiscipline == "先确认风险边界", "current discipline loads from the existing rules file")
            let blank = data.revision
            var numbered = buy; numbered.brokerID = "EXEC-1"
            var numberedAgain = numbered; numberedAgain.id = UUID().uuidString
            expectFailure("duplicate broker executions cannot be double-counted") { _ = try repo.saveTrades([numbered,numberedAgain], expected: blank) }
            let pendingCloud = repo.root.appendingPathComponent(".trades.icloud")
            try Data().write(to: pendingCloud)
            expectFailure("undownloaded annual folder is not treated as empty") { _ = try repo.load() }
            try FileManager.default.removeItem(at: pendingCloud)
            data = try repo.saveTrades([buy,add,sell], expected: data.revision)
            suite.expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("trades/2025.json").path), "first year persisted separately")
            suite.expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("trades/2026.json").path), "second year persisted separately")
            expectFailure("stale device save is rejected") { _ = try repo.saveTrades([buy], expected: blank) }
            let beforeInvalid = data.revision
            var tooMany = sell; tooMany.quantity = "9999"
            expectFailure("invalid batch import is all-or-nothing") { _ = try repo.saveTrades([div,tooMany], expected: data.revision) }
            suite.expect(try repo.load().revision == beforeInvalid, "invalid batch leaves files unchanged")
            add.date = "2025-12-31"
            data = try repo.saveTrades([add], expected: data.revision)
            suite.expect(data.trades.count == 3 && data.trades.first(where: { $0.id == add.id })?.date == "2025-12-31", "editing a trade across years moves it once")
            data = try repo.load()
            let oldRevision = data.revision
            let external = try StockRepository(root: repo.root)
            var change = buy; change.note = "另一设备更新"
            _ = try external.saveTrades([change], expected: oldRevision)
            expectFailure("external edits protected") { _ = try repo.saveTrades([buy], expected: oldRevision) }
            data = try repo.load()
            var review = StockReview(date: "2026-01-06", summary: "我的原始判断")
            data = try repo.saveReview(review, expected: data.revision)
            data = try repo.saveReview(StockReview(date: "2026-01-07"), expected: data.revision)
            suite.expect(data.reviews.count == 1, "empty reviews are not persisted")
            let snapshot = StockMarketSnapshot(date: "2026-01-06", metrics: ["涨停家数":12], sources: [StockSource(name:"涨停池",status:"ok")])
            data = try repo.saveSnapshot(snapshot)
            suite.expect(data.reviews.first?.summary == "我的原始判断", "automatic market updates preserve review text")
            data = try repo.saveSnapshot(StockMarketSnapshot(date:"2026-01-06", sources: [StockSource(name:"涨停池",status:"missing")]))
            suite.expect(data.snapshots[0].metrics["涨停家数"] == 12 && data.snapshots[0].metrics["最高连板"] == nil && data.snapshots[0].sources[0].status == "missing", "failed retry retains required readings and prunes retired metrics")
            _ = try repo.saveSnapshot(StockMarketSnapshot(date:"2026-01-07"))
            var declineSnapshot = StockMarketSnapshot(date: "2026-01-07")
            declineSnapshot.industryDecliners = [StockSector(code: "BKTEST", name: "测试行业", change: -3)]
            _ = try repo.saveSnapshot(declineSnapshot)
            let afterFailedRefresh = try repo.saveSnapshot(StockMarketSnapshot(date: "2026-01-07"))
            suite.expect(afterFailedRefresh.snapshots.first { $0.date == "2026-01-07" }?.industryDecliners == declineSnapshot.industryDecliners, "failed refresh preserves saved declining sectors")

            data = try repo.load()
            suite.expect(data.reviews.count == 1, "market collection does not create an empty review record")
            let destination = root.appendingPathComponent("migrated")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let migrated = try repo.migrate(to: destination)
            suite.expect(try migrated.load().revision == data.revision, "migration preserves all JSON data")
            suite.expect(try repo.load().revision == data.revision, "migration keeps source intact")
            expectFailure("migration must not overwrite existing destination") { _ = try repo.migrate(to: destination) }
            review.summary = "新的判断"
            _ = try repo.saveReview(review, expected: data.revision)
            let backups = try FileManager.default.contentsOfDirectory(at: repo.root.appendingPathComponent("backups"), includingPropertiesForKeys: nil).sorted { $0.lastPathComponent > $1.lastPathComponent }
            suite.expect(!backups.isEmpty, "writes generate recoverable backups")
            data = try repo.load()
            let restored = try repo.restore(from: backups[0], expected: data.revision)
            suite.expect(restored.reviews.first(where: { $0.date == review.date })?.summary == "我的原始判断", "backup restores the prior review")

            // Simulate a crash after journaling a cross-year write but before replacing the file.
            let yearURL = repo.root.appendingPathComponent("trades/2025.json")
            let previousBytes = try Data(contentsOf: yearURL)
            var year = try JSONDecoder().decode(StockYear<StockTrade>.self, from: previousBytes)
            year.entries[0].note = "崩溃恢复"
            let nextBytes = try JSONEncoder().encode(year)
            let pending: [String: Any] = ["version":1,"writes":[["path":"trades/2025.json","before":StockRepository.digest(previousBytes),"data":nextBytes.base64EncodedString()]]]
            try JSONSerialization.data(withJSONObject: pending).write(to: repo.root.appendingPathComponent(".transaction.json"))
            suite.expect(try repo.load().trades.contains(where: { $0.note == "崩溃恢复" }), "interrupted writes recover on next read")
            suite.expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(".transaction.json").path), "recovered journal removed")

            // A conflicting third-party write must not be overwritten by crash recovery.
            let existingYear = try Data(contentsOf: yearURL)
            var conflictingYear = try JSONDecoder().decode(StockYear<StockTrade>.self, from: existingYear)
            conflictingYear.entries[0].note = "外部修改需保留"
            let externalBytes = try JSONEncoder().encode(conflictingYear)
            let conflictingJournal: [String: Any] = ["version":1,"writes":[["path":"trades/2025.json","before":StockRepository.digest(previousBytes),"data":nextBytes.base64EncodedString()]]]
            try externalBytes.write(to: yearURL, options:.atomic)
            try JSONSerialization.data(withJSONObject: conflictingJournal).write(to: repo.root.appendingPathComponent(".transaction.json"))
            expectFailure("recovery refuses a concurrent external replacement") { _ = try repo.load() }
            suite.expect(try Data(contentsOf: yearURL) == externalBytes, "conflict recovery leaves external content intact")
            try FileManager.default.removeItem(at: repo.root.appendingPathComponent(".transaction.json"))

            var csvTrade = buy; csvTrade.note = "有逗号,有引号\"\n第二行"; csvTrade.instrument.name = "=危险公式"
            let csv = StockCSV.export([csvTrade,sell])
            let parsed = try StockCSV.preview(csv, existing: [])
            suite.expect(parsed.count == 2 && parsed[0].trade?.note == csvTrade.note && parsed[0].trade?.instrument.name == csvTrade.instrument.name, "CSV quoting, multiline notes and formula escaping round trip")
            suite.expect(parsed[0].trade?.instrument.symbol == "600519", "CSV code preserves digits")
            let duplicate = try StockCSV.preview(csv, existing: [csvTrade])
            suite.expect(duplicate[0].duplicate && !duplicate[0].selected, "matching record ID is blocked as duplicate")
            let ambiguous = try StockCSV.preview(StockCSV.export([StockTrade(instrument: stock,date:buy.date,price:buy.price,quantity:buy.quantity,commission:buy.commission)]), existing:[buy])
            suite.expect(!ambiguous[0].duplicate && !ambiguous[0].selected, "same execution values are flagged, not silently discarded")
            let shortCode = "证券代码,成交日期,买卖方向,成交价格,成交数量\n1,20260101,买入,10,100\n"
            suite.expect(try StockCSV.preview(shortCode,existing:[])[0].trade == nil, "stripped leading zero is not guessed")
            expectFailure("unclosed CSV quote rejected") { _ = try StockCSV.parse("a,b\n\"oops,b") }
            let tsv = "证券代码\t证券名称\t成交日期\t成交时间\t买卖方向\t成交价格\t成交数量\n000001\t平安银行\t2026/1/6\t093001\t证券买入\t10.01\t100\n"
            let imported = try StockCSV.preview(tsv, existing: [])
            suite.expect(imported[0].trade?.date == "2026-01-06" && imported[0].trade?.time == "09:30:01", "broker date, time and TSV normalized")
            suite.expect(imported[0].message.contains("费用"), "missing costs explicitly surfaced")
            let splitFills = "证券代码,成交日期,买卖方向,成交价格,成交数量,合同编号\n600519,20260106,买入,10,100,ORDER-1\n600519,20260106,买入,10.1,100,ORDER-1\n"
            let fills = try StockCSV.preview(splitFills, existing: [])
            suite.expect(fills.allSatisfy { $0.selected && !$0.duplicate }, "one order with two executions is not wrongly deduplicated by contract number")
            let etf = StockInstrument.inferred("510300", name: "沪深300 ETF")
            suite.expect(etf.kind == "etf" && etf.exchange == "SH", "ETF recognized")
            let pool: [[String:Any]] = [["c":"000001","n":"测试","lbc":3,"zdp":10.0,"fbt":93500,"hybk":"银行","zbc":2]]
            let limit = try StockMarketClient.limits(pool)[0]
            suite.expect(limit.boards == 3 && limit.firstTime == "093500" && limit.breaks == 2, "limit ladder uses source board count and seal time")
            expectFailure("incomplete pool cannot manufacture zero boards") { _ = try StockMarketClient.limits([["c":"000001"]]) }
            expectFailure("empty quotes cannot become zero-valued prices") { _ = try StockMarketClient.parseQuotes(Data("v_sh000001=\"\";".utf8)) }
            suite.expect(StockMarketClient.number("-") == nil && StockMarketClient.number("NaN") == nil, "missing and nonfinite readings remain missing")
        } catch { suite.expect(false, "stock review tests failed: \(error)") }
    }
}
