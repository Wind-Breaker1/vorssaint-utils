// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import Charts

struct AccountingLedgerView: View {
    @ObservedObject private var service = AccountingService.shared
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var kind: LedgerKind?
    @State private var category = ""
    @State private var deleting: LedgerEntry?
    @State private var edit: LedgerEntry?
    @State private var statistics = false
    @State private var deleteError: String?
    private var sections: [(Date, [LedgerEntry])] {
        Dictionary(grouping: service.snapshot.entries) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { service.showingLedger = false } label: { Image(systemName: "chevron.left") }.help("返回记账")
                Spacer()
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                Text(month.formatted(.dateTime.year().month())).frame(minWidth: 100)
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
                Button("本月") { month = Calendar.current.dateInterval(of: .month, for: Date())!.start; reload() }
                Picker("展示", selection: $statistics) {
                    Text("明细").tag(false)
                    Text("统计").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
            }.padding(10)
            HStack(spacing: 8) {
                summary("收入", service.snapshot.income, color: .green)
                summary("支出", service.snapshot.expense, color: .primary)
                summary("结余", service.snapshot.income - service.snapshot.expense, color: .secondary)
            }.padding(.horizontal, 10).padding(.bottom, 6)
            HStack(spacing: 12) {
                Picker("类型", selection: $kind) {
                    Text("全部收支").tag(Optional<LedgerKind>.none)
                    ForEach(LedgerKind.allCases) { Text($0.title).tag(Optional($0)) }
                }.fixedSize()
                Picker("分类", selection: $category) {
                    Text("全部分类").tag("")
                    ForEach(service.snapshot.categories.filter { kind == nil || $0.kind == kind }) {
                        Text($0.name + ($0.archived ? "（已停用）" : "")).tag($0.id)
                    }
                }.fixedSize()
                Spacer()
                Text("\(service.snapshot.count) 笔").foregroundStyle(.secondary)
                if service.loading { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 10).padding(.bottom, 6)
            Divider()
            if statistics {
                AccountingStatisticsView(snapshot: service.snapshot)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if service.snapshot.entries.isEmpty && !service.loading {
                            ContentUnavailableView("暂无账目", systemImage: "yensign.circle", description: Text("在灵动岛中记录收支"))
                                .frame(maxWidth: .infinity).padding(.top, 12)
                        }
                        ForEach(sections, id: \.0) { day, entries in
                            Text(day.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                            ForEach(entries) { entry in row(entry) }
                        }
                        if service.snapshot.entries.count < service.snapshot.count {
                            Button("加载更多") { service.loadMore() }.disabled(service.loading).frame(maxWidth: .infinity)
                        }
                    }.padding(10)
                }
            }
            if let error = deleteError ?? service.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(10)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .sheet(item: $edit) { entry in AccountingEntryView(entry: entry) { edit = nil } }
        .alert("删除这笔账目？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let entry = deleting { service.delete(entry) { deleteError = $0 } }
                deleting = nil
            }
        } message: { Text("删除后无法恢复。") }
        .onAppear(perform: reload)
        .onChange(of: kind) { _, _ in category = ""; reload() }
        .onChange(of: category) { _, _ in reload() }
    }
    private func summary(_ title: String, _ cents: Int64, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text((cents < 0 ? "−" : "") + LedgerMoney.display(abs(cents))).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
    private func row(_ entry: LedgerEntry) -> some View {
        Button { edit = entry } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.kind == .expense ? "arrow.up.right" : "arrow.down.left")
                    .foregroundStyle(entry.kind == .income ? .green : .secondary)
                    .frame(width: 32, height: 32).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.categoryName).font(.body.weight(.medium))
                    if !entry.note.isEmpty { Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                Text((entry.kind == .income ? "+" : "−") + LedgerMoney.display(entry.amount))
                    .font(.body.monospacedDigit()).foregroundStyle(entry.kind == .income ? .green : .primary)
            }.padding(12).contentShape(Rectangle())
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .contextMenu {
                Button("编辑") { edit = entry }
                Button("删除", role: .destructive) { deleting = entry }
            }
    }
    private func changeMonth(_ offset: Int) {
        month = Calendar.current.date(byAdding: .month, value: offset, to: month) ?? month
        reload()
    }
    private func reload() { service.select(month: month, kind: kind, category: category) }
}

struct AccountingQuickSection: View {
    @ObservedObject private var service = AccountingService.shared
    var body: some View {
        ZStack {
            if service.showingLedger {
                AccountingLedgerView()
                    .id("ledger")
                    .transition(.move(edge: .trailing))
            } else {
                AccountingEntryView(inline: true) {}
                    .id("entry")
                    .transition(.move(edge: .leading))
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: service.showingLedger)
    }
}

private struct AccountingStatisticsView: View {
    let snapshot: LedgerSnapshot
    private func categoryColor(_ id: String) -> Color {
        // A deterministic ID-derived hue survives renames and category additions.
        let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let hues: [Double] = [0.02, 0.07, 0.60, 0.66, 0.73, 0.80, 0.88, 0.95]
        return Color(hue: hues[Int(hash % UInt64(hues.count))], saturation: 0.65, brightness: 0.9)
    }
    var body: some View {
        GeometryReader { geometry in
            if snapshot.count == 0 {
                ContentUnavailableView("暂无统计数据", systemImage: "chart.bar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    Chart(snapshot.dailyTotals) { total in
                        BarMark(x: .value("日期", total.day), y: .value("金额", Double(total.amount) / 100))
                            .foregroundStyle(by: .value("类型", total.kind.title))
                            .position(by: .value("类型", total.kind.title))
                    }
                    .chartForegroundStyleScale(["支出": Color.orange, "收入": Color.green])
                    .chartLegend(position: .top, alignment: .leading, spacing: 6)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
                    }
                    .chartXAxisLabel("日", position: .bottom, alignment: .trailing)
                    .frame(maxWidth: .infinity)

                    Chart(snapshot.totals) { total in
                        BarMark(x: .value("金额", Double(total.amount) / 100), y: .value("分类", total.name), height: .fixed(22))
                            .foregroundStyle(categoryColor(total.id))
                            .annotation(position: .leading, alignment: .center, spacing: 6) {
                                Text(total.name.map(String.init).joined(separator: "\n"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize()
                            }
                            .annotation(position: .overlay, alignment: .leading) {
                                Text(LedgerMoney.display(total.amount))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.7), radius: 1)
                                    .padding(.leading, 4)
                                    .fixedSize()
                            }
                    }
                    .chartLegend(.hidden)
                    .chartXScale(range: .plotDimension(endPadding: 8))
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .padding(.leading, 6)
                    .padding(.top, 20)
                    .frame(width: max(150, geometry.size.width * 0.36))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}
