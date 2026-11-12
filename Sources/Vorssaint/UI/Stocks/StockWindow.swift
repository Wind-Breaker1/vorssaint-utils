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
        let service = StockService.shared
        if let window = owner.window {
            service.refresh()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            service.reviewWindowOpened()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "股票复盘"; window.contentMinSize = NSSize(width: 1000, height: 660)
        window.isReleasedWhenClosed = false; window.delegate = owner
        window.contentViewController = NSHostingController(rootView: StockWorkspace().environment(\.locale, Locale(identifier: "zh_CN")).environment(\.timeZone, StockDay.calendar.timeZone))
        window.setFrameAutosaveName("StockReviewWindow"); window.center(); owner.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        service.reviewWindowOpened()
    }
    static func close() { controller.window?.orderOut(nil); controller.window?.contentViewController = nil; controller.window = nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if sender.attachedSheet != nil { NSSound.beep(); return false }; return true }
}

enum StockPage: String, CaseIterable, Identifiable {
    case trades = "成交记录", reviews = "每日复盘"
    var id: String { rawValue }
    var icon: String { switch self { case .trades: return "arrow.left.arrow.right"; case .reviews: return "book.closed" } }
}
struct StockWorkspace: View {
    @ObservedObject private var service = StockService.shared
    @State private var page: StockPage = .reviews
    @State private var original: StockTrade?
    @State private var inlineTrade: StockTrade?
    @State private var tradePanelExpanded = true
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label("股票复盘", systemImage: "chart.line.uptrend.xyaxis").font(.title3.bold()).padding(.top, 24)
                Text("记录决策，回看执行").font(.caption).foregroundStyle(.secondary)
                ForEach(StockPage.allCases) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.icon).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(7)
                            .background(page == item ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.horizontal, 7).frame(width: 132).background(.quaternary.opacity(0.4))
            Divider()
            VStack(spacing: 0) {
                if let message = service.message {
                    HStack { Image(systemName: "info.circle"); Text(message).font(.callout).textSelection(.enabled); Spacer(); Button { service.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .padding(12).background(Color.orange.opacity(0.12)).padding(.horizontal, 22).padding(.bottom, 8)
                }
                Group {
                    switch page {
                    case .trades:
                        HStack(spacing: 0) {
                            StockTradeList(service: service, edit: { original = $0; inlineTrade = $0; tradePanelExpanded = true })
                            if let inlineTrade {
                                Divider()
                                VStack(spacing: 0) {
                                    HStack {
                                        if tradePanelExpanded { Text("成交录入").font(.headline); Spacer() }
                                        Button { tradePanelExpanded.toggle() } label: {
                                            Image(systemName: tradePanelExpanded ? "sidebar.right" : "chevron.left")
                                        }.buttonStyle(.borderless).help(tradePanelExpanded ? "收起录入栏（保留草稿）" : "展开录入栏")
                                    }.padding(10)
                                    StockTradeEditor(service: service, initial: inlineTrade, original: original, onClose: { original = nil; self.inlineTrade = StockTrade(instrument: StockInstrument(symbol: "", name: "")) })
                                        .id(inlineTrade.id)
                                        .frame(width: 250)
                                        .frame(height: tradePanelExpanded ? nil : 0)
                                        .clipped().opacity(tradePanelExpanded ? 1 : 0)
                                        .allowsHitTesting(tradePanelExpanded).accessibilityHidden(!tradePanelExpanded)
                                    if !tradePanelExpanded { Spacer() }
                                }.frame(width: tradePanelExpanded ? 250 : 38)
                                    .clipped().background(.regularMaterial)
                            }
                        }.onAppear {
                            if inlineTrade == nil {
                                original = nil
                                inlineTrade = StockTrade(instrument: StockInstrument(symbol: "", name: ""))
                            }
                        }
                    case .reviews: StockReviewsView(service: service)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) {
                    if service.collecting { ProgressView().controlSize(.mini) }
                    Text(service.collectionStatus.isEmpty ? "交易时段打开时自动获取行情" : service.collectionStatus).lineLimit(1)
                    Spacer()
                    if service.busy { ProgressView().controlSize(.mini) }
                    Button { service.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("重新读取数据目录").disabled(service.busy)
                    Text(service.storagePath).lineLimit(1).truncationMode(.middle).help(service.storagePath)
                }.font(.caption2).foregroundStyle(.secondary).padding(10)
            }.frame(minWidth: 760)
        }
        .sheet(isPresented: $service.showImport) { StockImportView(service: service) }
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
                Text("成交、每日复盘与市场快照按年保存 JSON；交易纪律单独保存在规则文件中。选择 iCloud Drive 文件夹即可由系统同步。切换设备前请等待文件下载完成。") .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("打开数据目录…") { service.chooseFolder(migrate: false) }
                    Button("迁移到空目录…") { service.chooseFolder(migrate: true) }
                    Button("在 Finder 中显示") { service.revealStorage() }
                }.disabled(service.busy || service.collecting)
            }
            Section("行情采集") {
                Toggle("交易时段打开股票复盘时自动获取行情", isOn: $service.autoCollect)
                Text("仅在北京时间交易时段打开股票复盘且实时指数确认当日开市时自动请求；不使用固定节假日表。手动按钮只采集最近一个交易日，不补采遗漏日期。").font(.caption).foregroundStyle(.secondary)
                Text("免费来源：腾讯实时指数行情、东方财富涨跌停池与板块，无需账户或密钥。").font(.caption).foregroundStyle(.secondary)
                Button(service.collecting ? "正在采集…" : "采集最近交易日") { service.collect(date: nil) }.disabled(service.busy || service.collecting)
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
