// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI

struct StockReviewsView: View {
    @ObservedObject var service: StockService
    @State private var selected = Date()
    @State private var tab = "行情"
    @State private var dirty = false
    private var day: String { StockDay.string(selected) }
    private var snapshot: StockMarketSnapshot? { service.data.snapshots.first { $0.date == day } }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                StockReviewCalendar(selection: $selected, savedDays: Set(service.data.reviews.filter(\.hasUserContent).map(\.date))).disabled(dirty)
                Divider()
                StockDisciplineEditor(service: service)
            }.padding(12).frame(width: 230).frame(maxHeight: .infinity, alignment: .top)
                .background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Picker("视图", selection: $tab) {
                        Text("行情").tag("行情")
                        Text("复盘").tag("复盘")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 160).fixedSize().offset(x: -8)
                    Spacer()
                    if tab == "行情" {
                        Text(service.lastRequestAt.map { "最后请求 " + $0.formatted(.dateTime.hour().minute().second()) } ?? "尚未请求")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { service.collect(date: day) } label: {
                            if service.collecting { ProgressView().controlSize(.mini) } else { Label("获取行情", systemImage: "arrow.clockwise") }
                        }.buttonStyle(.borderless).disabled(service.collecting || service.busy)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 0).padding(.trailing, 8).padding(.vertical, 6)
                Divider()
                if tab == "行情" {
                    marketContent
                } else {
                    StockInlineReview(service: service, date: day, dirty: $dirty).id(day).padding(14)
                    Spacer(minLength: 0)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }.onAppear {
            if let last = (service.data.reviews.filter(\.hasUserContent).map(\.date) + service.data.snapshots.map(\.date)).max(), let date = StockDay.date(last) { selected = date }
        }
    }

    @ViewBuilder private var marketContent: some View {
        if let snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let previous = service.data.snapshots.first { $0.date == snapshot.previousTradingDay }
                    StockMarketSummary(snapshot: snapshot, previous: previous)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("板块轮动").font(.headline)
                        StockRotationView(snapshots: service.data.snapshots, day: day)
                    }
                    Divider()
                    StockLimitLadder(limits: snapshot.limits)
                }.padding(16)
            }
        } else {
            ContentUnavailableView("该日还没有市场快照", systemImage: "chart.bar.xaxis", description: Text("选择交易日后获取或补全行情数据。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

private struct StockReviewCalendar: View {
    @Binding var selection: Date
    let savedDays: Set<String>
    @State private var month = Date()
    private let calendar = StockDay.calendar
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private var start: Date { calendar.dateInterval(of: .month, for: month)!.start }
    private var offset: Int { calendar.component(.weekday, from: start) - 1 }
    private var count: Int { calendar.range(of: .day, in: .month, for: start)!.count }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("\(calendar.component(.year, from: month), format: .number.grouping(.never))年\(calendar.component(.month, from: month))月").font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                monthButton("chevron.left", label: "上个月", delta: -1)
                monthButton("chevron.right", label: "下个月", delta: 1)
            }
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(["日", "一", "二", "三", "四", "五", "六"].enumerated()), id: \.offset) { _, day in
                    Text(day).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 20)
                }
                ForEach(0..<(offset + count), id: \.self) { index in
                    if index < offset { Color.clear.frame(height: 28) }
                    else {
                        let date = calendar.date(byAdding: .day, value: index - offset, to: start)!
                        let selected = calendar.isDate(date, inSameDayAs: selection)
                        Button { selection = date } label: {
                            Text("\(index - offset + 1)").font(.caption.monospacedDigit())
                                .foregroundStyle(selected ? Color.white : calendar.isDateInToday(date) ? Color.accentColor : Color.primary)
                                .frame(maxWidth: .infinity).frame(height: 28)
                                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                .overlay {
                                    if calendar.isDateInToday(date) && !selected {
                                        RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
                                    }
                                }
                                .overlay(alignment: .bottom) {
                                    if savedDays.contains(StockDay.string(date)) { Circle().fill(selected ? Color.white : Color.accentColor).frame(width: 3, height: 3).padding(.bottom, 2) }
                                }
                        }.buttonStyle(.plain).accessibilityLabel(StockDay.string(date))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
        .onAppear { month = selection }
        .onChange(of: selection) { _, value in month = value }
    }
    private func monthButton(_ icon: String, label: String, delta: Int) -> some View {
        Button { if let next = calendar.date(byAdding: .month, value: delta, to: start) { month = next } } label: {
            Image(systemName: icon).font(.caption.weight(.semibold)).frame(width: 22, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct StockInlineReview: View {
    @ObservedObject var service: StockService
    let date: String
    @Binding var dirty: Bool
    @State private var draft: StockReview?
    @State private var original: StockReview?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft != nil {
                HStack(alignment: .top, spacing: 10) {
                    field("市场观察", \.summary, prompt: "市场环境、板块变化、关键观察")
                    field("经验与改进", \.lesson, prompt: "值得重复的操作、需要改变的行为")
                }
                optionalField("明日计划", \.tomorrowPlan, prompt: "明日关注标的、触发条件、仓位安排与风险边界")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.onAppear { load() }
        .onChange(of: service.data.revision) { _, _ in if !dirty { load() } }
        .task(id: draft) {
            guard dirty else { return }
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            save()
        }
        .onChange(of: service.busy) { _, busy in if !busy && dirty && error == nil { save() } }
        .onDisappear { save() }
        .background {
            Button("保存正文") { save() }.keyboardShortcut("s", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }

    }
    private func save() {
        guard dirty, !service.busy, let savedDraft = draft else { return }
        service.saveReview(savedDraft, original: original) { ok in
            if ok {
                original = service.data.reviews.first { $0.date == date }
                if draft == savedDraft {
                    service.reviewDrafts[date] = nil
                    draft = original ?? savedDraft
                    dirty = false
                    error = nil
                } else if let draft {
                    service.reviewDrafts[date] = (draft, original)
                }
            } else { error = service.message }
        }
    }
    private func field(_ title: String, _ key: WritableKeyPath<StockReview, String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium))
            ZStack(alignment: .topLeading) {
                if (draft?[keyPath: key] ?? "").isEmpty { Text(prompt).font(.callout).foregroundStyle(.tertiary).padding(8).allowsHitTesting(false) }
                TextEditor(text: Binding(get: { draft?[keyPath: key] ?? "" }, set: {
                    draft?[keyPath: key] = $0; dirty = true; error = nil
                    if let draft { service.reviewDrafts[date] = (draft, original) }
                }))
                    .font(.body).scrollContentBackground(.hidden).padding(4).disabled(service.busy)
            }.frame(height: 132)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08)))
    }
    private func optionalField(_ title: String, _ key: WritableKeyPath<StockReview, String?>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium))
            ZStack(alignment: .topLeading) {
                if (draft?[keyPath: key] ?? "").isEmpty { Text(prompt).font(.callout).foregroundStyle(.tertiary).padding(8).allowsHitTesting(false) }
                TextEditor(text: Binding(get: { draft?[keyPath: key] ?? "" }, set: {
                    draft?[keyPath: key] = $0; dirty = true; error = nil
                    if let draft { service.reviewDrafts[date] = (draft, original) }
                }))
                    .font(.body).scrollContentBackground(.hidden).padding(4).disabled(service.busy)
            }.frame(height: 132)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08)))
    }
    private func load() {
        if let saved = service.reviewDrafts[date] {
            draft = saved.draft; original = saved.original; dirty = true; error = nil; return
        }
        original = service.data.reviews.first { $0.date == date }
        draft = original ?? StockReview(date: date)
        dirty = false; error = nil
    }
}
