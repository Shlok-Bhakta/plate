// DESIGN 4.6 cards 1 to 3: Calories (bars vs goal), Macros (stacked kcal or average grams vs targets),
// and Protein (bars vs goal, hit-day dots, the streak capsule).
import Charts
import SwiftUI

/// "avg 2,180 / 2,350": the prefix and suffix quiet, the value in label color.
func avgText(_ value: String, _ suffix: String = "", prefix: String = "avg ") -> AttributedString {
    var p = AttributedString(prefix)
    p.foregroundColor = Palette.secondaryLabel
    return p + TwoTone(value, suffix, Palette.secondaryLabel, first: Palette.label)
}

// MARK: - Calories

struct CaloriesCard: View {
    var data: TrendData
    var body: some View {
        let avg = TrendMath.mean(data.logged.map(\.kcal))
        TrendCard(title: "Calories", subtitle: data.loggedLine, link: .detail(.calories)) {
            HeaderValue(attributed: avgText(Fmt.kcal(avg), data.goals?.kcal.map { " / \(Fmt.whole($0))" } ?? ""))
                .rolling(avg ?? 0)
        } content: {
            CaloriesChart(data: data)
        }
        .accessibilityElement(children: .contain)
    }
}

struct CaloriesChart: View {
    var data: TrendData
    var height: CGFloat = 180
    @State private var selected: String?

    var body: some View {
        let goal = data.goals?.kcal
        let logged = data.logged
        let top = max(goal ?? 0, logged.map(\.kcal).max() ?? 0, 1000) * 1.1
        Chart {
            ForEach(logged, id: \.day) { s in
                BarMark(x: .value("Day", ChartDay.start(s.day), unit: .day), y: .value("kcal", s.kcal), width: .ratio(0.7))
                    .foregroundStyle(Palette.accent.opacity(barOpacity(s.day, today: data.today, selected: selected)))
                    .cornerRadius(barRadius(data.range))
            }
            goalRule(goal)
            selectionRule(selected) { day in
                let s = data.summary(day)
                ChartCallout(day: day) {
                    if let s, !s.isEmpty {
                        CalloutValue(value: Fmt.whole(s.kcal), unit: "kcal")
                        if let goal {
                            let d = s.kcal - goal
                            Text(d >= 0 ? "\(Fmt.whole(d)) over" : "\(Fmt.whole(-d)) left")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else {
                        Text("Nothing logged").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .trendAxes(data, y: 0...top, goal: goal)
        .daySelection($selected, in: data)
        .frame(height: height)
        .chartEmpty(logged.count < 3)
        .accessibilityLabel("Calories chart")
        .accessibilityValue(logged.isEmpty ? "No days logged" :
            "Average \(Fmt.whole(logged.map(\.kcal).reduce(0, +) / Double(logged.count))) kilocalories over \(logged.count) days")
    }
}

// MARK: - Macros

enum MacroMode: Hashable { case kcal, grams }

struct MacrosCard: View {
    var data: TrendData
    @AppStorage("trendsMacroGrams") private var grams = false

    private static let macros: [(key: String, name: String, perGram: Double)] = [
        ("protein", "Protein", 4), ("carbs", "Carbs", 4), ("fat", "Fat", 9),
    ]

    var body: some View {
        let split = TrendMath.macroSplit(data.summaries)
        let shares = [split.protein, split.carbs, split.fat]
        TrendCard(title: "Macros", subtitle: grams ? "Average grams on logged days" : "Share of calories from each macro",
                  link: .detail(.macros)) {
            CardToggle(options: [(MacroMode.kcal, "kcal"), (MacroMode.grams, "g")],
                       selection: Binding(get: { grams ? .grams : .kcal }, set: { grams = $0 == .grams }))
        } content: {
            if grams {
                gramsRows
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        ForEach(Array(Self.macros.enumerated()), id: \.offset) { i, m in
                            HStack(spacing: 5) {
                                Circle().fill(Palette.fill(m.key)).frame(width: 8, height: 8)
                                Text(m.name).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink(m.key))
                                Text(data.logged.isEmpty ? Fmt.missing : "\(Int(saturating: (shares[i] * 100).rounded()))%")
                                    .numberFont(15, .medium, relativeTo: .subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .lineLimit(1).minimumScaleFactor(0.8)
                    MacroStackChart(data: data)
                }
                .transition(.opacity)
            }
        }
    }

    private var gramsRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.macros + [("fiber", "Fiber", 0)], id: \.key) { m in
                let avg = TrendMath.mean(data.logged.map { $0.totals[m.key] })
                let target = data.goals?.target(m.key)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(m.name).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink(m.key))
                        Spacer()
                        Text(TwoTone(avg.map(Fmt.grams) ?? Fmt.missing, target.map { " / \(Fmt.grams($0)) g" } ?? " g"))
                            .numberFont(15, .medium, relativeTo: .subheadline)
                    }
                    CapsuleBar(fraction: NutritionMath.fraction(avg, of: target) ?? 0, height: 8, fill: Palette.fill(m.key))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(m.name), average \(avg.map(Fmt.grams) ?? "unknown") of \(target.map(Fmt.grams) ?? "no") grams")
            }
        }
        .padding(.vertical, 4)
    }
}

struct MacroStackChart: View {
    var data: TrendData
    var height: CGFloat = 180
    @State private var selected: String?

    private struct Slice: Identifiable {
        var day: String, macro: String, kcal: Double
        var id: String { day + macro }
    }

    var body: some View {
        let slices = data.logged.flatMap { s -> [Slice] in
            [Slice(day: s.day, macro: "Protein", kcal: (s.totals["protein"] ?? 0) * 4),
             Slice(day: s.day, macro: "Carbs", kcal: (s.totals["carbs"] ?? 0) * 4),
             Slice(day: s.day, macro: "Fat", kcal: (s.totals["fat"] ?? 0) * 9)]
        }
        let top = max(data.logged.map { s in ((s.totals["protein"] ?? 0) + (s.totals["carbs"] ?? 0)) * 4 + (s.totals["fat"] ?? 0) * 9 }.max() ?? 0,
                      data.goals?.kcal ?? 0, 1000) * 1.1
        Chart {
            ForEach(slices) { sl in
                BarMark(x: .value("Day", ChartDay.start(sl.day), unit: .day), y: .value("kcal", sl.kcal), width: .ratio(0.7))
                    .foregroundStyle(by: .value("Macro", sl.macro))
                    .opacity(barOpacity(sl.day, today: data.today, selected: selected) == 1 ? 1 : (selected == nil ? 0.7 : 0.3))
                    .cornerRadius(barRadius(data.range) / 2)
            }
            selectionRule(selected) { day in
                ChartCallout(day: day) {
                    if let s = data.summary(day), !s.isEmpty {
                        ForEach(["protein", "carbs", "fat"], id: \.self) { k in
                            HStack(spacing: 6) {
                                Circle().fill(Palette.fill(k)).frame(width: 7, height: 7)
                                Text(Fmt.amountWithUnit(s.totals[k], key: k)).numberFont(14, .semibold, relativeTo: .subheadline)
                            }
                        }
                    } else {
                        Text("Nothing logged").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartForegroundStyleScale(["Protein": Palette.protein, "Carbs": Palette.carbs, "Fat": Palette.fat])
        .chartLegend(.hidden)
        .trendAxes(data, y: 0...top)
        .daySelection($selected, in: data)
        .frame(height: height)
        .chartEmpty(data.logged.count < 3)
        .accessibilityLabel("Macro calories per day")
    }
}

// MARK: - Protein

struct ProteinCard: View {
    var data: TrendData
    var body: some View {
        let avg = TrendMath.mean(data.logged.map { $0.totals["protein"] })
        let target = data.goals?.target("protein")
        let hits = target.map { t in data.logged.filter { ($0.totals["protein"] ?? 0) >= t }.count }
        TrendCard(title: "Protein",
                  subtitle: hits.map { "Goal met on \($0) of \(data.logged.count) logged days" } ?? data.loggedLine,
                  link: .detail(.protein)) {
            HStack(spacing: 8) {
                if data.proteinStreak >= 2 { StreakCapsule(days: data.proteinStreak) }
                HeaderValue(attributed: avgText(avg.map(Fmt.grams) ?? Fmt.missing, avg == nil ? "" : " g"))
            }
        } content: {
            ProteinChart(data: data)
        }
    }
}

/// `flame.fill` 13 pt plus "6-day streak" in protein ink. Hidden under 2 days.
struct StreakCapsule: View {
    var days: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill").font(.system(size: 13, weight: .semibold))
            Text("\(days)-day streak").font(.footnote.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(Palette.proteinInk)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Palette.protein.opacity(0.14), in: Capsule())
        .fixedSize()
        .accessibilityLabel("Protein goal met \(days) days in a row")
    }
}

struct ProteinChart: View {
    var data: TrendData
    var height: CGFloat = 180
    @State private var selected: String?

    var body: some View {
        let target = data.goals?.target("protein")
        let logged = data.logged
        let top = max(target ?? 0, logged.map { $0.totals["protein"] ?? 0 }.max() ?? 0, 50) * 1.15
        Chart {
            ForEach(logged, id: \.day) { s in
                let g = s.totals["protein"] ?? 0
                BarMark(x: .value("Day", ChartDay.start(s.day), unit: .day), y: .value("Protein", g), width: .ratio(0.7))
                    .foregroundStyle(Palette.protein.opacity(barOpacity(s.day, today: data.today, selected: selected)))
                    .cornerRadius(barRadius(data.range))
                if let target, g >= target, data.range != .quarter {
                    PointMark(x: .value("Day", ChartDay.mid(s.day)), y: .value("Hit", g + top * 0.045))
                        .symbolSize(data.range == .week ? 30 : 14)
                        .foregroundStyle(Palette.protein)
                }
            }
            goalRule(target)
            selectionRule(selected) { day in
                ChartCallout(day: day) {
                    if let s = data.summary(day), !s.isEmpty {
                        let g = s.totals["protein"] ?? 0
                        HStack(spacing: 4) {
                            CalloutValue(value: Fmt.grams(g), unit: "g")
                            if let target, g >= target {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Palette.proteinInk)
                            }
                        }
                        if let target { Text("\(Int(saturating: (g / target * 100).rounded()))% of goal").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("Nothing logged").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .trendAxes(data, y: 0...top, goal: target)
        .daySelection($selected, in: data)
        .frame(height: height)
        .chartEmpty(logged.count < 3)
        .accessibilityLabel("Protein chart")
    }
}
