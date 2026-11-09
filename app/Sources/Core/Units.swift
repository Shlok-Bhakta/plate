// Display units (Settings → Units). Data stays metric everywhere (server, sync, Store, math); these
// convert only where a weight, food amount, volume or height is shown or typed. Nutrient units (g, mg,
// µg) and kcal never change. Stored in UserDefaults under `units.*`, apart from the health sync's keys.
import Foundation

/// Exact factors (international yard and pound, US customary fluid ounce).
enum UnitFactor {
    static let kgPerLb = 0.45359237
    static let gPerOz = 28.349523125
    static let mlPerFlOz = 29.5735295625
    static let cmPerInch = 2.54
}

/// Body weight (Health tiles, Trends, goal basis).
enum BodyWeightUnit: String, CaseIterable, Sendable {
    case lb, kg
    var symbol: String { rawValue }
    func fromKg(_ kg: Double) -> Double { self == .lb ? kg / UnitFactor.kgPerLb : kg }
    func toKg(_ value: Double) -> Double { self == .lb ? value * UnitFactor.kgPerLb : value }
}

/// Food amounts by weight (entry rows, serving picker, recipes, serving weights).
enum FoodWeightUnit: String, CaseIterable, Sendable {
    case oz, g
    var symbol: String { rawValue }
    var name: String { self == .oz ? "ounces" : "grams" }
    func fromGrams(_ g: Double) -> Double { self == .oz ? g / UnitFactor.gPerOz : g }
    func toGrams(_ value: Double) -> Double { self == .oz ? value * UnitFactor.gPerOz : value }
    /// The serving picker's step: half an ounce or 5 g.
    var step: Double { self == .oz ? 0.5 : 5 }
    /// Decimals a typed or stepped amount keeps.
    var inputDecimals: Int { self == .oz ? 1 : 0 }
}

/// Water (the water card, the water goal, the water nutrient).
enum VolumeUnit: String, CaseIterable, Sendable {
    case flOz = "floz", ml
    var symbol: String { self == .flOz ? "fl oz" : "ml" }
    var spoken: String { self == .flOz ? "fluid ounces" : "milliliters" }
    func fromMl(_ ml: Double) -> Double { self == .flOz ? ml / UnitFactor.mlPerFlOz : ml }
    func toMl(_ value: Double) -> Double { self == .flOz ? value * UnitFactor.mlPerFlOz : value }
    /// The water card's two buttons, in this unit: a glass and a bottle.
    var quickAdds: [Double] { self == .flOz ? [8, 16] : [250, 500] }
    /// The long-press menu, in this unit.
    var menu: [Double] { self == .flOz ? [6, 12, 20, 24] : [150, 330, 500, 750] }
    /// The water goal editor's step, in this unit.
    var goalStep: Double { self == .flOz ? 8 : 250 }
}

/// Height (the goal basis).
enum HeightUnit: String, CaseIterable, Sendable {
    case ftIn = "ftin", cm
    var symbol: String { self == .ftIn ? "ft/in" : "cm" }
}

enum UnitSystem: String, CaseIterable, Sendable { case us, metric }

struct Units: Hashable, Sendable {
    var weight: BodyWeightUnit
    var food: FoodWeightUnit
    var water: VolumeUnit
    var height: HeightUnit

    static let us = Units(weight: .lb, food: .oz, water: .flOz, height: .ftIn)
    static let metric = Units(weight: .kg, food: .g, water: .ml, height: .cm)

    init(weight: BodyWeightUnit, food: FoodWeightUnit, water: VolumeUnit, height: HeightUnit) {
        self.weight = weight; self.food = food; self.water = water; self.height = height
    }
    init(_ system: UnitSystem) { self = system == .us ? .us : .metric }

    /// The system all four follow, or nil when they're mixed.
    var system: UnitSystem? { self == .us ? .us : self == .metric ? .metric : nil }

    /// Defaults from the locale: US gives lb, oz, fl oz and ft/in. The UK weighs people in pounds
    /// (stones) and measures them in feet, but cooks and drinks in grams and milliliters.
    static func defaults(for system: Locale.MeasurementSystem) -> Units {
        switch system {
        case .us: .us
        case .uk: Units(weight: .lb, food: .g, water: .ml, height: .ftIn)
        default: .metric
        }
    }
    static var localeDefault: Units { defaults(for: Locale.current.measurementSystem) }

    /// UserDefaults keys. None may collide with the health sync's (`sent`, `lastSync`, `requested`,
    /// `lastDailySync`, `anchor.*`), which the logic tests check.
    enum Key {
        static let weight = "units.bodyWeight"
        static let food = "units.food"
        static let water = "units.water"
        static let height = "units.height"
        static let all = [weight, food, water, height]
    }

    /// Reads each unit from `read` (a key → raw value lookup), falling back to `fallback` for missing or
    /// unknown values.
    static func load(_ read: (String) -> String?, fallback: Units) -> Units {
        Units(weight: read(Key.weight).flatMap(BodyWeightUnit.init(rawValue:)) ?? fallback.weight,
              food: read(Key.food).flatMap(FoodWeightUnit.init(rawValue:)) ?? fallback.food,
              water: read(Key.water).flatMap(VolumeUnit.init(rawValue:)) ?? fallback.water,
              height: read(Key.height).flatMap(HeightUnit.init(rawValue:)) ?? fallback.height)
    }

    /// The raw values to store, by key.
    var stored: [String: String] {
        [Key.weight: weight.rawValue, Key.food: food.rawValue, Key.water: water.rawValue, Key.height: height.rawValue]
    }

    /// The saved preference, for code outside views (toasts). Views read `\.units` so they update live.
    static var current: Units { load({ UserDefaults.standard.string(forKey: $0) }, fallback: localeDefault) }

    func save(to defaults: UserDefaults = .standard) {
        for (key, value) in stored { defaults.set(value, forKey: key) }
    }
}

// MARK: - Typed input without drift

/// A metric amount edited in display units. The field starts with `text(for:)`; while the text is
/// unchanged, `metric(from:)` hands back the exact original, so opening and saving never moves a value
/// (170 g shown as "6" oz stays 170 g, not 170.097 g). Edited text converts exactly.
struct MetricInput: Equatable, Sendable {
    /// The stored metric value (g, ml, kg).
    let original: Double?
    let initialText: String
    private let factor: Double

    /// `factor` is metric per display unit (28.349523125 for ounces, 1 for grams).
    init(_ original: Double?, factor: Double, decimals: Int = 2) {
        self.original = original
        self.factor = factor
        initialText = original.map { Fmt.decimal($0 / factor, decimals: decimals) } ?? ""
    }
    init(grams: Double?, _ unit: FoodWeightUnit) { self.init(grams, factor: unit.toGrams(1)) }
    init(ml: Double?, _ unit: VolumeUnit) { self.init(ml, factor: unit.toMl(1)) }

    /// nil for empty or unreadable text.
    func metric(from text: String) -> Double? {
        if text == initialText { return original }
        guard let v = Fmt.parse(text) else { return nil }
        return v * factor
    }
}
