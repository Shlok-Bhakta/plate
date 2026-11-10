// The small pill on the Quick Log bar while an AI log runs behind its sheet: "Working…" with a spinner
// (the sheet it opens has the timer), then "Draft ready" (or "Didn't work"). A tap opens the sheet again (AgentCenter.open).
import SwiftUI

struct AgentWorkingPill: View {
    var pill: AgentPill
    /// The minimized Quick Log bar: the icon only.
    var compact = false
    @State private var center = AgentCenter.shared

    var body: some View {
        Button { center.open(pill.runID) } label: {
            HStack(spacing: 6) {
                icon
                if !compact {
                    Text(pill.title)
                    if pill.count > 1 {
                        Text("\(pill.count)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 5).frame(minHeight: 16)
                            .background(Palette.accent.opacity(0.25), in: Capsule())
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(pill.kind == .failed ? Palette.overInk : Palette.accentInk)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 7 : 11)
            .frame(height: 30)
            .background((pill.kind == .failed ? Palette.over : Palette.accent).opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .accessibilityLabel(accessibility)
        .accessibilityHint("Opens the AI log")
    }

    @ViewBuilder private var icon: some View {
        switch pill.kind {
        case .working: ProgressView().controlSize(.mini).tint(Palette.accentInk)
        case .ready: Image(systemName: "sparkles").symbolEffect(.bounce, value: pill.runID)
        case .failed: Image(systemName: "exclamationmark.circle.fill")
        }
    }

    private var accessibility: String {
        switch pill.kind {
        case .working: "AI log working"
        case .ready: "AI draft ready"
        case .failed: "AI log didn't work"
        }
    }
}
