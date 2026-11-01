// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Shared native calendar presentation for personal tools.
struct CalendarDatePicker: View {
    @Binding var selection: Date

    var body: some View {
        DatePicker("日期", selection: $selection, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .focusable(false)
            .focusEffectDisabled()
            .padding(12)
    }
}
