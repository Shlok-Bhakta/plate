// Display units in SwiftUI: `\.units` in the environment, fed from UserDefaults by UnitsProvider at the
// root so every screen (sheets included) redraws when a unit changes, and Settings → Units: one US / Metric
// switch that sets all four, then a compact row per unit to override it.
import SwiftUI

private struct UnitsKey: EnvironmentKey { static let defaultValue = Units.localeDefault }
extension EnvironmentValues {
    /// The display units. Data stays metric; convert only where a value is shown or typed.
    var units: Units {
        get { self[UnitsKey.self] }
        set { self[UnitsKey.self] = newValue }
    }
}

/// Reads the four `units.*` keys (locale defaults until they're set) into `\.units`.
struct UnitsProvider: ViewModifier {
    @AppStorage(Units.Key.weight) private var weight = Units.localeDefault.weight
    @AppStorage(Units.Key.food) private var food = Units.localeDefault.food
    @AppStorage(Units.Key.water) private var water = Units.localeDefault.water
    @AppStorage(Units.Key.height) private var height = Units.localeDefault.height

    func body(content: Content) -> some View {
        content.environment(\.units, Units(weight: weight, food: food, water: water, height: height))
    }
}

/// DESIGN 4.10 style: segmented controls in a Form section, like Mode and Plan under Goals.
struct UnitsSection: View {
    @AppStorage(Units.Key.weight) private var weight = Units.localeDefault.weight
    @AppStorage(Units.Key.food) private var food = Units.localeDefault.food
    @AppStorage(Units.Key.water) private var water = Units.localeDefault.water
    @AppStorage(Units.Key.height) private var height = Units.localeDefault.height

    private var units: Units { Units(weight: weight, food: food, water: water, height: height) }

    var body: some View {
        Section {
            LabeledContent {
                Picker("Units", selection: Binding(get: { units.system }, set: { set($0) })) {
                    Text("US").tag(UnitSystem?.some(.us))
                    Text("Metric").tag(UnitSystem?.some(.metric))
                }
                .pickerStyle(.segmented)
                .frame(width: controlWidth)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("System")
                    if units.system == nil {
                        Text("Custom").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            row("Body weight", $weight, BodyWeightUnit.allCases) { $0.symbol }
            row("Food", $food, FoodWeightUnit.allCases) { $0.symbol }
            row("Water", $water, VolumeUnit.allCases) { $0.symbol }
            row("Height", $height, HeightUnit.allCases) { $0.symbol }
        } header: {
            Text("Units")
        } footer: {
            Text("Only changes what you see and type; Plate stores everything in metric. Nutrients stay in g and mg, as on US labels.")
        }
    }

    private func row<U: Hashable>(_ title: String, _ value: Binding<U>, _ options: [U], label: @escaping (U) -> String) -> some View {
        LabeledContent(title) {
            Picker(title, selection: Binding(get: { value.wrappedValue }, set: { v in
                withAnimation(.smooth) { value.wrappedValue = v }
                Haptics.selection()
            })) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: controlWidth)
        }
    }

    /// One width for every switch, so the five line up in a column; it grows with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var controlWidth: CGFloat = 150

    private func set(_ system: UnitSystem?) {
        guard let system else { return }
        let u = Units(system)
        withAnimation(.smooth) {
            weight = u.weight; food = u.food; water = u.water; height = u.height
        }
        Haptics.selection()
    }
}
