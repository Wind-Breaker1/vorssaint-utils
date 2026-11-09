// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI
import Charts

extension StockService {
    func quote(for item: StockInstrument) -> StockQuote? {
        let cached = data.snapshots.sorted { $0.date > $1.date }.compactMap { $0.quotes.first { $0.code == item.quoteCode } }.first
        if let live = liveQuotes.first(where: { $0.code == item.quoteCode }), live.date >= (cached?.date ?? "") { return live }
        return cached
    }
}
struct StockOverview: View {
    @State private var tab = "持仓"
    @ObservedObject var service: StockService
    var record: ((StockTrade) -> Void)? = nil
    private var held: [StockPosition] { service.ledger.positions.filter { $0.quantity > 0 } }
    private var priced: [(StockPosition, StockQuote)] { held.compactMap { p in service.quote(for: p.instrument).map { (p,$0) } } }
    private var value: Decimal { priced.reduce(0) { $0 + $1.0.quantity * Decimal($1.1.price) } }
    private var floating: Decimal { priced.reduce(0) { $0 + $1.0.quantity * Decimal($1.1.price) - $1.0.cost } }
    private var curve: [(String, Double)] {
        var sums: [String: Decimal] = [:]
        for t in service.data.trades where t.deletedAt == nil {
            if let p = service.ledger.saleProfit[t.id] { sums[t.date, default: 0] += p }
            if t.action == .dividend, let amount = try? StockDecimal.parse(t.price) { sums[t.date, default: 0] += amount - t.fee }
        }
        var total: Decimal = 0
        return sums.keys.sorted().map { total += sums[$0]!; return ($0, NSDecimalNumber(decimal: total).doubleValue) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(["持仓", "统计数据"], id: \.self) { item in
                    Button { tab = item } label: {
                        Text(item).font(.callout.weight(.medium)).frame(width: 84, height: 26)
                            .foregroundStyle(tab == item ? Color.white : Color.primary)
                            .background(tab == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }.padding(2).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
            GeometryReader { geometry in
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if tab == "统计数据" { StockQualityCharts(service: service) }
                if tab == "持仓" {
                HStack(spacing: 12) {
                    StockMetricCard(title: "累计已实现盈亏", value: StockDecimal.display(service.ledger.realized), detail: "扣除费用 · 含现金分红", tint: stockColor(service.ledger.realized))
                    StockMetricCard(title: "已报价浮盈亏", value: StockDecimal.display(floating), detail: "\(priced.count)/\(held.count) 只持仓有报价", tint: stockColor(floating))
                    StockMetricCard(title: "已报价市值", value: StockDecimal.display(value), detail: "缺失行情不计入估值")
                }
                HStack(spacing: 12) {
                    StockMetricCard(title: "持仓成本", value: StockDecimal.display(held.reduce(0) { $0 + $1.cost }), detail: "\(held.count) 只证券 · 移动加权平均")
                    StockMetricCard(title: "累计费用", value: StockDecimal.display(service.ledger.fees), detail: "按录入的佣金、税费和其他费用")
                }
                HStack { Text("当前持仓 · \(held.count)").font(.headline); Spacer(); Button { service.refreshQuotes() } label: { Label("更新行情", systemImage: "arrow.clockwise") } }
                if held.isEmpty { ContentUnavailableView("当前没有持仓", systemImage: "tray", description: Text("录入买入成交后，持仓与估值会显示在这里。")) }
                else {
                    HStack(spacing: 12) {
                        Text("证券").frame(maxWidth: .infinity, alignment: .leading)
                        Text("数量").frame(width: 84, alignment: .trailing)
                        Text("成本 / 股").frame(width: 96, alignment: .trailing)
                        Text("现价").frame(width: 82, alignment: .trailing)
                        Text("浮盈亏").frame(width: 112, alignment: .trailing)
                        Color.clear.frame(width: 72)
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(held) { position in
                                StockPositionRow(position: position, quote: service.quote(for: position.instrument), record: record)
                            }
                        }
                    }.frame(height: max(100, geometry.size.height - 285))
                }
                }
                if tab == "统计数据", !curve.isEmpty {
                    Text("累计已实现收益").font(.headline)
                    Text("每次卖出与分红形成的收益；不代表含持仓波动的账户净值。").font(.caption).foregroundStyle(.secondary)
                    Chart(Array(curve.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("日期", point.0), y: .value("累计收益", point.1)).foregroundStyle(Color.accentColor)
                        PointMark(x: .value("日期", point.0), y: .value("累计收益", point.1)).symbolSize(16)
                    }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { AxisGridLine(); AxisValueLabel(anchor: .center) } }.frame(height: 190)
                }
            }.padding(.horizontal, 20).padding(.bottom, 20)
            }
            }
        }.onAppear { service.refreshQuotes() }
    }
}
private struct StockPositionRow: View {
    var position: StockPosition
    var quote: StockQuote?
    var record: ((StockTrade) -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) { Text(position.instrument.name).fontWeight(.medium).lineLimit(1); Text(position.instrument.id).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
            Text(StockDecimal.text(position.quantity)).frame(width: 84, alignment: .trailing)
            Text(StockDecimal.display(position.average, digits: 4)).frame(width: 96, alignment: .trailing)
            if let quote {
                VStack(alignment: .trailing, spacing: 2) { Text(String(format: "%.3f", locale: StockDecimal.locale, quote.price)); Text(quote.date).font(.caption2).foregroundStyle(.secondary) }.frame(width: 82, alignment: .trailing)
                let p = position.quantity * Decimal(quote.price) - position.cost
                Text(StockDecimal.display(p)).foregroundStyle(stockColor(p)).frame(width: 112, alignment: .trailing)
            } else { Text("缺少行情").font(.caption).foregroundStyle(.secondary).frame(width: 112, alignment: .trailing) }
            if let record { Button { record(StockTrade(instrument: position.instrument, action: .sell, quantity: StockDecimal.text(position.quantity))) } label: { Label("卖出", systemImage: "arrow.up.right") }.labelStyle(.titleAndIcon).frame(width: 72) }
        }.font(.callout.monospacedDigit()).padding(.horizontal, 10).frame(minHeight: 48).background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct StockCandles: View {
    let bars: [StockBar]
    let trades: [StockTrade]
    @Binding var selected: Int?
    private func average(_ index: Int, _ count: Int) -> Double? { guard index + 1 >= count else { return nil }; return bars[(index-count+1)...index].map(\.close).reduce(0,+) / Double(count) }
    var body: some View {
        VStack(spacing: 12) {
            Chart {
                ForEach(Array(bars.enumerated()), id: \.offset) { i, bar in
                    RuleMark(x: .value("交易日", i), yStart: .value("低", bar.low), yEnd: .value("高", bar.high)).foregroundStyle(bar.close >= bar.open ? Color.red : Color.green)
                    BarMark(x: .value("交易日", i), yStart: .value("开", min(bar.open,bar.close)), yEnd: .value("收", max(bar.open,bar.close) + (bar.open == bar.close ? 0.001 : 0)), width: .fixed(2.5)).foregroundStyle(bar.close >= bar.open ? Color.red : Color.green)
                    if let ma = average(i,5) { LineMark(x: .value("交易日",i), y: .value("MA5",ma), series: .value("均线","MA5")).foregroundStyle(Color.orange).lineStyle(StrokeStyle(lineWidth: 1)) }
                    if let ma = average(i,20) { LineMark(x: .value("交易日",i), y: .value("MA20",ma), series: .value("均线","MA20")).foregroundStyle(Color.purple).lineStyle(StrokeStyle(lineWidth: 1)) }
                }
                ForEach(trades.filter { $0.action == .buy || $0.action == .sell }) { t in
                    if let i = bars.firstIndex(where: { $0.date == t.date }), let p = Double(t.price) {
                        PointMark(x: .value("交易日",i), y: .value("成交价",p)).foregroundStyle(Color.blue).symbolSize(30).annotation(position: .top) { Text(t.action == .buy ? "B" : "S").font(.caption2.bold()).foregroundStyle(.blue) }
                    }
                }
                if let selected { RuleMark(x: .value("选中",selected)).foregroundStyle(Color.secondary.opacity(0.5)) }
            }.chartYScale(domain: .automatic(includesZero: false)).chartXSelection(value: $selected).chartXAxis {
                AxisMarks(values: .stride(by: 40)) { value in AxisGridLine(); AxisValueLabel { if let i = value.as(Int.self), bars.indices.contains(i) { Text(String(bars[i].date.dropFirst(5))) } } }
            }.frame(minHeight: 280)
            Chart(Array(bars.enumerated()), id: \.offset) { i, bar in BarMark(x: .value("交易日", i), y: .value("成交量（手）",bar.volume), width: .fixed(2.5)).foregroundStyle(bar.close >= bar.open ? Color.red.opacity(0.5) : Color.green.opacity(0.5)) }.chartXAxis(.hidden).frame(height: 90)
        }
    }
}

private struct StockQualityCharts: View {
    @ObservedObject var service: StockService
    private var samples: [StockQualitySample] { service.qualitySamples.filter { $0.assessment.isTrade } }
    private var stats: StockQualityStatistics { StockQualityStatistics(samples: samples) }
    private var judgments: [(String, Int)] {
        StockJudgment.allCases.map { judgment in
            (judgment.rawValue, stats.rules.reduce(0) { $0 + $1.counts[judgment, default: 0] })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("操作统计").font(.headline)
                Spacer()
            }
            Text("已完成复盘 \(stats.complete) / \(stats.valid.count) · 待完善 \(stats.valid.count - stats.complete) · 关联失效 \(samples.filter { $0.issue != nil }.count)").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                bars("规则判断 · 项次", rows: judgments)
                bars("计划执行 · 操作数", rows: stats.executions)
                bars("错误分布 · 前五项", rows: Array(stats.errors.prefix(5)))
            }
            Text("统计全部实际买卖历史；关联失效的评价不计入。规则按检查项累计，错误按已确认操作统计，可多选。盈亏不决定操作对错。").font(.caption2).foregroundStyle(.secondary)
        }.padding(12).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
    private func bars(_ title: String, rows: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold))
            if rows.allSatisfy({ $0.1 == 0 }) {
                Text("暂无统计数据").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart(rows, id: \.0) { label, count in
                    BarMark(x: .value("数量", count), y: .value("分类", label), height: .fixed(8))
                        .foregroundStyle(label == "违反" || label == "偏离计划" ? Color.orange : Color.accentColor)
                        .annotation(position: .trailing) { Text("\(count)").font(.caption2) }
                }.chartXAxis(.hidden).frame(height: CGFloat(max(1, rows.count)) * 25).padding(.trailing, 18)
            }
        }.frame(maxWidth: .infinity)
    }
}
