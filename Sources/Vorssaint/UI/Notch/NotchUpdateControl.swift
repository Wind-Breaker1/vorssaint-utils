// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The same upstream release offer as the menu panel, kept inside the island's
/// existing header so it cannot displace or resize the active tool.
struct NotchUpdateControl: View {
    @ObservedObject private var updates = UpdateService.shared
    let action: () -> Void
    var compact = false
    @ObservedObject private var l10n = L10n.shared

    @ViewBuilder var body: some View {
        switch updates.state {
        case let .available(version):
            let tint: Color = UpdateServiceSupport.SemanticVersion(raw: version)?.isPrerelease == true ? .orange : .blue
            let title = "\(l10n.s.updateBannerTitle), \(l10n.s.versionPrefix) \(version)"
            Button(action: action) {
                Group {
                    if compact {
                        Image(systemName: "arrow.down.circle.fill")
                    } else {
                        Label(l10n.s.tabReleaseNotes, systemImage: "arrow.down.circle.fill")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(tint)
            .fixedSize()
            .help(title)
            .accessibilityLabel(title)
            .accessibilityHint(l10n.s.tabReleaseNotes)
        default:
            EmptyView()
        }
    }

}
