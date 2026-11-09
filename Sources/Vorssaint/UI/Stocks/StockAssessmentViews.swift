// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI

struct StockTagField: View {
    var title: String
    @Binding var values: [String]
    var suggestions: [String]
    @State private var input = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(title + "（逗号分隔）", text: $input)
                    .onChange(of: input) { _, text in values = StockJournalText.tags(text) }
                if !suggestions.isEmpty {
                    Menu("选标签") { ForEach(suggestions, id: \.self) { tag in Button((values.contains(tag) ? "✓ " : "") + tag) {
                        if values.contains(tag) { values.removeAll { $0 == tag } } else { values.append(tag) }
                        input = values.joined(separator: "，")
                    } } }
                }
            }
            if !values.isEmpty { Text(values.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
        }.onAppear { input = values.joined(separator: "，") }
    }
}

struct StockAssessmentRow: View {
    var assessment: StockAssessment
    var issue: String? = nil
    var edit: () -> Void
    var body: some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(assessment.date).monospacedDigit()
                    Text(assessment.symbol.isEmpty ? "市场决策" : assessment.symbol).fontWeight(.semibold)
                    Text(assessment.isTrade ? "\(assessment.tradeIDs.count) 笔成交" : assessment.kind).foregroundStyle(.secondary)
                    Spacer()
                    if assessment.goodExample { Image(systemName: "bookmark.fill").foregroundStyle(.orange) }
                    Text(issue != nil ? "待重新核对" : assessment.isComplete ? "已复盘" : "待完善").font(.caption)
                }
                Text(assessment.reason.isEmpty ? "尚未填写决策依据" : assessment.reason).lineLimit(2).foregroundStyle(.secondary)
                HStack {
                    Text(assessment.style.rawValue); Text(assessment.execution.rawValue)
                    if !assessment.emotion.isEmpty { Text("情绪：" + assessment.emotion) }
                    if !assessment.mistakes.isEmpty { Text(assessment.mistakes.joined(separator: " · ")).foregroundStyle(.orange).lineLimit(1) }
                    Spacer(); Image(systemName: "chevron.right")
                }.font(.caption)
                if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct StockAssessmentEditor: View {
    @ObservedObject var service: StockService
    let original: StockAssessment?
    private let initial: StockAssessment
    @State private var draft: StockAssessment
    @State private var error: String?
    @State private var cancelling = false
    @State private var deleting = false
    @State private var selectedTab: Int
    @Environment(\.dismiss) private var dismiss
    init(service: StockService, initial: StockAssessment, original: StockAssessment?, initialTab: Int = 0) {
        self.service = service; self.initial = initial; self.original = original; _draft = State(initialValue: initial)
        _selectedTab = State(initialValue: initialTab)
    }
    private var selectedTrades: [StockTrade] { service.data.trades.filter { $0.deletedAt == nil && draft.tradeIDs.contains($0.id) }.sorted { $0.sortKey < $1.sortKey } }
    private var currentDay: String { selectedTrades.first?.date ?? draft.date }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(draft.isTrade ? "操作评价" : "复盘中的决策").font(.title2.bold())
                    Text("依据当时的信息回看；收益不参与评价").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Text(currentDay).monospacedDigit()
            }.padding(22)
            TabView(selection: $selectedTab) {
                decisionForm.tabItem { Text("决策与计划") }.tag(0)
                evaluationForm.tabItem { Text("规则与错误") }.tag(1)
                if draft.isTrade { tradeLinks.tabItem { Text("关联成交") }.tag(2) }
                context.tabItem { Text("市场背景") }.tag(3)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 20) }
            HStack {
                Button("取消") { if draft != initial { cancelling = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                if original != nil { Button("删除评价", role: .destructive) { deleting = true } }
                Spacer()
                Button("保存评价") { service.saveAssessment(draft, original: original) { ok in if ok { dismiss() } else { error = service.message } } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(20).disabled(service.busy)
        }.frame(width: 850, height: 780).interactiveDismissDisabled()
        .alert("放弃未保存的评价？", isPresented: $cancelling) { Button("继续编辑", role: .cancel) {}; Button("放弃", role: .destructive) { dismiss() } }
        .alert("删除这条评价？", isPresented: $deleting) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { if let original { service.deleteAssessment(original) { ok in if ok { dismiss() } else { error = service.message } } } }
        } message: { Text("原始成交和计划保留，删除前自动备份。相关成交将重新显示为待复盘。") }
    }
    private var decisionForm: some View {
        Form {
            Section("操作") {
                if draft.isTrade {
                    Text(selectedTrades.map { "\($0.instrument.name) \($0.action.title) \($0.price) × \($0.quantity)" }.joined(separator: "\n"))
                    if let issue = original?.linkIssue(in: service.data, rounds: service.rounds) { Text(issue + "；请在关联成交页核对，保存后才恢复统计。").foregroundStyle(.orange) }
                } else {
                    HStack {
                        TextField("决策类型", text: $draft.kind)
                        Menu("常用类型") { ForEach(["等待", "放弃买入", "继续持有", "应操作但未操作"], id: \.self) { type in Button(type) { draft.kind = type } } }
                    }
                    HStack {
                        DatePicker("发生日期", selection: Binding(get: { StockDay.date(draft.date) ?? Date() }, set: { draft.date = StockDay.string($0) }), displayedComponents: .date)
                        TextField("时间 HH:mm:ss（可选）", text: $draft.time)
                    }
                    TextField("证券代码 / 市场（可选）", text: $draft.symbol)
                    Picker("关联轮次", selection: Binding(get: { draft.roundID ?? "" }, set: { draft.roundID = $0.isEmpty ? nil : $0 })) {
                        Text("不关联").tag("")
                        ForEach(service.rounds.reversed()) { r in Text("\(r.instrument.name) · \(r.start)").tag(r.id) }
                        if let id = draft.roundID, !service.rounds.contains(where: { $0.id == id }) { Text("原轮次已失效，请重选").tag(id) }
                    }
                }
                Picker("当时的交易风格", selection: $draft.style) { ForEach(StockStyle.allCases) { Text($0.rawValue).tag($0) } }
                TextField("买卖 / 不操作的理由", text: $draft.reason, axis: .vertical).lineLimit(3...6)
                StockTagField(title: "理由标签", values: $draft.reasonTags, suggestions: service.data.rules.reasonTags)
                HStack {
                    TextField("当时的个人情绪", text: $draft.emotion)
                    Menu("常用情绪") { ForEach(service.data.rules.emotions, id: \.self) { emotion in Button(emotion) { draft.emotion = emotion } } }
                }
            }
            Section("计划与执行") {
                Picker("计划版本", selection: Binding(get: { draft.plan?.id ?? "" }, set: { id in draft.plan = service.data.planVersions.first { $0.id == id } })) {
                    Text("不关联").tag("")
                    ForEach(service.data.planVersions.reversed()) { p in Text("\(p.symbol) · v\(p.version) · \(p.condition.prefix(36))").tag(p.id) }
                    if let p = draft.plan, !service.data.planVersions.contains(where: { $0.id == p.id }) { Text("已保存的历史计划 · v\(p.version)").tag(p.id) }
                }
                if let plan = draft.plan {
                    Text(plan.condition)
                    Text("仓位：\(plan.position)\n失效条件：\(plan.stopLoss)").font(.caption).foregroundStyle(.secondary)
                    Text("版本记录时间：\(plan.recordedAt)").font(.caption2).textSelection(.enabled)
                    Text(plan.reason).font(.caption2).foregroundStyle(.secondary)
                    if StockRepository.isRecordedAfter(plan.recordedAt, day: currentDay, time: selectedTrades.first?.time ?? draft.time) {
                        Label("这个版本晚于操作，或缺少操作时间；不能作为已验证的事前计划。", systemImage: "clock").font(.caption).foregroundStyle(.orange)
                    }
                }
                Picker("是否按计划", selection: $draft.execution) { ForEach(StockExecution.allCases) { Text($0.rawValue).tag($0) } }
                TextField("调整依据 / 执行偏差（合理调整时必填）", text: $draft.adjustment, axis: .vertical).lineLimit(2...5)
            }
            Section("记录时间") {
                Text(original.map { "首次录入：\($0.createdAt)\n最后修改：\($0.updatedAt)" } ?? "保存时记录实际录入时间。").font(.caption).textSelection(.enabled)
                Text("操作发生时间与录入时间分别保存。晚于操作的补记会明确标注；不回填成事前记录。").font(.caption).foregroundStyle(.secondary)
                if let original, original.retrospective { Label("事后补记 / 缺少同期时间依据", systemImage: "clock").font(.caption).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped)
    }
    private var evaluationForm: some View {
        Form {
            Section("适用规则") {
                HStack {
                    Text("\(draft.style.rawValue) · \(draft.checks.count) 条规则")
                    Spacer(); Button("添加当前风格的规则") {
                        for rule in service.data.rules.rules where rule.enabled && rule.style == draft.style && !draft.checks.contains(where: { $0.rule.ruleID == rule.id }) {
                            draft.checks.append(StockRuleCheck(rule: rule.snapshot))
                        }
                    }.disabled(draft.style == .unspecified)
                }
                Text("已选规则保留其历史版本。不适用的规则请标记“不适用”；没有依据时选择“无法判断”。").font(.caption).foregroundStyle(.secondary)
                if draft.checks.isEmpty { Text("先选择超短或波段，再添加规则。未选择规则时不计为完成复盘。").foregroundStyle(.secondary) }
                ForEach($draft.checks) { $check in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(check.rule.title) · \(check.rule.style.rawValue) v\(check.rule.version)").fontWeight(.medium)
                            Spacer()
                            Picker("评价", selection: $check.judgment) { ForEach(StockJudgment.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 150)
                            Button { draft.checks.removeAll { $0.id == check.id } } label: { Image(systemName: "minus.circle") }.help("移除本次不需要的规则")
                        }
                        Text(check.rule.prompt).font(.caption).foregroundStyle(.secondary)
                        TextField("判断依据", text: $check.evidence, axis: .vertical).lineLimit(1...4)
                    }.padding(.vertical, 5)
                }
            }
            Section("错误与改进") {
                StockTagField(title: "犯错类型", values: $draft.mistakes, suggestions: service.data.rules.mistakes)
                Toggle("已核对本次理由、执行情况与错误", isOn: $draft.reviewed)
                Text("未确认的错误标签保留为草稿，不进入错误分布。没有错误标签不等于已经确认正确。").font(.caption).foregroundStyle(.secondary)
                TextField("下一次的具体改进措施", text: $draft.improvement, axis: .vertical).lineLimit(2...5)
                if !draft.improvement.isEmpty {
                    Picker("落实状态", selection: $draft.improvementStatus) { ForEach(["待落实", "执行中", "已回看"], id: \.self) { Text($0).tag($0) } }
                    TextField("后续案例与回看结论", text: $draft.followUp, axis: .vertical).lineLimit(2...5)
                    if let at = draft.improvementAt { Text("改进建立：\(at)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Section("正确操作案例") {
                Toggle("收藏为值得重复学习的操作", isOn: $draft.goodExample)
                if draft.goodExample { TextField("为什么值得重复（必填，不能只写盈利）", text: $draft.goodEvidence, axis: .vertical).lineLimit(2...5) }
                Text("由你根据当时依据确认，亏损操作也可以成为正确操作案例。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var tradeLinks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("同一次决策的分批成交可以合并评价。仅限同日、同一轮次、同一方向；每笔成交只属于一条评价。").foregroundStyle(.secondary)
            HStack { Text("已选 \(draft.tradeIDs.count) 笔"); Spacer(); Button("清空并重新关联") { draft.tradeIDs = []; draft.tradeSnapshots = []; draft.roundID = nil } }
            List {
                ForEach(service.rounds.reversed()) { round in
                    Section("\(round.instrument.name) · \(round.start) → \(round.end ?? "进行中")") {
                        ForEach(round.buySellTrades) { trade in
                            let owner = service.data.assessment(for: trade.id)
                            let first = selectedTrades.first
                            let incompatible = first.map { f in f.action != trade.action || f.date != trade.date || !round.trades.contains { $0.id == f.id } } ?? false
                            Toggle(isOn: Binding(get: { draft.tradeIDs.contains(trade.id) }, set: { selected in
                                draft.tradeIDs.removeAll { $0 == trade.id }; if selected { draft.tradeIDs.append(trade.id) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text("\(trade.date) \(trade.time) · \(round.actionTitle(for: trade)) · \(trade.price) × \(trade.quantity)")
                                    if let owner, owner.id != draft.id { Text("已有其他评价").font(.caption).foregroundStyle(.secondary) }
                                }
                            }.disabled((owner != nil && owner?.id != draft.id) || (incompatible && !draft.tradeIDs.contains(trade.id)))
                        }
                    }
                }
            }
            if draft.tradeIDs.contains(where: { id in !service.data.trades.contains(where: { $0.id == id && $0.deletedAt == nil }) }) {
                Text("包含已经删除的成交，请清空后重新选择。").foregroundStyle(.orange)
            }
        }.padding(20)
    }
    private var context: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(currentDay) · 收盘后的复盘背景").font(.headline)
                Text("这些数据可能在操作之后才生成，不代表当时已经知道。日 K 无法证明盘中条件的触发先后。").font(.caption).foregroundStyle(.secondary)
                if let snapshot = service.data.snapshots.first(where: { $0.date == currentDay }) {
                    StockMarketSummary(snapshot: snapshot)
                    Text("涨停梯队").font(.headline)
                    ForEach(Array(Set(snapshot.limits.map(\.boards))).sorted(by: >), id: \.self) { boards in
                        Text("\(boards) 板：" + snapshot.limits.filter { $0.boards == boards }.map(\.name).joined(separator: "、"))
                    }
                    Text("板块背景").font(.headline)
                    ForEach(snapshot.sectors.filter { $0.rank <= 5 }) { s in HStack { Text("\(s.kind) #\(s.rank) \(s.name)"); Spacer(); Text(stockPercent(s.change)) } }
                    ForEach(snapshot.sources) { source in Text("\(source.name)：\(source.status == "ok" ? "已保存" : "缺失或保留旧值") · \(source.detail)").font(.caption).foregroundStyle(.secondary) }
                } else { ContentUnavailableView("该日市场背景缺失", systemImage: "chart.bar.xaxis", description: Text("你仍可以保存全部操作评价；不会用其他日期的数据代替。")) }

            }.padding(20)
        }
    }
}

struct StockRulesView: View {
    @ObservedObject var service: StockService
    @State private var editing = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("逐步形成自己的交易纪律").font(.title3.bold()); Spacer(); Button("编辑规则与标签") { editing = true }.buttonStyle(.borderedProminent).disabled(service.busy) }
                Text("模板提供复盘提示，没有预设仓位或止损阈值。操作评价使用选定的规则版本，之后修改模板不会改写旧结论。").foregroundStyle(.secondary)
                ForEach([StockStyle.short, .swing]) { style in
                    Text(style.rawValue).font(.headline)
                    ForEach(service.data.rules.rules.filter { $0.style == style }) { rule in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(rule.title).fontWeight(.medium); Spacer(); Text("v\(rule.snapshot.version) · \(rule.enabled ? "启用" : "停用")").font(.caption) }
                            Text(rule.prompt).foregroundStyle(.secondary)
                            DisclosureGroup("历史版本（\(rule.versions.count)）") { ForEach(rule.versions) { v in Text("v\(v.version) \(v.title) · \(v.prompt)\n\(v.recordedAt.isEmpty ? "初始模板" : v.recordedAt)").font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) } }
                        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                Text("个人情绪：" + service.data.rules.emotions.joined(separator: "、"))
                Text("犯错类型：" + service.data.rules.mistakes.joined(separator: "、"))
            }.padding(22)
        }.sheet(isPresented: $editing) { StockRuleBookEditor(service: service, original: service.data.rules) }
    }
}
struct StockRuleBookEditor: View {
    @ObservedObject var service: StockService
    let original: StockRuleBook
    @State private var draft: StockRuleBook
    @State private var style: StockStyle = .short
    @State private var error: String?
    @State private var cancelling = false
    @Environment(\.dismiss) private var dismiss
    init(service: StockService, original: StockRuleBook) { self.service = service; self.original = original; _draft = State(initialValue: original) }
    var body: some View {
        VStack(spacing: 0) {
            Text("个人规则与标签").font(.title2.bold()).padding(20)
            Form {
                Section("规则模板") {
                    Picker("风格", selection: $style) { Text("超短").tag(StockStyle.short); Text("波段").tag(StockStyle.swing) }.pickerStyle(.segmented)
                    ForEach($draft.rules) { $rule in
                        if rule.style == style {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { TextField("规则名称", text: $rule.title); Toggle("启用", isOn: $rule.enabled) }
                                TextField("规则内容与复盘提示", text: $rule.prompt, axis: .vertical).lineLimit(2...5)
                                Text("保存内容修改后生成新版本；旧评价继续引用原版本。").font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                    }
                    Button("添加规则", systemImage: "plus") { draft.rules.append(StockRule(style: style)) }
                }
                Section("可自定义的常用标签") {
                    StockTagField(title: "理由标签", values: $draft.reasonTags, suggestions: [])
                    StockTagField(title: "个人情绪", values: $draft.emotions, suggestions: [])
                    StockTagField(title: "犯错类型", values: $draft.mistakes, suggestions: [])
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.orange).padding(.horizontal, 20) }
            HStack {
                Button("取消") { if draft != original { cancelling = true } else { dismiss() } }; Spacer()
                Button("保存规则") { service.saveRules(draft, original: original) { ok in if ok { dismiss() } else { error = service.message } } }.buttonStyle(.borderedProminent)
            }.padding(20).disabled(service.busy)
        }.frame(width: 760, height: 720).interactiveDismissDisabled()
            .alert("放弃未保存的规则？", isPresented: $cancelling) { Button("继续编辑", role: .cancel) {}; Button("放弃", role: .destructive) { dismiss() } }
    }
}
