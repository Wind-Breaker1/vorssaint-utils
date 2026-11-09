// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import AppKit
import SwiftUI

final class StockWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    private static let controller = StockWindowController()
    private var window: NSWindow?
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: StockStrings.title(L10n.shared.language), action: #selector(present), keyEquivalent: "")
        item.target = controller; return item
    }
    @objc private func present() { Self.open() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { AppFeature.stocks.isAvailable }
    static func open() {
        guard AppFeature.stocks.isAvailable else { return }
        let owner = controller
        if let window = owner.window { StockService.shared.refresh(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "股票复盘"; window.contentMinSize = NSSize(width: 1000, height: 660)
        window.isReleasedWhenClosed = false; window.delegate = owner
        window.contentViewController = NSHostingController(rootView: StockWorkspace().environment(\.locale, Locale(identifier: "zh_CN")).environment(\.timeZone, StockDay.calendar.timeZone))
        window.setFrameAutosaveName("StockReviewWindow"); window.center(); owner.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    static func close() { controller.window?.orderOut(nil); controller.window?.contentViewController = nil; controller.window = nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if sender.attachedSheet != nil { NSSound.beep(); return false }; return true }
}

enum StockPage: String, CaseIterable, Identifiable {
    case overview = "持仓总览", trades = "成交记录", reviews = "每日复盘"
    case rules = "规则与标签"
    var id: String { rawValue }
    var icon: String { switch self { case .rules: return "list.bullet.clipboard"; case .overview: return "chart.pie"; case .trades: return "arrow.left.arrow.right"; case .reviews: return "book.closed" } }
}
struct StockWorkspace: View {
    @ObservedObject private var service = StockService.shared
    @State private var page: StockPage = .overview
    @State private var editing: StockTrade?
    @State private var original: StockTrade?
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label("股票复盘", systemImage: "chart.line.uptrend.xyaxis").font(.title3.bold()).padding(.top, 24)
                Text("记录决策，回看执行").font(.caption).foregroundStyle(.secondary)
                ForEach(StockPage.allCases) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.icon).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(page == item ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.horizontal, 16).frame(width: 182).background(.quaternary.opacity(0.4))
            Divider()
            VStack(spacing: 0) {
                if let message = service.message {
                    HStack { Image(systemName: "info.circle"); Text(message).font(.callout).textSelection(.enabled); Spacer(); Button { service.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .padding(12).background(Color.orange.opacity(0.12)).padding(.horizontal, 22).padding(.bottom, 8)
                }
                Group {
                    switch page {
                    case .rules: StockRulesView(service: service)
                    case .overview: StockOverview(service: service, record: { original = nil; editing = $0 })
                    case .trades: StockTradeList(service: service, edit: { original = $0; editing = $0 }, copy: { original = nil; editing = $0 }, record: { original = nil; editing = StockTrade(instrument: StockInstrument(symbol: "", name: "")) })
                    case .reviews: StockReviewsView(service: service)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) {
                    if service.collecting { ProgressView().controlSize(.mini) }
                    Text(service.collectionStatus.isEmpty ? "收盘后自动保存市场快照" : service.collectionStatus).lineLimit(1)
                    Spacer()
                    if service.busy { ProgressView().controlSize(.mini) }
                    Button { service.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("重新读取数据目录").disabled(service.busy)
                    Text(service.storagePath).lineLimit(1).truncationMode(.middle).help(service.storagePath)
                }.font(.caption2).foregroundStyle(.secondary).padding(10)
            }.frame(minWidth: 760)
        }
        .sheet(item: $editing) { value in StockTradeEditor(service: service, initial: value, original: original) }
        .sheet(isPresented: $service.showImport) { StockImportView(service: service) }
    }
}

struct StockMetricCard: View {
    var title: String
    var value: String
    var detail = ""
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 9) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.monospacedDigit().bold()).foregroundStyle(tint); if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary) } }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
func stockColor(_ value: Decimal) -> Color { value > 0 ? .red : value < 0 ? .green : .secondary }
func stockPercent(_ value: Double) -> String { String(format: "%+.2f%%", locale: StockDecimal.locale, value) }

struct StockStorageView: View {
    @ObservedObject var service: StockService
    var body: some View {
        Form {
            Section("数据目录") {
                Text(service.storagePath).textSelection(.enabled)
                Text("交易、复盘、市场快照按年保存 JSON。选择 iCloud Drive 文件夹即可由系统同步。切换设备前请等待文件下载完成。").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("打开数据目录…") { service.chooseFolder(migrate: false) }
                    Button("迁移到空目录…") { service.chooseFolder(migrate: true) }
                    Button("在 Finder 中显示") { service.revealStorage() }
                }.disabled(service.busy || service.collecting)
            }
            Section("行情采集") {
                Toggle("交易日收盘后自动采集，启动时补采", isOn: $service.autoCollect)
                Text("北京时间 15:30 后采集，应用运行时每 5 分钟检查。首次保存最近收盘日，之后每轮最多补采 5 个遗漏交易日。收盘日由上证指数交易日期核对；取不到时暂停并提示。").font(.caption).foregroundStyle(.secondary)
                Text("免费来源：腾讯行情 / 日 K、东方财富涨跌停池与板块。无需账户、密钥或付费服务。历史排名与部分行情无法补回时保留缺失说明。").font(.caption).foregroundStyle(.secondary)
                Button(service.collecting ? "正在采集…" : "采集最近收盘日") { service.collect(date: nil) }.disabled(service.busy || service.collecting)
            }
            Section("备份与交换") {
                Text("每次数据变更前保存完整 JSON 备份，保留最近 30 份。备份位于数据目录 backups 下；年度 JSON 内保留成交删除标记。").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("恢复备份…") { service.restoreBackup() }
                    Button("导出全部成交 CSV…") { service.exportCSV() }
                    Button("导出导入模板…") { service.exportCSV(template: true) }
                }.disabled(service.busy || service.collecting)
            }
            Section("统计口径") {
                Text("执行质量按操作统计，交易轮次从建仓到清仓。规则符合率仅使用“符合 /（符合 + 违反）”，无法判断、未评价、不适用分别显示。实际买卖与复盘中的无成交决策分开统计；关联失效的评价需重新核对后才计入。盈亏不决定操作对错。")
                Text("人民币；移动加权平均成本；买入费用计入成本，卖出费用扣减已实现盈亏。现金分红计入已实现收益且不降低成本；送转拆合通过份额调整记录，总成本不变。未录入费用按 0，需按交割单补齐。")
                Text("持仓浮盈亏使用显示日期的未复权价格，缺失行情不计估值。这里只记录实际成交，不下单；股票与 ETF 不统一套用 T+1 限制。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
struct StockSettings: View {
    @ObservedObject private var service = StockService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("股票复盘").font(.title2.bold()); Spacer(); Button("打开股票复盘") { StockWindowController.open() }.buttonStyle(.borderedProminent) }.padding()
            StockStorageView(service: service)
            if let message = service.message { Text(message).foregroundStyle(.orange).padding() }
        }
    }
}
