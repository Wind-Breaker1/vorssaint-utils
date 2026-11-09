// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

enum StockStyle: String, Codable, CaseIterable, Identifiable {
    case short = "超短", swing = "波段", unspecified = "未分类"
    var id: String { rawValue }
}
extension StockTrade {
    func copyForNewTrade() -> StockTrade {
        StockTrade(instrument: instrument, action: action, price: price, quantity: quantity, strategy: strategy)
    }
}
enum StockJudgment: String, Codable, CaseIterable, Identifiable {
    case pending = "未评价", pass = "符合", fail = "违反", unknown = "无法判断", irrelevant = "不适用"
    var id: String { rawValue }
}
enum StockExecution: String, Codable, CaseIterable, Identifiable {
    case pending = "未评价", followed = "按计划", adjusted = "合理调整", deviated = "偏离计划", unplanned = "无计划", unknown = "无法判断"
    var id: String { rawValue }
}
struct StockRuleVersion: Codable, Equatable, Identifiable {
    var ruleID: String
    var version: Int
    var style: StockStyle
    var title: String
    var prompt: String
    var recordedAt: String
    var id: String { ruleID + ":" + String(version) }
}
struct StockRule: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var style: StockStyle = .short
    var title = ""
    var prompt = ""
    var enabled = true
    var versions: [StockRuleVersion] = []
    var snapshot: StockRuleVersion {
        versions.last ?? StockRuleVersion(ruleID: id, version: 1, style: style, title: title, prompt: prompt, recordedAt: "")
    }
}
struct StockRuleBook: Codable, Equatable {
    var schemaVersion = 2
    var rules: [StockRule] = []
    var reasonTags: [String] = []
    var emotions: [String] = ["平静", "犹豫", "急躁", "焦虑", "兴奋", "不甘心"]
    var mistakes: [String] = ["入场条件未满足", "忽略风险边界", "冲动加仓", "退出未执行", "临时改变策略未说明"]
    static var defaults: StockRuleBook {
        let prompts = [("入场", "当时的依据是什么？是否符合自己设定的触发条件？"),
                       ("风险", "是否明确风险边界与判断失效条件？"),
                       ("加减仓", "为什么改变持仓？是否符合条件或记录了调整依据？"),
                       ("退出", "退出或继续持有的依据是什么？"),
                       ("纪律", "是否遵守适用的个人规则？偏离的原因是什么？")]
        var book = StockRuleBook()
        for (index, style) in [StockStyle.short, .swing].enumerated() {
            for (n, prompt) in prompts.enumerated() {
                let id = "template-\(index)-\(n)"
                let version = StockRuleVersion(ruleID: id, version: 1, style: style, title: prompt.0, prompt: prompt.1, recordedAt: "")
                book.rules.append(StockRule(id: id, style: style, title: prompt.0, prompt: prompt.1, versions: [version]))
            }
        }
        return book
    }
    func revised(from old: StockRuleBook, at timestamp: String) throws -> StockRuleBook {
        var result = self
        guard schemaVersion == 2, Set(rules.map(\.id)).count == rules.count else { throw StockError("规则版本或 ID 无效") }
        for i in result.rules.indices {
            var rule = result.rules[i]
            guard !rule.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.style != .unspecified else { throw StockError("规则需要名称和超短 / 波段分类") }
            let previous = old.rules.first { $0.id == rule.id }
            rule.versions = previous?.versions ?? []
            if previous == nil || previous?.title != rule.title || previous?.prompt != rule.prompt || previous?.style != rule.style {
                rule.versions.append(StockRuleVersion(ruleID: rule.id, version: (rule.versions.last?.version ?? 0) + 1, style: rule.style, title: rule.title, prompt: rule.prompt, recordedAt: timestamp))
            }
            result.rules[i] = rule
        }
        // Retired rules remain available to historical evaluations.
        for var rule in old.rules where !result.rules.contains(where: { $0.id == rule.id }) { rule.enabled = false; result.rules.append(rule) }
        result.reasonTags = StockJournalText.tags(reasonTags.joined(separator: ","))
        result.emotions = StockJournalText.tags(emotions.joined(separator: ","))
        result.mistakes = StockJournalText.tags(mistakes.joined(separator: ","))
        return result
    }
}
enum StockJournalText {
    static func tags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
struct StockRuleCheck: Codable, Equatable, Identifiable {
    var rule: StockRuleVersion
    var judgment: StockJudgment = .pending
    var evidence = ""
    var id: String { rule.id }
}
struct StockPlanVersion: Codable, Equatable, Identifiable {
    var planID: String
    var version: Int
    var symbol: String
    var condition: String
    var position: String
    var stopLoss: String
    var recordedAt: String
    var reason: String
    var id: String { planID + ":" + String(version) }
    func matches(_ plan: StockPlan) -> Bool {
        symbol == plan.symbol && condition == plan.condition && position == plan.position && stopLoss == plan.stopLoss
    }
}
extension StockPlan {
    var snapshot: StockPlanVersion {
        versions?.last ?? StockPlanVersion(planID: id, version: 1, symbol: symbol, condition: condition, position: position, stopLoss: stopLoss, recordedAt: updatedAt, reason: "第一版记录；历史版本未保存")
    }
    func revised(from previous: StockPlan?, at timestamp: String) throws -> StockPlan {
        var result = self
        result.versions = previous.map { $0.versions ?? [$0.snapshot] } ?? []
        if previous == nil || !(previous!.snapshot.matches(self)) {
            if previous != nil && (changeReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw StockError("修改原计划时请填写变更原因，事后结果请写在验证栏") }
            result.versions!.append(StockPlanVersion(planID: id, version: (result.versions!.last?.version ?? 0) + 1, symbol: symbol, condition: condition, position: position, stopLoss: stopLoss, recordedAt: timestamp, reason: previous == nil ? "建立计划" : changeReason!))
        }
        result.createdAt = previous?.createdAt ?? timestamp
        result.updatedAt = previous == self ? previous!.updatedAt : timestamp
        return result
    }
}
struct StockStyleChange: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var style: StockStyle
    var recordedAt: String = StockDay.timestamp()
    var reason: String
}
struct StockRoundNote: Codable, Equatable, Identifiable {
    var id: String // Opening trade ID, stable across calendar years.
    var date: String
    var style: StockStyle = .unspecified
    var strategy = ""
    var summary = ""
    var changes: [StockStyleChange] = []
}
struct StockAssessment: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var date: String
    var time = ""
    var kind = "买卖操作"
    var symbol = ""
    var roundID: String? = nil
    var tradeIDs: [String] = []
    var tradeSnapshots: [StockTrade] = []
    var style: StockStyle = .unspecified
    var reason = ""
    var reasonTags: [String] = []
    var emotion = ""
    var execution: StockExecution = .pending
    var adjustment = ""
    var mistakes: [String] = []
    var checks: [StockRuleCheck] = []
    var plan: StockPlanVersion? = nil
    var reviewed = false
    var goodExample = false
    var goodEvidence = ""
    var improvement = ""
    var improvementAt: String? = nil
    var improvementStatus = "待落实"
    var followUp = ""
    var createdAt = StockDay.timestamp()
    var updatedAt = StockDay.timestamp()
    var retrospective = true
    var isTrade: Bool { kind == "买卖操作" }
    var isComplete: Bool { reviewed && checks.contains { $0.judgment != .irrelevant } && checks.allSatisfy { $0.judgment != .pending } }
    var hasUnknown: Bool { execution == .unknown || checks.contains { $0.judgment == .unknown } }
    func validate() throws {
        _ = try StockDay.year(date)
        guard UUID(uuidString: id) != nil, !kind.isEmpty, Set(tradeIDs).count == tradeIDs.count,
              Set(checks.map { $0.rule.ruleID }).count == checks.count,
              checks.allSatisfy({ $0.rule.version > 0 && !$0.rule.title.isEmpty }) else { throw StockError("操作 ID、类型或规则评价重复 / 无效") }
        if !time.isEmpty && time.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$"#, options: .regularExpression) == nil { throw StockError("操作时间须为 HH:mm:ss 或留空") }
        if execution == .adjusted && adjustment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw StockError("合理调整需要填写新信息与调整依据") }
        if goodExample && (!reviewed || goodEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { throw StockError("收藏正确操作前请确认已复盘，并填写判断依据") }
        guard isTrade ? !tradeIDs.isEmpty : tradeIDs.isEmpty else { throw StockError("买卖评价需要关联成交，无成交决策不能包含成交") }
    }
    func linkIssue(in data: StockDataset, rounds: [StockRound]) -> String? {
        guard isTrade else {
            if let roundID, !rounds.contains(where: { $0.id == roundID }) { return "关联轮次已变化，请重新关联" }; return nil
        }
        let trades = data.trades.filter { $0.deletedAt == nil && tradeIDs.contains($0.id) }
        guard trades.count == tradeIDs.count, !trades.isEmpty else { return "关联成交已删除或缺失" }
        guard let round = rounds.first(where: { $0.id == roundID }), trades.allSatisfy({ t in round.trades.contains { $0.id == t.id } }),
              Set(trades.map { $0.action }).count == 1, trades.allSatisfy({ $0.action == .buy || $0.action == .sell }) else { return "成交已不属于同一轮次或买卖方向" }
        let first = trades.min { $0.sortKey < $1.sortKey }!
        guard trades.allSatisfy({ $0.date == first.date }), date == first.date, time == first.time, symbol == first.instrument.symbol else { return "成交日期、时间或证券已变更，请重新核对" }
        guard trades.allSatisfy({ t in tradeSnapshots.contains { $0.id == t.id && $0.fingerprint == t.fingerprint } }) else { return "成交内容已变更，请核对后重新保存评价" }
        return nil
    }
}
struct StockReviewJournal: Codable, Equatable {
    var assessments: [StockAssessment] = []
    var rounds: [StockRoundNote] = []
}
struct StockRound: Identifiable {
    var id: String
    var instrument: StockInstrument
    var trades: [StockTrade]
    var quantity: Decimal
    var start: String { trades[0].date }
    var end: String? { quantity == 0 ? trades.last?.date : nil }
    var buySellTrades: [StockTrade] { trades.filter { $0.action == .buy || $0.action == .sell } }
    func actionTitle(for trade: StockTrade) -> String {
        if trade.action == .buy { return trade.id == id ? "建仓" : "加仓" }
        if trade.action == .sell { return end != nil && trade.id == trades.last?.id ? "清仓" : "减仓" }
        return trade.action.title
    }
    static func build(_ trades: [StockTrade]) -> [StockRound] {
        var rounds: [StockRound] = [], active: [String: Int] = [:]
        for trade in trades.filter({ $0.deletedAt == nil }).sorted(by: { $0.sortKey < $1.sortKey }) {
            let quantity = (try? StockDecimal.parse(trade.quantity, signed: trade.action == .shares)) ?? 0
            let key = trade.instrument.id
            if active[key] == nil && trade.action == .buy {
                active[key] = rounds.count; rounds.append(StockRound(id: trade.id, instrument: trade.instrument, trades: [], quantity: 0))
            }
            guard let index = active[key] else { continue }
            rounds[index].trades.append(trade)
            switch trade.action { case .buy, .shares: rounds[index].quantity += quantity; case .sell: rounds[index].quantity -= quantity; case .dividend: break }
            if rounds[index].quantity == 0 { active[key] = nil }
        }
        return rounds
    }
}
extension StockDataset {
    var rounds: [StockRound] { StockRound.build(trades) }
    var assessments: [StockAssessment] { reviews.flatMap { $0.journal?.assessments ?? [] } }
    var roundNotes: [StockRoundNote] { reviews.flatMap { $0.journal?.rounds ?? [] } }
    var planVersions: [StockPlanVersion] { reviews.flatMap(\.plans).flatMap { $0.versions ?? [$0.snapshot] } }
    func assessment(for tradeID: String) -> StockAssessment? { assessments.first { $0.tradeIDs.contains(tradeID) } }
    func draftAssessment(for trade: StockTrade) -> StockAssessment {
        let round = rounds.first { $0.trades.contains { $0.id == trade.id } }
        let style = roundNotes.first { $0.id == round?.id }?.style ?? .unspecified
        return StockAssessment(date: trade.date, time: trade.time, symbol: trade.instrument.symbol, roundID: round?.id, tradeIDs: [trade.id], tradeSnapshots: [trade], style: style, reason: trade.note,
                               checks: rules.rules.filter { $0.enabled && $0.style == style }.map { StockRuleCheck(rule: $0.snapshot) },
                               plan: reviews.flatMap(\.plans).first { $0.id == trade.planID }?.snapshot)
    }
    var qualitySamples: [StockQualitySample] {
        let rounds = self.rounds
        let saved = assessments
        let claimed = Set(saved.flatMap(\.tradeIDs))
        var result = saved.map { StockQualitySample(assessment: $0, persisted: true, issue: $0.linkIssue(in: self, rounds: rounds)) }
        for round in rounds {
            let style = roundNotes.first { $0.id == round.id }?.style ?? .unspecified
            for trade in round.buySellTrades where !claimed.contains(trade.id) {
                var draft = StockAssessment(id: trade.id, date: trade.date, time: trade.time, symbol: trade.instrument.symbol, roundID: round.id, tradeIDs: [trade.id], tradeSnapshots: [trade], style: style, reason: trade.note)
                draft.checks = rules.rules.filter { $0.enabled && $0.style == style }.map { StockRuleCheck(rule: $0.snapshot) }
                result.append(StockQualitySample(assessment: draft, persisted: false, issue: nil))
            }
        }
        return result.sorted { ($0.assessment.date + $0.assessment.time + $0.id) > ($1.assessment.date + $1.assessment.time + $1.id) }
    }
}
struct StockQualitySample: Identifiable {
    var assessment: StockAssessment
    var persisted: Bool
    var issue: String?
    var id: String { assessment.id }
}
struct StockQualityFilter {
    var from = ""
    var through = ""
    var style = "全部"
    var symbol = ""
    var rule = "全部"
    var mistake = "全部"
    var emotion = "全部"
    var execution = "全部"
    var kind = "实际买卖"
    var examplesOnly = false
    var pendingOnly = false
    func matches(_ sample: StockQualitySample) -> Bool {
        let a = sample.assessment
        return (from.isEmpty || a.date >= from) && (through.isEmpty || a.date <= through)
            && (style == "全部" || a.style.rawValue == style) && (symbol.isEmpty || a.symbol.localizedCaseInsensitiveContains(symbol))
            && (rule == "全部" || a.checks.contains { $0.rule.id == rule })
            && (mistake == "全部" || a.mistakes.contains(mistake)) && (emotion == "全部" || a.emotion == emotion)
            && (execution == "全部" || a.execution.rawValue == execution)
            && (kind == "实际买卖" ? a.isTrade : !a.isTrade)
            && (!examplesOnly || a.goodExample) && (!pendingOnly || !a.isComplete)
    }
}
struct StockRuleStatistic: Identifiable {
    var rule: StockRuleVersion
    var counts: [StockJudgment: Int] = [:]
    var id: String { rule.id }
    var denominator: Int { counts[.pass, default: 0] + counts[.fail, default: 0] }
    var ratio: String { denominator == 0 ? "无可判断样本" : String(format: "%.1f%%", locale: StockDecimal.locale, Double(counts[.pass, default: 0]) / Double(denominator) * 100) }
}
struct StockQualityStatistics {
    var samples: [StockQualitySample]
    var valid: [StockAssessment] { samples.filter { $0.issue == nil }.map(\.assessment) }
    var complete: Int { valid.filter(\.isComplete).count }
    var reviewed: [StockAssessment] { valid.filter(\.reviewed) }
    var unknown: Int { valid.filter(\.hasUnknown).count }
    var rules: [StockRuleStatistic] {
        var map: [String: StockRuleStatistic] = [:]
        for a in valid { for check in a.checks {
            if map[check.id] == nil { map[check.id] = StockRuleStatistic(rule: check.rule) }
            map[check.id]!.counts[check.judgment, default: 0] += 1
        } }
        return map.values.sorted { $0.id < $1.id }
    }
    var executions: [(String, Int)] { StockExecution.allCases.map { state in (state.rawValue, valid.filter { $0.execution == state }.count) } }
    var errors: [(String, Int)] {
        let tags = Set(reviewed.flatMap(\.mistakes))
        return tags.map { tag in (tag, reviewed.filter { $0.mistakes.contains(tag) }.count) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }
    var months: [(String, Int, Int)] {
        Set(valid.map { String($0.date.prefix(7)) }).sorted().map { month in
            let rows = reviewed.filter { $0.date.hasPrefix(month) }
            return (month, rows.filter { !$0.mistakes.isEmpty }.count, rows.count)
        }
    }
    var emotions: [(String, Int, Int)] {
        Set(reviewed.map(\.emotion)).sorted().map { emotion in
            let rows = reviewed.filter { $0.emotion == emotion }
            return (emotion, rows.filter { !$0.mistakes.isEmpty }.count, rows.count)
        }
    }
}
