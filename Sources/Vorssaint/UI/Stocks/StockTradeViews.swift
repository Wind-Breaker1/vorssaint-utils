// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI

struct StockTradeList: View {
    @ObservedObject var service: StockService
    var edit: (StockTrade) -> Void
    var copy: ((StockTrade) -> Void)? = nil
    var record: (() -> Void)? = nil
    @State private var query = ""
    @State private var year = "全部"
    @State private var action = "全部"
    @State private var deleting: StockTrade?
    @State private var evaluating: StockAssessment?
    @State private var evaluationOriginal: StockAssessment?
    private var years: [String] { Array(Set(service.data.trades.map { String($0.date.prefix(4)) })).sorted(by: >) }
    private var rows: [StockTrade] {
        service.data.trades.filter { t in t.deletedAt == nil && (year == "全部" || t.date.hasPrefix(year)) && (action == "全部" || t.action.title == action) && (query.isEmpty || "\(t.instrument.symbol) \(t.instrument.name) \(t.note) \(t.strategy)".localizedCaseInsensitiveContains(query)) }.sorted { $0.sortKey > $1.sortKey }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("搜索代码、名称、策略、备注", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Picker("年份", selection: $year) { Text("全部").tag("全部"); ForEach(years, id: \.self) { Text($0).tag($0) } }.frame(width: 130)
                Picker("方向", selection: $action) { Text("全部").tag("全部"); ForEach(StockAction.allCases) { Text($0.title).tag($0.title) } }.frame(width: 150)
                Spacer(); Menu("导入 / 导出") {
                    Button("导入成交 CSV / TSV…") { service.chooseImport() }
                    Button("导出全部成交…") { service.exportCSV() }
                    Button("下载 CSV 表头模板…") { service.exportCSV(template: true) }
                }
                if let record { Button("记一笔", systemImage: "plus", action: record).buttonStyle(.borderedProminent) }
            }.padding(.horizontal, 20).padding(.top, 16)
            HStack { Text("\(rows.count) 笔成交").font(.caption).foregroundStyle(.secondary); Spacer(); Text("买卖金额不含费用 · 盈亏按历史完整流水计算").font(.caption2).foregroundStyle(.secondary) }.padding(.horizontal, 20)
            if rows.isEmpty { ContentUnavailableView("还没有成交记录", systemImage: "arrow.left.arrow.right", description: Text("点击右上角“记一笔”，或导入券商导出的成交 CSV。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                HStack(spacing: 8) {
                    Text("成交时间").frame(width: 88, alignment: .leading)
                    Text("证券").frame(width: 108, alignment: .leading)
                    Text("方向").frame(width: 46, alignment: .leading)
                    Text("价格 / 数量").frame(width: 80, alignment: .trailing)
                    Text("费用").frame(width: 58, alignment: .trailing)
                    Text("已实现盈亏").frame(width: 88, alignment: .trailing)
                    Text("策略 / 备注").frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 28)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { t in
                            StockTradeRow(service: service, trade: t, edit: edit, copy: copy, delete: { deleting = t }) {
                                evaluationOriginal = service.data.assessment(for: t.id)
                                evaluating = evaluationOriginal ?? service.data.draftAssessment(for: t)
                            }
                            Divider().opacity(0.45)
                        }
                    }.padding(.horizontal, 10)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).disabled(service.busy)
        .sheet(item: $evaluating) { a in StockAssessmentEditor(service: service, initial: a, original: evaluationOriginal) }
        .alert("删除这笔成交？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let t = deleting { service.deleteTrade(t) }; deleting = nil }
        } message: { Text("会重新计算后续持仓和盈亏。如果删除导致后续卖出超过持仓，将拒绝删除；修改前会自动备份。") }
    }
}

private struct StockTradeRow: View {
    @ObservedObject var service: StockService
    let trade: StockTrade
    let edit: (StockTrade) -> Void
    let copy: ((StockTrade) -> Void)?
    let delete: () -> Void
    let evaluate: () -> Void
    private var profit: Decimal? { service.ledger.saleProfit[trade.id] }
    private var codeLabel: String { trade.instrument.exchange + " " + trade.instrument.symbol }
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) { Text(trade.date); Text(trade.time).font(.caption2).foregroundStyle(.secondary) }.frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) { Text(trade.instrument.name).lineLimit(1); Text(codeLabel).font(.caption2).foregroundStyle(.secondary) }.frame(width: 108, alignment: .leading)
            actionLabel.frame(width: 46, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) { Text(trade.price); Text(trade.quantity).foregroundStyle(.secondary) }.frame(width: 80, alignment: .trailing)
            Text(StockDecimal.display(trade.fee)).frame(width: 58, alignment: .trailing)
            profitLabel.frame(width: 88, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if !trade.strategy.isEmpty { Text(trade.strategy).lineLimit(1) }
                Text(trade.note.isEmpty ? "—" : trade.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            actions.frame(width: 28)
        }.font(.callout.monospacedDigit()).padding(.horizontal, 4).frame(minHeight: 54)
    }
    private var actionLabel: some View {
        Text(trade.action.title).foregroundStyle(trade.action == .buy ? Color.red : trade.action == .sell ? Color.green : Color.secondary)
    }
    private var profitLabel: some View {
        Text(profit.map { StockDecimal.display($0) } ?? "—").foregroundStyle(profit.map { stockColor($0) } ?? .secondary)
    }
    private var actions: some View {
        Menu {
            Button("编辑成交") { edit(trade) }
            if trade.action == .buy || trade.action == .sell { Button("评价 / 查看操作", action: evaluate) }
            if let copy { Button("复制为新成交") { copy(trade.copyForNewTrade()) } }
            Button("删除成交", role: .destructive, action: delete)
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
    }
}

struct StockTradeEditor: View {
    @ObservedObject var service: StockService
    let original: StockTrade?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StockTrade
    @State private var error: String?
    @State private var cancel = false
    @State private var showingDatePicker = false
    @State private var matches: [StockInstrument] = []
    @State private var searchStatus = ""
    @State private var resolvedName = ""
    private let initial: StockTrade
    init(service: StockService, initial: StockTrade, original: StockTrade?) { self.service = service; self.original = original; self.initial = initial; _draft = State(initialValue: initial) }
    private var day: Binding<Date> { Binding(get: { StockDay.date(draft.date) ?? Date() }, set: { draft.date = StockDay.string($0) }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(original == nil ? "记录成交" : "编辑成交").font(.title2.bold()); Spacer(); Text("实际成交 · 人民币").foregroundStyle(.secondary) }.padding(16)
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { TextField("代码（六位）", text: $draft.instrument.symbol).frame(width: 130); TextField("中文名称", text: Binding(get: { draft.instrument.name }, set: { value in draft.instrument.name = value; draft.instrument.symbol = ""; resolvedName = ""; matches = [] }))
                        Picker("品种", selection: $draft.instrument.kind) { Text("股票").tag("stock"); Text("场内 ETF").tag("etf") }.frame(width: 160)
                    }
                    if !searchStatus.isEmpty { Text(searchStatus).font(.caption).foregroundStyle(.secondary) }
                    ForEach(matches) { item in
                        Button { select(item) } label: {
                            HStack { Text(item.name); Spacer(); Text(item.symbol + " · " + item.exchange).foregroundStyle(.secondary) }
                        }.buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    if let original, service.data.assessment(for: original.id) != nil { Text("修改日期、方向、价格、数量或费用后，原操作评价会标记为待重新核对，并暂时退出统计。").font(.caption).foregroundStyle(.orange) }
                    HStack(spacing: 16) {
                    Picker("业务", selection: $draft.action) { ForEach(StockAction.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        HStack(spacing: 6) {
                            Text("日期").foregroundStyle(.secondary)
                            Button { showingDatePicker.toggle() } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "calendar")
                                    Text(day.wrappedValue.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                                    Image(systemName: "chevron.down").font(.caption2)
                                }
                            }.buttonStyle(.plain)
                                .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
                                    CalendarDatePicker(selection: day)
                                }
                        }
                    }
                    HStack {
                        TextField(draft.action == .dividend ? "分红税前总额" : "成交价格", text: $draft.price)
                        TextField(draft.action == .shares ? "增减份额（可负数）" : "成交数量（股 / 份）", text: $draft.quantity)
                    }
                    if draft.action == .dividend { Text("填写分红总额，数量填 0；").font(.caption).foregroundStyle(.secondary) }
                    if draft.action == .shares { Text("送转、拆合或份额折算：价格填 0，数量填增加或减少的份额，总成本保持不变。").font(.caption).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    TextField("策略 / 交易模式", text: $draft.strategy)
                    TextField("买卖理由、执行情况", text: $draft.note, axis: .vertical).lineLimit(2...4)
                    Text("可以先保存成交，再从成交列表补充规则评价、个人情绪和错误类型。").font(.caption).foregroundStyle(.secondary)
                }
            }.textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.vertical, 4)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout).padding(.horizontal, 22).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { if draft != initial { cancel = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button(service.busy ? "正在保存…" : "保存成交") {
                    do { try draft.validate(); service.saveTrade(draft, original: original) { ok in if ok { dismiss() } else { error = service.message } } }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(16).disabled(service.busy)
        }.frame(width: 640, height: 410).interactiveDismissDisabled()
        .onChange(of: draft.instrument.symbol) { _, code in
            if code.count == 6 { let item = StockInstrument.inferred(code); draft.instrument.exchange = item.exchange; draft.instrument.kind = item.kind }
        }
        .task(id: draft.instrument.name) {
            let query = draft.instrument.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query != resolvedName, !(query == initial.instrument.name && !draft.instrument.symbol.isEmpty) else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                searchStatus = "正在匹配证券…"
                let local = service.instruments.filter { $0.name == query }
                let results = local.isEmpty ? try await StockMarketClient.searchInstruments(query) : local
                try Task.checkCancellation()
                guard draft.instrument.name.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                let exact = results.filter { $0.name == query }
                if exact.count == 1 { select(exact[0]) }
                else if results.count == 1 { select(results[0]) }
                else { matches = Array(results.prefix(8)); searchStatus = results.isEmpty ? "未找到匹配，可手动填写代码" : "请选择证券以填写代码" }
            } catch {
                guard !Task.isCancelled else { return }
                searchStatus = "搜索暂不可用，可手动填写代码"
            }
        }
        .alert("放弃未保存的成交？", isPresented: $cancel) { Button("继续编辑", role: .cancel) {}; Button("放弃", role: .destructive) { dismiss() } }
    }
    private func select(_ item: StockInstrument) {
        resolvedName = item.name
        draft.instrument = item
        matches = []
        searchStatus = "已匹配 " + item.symbol + " · " + item.exchange
    }

}

struct StockImportView: View {
    @ObservedObject var service: StockService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("核对导入成交").font(.title2.bold())
            Text("勾选记录会一次性校验并保存。缺少买入历史、卖超持仓或发生重复时不会部分导入。疑似重复默认不勾选，请按交割单核对。").foregroundStyle(.secondary)
            HStack { Text("\(service.importRows.count) 行 · 已选 \(service.importRows.filter(\.selected).count) 行"); Spacer(); Button("全不选") { for i in service.importRows.indices { service.importRows[i].selected = false } } }
            List($service.importRows) { $row in
                HStack(alignment: .top) {
                    Toggle("", isOn: $row.selected).labelsHidden().disabled(row.trade == nil || row.duplicate)
                    Text("\(row.line)").frame(width: 34).foregroundStyle(.secondary)
                    if let t = row.trade {
                        Text(t.date).frame(width: 90); Text(t.instrument.symbol + " " + t.instrument.name).frame(width: 150, alignment: .leading)
                        Text(t.action.title).frame(width: 70); Text(t.price + " × " + t.quantity).frame(width: 130, alignment: .trailing)
                    }
                    Text(row.message).font(.caption).foregroundStyle(row.message == "可导入" ? Color.secondary : Color.orange)
                }.padding(.vertical, 4)
            }
            if let message = service.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("导入选中记录") { service.commitImport() }.buttonStyle(.borderedProminent).disabled(!service.importRows.contains(where: \.selected)) }.disabled(service.busy)
        }.padding(24).frame(width: 990, height: 620).interactiveDismissDisabled()
    }
}
