// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

enum StockJournalTests {
    static func run(_ suite: TestSuite) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stock-journal-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func fails(_ name: String, _ body: () throws -> Void) {
            do { try body(); suite.expect(false, name) } catch { suite.expect(true, name) }
        }
        do {
            let repo = try StockRepository(root: root.appendingPathComponent("data"))
            let stock = StockInstrument.inferred("600519", name: "测试股票")
            let etf = StockInstrument.inferred("510300", name: "测试 ETF")
            let buy = StockTrade(instrument: stock, date: "2025-12-30", time: "09:40:00", price: "10", quantity: "100")
            var add = StockTrade(instrument: stock, date: "2025-12-30", time: "09:40:01", price: "10.1", quantity: "100")
            let partial = StockTrade(instrument: stock, date: "2026-01-05", time: "10:00:00", action: .sell, price: "11", quantity: "50")
            let dividend = StockTrade(instrument: stock, date: "2026-01-06", action: .dividend, price: "15", quantity: "0")
            let shares = StockTrade(instrument: stock, date: "2026-01-07", action: .shares, price: "0", quantity: "150")
            let sell = StockTrade(instrument: stock, date: "2026-01-08", time: "10:00:00", action: .sell, price: "4", quantity: "300")
            let reentry = StockTrade(instrument: stock, date: sell.date, time: "10:01:00", price: "5", quantity: "100")
            let fund = StockTrade(instrument: etf, date: "2026-01-08", price: "4", quantity: "100")
            let trades = [buy, add, partial, dividend, shares, sell, reentry, fund]
            var data = try repo.load()
            data = try repo.saveTrades(trades.reversed(), expected: data.revision)
            suite.expect(data.rounds.count == 3, "same-day reentry starts a new round; ETF stays separate")
            let round = data.rounds.first { $0.id == buy.id }!
            suite.expect(round.start == buy.date && round.end == sell.date && round.quantity == 0, "round spans years until flat, including corporate actions")
            suite.expect(round.trades.count == 6 && round.buySellTrades.count == 4, "dividends and share adjustments are not buy/sell decisions")
            suite.expect(round.actionTitle(for: buy) == "建仓" && round.actionTitle(for: add) == "加仓" && round.actionTitle(for: partial) == "减仓" && round.actionTitle(for: sell) == "清仓", "round action labels follow actual position transitions")
            suite.expect(data.rounds.filter { $0.end == nil }.count == 2, "open rounds remain in progress")
            suite.expect(data.qualitySamples.count == 6 && data.qualitySamples.allSatisfy { !$0.assessment.isComplete }, "unreviewed fills are represented in coverage")

            var note = StockRoundNote(id: buy.id, date: buy.date, style: .short, strategy: "测试", summary: "跨年轮次")
            data = try repo.saveRoundNote(note, reason: "", expected: data.revision)
            note = data.roundNotes[0]
            suite.expect(note.changes.count == 1 && note.changes[0].style == .short, "initial classification records history")
            var assessment = data.draftAssessment(for: buy)
            assessment.tradeIDs = [buy.id, add.id]
            assessment.reason = "当时的触发条件已经满足"
            assessment.execution = .followed; assessment.reviewed = true
            assessment.checks = [StockRuleCheck(rule: data.rules.rules[0].snapshot, judgment: .pass, evidence: "记录的触发依据")]
            assessment.goodExample = true; assessment.goodEvidence = "按自己设定的条件建仓并控制风险"
            data = try repo.saveAssessment(assessment, expected: data.revision)
            assessment = data.assessments[0]
            suite.expect(data.qualitySamples.count == 5, "two fills grouped into one decision reduce the sample denominator by one")
            suite.expect(assessment.tradeSnapshots.count == 2 && assessment.isComplete, "merged decision saves actual fills and complete rule evaluation")
            suite.expect(assessment.retrospective, "historical notes are marked retrospective using actual recording time")
            suite.expect(data.reviews.first(where: { $0.date == buy.date })?.journal?.assessments.count == 1, "evaluation belongs to operation day in annual review JSON")
            let v2file = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.root.appendingPathComponent("reviews/2025.json"))) as! [String: Any]
            suite.expect(v2file["schemaVersion"] as? Int == 2, "review files declare schema version 2")
            var duplicate = assessment; duplicate.id = UUID().uuidString
            fails("a fill cannot participate in two evaluations") { _ = try repo.saveAssessment(duplicate, expected: data.revision) }
            var badGroup = assessment; badGroup.tradeIDs = [buy.id, partial.id]
            fails("opposite directions cannot be grouped") { _ = try repo.saveAssessment(badGroup, expected: data.revision) }
            badGroup.tradeIDs = [buy.id, reentry.id]
            fails("two rounds cannot be grouped") { _ = try repo.saveAssessment(badGroup, expected: data.revision) }
            badGroup.tradeIDs = [buy.id, fund.id]
            fails("different securities cannot be grouped") { _ = try repo.saveAssessment(badGroup, expected: data.revision) }
            badGroup.tradeIDs = [dividend.id]
            fails("corporate actions cannot become decisions") { _ = try repo.saveAssessment(badGroup, expected: data.revision) }

            var changedNote = note; changedNote.style = .swing
            fails("changing trading style requires an explanation") { _ = try repo.saveRoundNote(changedNote, reason: "", expected: data.revision) }
            data = try repo.saveRoundNote(changedNote, reason: "重新评估后改为波段", expected: data.revision)
            suite.expect(data.roundNotes[0].changes.count == 2 && data.assessments[0].style == .short, "style history preserves previous operation classification")
            suite.expect(data.qualitySamples.first(where: { $0.assessment.tradeIDs == [partial.id] })?.assessment.style == .swing, "unreviewed operations use current round default")

            let savedRule = assessment.checks[0].rule
            var rules = data.rules; rules.rules[0].title = "新的入场检查"; rules.mistakes = ["冲动", "冲动", "提前退出"]
            data = try repo.saveRules(rules, expected: data.revision)
            suite.expect(data.rules.rules[0].versions.count == 2 && data.rules.rules[0].snapshot.version == 2, "rule edits create versions")
            suite.expect(data.assessments[0].checks[0].rule == savedRule, "rule changes cannot rewrite historical evaluation wording")
            suite.expect(data.rules.mistakes == ["冲动", "提前退出"], "custom tag configuration deduplicates")
            rules = data.rules; rules.rules.removeFirst()
            data = try repo.saveRules(rules, expected: data.revision)
            suite.expect(data.rules.rules.contains { $0.id == savedRule.ruleID && !$0.enabled && $0.versions.count == 2 }, "retired rules retain historical versions")

            var review = StockReview(date: "2025-12-29", summary: "盘前计划", plans: [StockPlan(symbol: stock.symbol, condition: "原入场条件", position: "预设风险边界", stopLoss: "判断失效")])
            data = try repo.saveReview(review, expected: data.revision)
            review = data.reviews.first { $0.date == review.date }!
            let originalPlan = review.plans[0].snapshot
            var sellEvaluation = data.draftAssessment(for: sell)
            sellEvaluation.plan = originalPlan; sellEvaluation.reason = "按失效条件退出"; sellEvaluation.reviewed = true
            sellEvaluation.execution = .followed; sellEvaluation.checks = [StockRuleCheck(rule: savedRule, judgment: .pass)]
            sellEvaluation.goodExample = true; sellEvaluation.goodEvidence = "按记录的风险边界退出"
            data = try repo.saveAssessment(sellEvaluation, expected: data.revision)
            review.plans[0].condition = "新入场条件"
            fails("plan changes require a reason") { _ = try repo.saveReview(review, expected: data.revision) }
            review.plans[0].changeReason = "新增市场信息"
            data = try repo.saveReview(review, expected: data.revision)
            review = data.reviews.first { $0.date == review.date }!
            suite.expect(review.plans[0].versions?.count == 2 && review.plans[0].snapshot.version == 2, "plan revision keeps both versions")
            suite.expect(data.assessments.first { $0.id == sellEvaluation.id }?.plan == originalPlan, "operation retains the linked plan version")
            review.plans[0].outcome = "盘后验证结果"
            data = try repo.saveReview(review, expected: data.revision)
            suite.expect(data.reviews.first { $0.date == review.date }?.plans[0].versions?.count == 2, "hindsight outcome does not create or rewrite a plan version")
            review.plans = []
            data = try repo.saveReview(review, expected: data.revision)
            suite.expect(data.reviews.first { $0.date == review.date }?.plans[0].status == "已取消", "removing a plan archives it rather than losing history")

            var decision = StockAssessment(date: "2026-01-08", time: "13:00:00", kind: "放弃买入", symbol: "市场", style: .short, reason: "不满足入场条件", emotion: "平静", execution: .unplanned)
            decision.checks = [StockRuleCheck(rule: savedRule, judgment: .unknown)]
            decision.reviewed = true
            data = try repo.saveAssessment(decision, expected: data.revision)
            suite.expect(data.trades.count == trades.count && data.rounds.count == 3, "no-trade decision creates neither a fill nor a round")
            let noTradeFilter = StockQualityFilter(kind: "无成交决策")
            let noTradeStats = StockQualityStatistics(samples: data.qualitySamples.filter(noTradeFilter.matches))
            suite.expect(noTradeStats.valid.count == 1 && noTradeStats.complete == 1 && noTradeStats.unknown == 1, "unknown judgments are reviewed but remain explicitly unknown")
            suite.expect(noTradeStats.rules[0].denominator == 0 && noTradeStats.rules[0].ratio == "无可判断样本", "unknown is not counted as pass or fail")
            var adjusted = data.draftAssessment(for: partial); adjusted.execution = .adjusted
            fails("reasonable adjustment requires evidence") { _ = try repo.saveAssessment(adjusted, expected: data.revision) }
            adjusted.adjustment = "新信息改变原触发条件"; adjusted.reviewed = true; adjusted.emotion = "急躁"
            adjusted.mistakes = ["冲动", "冲动", "提前退出"]
            adjusted.checks = [StockRuleCheck(rule: savedRule, judgment: .fail)]
            adjusted.improvement = "每次减仓先核对条件"
            data = try repo.saveAssessment(adjusted, expected: data.revision)
            adjusted = data.assessments.first { $0.id == adjusted.id }!
            suite.expect(adjusted.mistakes.count == 2 && adjusted.improvementAt != nil, "mistakes deduplicate and improvement gets real creation time")
            let improvementAt = adjusted.improvementAt
            adjusted.followUp = "之后继续回看"; adjusted.improvementStatus = "执行中"
            data = try repo.saveAssessment(adjusted, expected: data.revision)
            suite.expect(data.assessments.first { $0.id == adjusted.id }?.improvementAt == improvementAt, "follow-up does not reset improvement baseline")
            let quality = StockQualityStatistics(samples: data.qualitySamples.filter(StockQualityFilter().matches))
            suite.expect(quality.valid.count == 5 && quality.complete == 3, "coverage counts operations and leaves two unreviewed")
            suite.expect(quality.rules.first { $0.id == savedRule.id }?.denominator == 3, "rule denominator includes two passes and one violation only")
            suite.expect(quality.executions.first { $0.0 == "合理调整" }?.1 == 1 && quality.executions.first { $0.0 == "偏离计划" }?.1 == 0, "adjustment stays distinct from violation")
            suite.expect(quality.errors.first { $0.0 == "冲动" }?.1 == 1 && quality.reviewed.count == 3, "errors count once per reviewed operation")
            suite.expect(quality.months.first { $0.0 == "2026-01" }?.2 == 2, "monthly trend exposes reviewed sample denominator")
            suite.expect(quality.emotions.first { $0.0 == "急躁" }?.1 == 1, "emotion distribution can trace erroneous operations")
            let ledger = try StockLedger.calculate(data.trades)
            suite.expect(ledger.saleProfit[sell.id]! < 0 && data.assessments.first { $0.id == sellEvaluation.id }!.goodExample, "rule-following loss can be a correct-operation example")
            suite.expect(ledger.saleProfit[partial.id]! > 0 && adjusted.checks[0].judgment == .fail, "profitable sale can violate the rule")
            let filtered = StockQualityFilter(from: "2026-01-01", through: "2026-01-31", style: "波段", symbol: stock.symbol, rule: savedRule.id, mistake: "冲动", emotion: "急躁", execution: "合理调整")
            suite.expect(data.qualitySamples.filter(filtered.matches).map(\.id) == [adjusted.id], "combined filters lead to exact contributing operation")
            suite.expect(data.qualitySamples.filter(StockQualityFilter(examplesOnly: true).matches).count == 2, "correct-operation library includes losing examples")
            var emptyChecks = StockAssessment(date: buy.date, kind: "等待", reviewed: true)
            suite.expect(!emptyChecks.isComplete, "no checks do not vacuously complete a review")
            emptyChecks.checks = [StockRuleCheck(rule: savedRule, judgment: .irrelevant)]
            suite.expect(!emptyChecks.isComplete, "all-inapplicable checks do not manufacture completion")
            emptyChecks.goodExample = true
            fails("correct example needs evidence") { try emptyChecks.validate() }

            add.price = "10.2"
            data = try repo.saveTrades([add], expected: data.revision)
            suite.expect(data.assessments.first { $0.id == assessment.id }?.tradeSnapshots.first { $0.id == add.id }?.price == "10.1", "editing fact preserves old assessment evidence")
            suite.expect(data.qualitySamples.first { $0.id == assessment.id }?.issue != nil, "changed trade invalidates old evaluation until reviewed again")
            suite.expect(StockQualityStatistics(samples: data.qualitySamples.filter(StockQualityFilter().matches)).complete == 2, "invalidated evaluation excluded from quality metrics")
            data = try repo.saveAssessment(assessment, expected: data.revision)
            suite.expect(data.qualitySamples.first { $0.id == assessment.id }?.issue == nil, "explicit confirmation renews trade snapshot")

            var moved = data.assessments.first { $0.id == decision.id }!; moved.date = "2025-12-31"
            data = try repo.saveAssessment(moved, expected: data.revision)
            suite.expect(data.reviews.first { $0.date == "2026-01-08" }?.journal?.assessments.contains { $0.id == decision.id } == false, "moving decision across years removes old date occurrence")
            suite.expect(data.assessments.filter { $0.id == decision.id }.count == 1 && data.assessments.first { $0.id == decision.id }?.date == moved.date, "cross-year decision move is unique")
            let revision = data.revision
            var later = moved; later.reason = "外部修改"
            data = try repo.saveAssessment(later, expected: data.revision)
            fails("stale evaluation write is rejected") { _ = try repo.saveAssessment(moved, expected: revision) }

            let destination = root.appendingPathComponent("copy")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let copy = try repo.migrate(to: destination)
            suite.expect(try copy.load().revision == data.revision, "migration includes rules, version histories and evaluations")
            suite.expect(try copy.load().rules == data.rules, "shared tag and rule configuration survives migration")
            var changedRules = data.rules; changedRules.emotions.append("新增情绪")
            data = try repo.saveRules(changedRules, expected: data.revision)
            data = try repo.restore(from: destination, expected: data.revision)
            suite.expect(!data.rules.emotions.contains("新增情绪") && data.assessments.count == 4, "restore recovers both rules and journal")
            let preserved = data.assessments.first { $0.id == decision.id }!
            data = try repo.deleteAssessment(preserved.id, expected: data.revision)
            suite.expect(data.assessments.count == 3 && data.trades.count == trades.count, "deleting decision leaves all original fills")
            let backups = try FileManager.default.contentsOfDirectory(at: repo.root.appendingPathComponent("backups"), includingPropertiesForKeys: nil).sorted { $0.lastPathComponent > $1.lastPathComponent }
            let backupData = try StockRepository(root: backups[0]).load()
            suite.expect(backupData.assessments.contains { $0.id == preserved.id }, "removed assessment can be restored from pre-write backup")
            let placeholder = repo.root.appendingPathComponent(".rules.json.icloud")
            try Data().write(to: placeholder)
            fails("undownloaded rules cannot fall back to empty defaults") { _ = try repo.load() }
            try FileManager.default.removeItem(at: placeholder)

            // Actual v1 JSON lacks all new optional fields; upgrade must preserve body and plan.
            let legacyRoot = root.appendingPathComponent("legacy")
            try FileManager.default.createDirectory(at: legacyRoot.appendingPathComponent("reviews"), withIntermediateDirectories: true)
            let legacyReview = StockReview(date: "2024-12-31", summary: "旧版内容", plans: [StockPlan(condition: "旧计划")])
            let legacyBytes = try JSONEncoder().encode(StockYear(year: 2024, entries: [legacyReview]))
            try legacyBytes.write(to: legacyRoot.appendingPathComponent("reviews/2024.json"))
            let legacyRepo = try StockRepository(root: legacyRoot)
            var legacy = try legacyRepo.load()
            suite.expect(legacy.reviews[0].journal == nil && legacy.reviews[0].plans[0].versions == nil, "v1 decodes without synthetic historical evaluations")
            legacy = try legacyRepo.saveAssessment(StockAssessment(date: "2024-12-31", kind: "继续持有", reason: "补录"), expected: legacy.revision)
            suite.expect(legacy.reviews[0].summary == "旧版内容" && legacy.reviews[0].plans[0].condition == "旧计划", "upgrade does not alter v1 content")
            let oldBackups = try FileManager.default.contentsOfDirectory(at: legacyRoot.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
            suite.expect(try Data(contentsOf: oldBackups[0].appendingPathComponent("reviews/2024.json")) == legacyBytes, "pre-upgrade backup preserves exact original bytes")
            let copiedTrade = buy.copyForNewTrade()
            suite.expect(copiedTrade.id != buy.id && copiedTrade.brokerID.isEmpty && copiedTrade.note.isEmpty && copiedTrade.planID == nil && copiedTrade.date == StockDay.string(), "quick copy creates new fact without inheriting old evaluation, execution ID or plan")
            suite.expect(StockRepository.isRecordedAfter("2026-01-08T02:00:01.000Z", day: "2026-01-08", time: "10:00:00"), "record time uses Shanghai timezone for after-the-fact labeling")
            suite.expect(!StockRepository.isRecordedAfter("2026-01-08T01:59:59.000Z", day: "2026-01-08", time: "10:00:00"), "earlier plan timestamp is distinguished from hindsight")
            suite.expect(StockRepository.isRecordedAfter("2026-01-08T01:59:59.000Z", day: "2026-01-08", time: ""), "missing operation time does not assert contemporaneous evidence")

            // Removing the opening fill can leave valid accounting with a different round ID.
            let orphanRepo = try StockRepository(root: root.appendingPathComponent("orphan"))
            var orphan = try orphanRepo.load()
            orphan = try orphanRepo.saveTrades([buy, add], expected: orphan.revision)
            orphan = try orphanRepo.saveRoundNote(note, reason: "", expected: orphan.revision)
            var toDelete = buy; toDelete.deletedAt = StockDay.timestamp()
            orphan = try orphanRepo.saveTrades([toDelete], expected: orphan.revision)
            suite.expect(orphan.roundNotes[0].id == buy.id && orphan.rounds[0].id == add.id, "orphaned note remains recoverable after opening fill deletion")
            orphan = try orphanRepo.relinkRoundNote(orphan.roundNotes[0], to: add.id, expected: orphan.revision)
            suite.expect(orphan.roundNotes.count == 1 && orphan.roundNotes[0].id == add.id && orphan.roundNotes[0].summary == note.summary, "explicit reassociation preserves original round summary")
        } catch { suite.expect(false, "stock journal scenario failed: \(error)") }
    }
}
