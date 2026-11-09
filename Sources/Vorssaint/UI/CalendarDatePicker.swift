// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Shared native calendar presentation for personal tools.
struct CalendarDatePicker: View {
    @Binding var selection: Date

    var body: some View {
        TransparentCalendar(selection: $selection)
            .fixedSize()
            .padding(12)
    }
}

private struct TransparentCalendar: NSViewRepresentable {
    @Binding var selection: Date

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.drawsBackground = false
        picker.backgroundColor = .clear
        picker.isBordered = false
        picker.isBezeled = false
        picker.focusRingType = .none
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.dateValue = selection
        picker.sizeToFit()
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.selection = $selection
        picker.locale = context.environment.locale
        picker.timeZone = context.environment.timeZone
        if picker.dateValue != selection { picker.dateValue = selection }
    }

    final class Coordinator: NSObject {
        var selection: Binding<Date>
        init(selection: Binding<Date>) { self.selection = selection }
        @objc func changed(_ sender: NSDatePicker) { selection.wrappedValue = sender.dateValue }
    }
}
