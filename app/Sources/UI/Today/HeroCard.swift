// DESIGN 4.1 hero card (ring, center toggle, subline, 2 × 2 macro grid) and the week strip.
import SwiftUI

struct HeroCard: View {
    var summary: DaySummary
    var goals: Goals?
    @Binding var showsEaten: Bool
    /// Changes when protein first crosses its goal today.
    var celebration: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = HeroCard.launchAnimated
    @State private var glow = false
    /// The ring and bars animate from 0 once per launch.
    nonisolated(unsafe) private static var launchAnimated = false

    private var eaten: Double { summary.kcal }
    private var goal: Double? { goals?.kcal }
    private var progress: Double { goal.map { eaten / $0 } ?? 0 }
    private var eatenMode: Bool { showsEaten || goal == nil }

    var body: some View {
        VStack(spacing: 20) {
            ring
            subline
            if let goals {
                MacroGrid(totals: summary.totals, goals: goals, appeared: appeared, celebration: celebration)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !appeared else { return }
            HeroCard.launchAnimated = true
            withAnimation(Motion.adapt(Motion.launch, reduce: reduceMotion).delay(0.15)) { appeared = true }
        }
        .onChange(of: progress >= 1) { was, now in
            guard now, !was, appeared, !reduceMotion else { return }
            Haptics.light()
            withAnimation(.easeOut(duration: 0.4)) { glow = true }
            withAnimation(.easeIn(duration: 0.4).delay(0.4)) { glow = false }
        }
    }

    private var ring: some View {
        ZStack {
            ProgressRing(progress: appeared && goal != nil ? progress : 0, lineWidth: 20, glow: glow)
                .animation(Motion.adapt(Motion.log, reduce: reduceMotion), value: progress)
            center
        }
        .frame(width: 188, height: 188)
        .contentShape(Circle())
        .onTapGesture {
            guard goal != nil else { return }
            withAnimation(.snappy) { showsEaten.toggle() }
            Haptics.selection()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityHint(goal == nil ? "" : "Double-tap to switch between remaining and eaten.")
        .accessibilityAddTraits(.isButton)
    }

    private var center: some View {
        let (value, unit) = centerText
        return VStack(spacing: 0) {
            Text(Fmt.whole(appeared ? value : 0))
                .numberFont(52, .bold, relativeTo: .largeTitle)
                .tracking(-0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .rolling(appeared ? value : 0)
            Text(unit)
                .scaledFont(13, .semibold, relativeTo: .footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var centerText: (Double, String) {
        guard let goal, !eatenMode else { return (eaten, "kcal eaten") }
        if eaten > goal { return (eaten - goal, "kcal over") }
        return (goal - eaten, eaten == 0 ? "kcal to go" : "kcal left")
    }

    @ViewBuilder private var subline: some View {
        if let goal {
            let left = goal - eaten
            let first = eatenMode
                ? (left >= 0 ? "Left \(Fmt.whole(left))" : "Over \(Fmt.whole(-left))")
                : "Eaten \(Fmt.whole(eaten))"
            Text("\(first)   ·   Goal \(Fmt.whole(goal))")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        } else {
            Text("Goals sync from the server").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var accessibility: String {
        guard let goal else { return "\(Fmt.whole(eaten)) calories eaten. Goals sync from the server." }
        let left = goal - eaten
        let state = left >= 0 ? "\(Fmt.whole(left)) left" : "\(Fmt.whole(-left)) over"
        return "Calories, \(Fmt.whole(eaten)) of \(Fmt.whole(goal)) eaten, \(state)"
    }
}

/// The 2 × 2 macro grid: label in ink, 8 pt bar in fill, "96 / 150 g".
struct MacroGrid: View {
    var totals: NutrientMap
    var goals: Goals
    var appeared: Bool
    var celebration: Int

    var body: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
                MacroCell(key: "protein", amount: totals["protein"], target: goals.target("protein"), index: 0,
                          appeared: appeared, celebration: celebration)
                MacroCell(key: "carbs", amount: totals["carbs"], target: goals.target("carbs"), index: 1,
                          appeared: appeared, celebration: 0)
            }
            GridRow {
                MacroCell(key: "fat", amount: totals["fat"], target: goals.target("fat"), index: 2,
                          appeared: appeared, celebration: 0)
                MacroCell(key: "fiber", amount: totals["fiber"], target: goals.target("fiber"), index: 3,
                          appeared: appeared, celebration: 0)
            }
        }
    }
}

struct MacroCell: View {
    var key: String
    var amount: Double?
    var target: Double?
    var index: Int
    var appeared: Bool
    var celebration: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: CGFloat = -1
    @State private var seal = false

    private var fraction: Double { NutritionMath.fraction(amount ?? 0, of: target) ?? 0 }
    private var met: Bool { fraction >= 1 }
    private var name: String { key == "carbs" ? "Carbs" : (Nutrients.info(key)?.name ?? key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .scaledFont(15, .semibold, relativeTo: .subheadline)
                .foregroundStyle(Palette.ink(key))
            CapsuleBar(fraction: appeared ? fraction : 0, height: 8, fill: Palette.fill(key))
                .overlay { sweepHighlight }
                .clipShape(Capsule())
                .animation(Motion.adapt(Motion.launch, reduce: reduceMotion).delay(appeared ? Double(index) * 0.06 : 0),
                           value: appeared)
                .animation(Motion.adapt(Motion.log, reduce: reduceMotion), value: fraction)
            HStack(spacing: 4) {
                Text(TwoTone(Fmt.grams(amount ?? 0), target.map { " / \(Fmt.grams($0)) g" } ?? " g"))
                    .numberFont(15, .medium, relativeTo: .subheadline)
                    .contentTransition(.numericText(value: amount ?? 0))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if met {
                    Image(systemName: key == "protein" && seal ? "checkmark.seal.fill" : "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.ink(key))
                        .symbolEffect(.bounce, value: seal)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(Fmt.grams(amount ?? 0)) of \(target.map(Fmt.grams) ?? "no goal") grams"
                            + (target != nil ? ", \(Int(saturating: (fraction * 100).rounded())) percent" : ""))
        .onChange(of: celebration) { _, _ in celebrate() }
    }

    /// DESIGN 6 "protein moment": a 24 pt white sweep at 30% across the bar over 0.7 s, then the seal.
    private var sweepHighlight: some View {
        GeometryReader { g in
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.3), .white.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 24)
                .offset(x: sweep * (g.size.width + 24) - 24)
                .opacity(sweep > -1 && sweep < 1 ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    private func celebrate() {
        guard key == "protein", celebration > 0 else { return }
        if reduceMotion { seal = true; return }
        sweep = 0
        withAnimation(.easeInOut(duration: 0.7).delay(0.3)) { sweep = 0.999 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            sweep = -1
            withAnimation(.bouncy) { seal = true }
        }
    }
}

// MARK: - Week strip

struct WeekStrip: View {
    @Binding var day: String
    var today: String
    @Environment(Store.self) private var store
    @State private var position: String?

    /// 26 weeks back through the current week.
    private var weeks: [String] {
        let current = Days.weekStart(today)
        return (0...26).reversed().map { Days.add(-7 * $0, to: current) }
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(weeks, id: \.self) { start in
                    HStack(spacing: 0) {
                        ForEach(Days.week(start), id: \.self) { d in
                            DayColumn(day: d, selected: d == day, isToday: d == today, isFuture: d > today,
                                      progress: progress(d)) {
                                guard d <= today, d != day else { return }
                                day = d
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 12)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $position)
        .scrollIndicators(.hidden)
        .onAppear { position = Days.weekStart(day) }
        .onChange(of: day) { _, d in
            let start = Days.weekStart(d)
            if position != start { withAnimation(.smooth) { position = start } }
        }
        .sensoryFeedback(.selection, trigger: position)
    }

    private func progress(_ d: String) -> Double {
        guard let goal = store.goals?.kcal else { return 0 }
        return store.summary(for: d).kcal / goal
    }
}

private struct DayColumn: View {
    var day: String
    var selected: Bool
    var isToday: Bool
    var isFuture: Bool
    var progress: Double
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(Days.weekdayLetter(day)).font(.caption).foregroundStyle(.secondary)
                ZStack {
                    Circle().fill(selected ? Palette.accent : .clear)
                    Text("\(Days.dayNumber(day))")
                        .numberFont(17, .medium, relativeTo: .body)
                        .foregroundStyle(selected ? Color.white : (isToday ? Palette.accentInk : Color.primary))
                }
                .frame(width: 36, height: 36)
                ProgressRing(progress: isFuture ? 0 : progress, lineWidth: 3)
                    .frame(width: 22, height: 22)
            }
            .frame(width: 44)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isFuture ? 0.3 : 1)
        .disabled(isFuture)
        .accessibilityLabel("\(Days.title(day)), \(Int(saturating: (progress * 100).rounded())) percent of calories")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
