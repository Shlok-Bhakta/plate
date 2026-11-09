// DESIGN 4.10 goal rows: a target with its "auto" or "override" badge (✕ clears an override), and an
// inline editor (stepper plus a typed field) that writes `goals.overrides[key]` in auto mode or
// `goals.targets[key]` in manual mode. Water writes `water_ml`. The server recomputes the targets.
import SwiftUI

/// Shown in place of derived values while the server recomputes targets after a change.
@Observable
@MainActor
final class GoalsRecalc {
    static let shared = GoalsRecalc()
    private(set) var active = false
    @ObservationIgnored private var since: Int?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    /// Call after a write the server will recompute (mode, plan, kcal override, cleared override).
    func begin(_ store: Store) {
        guard !store.isDemo else { return }
        since = store.goals?.version
        active = true
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.active = false
        }
    }

    /// Ends once a newer goals row arrives from the server.
    func observe(_ version: Int?) {
        guard active, let version, version != since else { return }
        withAnimation(.smooth) { active = false }
        timeout?.cancel()
    }
}

/// "auto" (secondarySystemFill), "override" (accent 15%), "manual"; 11 pt semibold.
struct GoalBadge: View {
    enum Kind { case auto, override, manual, limit }
    var kind: Kind
    var body: some View {
        let (text, ink, fill): (String, Color, Color) = switch kind {
        case .auto: ("auto", .secondary, Palette.chip)
        case .override: ("override", Palette.accentInk, Palette.accent.opacity(0.15))
        case .manual: ("manual", .secondary, Palette.chip)
        case .limit: ("limit", .secondary, Palette.chip)
        }
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(fill, in: Capsule())
    }
}

enum GoalStep {
    /// The most a target can be set to, so a typo can't store an absurd goal (or overflow a format).
    static func maximum(_ key: String) -> Double {
        switch key {
        case "kcal": 10_000
        case "water": 10_000
        case "protein", "carbs", "fat", "fiber", "sugar", "added_sugar", "sat_fat": 2_000
        default: 100_000
        }
    }

    /// A comfortable step for a target's size and unit.
    static func size(_ key: String, value: Double) -> Double {
        switch key {
        case "kcal": return 50
        case "water": return 250
        case "protein", "carbs", "fat": return 5
        case "fiber": return 1
        default:
            let v = abs(value)
            return v < 2 ? 0.1 : v < 20 ? 1 : v < 200 ? 5 : v < 2000 ? 50 : 100
        }
    }
}

struct GoalTargetRow: View {
    var key: String
    @Binding var expanded: String?
    @Environment(Store.self) private var store
    @Environment(\.units) private var units
    @State private var value: Double = 0
    @State private var text = ""
    /// Water's typed field in liters or fluid ounces; unchanged text keeps the exact ml.
    @State private var waterInput = MetricInput(nil, factor: 1)
    @FocusState private var focused: Bool

    private var goals: Goals { store.goals ?? Goals() }
    private var isWater: Bool { key == "water" }
    private var info: NutrientInfo? { Nutrients.info(key) }
    private var current: Double? { isWater ? goals.water : goals.target(key) }
    private var override: Double? { isWater ? nil : goals.overrides[key] }
    private var isOpen: Bool { expanded == key }
    private var recalculating: Bool { GoalsRecalc.shared.active && override == nil && !isWater && goals.mode == "auto" }
    private var unit: String { isWater ? (units.water == .ml ? "L" : units.water.symbol) : info?.displayUnit ?? "" }

    private var name: String {
        switch key {
        case "kcal": "Calories"
        case "carbs": "Carbs"
        default: info?.name ?? key
        }
    }

    private func display(_ v: Double?) -> String {
        guard let v else { return Fmt.missing }
        if isWater { return Fmt.waterGoal(v, units) }
        return Fmt.amountWithUnit(v, key: key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(name).foregroundStyle(.primary)
                if goals.isLimit(key) { GoalBadge(kind: .limit) }
                Spacer(minLength: 8)
                if recalculating {
                    Text("Recalculating…").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(display(current))
                        .numberFont(17, relativeTo: .body)
                        .foregroundStyle(current == nil ? .tertiary : .secondary)
                        .contentTransition(.numericText(value: current ?? 0))
                }
                if override != nil {
                    GoalBadge(kind: .override)
                    Button { clearOverride() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                            .symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear \(name) override")
                } else if !isWater {
                    GoalBadge(kind: goals.mode == "manual" ? .manual : .auto)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isOpen ? "Closes the editor" : "Edits this target")

            if isOpen { editor.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .animation(.snappy, value: isOpen)
        .onAppear { if isOpen { load() } }
        .onChange(of: isOpen) { _, open in if open { load() } }
    }

    private func load() {
        value = current ?? 0
        if isWater {
            waterInput = units.water == .ml ? MetricInput(value, factor: 1000) : MetricInput(value, factor: units.water.toMl(1), decimals: 0)
            text = waterInput.initialText
        } else {
            text = Fmt.trim(value)
        }
    }

    /// Water's display unit per ml: liters or fluid ounces.
    private var waterFactor: Double { units.water == .ml ? 1000 : units.water.toMl(1) }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                stepButton("minus") { set(max(0, value - step)) }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .multilineTextAlignment(.trailing)
                        .numberFont(22, .semibold, relativeTo: .title2)
                        .fixedSize()
                        .onChange(of: text) { _, t in
                            if isWater {
                                if let ml = waterInput.metric(from: t) { value = min(GoalStep.maximum(key), ml) }
                            } else if let v = parse(t) {
                                value = min(GoalStep.maximum(key), v)
                            }
                        }
                    Text(unit).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(minWidth: 96)
                stepButton("plus") { set(min(GoalStep.maximum(key), value + step)) }
                Spacer(minLength: 8)
                Button("Set") { commit() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(Palette.accent)
                    .disabled(value <= 0)
            }
            Text(caption).font(.footnote).foregroundStyle(.secondary)
        }
        .sensoryFeedback(.selection, trigger: value)
    }

    private var caption: String {
        if isWater { return "Your daily water goal." }
        if goals.mode == "manual" { return "Manual mode: this is your target until you change it." }
        if key == "kcal" { return "An override replaces the adaptive calories; protein, carbs and fat follow it." }
        return override == nil ? "Setting a value saves it as an override of the auto target." : "Clear the override with ✕ to go back to auto."
    }

    /// Water steps by 250 ml or a cup (8 fl oz); the others by GoalStep.
    private var step: Double { isWater ? units.water.toMl(units.water.goalStep) : GoalStep.size(key, value: value) }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 32)
                .background(Palette.chip, in: Capsule())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }

    private func parse(_ t: String) -> Double? {
        Double(t.replacingOccurrences(of: ",", with: ".")).flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
    }

    private func set(_ v: Double) {
        if isWater {
            // Snap in the shown unit, so fluid ounces land on whole cups.
            let shownStep = units.water.goalStep
            let shown = (units.water.fromMl(v) / shownStep).rounded() * shownStep
            value = units.water.toMl(shown)
            text = Fmt.decimal(value / waterFactor, decimals: units.water == .ml ? 2 : 0)
            return
        }
        value = (v / step).rounded() * step
        text = Fmt.trim(value)
    }

    private func toggle() {
        if isOpen {
            expanded = nil
            focused = false
        } else {
            load()
            expanded = key
        }
        Haptics.selection()
    }

    private func commit() {
        let v = NutritionMath.round3(min(value, GoalStep.maximum(key)))
        guard v > 0 else { return }
        let key = key, isWater = isWater
        store.updateGoals { g in
            if isWater {
                g.waterMl = v
                g.targets["water"] = v
                g.overrides["water"] = nil
            } else if g.mode == "manual" {
                g.targets[key] = v
                g.overrides[key] = nil
            } else {
                g.overrides[key] = v
            }
        }
        if key == "kcal" && goals.mode == "auto" { GoalsRecalc.shared.begin(store) }
        Haptics.light()
        focused = false
        expanded = nil
    }

    private func clearOverride() {
        let key = key
        store.updateGoals { $0.overrides[key] = nil }
        GoalsRecalc.shared.begin(store)
        Haptics.soft()
        if isOpen { expanded = nil }
    }
}
