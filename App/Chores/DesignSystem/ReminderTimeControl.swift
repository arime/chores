import SwiftUI
import ChoresCore

/// A reminder time as a row: a label, a switch, and — while on — a picker for
/// the hour and minute. `nil` is off. The parent's own evening reminder uses
/// it once; a child's edit sheet uses it twice.
struct ReminderTimeControl: View {
    let label: Text
    @Binding var time: TimeOfDay?
    /// What "on" starts at when the switch is flipped from off.
    let defaultTime: TimeOfDay
    let identifier: String

    /// Any fixed day will do: only the hour and minute survive the round trip.
    private static let anchorDay = CalendarDay(year: 2000, month: 1, day: 1)

    private var isOn: Binding<Bool> {
        Binding(get: { time != nil },
                set: { on in time = on ? (time ?? defaultTime) : nil })
    }

    private var pickerDate: Binding<Date> {
        Binding(get: { (time ?? defaultTime).date(on: Self.anchorDay, in: .current) },
                set: { time = TimeOfDay($0, in: .current) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: isOn) {
                label
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("\(identifier).toggle")

            if time != nil {
                DatePicker("", selection: pickerDate, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Theme.accent)
                    .accessibilityIdentifier("\(identifier).picker")
            }
        }
        .ruledRow(minHeight: 52, verticalPadding: 8)
        .animation(.easeInOut(duration: 0.15), value: time != nil)
    }
}
