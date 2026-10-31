// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI
import AppKit

struct SystemDataSettings: View {
    @ObservedObject private var service = SystemDataService.shared
    @State private var collapsedCategories: Set<SystemDataCategory> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("系统数据").font(.title2.bold())
                Text("查看 macOS 归类为“系统数据”的存储占用。每项都会标记为安全、需确认或仅手动处理。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button(service.phase == .scanning ? "扫描中…" : "扫描") { service.scan() }
                        .disabled(service.phase == .scanning || service.phase == .cleaning)
                    if service.items.contains(where: { $0.safety == .safe }) {
                        Button("选择安全清理项目") { service.selectSafeItems() }
                            .disabled(service.phase == .scanning || service.phase == .cleaning)
                    }
                    if service.selectedCount > 0 {
                        Button(service.phase == .cleaning ? "清理并刷新中…" : "清理所选项目") { service.cleanSelected() }
                            .disabled(service.phase == .scanning || service.phase == .cleaning)
                    }
                    Spacer()
                    if service.selectedSize > 0 { Text(ByteCountFormatter.string(fromByteCount: service.selectedSize, countStyle: .file)).foregroundStyle(.secondary) }
                }
                if let progress = service.progress {
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
                if let notice = service.lastNotice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let error = service.lastError {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if service.items.isEmpty && service.phase == .results {
                    Text("没有发现系统数据项目。").foregroundStyle(.secondary)
                }
                ForEach(SystemDataCategory.allCases, id: \.self) { category in
                    let categoryItems = service.items.filter { $0.category == category }
                    if !categoryItems.isEmpty {
                        DisclosureGroup(isExpanded: Binding(
                            get: { !collapsedCategories.contains(category) },
                            set: { expanded in
                                if expanded { collapsedCategories.remove(category) }
                                else { collapsedCategories.insert(category) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(categoryItems) { item in
                                    itemRow(item)
                                }
                            }
                            .padding(.top, 12)
                        } label: {
                            HStack {
                                Text(category.title).font(.headline)
                                Spacer()
                                Text(categorySize(categoryItems))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                            }
                        }
                        .disclosureGroupStyle(SystemDataCategoryDisclosureStyle())
                        .padding(.top, 8)
                    }
                }
            }.padding(22).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func categorySize(_ items: [SystemDataService.Item]) -> String {
        let knownItems = items.filter { !$0.sizeIsUnknown }
        guard !knownItems.isEmpty else { return "大小未知" }
        let size = knownItems.reduce(Int64(0)) { $0 + $1.size }
        let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return knownItems.count == items.count ? formatted : formatted + " · 部分未知"
    }

    @ViewBuilder
    private func itemRow(_ item: SystemDataService.Item) -> some View {
        HStack(alignment: .top) {
            Toggle("", isOn: Binding(get: { item.selected }, set: { service.setSelected($0, id: item.id) })).labelsHidden()
                .disabled(item.safety == .manual || service.phase == .scanning || service.phase == .cleaning)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name).font(.headline)
                    Text(item.safety.label).font(.caption).foregroundStyle(item.safety.color)
                    Spacer()
                    Text(item.sizeIsUnknown ? "大小未知" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                Text(item.path.path).font(.caption).foregroundStyle(.tertiary)
            }
        }
        Divider()
    }
}

private struct SystemDataCategoryDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已折叠")
            if configuration.isExpanded { configuration.content }
        }
    }
}

private extension SystemDataService.Safety {
    var label: String {
        switch self { case .safe: "安全清理"; case .review: "需确认"; case .manual: "手动处理" }
    }
    var color: Color {
        switch self { case .safe: .green; case .review: .orange; case .manual: .secondary }
    }
}
