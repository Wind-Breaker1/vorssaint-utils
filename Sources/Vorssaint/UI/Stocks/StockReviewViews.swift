// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI

struct StockReviewsView: View {
    @ObservedObject var service: StockService
    @State private var selected = Date()
    @State private var dirty = false
    @State private var editing: StockReview?
    @State private var original: StockReview?
    @State private var evaluating: StockAssessment?
    @State private var evaluationOriginal: StockAssessment?
    private var day: String { StockDay.string(selected) }
    private var review: StockReview? { service.data.reviews.first { $0.date == day } }
    private var snapshot: StockMarketSnapshot? { service.data.snapshots.first { $0.date == day } }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                StockReviewCalendar(selection: $selected, savedDays: Set(service.data.reviews.map(\.date))).disabled(dirty)
                Divider()
                HStack {
                    Text("行情快照").font(.headline)
                    Spacer()
                    Button { service.collect(date: day) } label: {
                        if service.collecting { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                    }.buttonStyle(.plain).help("获取或更新当日行情").disabled(service.collecting || service.busy || dirty)
                }
                ScrollView {
                if let snapshot { StockMarketSidebar(snapshot: snapshot, previous: service.data.snapshots.first { $0.date == snapshot.previousTradingDay }) }
                else { Text("当天行情尚未保存，点击刷新获取。").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxHeight: .infinity)
            }.padding(12).frame(width: 230).frame(maxHeight: .infinity, alignment: .top)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("每日复盘").font(.headline)
                            Text(selected, format: .dateTime.year().month().day().weekday(.wide))
                                .font(.callout.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Label(dirty ? "编辑中" : review == nil ? "未记录" : "已保存",
                              systemImage: dirty ? "pencil.circle" : review == nil ? "circle.dashed" : "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(dirty ? Color.orange : Color.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.quaternary.opacity(0.45), in: Capsule())
                        Spacer(minLength: 4)
                        Button { moveDay(-1) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.borderless).help("前一天").disabled(dirty)
                        Button("今天") { selected = StockDay.calendar.startOfDay(for: Date()) }
                            .buttonStyle(.borderless).disabled(dirty)
                        Button { moveDay(1) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.borderless).help("后一天")
                            .disabled(dirty || StockDay.calendar.isDateInToday(selected))
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        Button {
                            original = review
                            editing = review ?? StockReview(date: day)
                        } label: {
                            Label("计划与成交", systemImage: "list.bullet.clipboard")
                        }.buttonStyle(.bordered).disabled(dirty || service.busy)
                        Button {
                            evaluationOriginal = nil
                            evaluating = StockAssessment(date: day, kind: "等待")
                        } label: {
                            Label("无成交决策", systemImage: "text.badge.plus")
                        }.buttonStyle(.borderedProminent).disabled(dirty || service.busy)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                StockInlineReview(service: service, date: day, dirty: $dirty)
                    .id(day).padding(14)
                Divider()
                HStack {
                    Text("连板天梯").font(.headline)
                    Spacer()
                    if let snapshot {
                        Text("连板 \(snapshot.limits.filter { $0.boards > 1 }.count) 只 · 首板 \(snapshot.limits.filter { $0.boards == 1 }.count) 只")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 12)
                ScrollView {
                    if let snapshot { StockLimitLadder(limits: snapshot.limits, showsHeader: false).frame(maxWidth: .infinity, alignment: .topLeading) }
                    else { Text("当天连板数据尚未保存").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.onAppear { if let last = service.data.reviews.map(\.date).max(), let date = StockDay.date(last) { selected = date } }
        .sheet(item: $editing) { draft in StockReviewEditor(service: service, initial: draft, original: original) }
        .sheet(item: $evaluating) { a in StockAssessmentEditor(service: service, initial: a, original: evaluationOriginal) }

    }
    private func moveDay(_ offset: Int) {
        if let next = StockDay.calendar.date(byAdding: .day, value: offset, to: selected) { selected = next }
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

struct StockPlanSummary: View {
    let plan: StockPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(plan.symbol.isEmpty ? "市场计划" : plan.symbol).fontWeight(.semibold); Spacer(); Text(plan.status).font(.caption).foregroundStyle(.secondary) }
            Text(plan.condition)
            if !plan.position.isEmpty || !plan.stopLoss.isEmpty { Text("仓位：\(plan.position)    止损 / 失效：\(plan.stopLoss)").font(.caption).foregroundStyle(.secondary) }
            if !plan.outcome.isEmpty { Text("验证结果：\(plan.outcome)").font(.callout) }
            DisclosureGroup("计划历史版本（\(plan.versions?.count ?? 1)）") {
                ForEach(plan.versions ?? [plan.snapshot]) { version in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("v\(version.version) · \(version.recordedAt)").font(.caption2)
                        Text(version.condition).font(.caption)
                        Text("仓位：\(version.position)；失效：\(version.stopLoss)").font(.caption)
                        Text(version.reason).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
struct StockReviewEditor: View {
    @ObservedObject var service: StockService
    let original: StockReview?
    private let initial: StockReview
    @State private var draft: StockReview
    @State private var error: String?
    @State private var cancel = false
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    init(service: StockService, initial: StockReview, original: StockReview?) {
        self.service = service; self.original = original
        var editing = initial
        for i in editing.plans.indices { editing.plans[i].changeReason = "" }
        self.initial = editing; _draft = State(initialValue: editing)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("\(draft.date) · 每日复盘").font(.title2.bold()); Spacer() }.padding(22)
            TabView {
                Form {
                    Section("市场观察") { TextEditor(text: $draft.summary).frame(minHeight: 120) }
                    Section("我的执行") { TextEditor(text: $draft.execution).frame(minHeight: 100) }
                    Section("经验与改进") { TextEditor(text: $draft.lesson).frame(minHeight: 100) }
                    Section("我的情绪判断") { TextField("例如：分歧加大，等待确认", text: $draft.emotion) }
                }.formStyle(.grouped).tabItem { Text("复盘正文") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("记录触发条件和风险边界，后续把执行结果补充在独立字段中。").foregroundStyle(.secondary)
                        ForEach($draft.plans) { $plan in
                            VStack(spacing: 12) {
                                HStack { TextField("标的 / 市场", text: $plan.symbol); Picker("状态", selection: $plan.status) { ForEach(["待验证","已执行","未触发","偏离计划","已取消"], id: \.self) { Text($0).tag($0) } } }
                                TextField("原计划：触发条件", text: $plan.condition, axis: .vertical).lineLimit(2...5)
                                HStack { TextField("计划仓位", text: $plan.position); TextField("止损 / 失效条件", text: $plan.stopLoss) }
                                TextField("修改原计划的原因（修改时必填）", text: Binding(get: { plan.changeReason ?? "" }, set: { plan.changeReason = $0 }), axis: .vertical).lineLimit(1...3)
                                TextField("事后验证：实际执行、结果与偏差", text: $plan.outcome, axis: .vertical).lineLimit(2...5)
                                HStack { Text("建立：\(plan.createdAt) · v\(plan.snapshot.version)").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("取消计划") { plan.status = "已取消" } }
                            }.textFieldStyle(.roundedBorder).padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Button("添加计划", systemImage: "plus") { draft.plans.append(StockPlan()) }
                    }.padding(20)
                }.tabItem { Text("交易计划与结果") }
                VStack(alignment: .leading, spacing: 12) {
                    Text("当天成交自动关联。可搜索证券、日期或备注，补充跨日成交关联。").foregroundStyle(.secondary)
                    TextField("搜索其他日期的成交", text: $query).textFieldStyle(.roundedBorder)
                    List(service.data.trades.filter { $0.deletedAt == nil && (draft.tradeIDs.contains($0.id) || $0.date == draft.date || (!query.isEmpty && "\($0.date) \($0.instrument.symbol) \($0.instrument.name) \($0.note)".localizedCaseInsensitiveContains(query))) }.sorted { $0.sortKey > $1.sortKey }) { t in
                        Toggle(isOn: Binding(get: { t.date == draft.date || draft.tradeIDs.contains(t.id) }, set: { yes in draft.tradeIDs.removeAll { $0 == t.id }; if yes { draft.tradeIDs.append(t.id) } })) {
                            Text("\(t.date) \(t.instrument.name) \(t.action.title) \(t.quantity) × \(t.price)")
                        }.disabled(t.date == draft.date)
                    }
                }.padding(20).tabItem { Text("关联成交") }

            }
            if let error { Text(error).foregroundStyle(.orange).padding(.horizontal, 20).textSelection(.enabled) }
            HStack {
                Button("取消") { if draft != initial { cancel = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存复盘") {
                    for i in draft.plans.indices where initial.plans.first(where: { $0.id == draft.plans[i].id }) != draft.plans[i] { draft.plans[i].updatedAt = StockDay.timestamp() }
                    service.saveReview(draft, original: original) { ok in if ok { dismiss() } else { error = service.message } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(20).disabled(service.busy)
        }.frame(width: 820, height: 760).interactiveDismissDisabled()
        .alert("放弃未保存的复盘？", isPresented: $cancel) { Button("继续编辑", role: .cancel) {}; Button("放弃", role: .destructive) { dismiss() } }
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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
                    field("市场观察", \.summary, prompt: "市场环境、板块变化、关键观察")
                    field("我的执行", \.execution, prompt: "计划执行情况、偏差与原因")
                    field("经验与改进", \.lesson, prompt: "值得重复的操作、需要改变的行为")
                    field("情绪判断", \.emotion, prompt: "记录当日情绪与决策状态")
                }
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
        }.frame(height: 112)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
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
