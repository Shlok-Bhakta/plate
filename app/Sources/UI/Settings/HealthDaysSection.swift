// Settings → Apple Health in builds without a health server: whether Health access was allowed, the
// daily totals HealthDaysPush last sent to your server, and Allow or Sync now. Demo mode shows a fixture.
import SwiftUI

struct HealthDaysSection: View {
    @Environment(Store.self) private var store
    private var push: HealthDaysPush { .shared }

    private struct ViewState {
        var available: Bool
        var requested: Bool
        var busy: Bool
        var status: String
        var failed: Bool
        var lastPush: Date?
        var lastSentDay: String?
        var daysSent: Int
    }

    private var state: ViewState {
        if store.isDemo {
            return ViewState(available: true, requested: true, busy: false, status: "Up to date", failed: false,
                             lastPush: Days.now().addingTimeInterval(-6 * 60), lastSentDay: Days.today, daysSent: 30)
        }
        return ViewState(available: HealthDaysPush.isAvailable, requested: push.requested, busy: push.busy, status: push.status,
                         failed: push.failed, lastPush: push.lastPush, lastSentDay: push.lastSentDay, daysSent: push.daysSent)
    }

    var body: some View {
        let s = state
        Section {
            HStack(alignment: .top, spacing: 12) {
                StatusDot(color: dotColor(s), pulsing: s.busy)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title(s)).font(.headline)
                        Spacer(minLength: 8)
                        if s.requested { LastSentText(date: s.lastPush) }
                    }
                    Text(detail(s)).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .animation(Motion.smooth, value: s.busy)
            if s.requested {
                LabeledContent("Sent through") {
                    Text(s.lastSentDay.map { Days.title($0) } ?? "Not yet").monospacedDigit()
                }
                LabeledContent("Days stored") {
                    Text(s.daysSent.formatted()).monospacedDigit()
                }
            }
            if s.available {
                Button {
                    Haptics.light()
                    guard !store.isDemo else { return }
                    Task {
                        if s.requested { await push.pushIfDue(force: true) } else { await push.requestAccess() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: s.requested ? "arrow.triangle.2.circlepath" : "heart.text.square")
                            .symbolEffect(.rotate, options: .repeating, isActive: s.busy)
                        Text(s.requested ? (s.busy ? "Sending…" : "Send now") : "Allow Health access")
                    }
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.accentInk)
                }
                .disabled(s.busy)
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Plate reads daily totals of weight, active and resting energy, steps and exercise minutes, plus your height, birth date and sex, and sends them only to your server, so your goals adapt. It sends when you open Plate and now and then in the background. Health can't be read while the phone is locked.")
        }
    }

    private func title(_ s: ViewState) -> String {
        if !s.available { return "Not available" }
        if !s.requested { return "Health access needed" }
        if s.busy { return "Sending" }
        if !s.status.isEmpty { return s.status }
        return s.lastPush == nil ? "Waiting to send" : "Up to date"
    }

    private func detail(_ s: ViewState) -> String {
        if !s.available { return "Apple Health isn't available on this device, or this build doesn't have the HealthKit capability." }
        if !s.requested { return "Allow access once and Plate sends the last 30 days, then each new day." }
        if s.busy { return "Reading Apple Health and sending the latest days to your server." }
        if s.failed { return "Plate will try again the next time you open it." }
        return "Daily totals go to your server, where they set your calorie goal."
    }

    private func dotColor(_ s: ViewState) -> Color {
        if !s.available || !s.requested || s.busy { return Color(uiColor: .systemGray) }
        if s.failed { return Palette.fat }
        return Palette.fiber
    }
}

/// "sent 3 min ago", ticking.
private struct LastSentText: View {
    var date: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(label(context.date)).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
        }
    }
    private func label(_ now: Date) -> String {
        guard let date else { return "not yet sent" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "sent just now"
        case ..<3600: return "sent \(s / 60) min ago"
        default: return "sent \(date.formatted(date: .omitted, time: .shortened))"
        }
    }
}
