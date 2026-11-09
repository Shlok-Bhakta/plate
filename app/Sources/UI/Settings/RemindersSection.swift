// Settings → Reminders: the master switch (it asks iOS once, the first time), a check and a time for each
// meal, and the optional evening summary. Also the one-time intro shown on the first open after this update.
// Scheduling lives in Sources/Reminders; the decision of what to schedule in Core/ReminderPlan.
import SwiftUI

struct RemindersSection: View {
    @Environment(Store.self) private var store
    private var reminders: Reminders { .shared }

    private var on: Bool { reminders.settings.enabled && reminders.isAllowed }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { on }, set: { v in
                Haptics.selection()
                withAnimation(Motion.smooth) { reminders.setEnabled(v) }
            })) {
                HStack(spacing: 12) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(Palette.accent.gradient, in: .rect(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Meal reminders")
                        Text(status).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            .contentTransition(.opacity)
                    }
                }
            }
            .tint(Palette.accent)

            ForEach(ReminderSettings.meals) { meal in
                SlotRow(title: meal.title, detail: nil,
                        slot: Binding(get: { reminders.settings[meal] ?? .init(on: false, minutes: 0) },
                                      set: { s in reminders.update { $0[meal] = s } }))
                    .disabled(!on)
                    .opacity(on ? 1 : 0.5)
            }
            SlotRow(title: "Daily summary", detail: "Calories and protein so far",
                    slot: Binding(get: { reminders.settings.summary }, set: { s in reminders.update { $0.summary = s } }))
                .disabled(!on)
                .opacity(on ? 1 : 0.5)
        } header: {
            Text("Reminders")
        } footer: {
            Text(footer)
        }
        .task { await reminders.refreshAuthorization() }
    }

    private var footer: String {
        if reminders.isDenied { return "Notifications are off for Plate in iOS Settings. Turn the switch on to open them." }
        if !reminders.isAllowed { return "Plate asks iOS once, the first time you turn this on." }
        return "A meal's reminder only comes when nothing is logged for it yet, including what the agent logs from your photos. Press and hold one for Same as yesterday."
    }

    private var status: String {
        if reminders.isDenied { return "Off in iOS Settings" }
        guard on else { return "Off" }
        guard let next = reminders.next() else { return "Nothing due" }
        let what = next.meal?.title ?? "Summary"
        let when = next.day == Days.today ? "today" : "tomorrow"
        let minutes = Days.calendar.component(.hour, from: next.fireAt) * 60 + Days.calendar.component(.minute, from: next.fireAt)
        return "Next: \(what), \(when) \(ReminderPlan.timeLabel(minutes))"
    }
}

/// A check, the meal name and a compact time picker (wall-clock time in the server's zone, like every day key).
private struct SlotRow: View {
    var title: String
    var detail: String?
    @Binding var slot: ReminderSettings.Slot

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.selection()
                withAnimation(Motion.snappy) { slot.on.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: slot.on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(slot.on ? Palette.accent : Color(uiColor: .tertiaryLabel))
                        .frame(width: 29)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).foregroundStyle(.primary)
                        if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(slot.on ? "On, \(ReminderPlan.timeLabel(slot.minutes))" : "Off")
            .accessibilityAddTraits(.isToggle)

            DatePicker(title, selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .environment(\.timeZone, Days.zone)
                .disabled(!slot.on)
                .opacity(slot.on ? 1 : 0.4)
        }
    }

    private var time: Binding<Date> {
        Binding(get: { ReminderPlan.fireDate(day: Days.today, minutes: slot.minutes) },
                set: { date in
                    let c = Days.calendar.dateComponents([.hour, .minute], from: date)
                    slot.minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                })
    }
}

/// The one-time explanation before iOS's notification prompt, on the first open after this update.
struct ReminderIntro: ViewModifier {
    func body(content: Content) -> some View {
        @Bindable var reminders = Reminders.shared
        content.alert("Meal reminders?", isPresented: $reminders.showIntro) {
            Button("Turn on") { Task { await reminders.requestPermission() } }
            Button("Not now", role: .cancel) { reminders.declineIntro() }
        } message: {
            Text("A quiet nudge at breakfast, lunch and dinner, only when nothing's logged yet, counting what the agent logs from your photos. Change the times in Settings.")
        }
    }
}
