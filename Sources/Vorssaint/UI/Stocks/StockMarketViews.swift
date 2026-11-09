// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI

struct StockMarketSummary: View {
    let snapshot: StockMarketSnapshot
    private let names = ["上涨家数","下跌家数","涨停家数","跌停家数","炸板家数","最高连板","涨停晋级率","炸板率","昨日涨停平均涨幅"]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !snapshot.indices.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210))], alignment: .leading, spacing: 8) { ForEach(snapshot.indices) { q in
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
            if let amount = snapshot.metrics["沪深成交额"] { Text("沪深成交额 \(amount / 100_000_000, specifier: "%.2f") 亿元").font(.caption).foregroundStyle(.secondary) }
        }.padding(10).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
    }
}
struct StockMarketView: View {
    @ObservedObject var service: StockService
    @State private var selected = Date()
    @State private var kind = "行业"
    private var day: String { StockDay.string(selected) }
    private var snapshot: StockMarketSnapshot? { service.data.snapshots.first { $0.date == day } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DatePicker("交易日", selection: $selected, displayedComponents: .date).frame(width: 220)
                    Menu("已保存日期") { ForEach(service.data.snapshots.sorted { $0.date > $1.date }) { s in Button(s.date) { selected = StockDay.date(s.date)! } } }
                    Spacer(); Button(service.collecting ? "正在采集…" : "获取 / 补全当日数据") { service.collect(date: day) }.disabled(service.collecting || service.busy)
                }
                if let snapshot {
                    StockMarketSummary(snapshot: snapshot)
                    let previous = service.data.snapshots.filter { $0.date < day }.max { $0.date < $1.date }
                    if let now = snapshot.metrics["沪深成交额"], let previous, let before = previous.metrics["沪深成交额"] {
                        Text("较已保存的 \(previous.date) 成交额变化：\((now-before)/100_000_000, specifier: "%+.2f") 亿元").font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("涨停梯队 · \(snapshot.limits.count) 只").font(.headline)
                            StockLimitTable(limits: snapshot.limits)
                        }.frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text("板块轮动").font(.headline); Spacer(); Picker("板块", selection: $kind) { Text("行业").tag("行业"); Text("概念").tag("概念") }.labelsHidden().pickerStyle(.segmented).frame(width: 140) }
                            ScrollView { StockRotationView(snapshots: service.data.snapshots, day: day, kind: kind) }.frame(height: 400)
                        }.frame(maxWidth: .infinity)
                    }
                    DisclosureGroup("数据来源、采集状态与口径") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("采集时间：\(snapshot.fetchedAt) · 计算口径 v\(snapshot.formulaVersion)").font(.caption)
                            Text("涨跌家数：上游沪深北市场统计；涨停/跌停/炸板按东方财富专题池，覆盖范围不保证包含全部北交所及特殊状态证券。炸板率=炸板/(涨停+炸板)；晋级率=昨日涨停样本中今日仍涨停的比例。板块保存行业与概念涨幅前 100 名，名次缺失不等于跌出榜或下跌。").font(.caption).foregroundStyle(.secondary)
                            ForEach(snapshot.sources) { source in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Image(systemName: source.status == "ok" ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(source.status == "ok" ? .green : .orange); Text(source.name).fontWeight(.medium); Spacer(); if let url = URL(string: source.url) { Link("来源", destination: url) } }
                                    Text(source.detail).font(.caption).foregroundStyle(.secondary)
                                    Text(source.fetchedAt).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.top, 10)
                    }
                } else { ContentUnavailableView("该日还没有市场快照", systemImage: "chart.bar.xaxis", description: Text("收盘后自动保存最近交易日，也可以选择日期手动采集。无法取得的历史数据会明确标记。")) }
            }.padding(16)
        }.onAppear { if let last = service.data.snapshots.map(\.date).max(), let date = StockDay.date(last) { selected = date } }
    }
    private func formatTime(_ value: String) -> String { value.count == 6 ? String(value.prefix(2)) + ":" + String(value.dropFirst(2).prefix(2)) + ":" + String(value.suffix(2)) : value }
}
private struct StockRotationView: View {
    let snapshots: [StockMarketSnapshot]
    let day: String
    let kind: String
    private var history: [StockMarketSnapshot] { Array(snapshots.filter { $0.date <= day }.sorted { $0.date < $1.date }.suffix(5)) }
    private var sectors: [StockSector] {
        var result: [StockSector] = []
        for s in history.reversed() { for sector in s.sectors.filter({ $0.kind == kind && $0.rank <= 10 }).sorted(by: { $0.rank < $1.rank }) where !result.contains(where: { $0.id == sector.id }) { result.append(sector) } }
        return Array(result.prefix(30))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近 5 个已保存交易日的涨幅排名与涨跌幅；展示这些日期前十名的并集，最多 30 个板块。缺失历史需逐日积累。").font(.caption).foregroundStyle(.secondary)
            if sectors.isEmpty { Text("暂无板块排名").foregroundStyle(.secondary) }
            else {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                    GridRow { Text("板块").fontWeight(.medium); ForEach(history) { Text(String($0.date.dropFirst(5))).font(.caption).frame(maxWidth: .infinity) } }
                    ForEach(sectors) { sector in
                        GridRow {
                            Text(sector.name).font(.callout).lineLimit(1).frame(width: 82, alignment: .leading)
                            ForEach(history) { s in
                                if let item = s.sectors.first(where: { $0.id == sector.id }) {
                                    VStack(spacing: 3) { Text("#\(item.rank)").font(.caption.bold()); Text(stockPercent(item.change)).font(.caption2) }.frame(maxWidth: .infinity).padding(4).background((item.change >= 0 ? Color.red : Color.green).opacity(min(0.25, abs(item.change)/25 + 0.04)), in: RoundedRectangle(cornerRadius: 5))
                                } else { Text("—").frame(maxWidth: .infinity).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct StockLimitTable: View {
    let limits: [StockLimit]
    @State private var boards = 0
    @State private var query = ""
    private var rows: [StockLimit] { limits.filter { (boards == 0 || $0.boards == boards) && (query.isEmpty || ($0.name + $0.code + $0.industry).localizedCaseInsensitiveContains(query)) }.sorted { $0.boards == $1.boards ? $0.firstTime < $1.firstTime : $0.boards > $1.boards } }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("梯队", selection: $boards) { Text("全部").tag(0); ForEach(Array(Set(limits.map(\.boards))).sorted(by: >), id: \.self) { n in Text("\(n) 板 · \(limits.filter { $0.boards == n }.count)").tag(n) } }.labelsHidden().frame(width: 140)
                TextField("代码 / 名称 / 行业", text: $query).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                Text("板").frame(width: 28, alignment: .leading)
                Text("证券").frame(maxWidth: .infinity, alignment: .leading)
                Text("行业").frame(width: 72, alignment: .leading)
                Text("首封").frame(width: 48, alignment: .trailing)
                Text("开板").frame(width: 36, alignment: .trailing)
            }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8)
            if rows.isEmpty { Text("没有匹配样本；数据缺失不等于零。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 56) }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { item in
                            HStack(spacing: 6) {
                                Text("\(item.boards)").font(.callout.weight(.semibold)).foregroundStyle(item.boards > 1 ? Color.orange : Color.secondary).frame(width: 28, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) { Text(item.name).lineLimit(1); Text(item.code).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.industry.isEmpty ? "—" : item.industry).font(.caption).lineLimit(1).frame(width: 72, alignment: .leading)
                                Text(item.firstTime.count == 6 ? String(item.firstTime.prefix(2)) + ":" + String(item.firstTime.dropFirst(2).prefix(2)) : item.firstTime).monospacedDigit().frame(width: 48, alignment: .trailing)
                                Text("\(item.breaks)").monospacedDigit().frame(width: 36, alignment: .trailing)
                            }.font(.caption).padding(.horizontal, 8).frame(height: 34).background(item.boards > 1 ? Color.orange.opacity(0.07) : Color.clear)
                            Divider().opacity(0.45)
                        }
                    }
                }.frame(height: min(480, CGFloat(rows.count) * 35 + 2))
            }
        }
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

struct StockMarketSidebar: View {
    let snapshot: StockMarketSnapshot
    var previous: StockMarketSnapshot? = nil
    private let metrics = ["上涨家数", "下跌家数", "跌停家数", "炸板家数", "最高连板", "涨停晋级率", "炸板率", "昨日涨停平均涨幅"]
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(snapshot.indices.filter { $0.code != "sz399006" && !$0.name.contains("创业板") }) { quote in
                VStack(alignment: .leading, spacing: 1) {
                    Text(quote.name).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", locale: StockDecimal.locale, quote.price)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Text(stockPercent(quote.change)).font(.system(size: 10)).monospacedDigit().foregroundStyle(quote.change >= 0 ? Color.red : Color.green)
                }.lineLimit(1).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 44).padding(.horizontal, 7)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
            if let amount = snapshot.metrics["沪深成交额"] {
                card("沪深成交额", value: String(format: "%.0f 亿", locale: StockDecimal.locale, amount / 100_000_000), height: snapshot.indices.isEmpty ? 34 : 44)
            }
            if let previous, previous.date == snapshot.previousTradingDay,
               let current = snapshot.metrics["沪深成交额"], current > 0,
               let before = previous.metrics["沪深成交额"], before > 0 {
                let delta = current - before
                card(delta > 0 ? "放量（成交额）" : delta < 0 ? "缩量（成交额）" : "成交额持平", value: String(format: "%+.0f 亿", locale: StockDecimal.locale, delta / 100_000_000))
                    .help(String(format: "较 %@：%+.2f%%（沪深成交额）", locale: StockDecimal.locale, previous.date, delta / before * 100))
            } else {
                card("放量 / 缩量", value: "暂无对比").help("需要当天与前一交易日的沪深成交额；旧快照请更新当日行情以确认比较日期。")
            }
            ForEach(metrics, id: \.self) { name in
                card(name, value: snapshot.metrics[name].map { name.contains("率") || name.contains("涨幅") ? String(format: "%.1f%%", locale: StockDecimal.locale, $0) : String(format: "%.0f", locale: StockDecimal.locale, $0) } ?? "—")
            }
            sectorCard("领涨板块", sectors: snapshot.sectors.filter { $0.kind == "行业" && $0.change > 0 }.sorted { $0.rank < $1.rank }, rising: true)
            sectorCard("领跌板块", sectors: (snapshot.industryDecliners ?? []).filter { $0.change < 0 }.sorted { $0.rank < $1.rank }, rising: false)
        }
    }
    private func sectorCard(_ title: String, sectors: [StockSector], rising: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title + " · 前五").font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { index in
                VStack(alignment: .leading, spacing: 1) {
                    if sectors.indices.contains(index) {
                        let sector = sectors[index]
                        Text("\(index + 1). \(sector.name)").font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(stockPercent(sector.change)).font(.system(size: 10)).monospacedDigit().foregroundStyle(rising ? Color.red : Color.green)
                    } else {
                        Text("\(index + 1). —").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("暂无数据").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 29)
            }
        }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
    private func card(_ title: String, value: String, height: CGFloat = 34) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }.lineLimit(1).minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: height).padding(.horizontal, 7)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}
