// Settings → Goals, one level deeper: micronutrient targets (grouped, each with its badge and the inline
// editor), the meal split, and which nutrients are limits. Every write goes through Store.updateGoals.
import SwiftUI

struct MicronutrientTargetsView: View {
    @Environment(Store.self) private var store
    @State private var expanded: String?

    private static let mainKeys: Set<String> = ["kcal", "protein", "carbs", "fat", "fiber", "water"]

    var body: some View {
        let goals = store.goals ?? Goals()
        List {
            ForEach(Nutrients.detailSections, id: \.group) { section in
                let keys = section.keys.filter { !Self.mainKeys.contains($0) && (goals.target($0) != nil || goals.isLimit($0)) }
                if !keys.isEmpty {
                    Section {
                        ForEach(keys, id: \.self) { GoalTargetRow(key: $0, expanded: $expanded) }
                    } header: {
                        HStack(spacing: 6) {
                            GroupDot(color: Palette.group(section.group))
                            Text(section.group == .macro ? "Sugars" : section.group.title)
                        }
                    }
                }
            }
            let untracked = Nutrients.all.filter { goals.target($0.key) == nil && !goals.isLimit($0.key) && !Self.mainKeys.contains($0.key) }
            if !untracked.isEmpty {
                Section {
                    Text(untracked.map(\.name).joined(separator: ", "))
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: {
                    Text("Tracked without a target")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Micronutrients")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Micronutrients").font(.headline)
                    Text(basisLine(goals)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func basisLine(_ g: Goals) -> String {
        let n = Nutrients.all.filter { !Self.mainKeys.contains($0.key) && g.target($0.key) != nil }.count
        if let sex = g.basis?.sex, let age = g.basis?.age { return "\(n) targets · RDA for a \(Fmt.whole(age))-year-old \(sex)" }
        return "\(n) targets · FDA daily values"
    }
}

// MARK: - Meal split

struct MealSplitView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var shares: [Meal: Double] = [:]
    @State private var loaded = false

    private var total: Int { Int(saturating: (Meal.allCases.reduce(0) { $0 + (shares[$1] ?? 0) } * 100).rounded()) }
    private var original: [Meal: Double] {
        let s = store.goals?.mealSplit ?? [:]
        return Dictionary(uniqueKeysWithValues: Meal.allCases.map { ($0, s[$0.rawValue] ?? 0.25) })
    }

    var body: some View {
        let kcal = store.goals?.kcal
        List {
            Section {
                SplitBar(shares: Meal.allCases.map { shares[$0] ?? 0 })
                    .listRowInsets(EdgeInsets(top: 16, leading: Space.l, bottom: 16, trailing: Space.l))
                ForEach(Meal.allCases) { meal in
                    HStack(spacing: 12) {
                        Circle().fill(Palette.accent.opacity(SplitBar.opacity(Meal.allCases.firstIndex(of: meal) ?? 0)))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meal.title)
                            if let kcal {
                                Text("\(Fmt.kcal(kcal * (shares[meal] ?? 0))) kcal")
                                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                                    .contentTransition(.numericText(value: kcal * (shares[meal] ?? 0)))
                            }
                        }
                        Spacer()
                        stepper(meal)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                if total == 100 {
                    Text("Each meal header on Today shows its share of your calories as a faint target.")
                } else {
                    Text("Adds up to \(total)%. Make it 100% to save.").foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Reset to 25 · 35 · 30 · 10") {
                    withAnimation(.snappy) {
                        shares = [.breakfast: 0.25, .lunch: 0.35, .dinner: 0.3, .snack: 0.1]
                    }
                }
                .foregroundStyle(Palette.accentInk)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Meal split")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) { Image(systemName: "checkmark") }
                    .disabled(total != 100 || shares == original)
                    .accessibilityLabel("Save")
            }
        }
        .onAppear {
            guard !loaded else { return }
            shares = original
            loaded = true
        }
    }

    private func stepper(_ meal: Meal) -> some View {
        let pct = Int(saturating: ((shares[meal] ?? 0) * 100).rounded())
        return HStack(spacing: 6) {
            stepButton("minus") { shares[meal] = max(0, Double(pct - 5) / 100) }.disabled(pct <= 0)
            Text("\(pct)%").numberFont(17, .semibold, relativeTo: .body).frame(minWidth: 48)
                .contentTransition(.numericText(value: Double(pct)))
            stepButton("plus") { shares[meal] = min(1, Double(pct + 5) / 100) }.disabled(pct >= 100)
        }
        .sensoryFeedback(.selection, trigger: pct)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meal.title)
        .accessibilityValue("\(pct) percent")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: shares[meal] = min(1, Double(pct + 5) / 100)
            case .decrement: shares[meal] = max(0, Double(pct - 5) / 100)
            default: break
            }
        }
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 32)
                .background(Palette.chip, in: Capsule())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }

    private func save() {
        let split = Dictionary(uniqueKeysWithValues: Meal.allCases.map { ($0.rawValue, NutritionMath.round3(shares[$0] ?? 0)) })
        store.updateGoals { $0.mealSplit = split }
        Haptics.success()
        dismiss()
    }
}

/// The split as one capsule, four segments in accent from deep to light, 2 pt gaps.
struct SplitBar: View {
    var shares: [Double]
    static func opacity(_ i: Int) -> Double { [1, 0.72, 0.48, 0.28][min(i, 3)] }

    var body: some View {
        GeometryReader { g in
            let parts = shares.enumerated().filter { $0.element > 0 }
            let gaps = CGFloat(max(0, parts.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(parts, id: \.offset) { i, s in
                    Capsule().fill(Palette.accent.opacity(Self.opacity(i)))
                        .frame(width: max(4, (g.size.width - gaps) * s / max(shares.reduce(0, +), 0.0001)))
                }
            }
        }
        .frame(height: 12)
        .animation(.snappy, value: shares)
        .accessibilityHidden(true)
    }
}

// MARK: - Limits

struct LimitsView: View {
    @Environment(Store.self) private var store
    private static let candidates = ["sodium", "sat_fat", "added_sugar", "cholesterol", "sugar", "trans_fat", "caffeine", "alcohol"]

    var body: some View {
        let goals = store.goals ?? Goals()
        List {
            Section {
                ForEach(Self.candidates, id: \.self) { key in
                    Toggle(isOn: Binding(get: { goals.isLimit(key) }, set: { on in set(key, on) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Nutrients.info(key)?.name ?? key)
                            Text(goals.target(key).map { "Under \(Fmt.amountWithUnit($0, key: key)) a day" } ?? "No daily amount set")
                                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .tint(Palette.accent)
                }
            } footer: {
                Text("Limits are ceilings, not goals. Plate draws them in gray and only turns them red once you pass them.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Limits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func set(_ key: String, _ on: Bool) {
        store.updateGoals { g in
            if on { if !g.limits.contains(key) { g.limits.append(key) } } else { g.limits.removeAll { $0 == key } }
        }
        Haptics.selection()
    }
}
