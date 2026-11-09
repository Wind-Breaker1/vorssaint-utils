// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI

struct StockQualityView: View {
    @ObservedObject var service: StockService
    @State private var filter = StockQualityFilter()
    @State private var limited = false
    @State private var from = StockDay.calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var through = Date()
    @State private var editing: StockAssessment?
    @State private var original: StockAssessment?
    private var all: [StockQualitySample] { service.qualitySamples }
    private var appliedFilter: StockQualityFilter { var f = filter; f.from = limited ? StockDay.string(from) : ""; f.through = limited ? StockDay.string(through) : ""; return f }
    private var samples: [StockQualitySample] { all.filter { appliedFilter.matches($0) } }
    private var stats: StockQualityStatistics { StockQualityStatistics(samples: samples) }
    private var ruleChoices: [StockRuleVersion] {
        var seen = Set<String>(); return all.flatMap { $0.assessment.checks.map(\.rule) }.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("按操作发生日期统计；同一决策的分批成交合并后算一次。盈亏不会改变评价。").font(.caption).foregroundStyle(.secondary)
                filters
                if limited && from > through { Text("开始日期不能晚于结束日期。").foregroundStyle(.orange) }
                HStack(spacing: 12) {
                    StockMetricCard(title: "完成复盘", value: "\(stats.complete) / \(stats.valid.count)", detail: "当前筛选 · 有效操作样本")
                    StockMetricCard(title: "仍待完善", value: "\(stats.valid.count - stats.complete)", detail: "规则未评或尚未确认")
                    StockMetricCard(title: "含无法判断项", value: "\(stats.unknown)", detail: "单列保留，不算正确或错误")
                }
                HStack {
                    Toggle("只看待完善", isOn: $filter.pendingOnly)
                    Toggle("只看正确操作案例", isOn: $filter.examplesOnly)
                    Spacer()
                    Text("\(samples.filter { $0.issue != nil }.count) 条关联失效，未进入统计").font(.caption).foregroundStyle(.orange)
                }
                if stats.valid.isEmpty { Text("当前没有有效样本。录入成交后可逐笔评价；无成交决策在每日复盘中记录。").foregroundStyle(.secondary).padding(.vertical, 12) }
                DisclosureGroup("规则符合情况 · \(stats.rules.count) 个规则版本") { ruleStatistics }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("计划执行").font(.headline)
                        ForEach(stats.executions, id: \.0) { title, count in
                            Button { filter.execution = title } label: { HStack { Text(title); Spacer(); Text("\(count)").monospacedDigit() } }.buttonStyle(.plain)
                        }
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("错误分布").font(.headline)
                        Text("\(stats.reviewed.count) 个已确认复盘样本；可多选，各类占比之和可能超过 100%。").font(.caption).foregroundStyle(.secondary)
                        ForEach(stats.errors, id: \.0) { tag, count in
                            Button { filter.mistake = tag } label: { HStack { Text(tag); Spacer(); Text("\(count) / \(stats.reviewed.count)") } }.buttonStyle(.plain)
                        }
                        if stats.errors.isEmpty { Text("暂无已确认的错误标签").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity)
                }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                DisclosureGroup("错误复发与情绪关联") { trends }
                improvements
                HStack { Text(filter.examplesOnly ? "正确操作案例" : "操作明细 · 点击回看与评价").font(.headline); Spacer(); Text("\(samples.count) 条").font(.caption).foregroundStyle(.secondary) }
                LazyVStack(spacing: 10) {
                    ForEach(samples) { sample in
                        StockAssessmentRow(assessment: sample.assessment, issue: sample.issue) {
                            original = sample.persisted ? sample.assessment : nil; editing = sample.assessment
                        }
                    }
                }
            }.padding(22)
        }.sheet(item: $editing) { a in StockAssessmentEditor(service: service, initial: a, original: original) }
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("样本", selection: $filter.kind) { Text("实际买卖").tag("实际买卖"); Text("无成交决策").tag("无成交决策") }.pickerStyle(.segmented).frame(width: 240)
                Picker("风格", selection: $filter.style) { Text("全部").tag("全部"); ForEach(StockStyle.allCases) { Text($0.rawValue).tag($0.rawValue) } }.frame(width: 160)
                TextField("证券代码 / 市场", text: $filter.symbol).frame(maxWidth: 200)
                Spacer(); Button("重置") { filter = StockQualityFilter(); limited = false }
            }
            HStack {
                Toggle("限定日期", isOn: $limited)
                if limited { DatePicker("从", selection: $from, displayedComponents: .date); DatePicker("至", selection: $through, displayedComponents: .date) }
                Spacer()
            }
            HStack {
                Picker("规则版本", selection: $filter.rule) { Text("全部").tag("全部"); ForEach(ruleChoices) { r in Text("\(r.style.rawValue) · \(r.title) v\(r.version)").tag(r.id) } }
                Picker("错误", selection: $filter.mistake) { Text("全部").tag("全部"); ForEach(Array(Set(all.flatMap { $0.assessment.mistakes })).sorted(), id: \.self) { Text($0).tag($0) } }
            }
            HStack {
                Picker("情绪", selection: $filter.emotion) { Text("全部").tag("全部"); ForEach(Array(Set(all.map { $0.assessment.emotion })).sorted(), id: \.self) { Text($0.isEmpty ? "未填写" : $0).tag($0) } }
                Picker("执行", selection: $filter.execution) { Text("全部").tag("全部"); ForEach(StockExecution.allCases) { Text($0.rawValue).tag($0.rawValue) } }
            }
        }.textFieldStyle(.roundedBorder)
    }
    private var ruleStatistics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("规则符合情况").font(.headline)
            Text("符合率 = 符合 /（符合 + 违反）。每个版本分别统计；点击查看参与计算的操作。").font(.caption).foregroundStyle(.secondary)
            ForEach(stats.rules) { r in
                Button { filter.rule = r.id } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text("\(r.rule.style.rawValue) · \(r.rule.title) v\(r.rule.version)"); Spacer(); Text(r.ratio).fontWeight(.semibold) }
                        Text("符合 \(r.counts[.pass, default: 0]) · 违反 \(r.counts[.fail, default: 0]) · 无法判断 \(r.counts[.unknown, default: 0]) · 未评价 \(r.counts[.pending, default: 0]) · 不适用 \(r.counts[.irrelevant, default: 0])").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            if stats.rules.isEmpty { Text("还没有适用规则。先给轮次分类，再在操作评价中选择规则。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var trends: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("错误复发与情绪关联").font(.headline)
            Text("每月展示有错误的操作数 / 已确认复盘数。操作减少不直接代表改进；情绪关联不代表因果。").font(.caption).foregroundStyle(.secondary)
            ForEach(stats.months, id: \.0) { month, count, total in
                Button {
                    if let first = StockDay.date(month + "-01"), let next = StockDay.calendar.date(byAdding: .month, value: 1, to: first), let last = StockDay.calendar.date(byAdding: .day, value: -1, to: next) { from = first; through = last; limited = true }
                } label: { HStack { Text(month); Spacer(); Text("\(count) / \(total) 个操作有错误"); Text(total == 0 ? "无已确认样本" : String(format: "%.1f%%", locale: StockDecimal.locale, Double(count) / Double(total) * 100)).frame(width: 115, alignment: .trailing) } }.buttonStyle(.plain)
            }
            Divider()
            ForEach(stats.emotions, id: \.0) { emotion, count, total in
                Button { filter.emotion = emotion } label: { HStack { Text(emotion.isEmpty ? "情绪未填写" : emotion); Spacer(); Text("\(count) / \(total) 个操作有错误") } }.buttonStyle(.plain)
            }
        }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
    private var improvements: some View {
        DisclosureGroup("改进跟踪（\(stats.valid.filter { !$0.improvement.isEmpty }.count)）") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(stats.valid.filter { !$0.improvement.isEmpty }) { a in
                    let later = all.filter { sample in
                        let next = sample.assessment
                        guard let at = a.improvementAt else { return false }
                        return sample.issue == nil && next.id != a.id && next.reviewed && next.style == a.style && next.isTrade == a.isTrade && !next.time.isEmpty && !StockRepository.isRecordedAfter(at, day: next.date, time: next.time)
                    }.map(\.assessment)
                    let recurrences = later.filter { !Set($0.mistakes).isDisjoint(with: a.mistakes) }
                    VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(a.improvement).fontWeight(.medium); Spacer(); Text(a.improvementStatus).font(.caption) }
                            Text("建立于 \(a.improvementAt ?? "尚未保存")").font(.caption2).foregroundStyle(.secondary)
                            Text("措施建立后，同风格、同类样本已有 \(later.count) 个确认复盘；原错误复发于 \(recurrences.count) 个操作。缺少发生时间的记录不计入。").font(.caption).foregroundStyle(.secondary)
                            if !a.followUp.isEmpty { Text(a.followUp).font(.callout) }
                            Button("编辑措施与回看结论") { original = a; editing = a }
                            DisclosureGroup("查看后续 \(later.count) 个样本") {
                                ForEach(later) { next in
                                    Button { original = next; editing = next } label: {
                                        HStack { Text("\(next.date) · \(next.symbol)"); Spacer(); Text(next.mistakes.isEmpty ? "未记录错误" : next.mistakes.joined(separator: "、")).lineLimit(1) }
                                    }.buttonStyle(.plain).padding(.vertical, 5)
                                }
                            }
                    }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(.top, 10)
        }
    }
}

struct StockRoundsView: View {
    @ObservedObject var service: StockService
    @State private var selected: String?
    @State private var query = ""
    @State private var state = "全部"
    @State private var style = "全部"
    private var rounds: [StockRound] {
        service.rounds.filter { r in
            (query.isEmpty || (r.instrument.name + r.instrument.symbol).localizedCaseInsensitiveContains(query))
            && (state == "全部" || (state == "进行中" ? r.end == nil : r.end != nil))
            && (style == "全部" || (service.data.roundNotes.first { $0.id == r.id }?.style.rawValue ?? "未分类") == style)
        }.reversed()
    }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("搜索证券", text: $query).textFieldStyle(.roundedBorder)
                Picker("状态", selection: $state) { ForEach(["全部", "进行中", "已完成"], id: \.self) { Text($0).tag($0) } }
                Picker("风格", selection: $style) { Text("全部").tag("全部"); ForEach(StockStyle.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                Text("\(rounds.count) 轮 · 跨年连续计算").font(.caption).foregroundStyle(.secondary)
                List(selection: $selected) {
                    ForEach(rounds) { round in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(round.instrument.name).fontWeight(.medium)
                            Text(round.start + " → " + (round.end ?? "进行中")).font(.caption)
                            Text("\(round.buySellTrades.count) 笔买卖 · \(service.data.roundNotes.first { $0.id == round.id }?.style.rawValue ?? "未分类")").font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(round.id)
                    }
                }
                let missing = service.data.roundNotes.filter { note in !service.rounds.contains { $0.id == note.id } }
                if !missing.isEmpty {
                    DisclosureGroup("\(missing.count) 条原轮次备注待关联") {
                        ScrollView { ForEach(missing) { note in VStack(alignment: .leading, spacing: 6) {
                            Text("\(note.date) · \(note.style.rawValue) · \(note.strategy)").font(.caption)
                            Text(note.summary).font(.caption).textSelection(.enabled)
                            Menu("关联到新轮次") { ForEach(service.rounds.filter { r in !service.data.roundNotes.contains { $0.id == r.id } }) { round in
                                Button("\(round.instrument.name) · \(round.start)") { service.relinkRoundNote(note, to: round.id) }
                            } }
                        }.padding(.vertical, 8) } }.frame(maxHeight: 170)
                    }.font(.caption).foregroundStyle(.orange)
                }
            }.padding(16).frame(minWidth: 235, idealWidth: 255, maxWidth: 310)
            if let round = service.rounds.first(where: { $0.id == selected }), rounds.contains(where: { $0.id == round.id }) {
                StockRoundDetail(service: service, round: round).id(round.id)
            } else { ContentUnavailableView("选择一轮交易", systemImage: "arrow.triangle.2.circlepath", description: Text("从建仓到清仓，逐次回看决策和执行。")) }
        }.onAppear { if selected == nil { selected = rounds.first?.id } }
    }
}
struct StockRoundDetail: View {
    @ObservedObject var service: StockService
    var round: StockRound
    @State private var editing: StockAssessment?
    @State private var original: StockAssessment?
    @State private var editingNote = false
    @State private var selectedBar: Int?
    private var note: StockRoundNote? { service.data.roundNotes.first { $0.id == round.id } }
    private var samples: [StockQualitySample] { service.qualitySamples.filter { $0.assessment.roundID == round.id } }
    private var bars: [StockBar] {
        let all = service.data.charts[round.instrument.quoteCode] ?? []
        let first = all.firstIndex(where: { $0.date >= round.start }) ?? all.count
        return Array(all.dropFirst(max(0, first - 20)).filter { round.end == nil || $0.date <= round.end! })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(round.instrument.name + " · " + round.instrument.symbol).font(.title2.bold())
                        Text(round.start + " → " + (round.end ?? "进行中") + " · " + (note?.style.rawValue ?? "未分类")).foregroundStyle(.secondary)
                    }
                    Spacer(); Button("分类与轮次总结") { editingNote = true }.disabled(service.busy)
                }
                if let note {
                    if !note.strategy.isEmpty { Text("策略：" + note.strategy) }
                    if !note.summary.isEmpty { Text(note.summary).textSelection(.enabled) }
                    if !note.changes.isEmpty { DisclosureGroup("风格调整记录") { ForEach(note.changes) { change in Text("\(change.recordedAt) · \(change.style.rawValue) · \(change.reason)").font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) } } }
                }
                HStack {
                    StockMetricCard(title: "实际买卖", value: "\(round.buySellTrades.count) 笔", detail: "成交事实保留")
                    StockMetricCard(title: "已完成操作复盘", value: "\(samples.filter { $0.issue == nil && $0.assessment.isComplete && $0.assessment.isTrade }.count)", detail: "分批成交可合并评价")
                    StockMetricCard(title: "当前份额", value: StockDecimal.text(round.quantity), detail: round.end == nil ? "进行中" : "已清仓")
                }
                HStack { Text("日 K 与本轮买卖点").font(.headline); Spacer(); Button(service.chartLoading ? "获取中…" : "获取 / 更新日 K") { service.loadChart(round.instrument) }.disabled(service.chartLoading) }
                if let error = service.chartError, service.chartCode == round.instrument.id { Text(error).font(.caption).foregroundStyle(.orange) }
                if bars.isEmpty { Text("这一时段尚无日 K 缓存；可以继续查看和评价全部操作。").foregroundStyle(.secondary) }
                else {
                    StockCandles(bars: bars, trades: round.trades, selected: $selectedBar)
                    if let i = selectedBar, bars.indices.contains(i) {
                        let bar = bars[i]
                        Text("\(bar.date) · 开 \(bar.open, specifier: "%.3f") 高 \(bar.high, specifier: "%.3f") 低 \(bar.low, specifier: "%.3f") 收 \(bar.close, specifier: "%.3f")").font(.caption).monospacedDigit()
                        ForEach(round.buySellTrades.filter { $0.date == bar.date }) { trade in
                            Button("\(round.actionTitle(for: trade)) \(trade.price) × \(trade.quantity) · 查看理由与评价") { edit(trade) }
                        }
                    }
                    Text("不复权日线；可用范围 \(bars.first!.date) 至 \(bars.last!.date)。未覆盖日期不代表没有行情，日线不证明盘中触发先后。").font(.caption).foregroundStyle(.secondary)
                }
                Text("操作过程").font(.headline)
                ForEach(round.trades) { trade in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(trade.date) \(trade.time) · \(round.actionTitle(for: trade))")
                            Text("\(trade.price) × \(trade.quantity) · 费用 \(StockDecimal.display(trade.fee))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if trade.action == .buy || trade.action == .sell { Button(service.data.assessment(for: trade.id) == nil ? "评价操作" : "查看评价") { edit(trade) } }
                    }.padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("本轮评价与无成交决策").font(.headline)
                ForEach(samples.filter(\.persisted)) { sample in StockAssessmentRow(assessment: sample.assessment, issue: sample.issue) { original = sample.assessment; editing = sample.assessment } }
            }.padding(22)
        }.frame(minWidth: 540)
        .sheet(item: $editing) { a in StockAssessmentEditor(service: service, initial: a, original: original) }
        .sheet(isPresented: $editingNote) { StockRoundNoteEditor(service: service, round: round, original: note) }
    }
    private func edit(_ trade: StockTrade) {
        original = service.data.assessment(for: trade.id); editing = original ?? service.data.draftAssessment(for: trade)
    }
}
struct StockRoundNoteEditor: View {
    @ObservedObject var service: StockService
    let original: StockRoundNote?
    @State private var draft: StockRoundNote
    @State private var reason = ""
    @State private var error: String?
    @State private var cancelling = false
    private let initial: StockRoundNote
    @Environment(\.dismiss) private var dismiss
    init(service: StockService, round: StockRound, original: StockRoundNote?) {
        self.service = service; self.original = original
        let note = original ?? StockRoundNote(id: round.id, date: round.start)
        initial = note; _draft = State(initialValue: note)
    }
    var body: some View {
        VStack(spacing: 0) {
            Text("轮次分类与总结").font(.title2.bold()).padding(20)
            Form {
                Picker("风格", selection: $draft.style) { ForEach(StockStyle.allCases) { Text($0.rawValue).tag($0) } }
                TextField("分类 / 调整原因", text: $reason, axis: .vertical).lineLimit(2...4)
                TextField("策略标签", text: $draft.strategy)
                TextField("整轮总结", text: $draft.summary, axis: .vertical).lineLimit(5...10)
                Text("分类用于新操作的默认值；已有操作的风格、规则和计划版本保留原样。").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.orange).padding(.horizontal, 20) }
            HStack { Button("取消") { if draft != initial || !reason.isEmpty { cancelling = true } else { dismiss() } }; Spacer(); Button("保存") { service.saveRoundNote(draft, original: original, reason: reason) { ok in if ok { dismiss() } else { error = service.message } } }.buttonStyle(.borderedProminent) }.padding(20).disabled(service.busy)
        }.frame(width: 640, height: 520).interactiveDismissDisabled()
            .alert("放弃未保存的轮次总结？", isPresented: $cancelling) { Button("继续编辑", role: .cancel) {}; Button("放弃", role: .destructive) { dismiss() } }
    }
}
