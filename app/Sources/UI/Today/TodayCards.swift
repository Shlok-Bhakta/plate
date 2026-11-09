// DESIGN 4.1 water card, nutrients insight line, and health tiles.
import SwiftUI

struct WaterCard: View {
    var day: String
    var ml: Double
    var goalMl: Double
    @Environment(\.units) private var units
    @State private var drops: [UUID] = []

    var body: some View {
        let progress = Fmt.waterProgress(ml, goal: goalMl, units)
        let quick = units.water.quickAdds
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Water").font(.headline)
                Spacer()
                Text(TwoTone(progress.value, progress.rest))
                    .numberFont(17, .semibold, relativeTo: .headline)
                    .contentTransition(.numericText(value: ml))
            }
            HStack(spacing: 10) {
                CapsuleBar(fraction: ml / max(goalMl, 1), height: 10, fill: Palette.water)
                    .animation(Motion.log, value: ml)
                waterButton(quick[0])
                    .overlay(alignment: .top) {
                        ZStack { ForEach(drops, id: \.self) { _ in FloatingDrop() } }.allowsHitTesting(false)
                    }
                waterButton(quick[1])
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(units.water == .ml ? "Water, \(Fmt.liters(ml)) of \(Fmt.liters(goalMl, decimals: 1)) liters"
                            : "Water, \(progress.value) of \(Fmt.volumeValue(goalMl, units)) fluid ounces")
    }

    /// `amount` is in the shown unit (fl oz or ml); the entry gets its exact ml.
    private func waterButton(_ amount: Double) -> some View {
        Menu {
            ForEach(units.water.menu, id: \.self) { v in
                Button("\(Fmt.whole(v)) \(units.water.symbol)") { add(v) }
            }
        } label: {
            Text("+\(Fmt.whole(amount))")
                .numberFont(15, .semibold, relativeTo: .subheadline)
                .padding(.horizontal, 4)
                .frame(minHeight: 22)
        } primaryAction: {
            add(amount)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(Palette.water)
        .accessibilityLabel("Add \(Fmt.whole(amount)) \(units.water.spoken)")
    }

    private func add(_ amount: Double) {
        let id = UUID()
        drops.append(id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            drops.removeAll { $0 == id }
        }
        withAnimation(Motion.log) { Actions.water(units.water.toMl(amount), day: day) }
    }
}

/// A single drop that floats up 16 pt and fades over 0.6 s.
private struct FloatingDrop: View {
    @State private var up = false
    var body: some View {
        Image(systemName: "drop.fill")
            .font(.system(size: 13))
            .foregroundStyle(Palette.water)
            .offset(y: up ? -26 : -6)
            .opacity(up ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.6)) { up = true } }
    }
}

/// One line of insight (DESIGN 4.1): the lowest 2 or 3 target nutrients, plus any exceeded limit.
struct NutrientsInsightCard: View {
    var day: String
    var summary: DaySummary
    var goals: Goals
    @Environment(Router.self) private var router

    var body: some View {
        Button { router.todayPath.append(.nutrients(day: day)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("Nutrients").font(.headline)
                    Spacer()
                    Group {
                        Text("All")
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                let low = summary.lowest(goals: goals, count: 3)
                if low.isEmpty {
                    Text(summary.foodEntryCount < 2 ? "Log a little more to see micronutrients" : "Nothing low so far")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    let prefix = day == Days.today && Days.hour() < 18 ? "Low so far" : "Low today"
                    let list = low.map { "\(shortName($0.info)) \($0.percent)%" }.joined(separator: " · ")
                    Text(TwoTone("\(prefix): ", list, Palette.label, first: Palette.secondaryLabel))
                        .font(.subheadline)
                        .monospacedDigit()
                        .lineLimit(2)
                }
                ForEach(summary.exceededLimits(goals: goals).prefix(2), id: \.info.key) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.over)
                        Text("\(item.info.name) \(Fmt.amount(item.amount, unit: item.info.unit)) / \(Fmt.amountWithUnit(item.limit, key: item.info.key))")
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dayShifted()
        }
        .buttonStyle(.plain)
        // HOOK (wave 2): NutrientsView(day:) is the full DESIGN 4.7 detail; this card links to it.
    }

    private func shortName(_ info: NutrientInfo) -> String {
        info.name.replacingOccurrences(of: #" \(.*\)"#, with: "", options: .regularExpression)
    }
}

struct HealthTiles: View {
    var day: String
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.units) private var units

    var body: some View {
        let h = store.healthDay(day)
        let weight = day == Days.today ? store.latestWeight?.kg : h?.weightKg
        HStack(spacing: 12) {
            tile("weight") {
                StatTile(label: "Weight", value: weight.map { Fmt.bodyWeightValue($0, units) } ?? Fmt.missing,
                         unit: units.weight.symbol, detail: Fmt.weightRate(store.weeklyWeightRate, units))
            }
            tile("active") {
                StatTile(label: "Active", value: h?.activeKcal.map(Fmt.whole) ?? Fmt.missing, unit: "kcal")
            }
            tile("steps") {
                StatTile(label: "Steps", value: h?.steps.map(Fmt.whole) ?? Fmt.missing)
            }
        }
        .dayShifted()
    }

    private func tile<C: View>(_ focus: String, @ViewBuilder _ content: () -> C) -> some View {
        Button {
            router.trendsFocus = focus
            router.tab = .trends
        } label: { content() }
            .buttonStyle(.plain)
    }
}
