// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI

struct StockMarketSummary: View {
    let snapshot: StockMarketSnapshot
    var previous: StockMarketSnapshot? = nil
    private let names = ["上涨家数","下跌家数","平盘家数","涨停家数","跌停家数","炸板家数","涨停晋级率","炸板率"]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !snapshot.indices.isEmpty {
                HStack(spacing: 8) { ForEach(snapshot.indices.prefix(3)) { q in
                    HStack(spacing: 6) { Text(q.name).font(.caption); Text(String(format: "%.2f", locale: StockDecimal.locale, q.price)).fontWeight(.semibold); Text(stockPercent(q.change)).foregroundStyle(q.change >= 0 ? Color.red : Color.green) }
                        .monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                } }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], alignment: .leading, spacing: 6) {
                ForEach(names, id: \.self) { name in
                    let value = snapshot.metrics[name]
                    HStack(spacing: 5) {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text(value.map { name.contains("率") || name.contains("涨幅") ? String(format: "%.1f%%", locale: StockDecimal.locale, $0) : String(format: "%.0f", locale: StockDecimal.locale, $0) } ?? "—").font(.callout.monospacedDigit().weight(.semibold))
                    }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if let amount = snapshot.metrics["沪深成交额"] {
                HStack(spacing: 12) {
                    Text("沪深成交额 \(amount / 100_000_000, specifier: "%.2f") 亿元")
                    if let previous,
                       previous.date == snapshot.previousTradingDay,
                       let before = previous.metrics["沪深成交额"],
                       before > 0 {
                        let delta = amount - before
                        Text(delta > 0 ? "较前日放量 \(delta / 100_000_000, specifier: "%.2f") 亿元" :
                             delta < 0 ? "较前日缩量 \(abs(delta) / 100_000_000, specifier: "%.2f") 亿元" : "较前日持平")
                            .foregroundStyle(delta > 0 ? Color.red : delta < 0 ? Color.green : Color.secondary)
                        Text(String(format: "%+.1f%%", locale: StockDecimal.locale, delta / before * 100))
                            .foregroundStyle(delta > 0 ? Color.red : delta < 0 ? Color.green : Color.secondary)
                    } else {
                        Text("前日对比数据不可用").foregroundStyle(.secondary)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
    }
}
struct StockRotationView: View {
    let snapshots: [StockMarketSnapshot]
    let day: String
    private var history: [StockMarketSnapshot] { Array(snapshots.filter { $0.date <= day }.sorted { $0.date < $1.date }.suffix(3)) }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(history) { snapshot in
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(snapshot.date.dropFirst(5))).font(.subheadline.weight(.semibold))
                    HStack(alignment: .top, spacing: 8) {
                        sectorList("领涨", sectors: Array(snapshot.sectors.prefix(5)), color: .red)
                        sectorList("领跌", sectors: Array((snapshot.industryDecliners ?? []).prefix(5)), color: .green)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }
            if history.isEmpty { Text("暂无近三日板块数据").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func sectorList(_ title: String, sectors: [StockSector], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            if sectors.isEmpty {
                Text("暂无数据").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(sectors) { sector in
                    HStack(spacing: 3) {
                        Text(sector.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(stockPercent(sector.change)).monospacedDigit()
                    }.font(.caption2).foregroundStyle(color)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct StockLimitLadder: View {
    let limits: [StockLimit]
    var showsHeader = true
    private var levels: [Int] { Array(Set(limits.map(\.boards))).sorted(by: >) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader { HStack {
                Text("连板天梯").font(.headline)
                Spacer()
                Text("连板 \(limits.filter { $0.boards > 1 }.count) 只 · 首板 \(limits.filter { $0.boards == 1 }.count) 只").font(.caption).foregroundStyle(.secondary)
            }
            }
            if limits.isEmpty {
                Text("暂无涨停样本，请查看来源与缺失状态确认是否获取成功。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(levels, id: \.self) { level in
                    let items = limits.filter { $0.boards == level }.sorted { $0.firstTime == $1.firstTime ? $0.code < $1.code : $0.firstTime < $1.firstTime }
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 4) {
                            Text(level == 1 ? "首板" : "\(level) 板").font(.callout.bold()).foregroundStyle(level > 1 ? Color.orange : Color.secondary)
                            Text("\(items.count) 只").font(.caption2).foregroundStyle(.secondary)
                        }.frame(width: 44).padding(.top, 8)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155))], alignment: .leading, spacing: 6) {
                            ForEach(items) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 4) {
                                        Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(item.code).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Text(item.industry.isEmpty ? "行业未提供" : item.industry).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text("首封 \(time(item.firstTime)) · 开板 \(item.breaks) 次").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                                    .help("\(item.name) \(item.code) · \(item.industry) · 首封 \(time(item.firstTime)) · 开板 \(item.breaks) 次")
                            }
                        }
                    }
                }
            }
        }
    }
    private func time(_ value: String) -> String {
        guard value.count == 6 else { return value.isEmpty ? "—" : value }
        return String(value.prefix(2)) + ":" + String(value.dropFirst(2).prefix(2))
    }
}
