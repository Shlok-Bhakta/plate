// Number formatting rules (DESIGN 2.3): thousands separators, whole kcal and mg, grams with one
// decimal under 10, whole percentages, and an en dash for missing values.
import Foundation

enum Fmt {
    static let missing = "–"

    private static func number(_ x: Double, decimals: Int) -> String {
        x.formatted(.number.precision(.fractionLength(0...decimals)).grouping(.automatic))
    }

    /// "1,240"
    static func whole(_ x: Double) -> String { number(x.rounded(), decimals: 0) }
    static func kcal(_ x: Double?) -> String { x.map(whole) ?? missing }

    /// One decimal under 10, none above: "9.5", "96".
    static func grams(_ x: Double) -> String {
        abs(x) < 10 ? number((x * 10).rounded() / 10, decimals: 1) : whole(x)
    }

    /// A nutrient amount in its own unit, without the unit.
    static func amount(_ x: Double?, unit: String) -> String {
        guard let x else { return missing }
        switch unit {
        case "kcal", "mg", "ml": return whole(x)
        case "ug": return abs(x) < 10 ? number((x * 10).rounded() / 10, decimals: 1) : whole(x)
        default: return grams(x)
        }
    }

    /// "96 g", "2,640 mg", "12 µg".
    static func amountWithUnit(_ x: Double?, key: String) -> String {
        guard let info = Nutrients.info(key) else { return x.map { grams($0) } ?? missing }
        guard let x else { return missing }
        return "\(amount(x, unit: info.unit)) \(info.displayUnit)"
    }

    static func percent(_ p: Int?) -> String { p.map { "\($0)%" } ?? missing }

    /// Liters with two decimals: "1.25"; the target uses one: "3.0".
    static func liters(_ ml: Double, decimals: Int = 2) -> String {
        (ml / 1000).formatted(.number.precision(.fractionLength(decimals)))
    }

    /// Servings and other amounts without trailing zeros: 1, 1.5, 0.25.
    static func trim(_ x: Double) -> String {
        guard x.isFinite else { return missing }
        let r = (x * 100).rounded() / 100
        if r == r.rounded(), abs(r) < 1e15 { return String(Int(r)) }
        return r.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// "1.5" written as a friendly fraction where one fits: ½, 1½, ¼.
    static func servings(_ x: Double) -> String {
        guard x.isFinite, abs(x) < 1e15 else { return trim(x) }
        let whole = Int(x.rounded(.down))
        let frac = x - Double(whole)
        let glyph: String? = switch (frac * 100).rounded() {
        case 25: "¼"
        case 50: "½"
        case 75: "¾"
        default: nil
        }
        guard let glyph else { return trim(x) }
        return whole == 0 ? glyph : "\(whole)\(glyph)"
    }
}

// MARK: - Display units (Settings → Units)

/// Weights, food amounts, water and height in the chosen units. The values passed in are always metric
/// (kg, g, ml, cm); rounding happens here only. Body weight 0.1 lb or kg; ounces 0.1 under 10 and whole
/// above (two decimals for a sliver under 0.1); fluid ounces whole; grams follow `grams`.
extension Fmt {
    /// Up to `decimals` decimals with trailing zeros dropped, no grouping, POSIX: for typed fields.
    static func decimal(_ x: Double, decimals: Int) -> String {
        guard x.isFinite else { return missing }
        let p = pow(10, Double(decimals))
        let r = (x * p).rounded() / p
        if r == r.rounded(), abs(r) < 1e15 { return String(Int(r)) }
        return r.formatted(.number.precision(.fractionLength(0...decimals)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// A typed number: "8,5" and "8.5" both read 8.5. nil for empty, negative or unreadable text.
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(t).flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
    }

    // Body weight

    /// "255.7" (lb) or "116.0" (kg).
    static func bodyWeightValue(_ kg: Double, _ u: Units) -> String {
        u.weight.fromKg(kg).formatted(.number.precision(.fractionLength(1)))
    }
    /// "255.7 lb"
    static func bodyWeight(_ kg: Double, _ u: Units) -> String { "\(bodyWeightValue(kg, u)) \(u.weight.symbol)" }
    /// Whole pounds or kilograms as given ("256 lb", "115.8 kg"), for the goal basis.
    static func bodyWeightShort(_ kg: Double, _ u: Units) -> String {
        u.weight == .lb ? "\(whole(u.weight.fromKg(kg))) lb" : "\(trim(kg)) kg"
    }
    /// "↓ 0.5 lb/wk", never colored. The arrow flattens under 0.05 of the shown unit.
    static func weightRate(_ kgPerWeek: Double?, _ u: Units) -> String? {
        guard let kgPerWeek else { return nil }
        let r = u.weight.fromKg(kgPerWeek)
        let arrow = r < -0.05 ? "↓" : (r > 0.05 ? "↑" : "→")
        return "\(arrow) \(String(format: "%.1f", abs(r))) \(u.weight.symbol)/wk"
    }
    /// "0.8 g per lb" for a protein factor given per kg.
    static func perBodyWeight(_ gPerKg: Double, _ u: Units) -> String {
        let v = u.weight == .lb ? gPerKg * UnitFactor.kgPerLb : gPerKg
        return "\(v.formatted(.number.precision(.fractionLength(1)))) g per \(u.weight.symbol)"
    }

    // Food weight

    /// "9", "8.6", "0.04" (oz) or "255", "9.5" (g).
    static func foodWeightValue(_ g: Double, _ u: Units) -> String {
        guard u.food == .oz else { return grams(g) }
        let oz = u.food.fromGrams(g)
        if abs(oz) >= 10 { return whole(oz) }
        let tenth = (oz * 10).rounded() / 10
        if tenth == 0 && oz != 0 { return decimal(oz, decimals: 2) }
        return number(tenth, decimals: 1)
    }
    /// "9 oz", "255 g"
    static func foodWeight(_ g: Double, _ u: Units) -> String { "\(foodWeightValue(g, u)) \(u.food.symbol)" }
    /// An amount the user typed or stepped in `unit` ("8.5" oz, "255" g), kept to the unit's input decimals.
    static func foodInput(_ amount: Double, _ unit: FoodWeightUnit) -> String {
        decimal(amount, decimals: unit.inputDecimals)
    }

    // Volume

    /// "8" (fl oz) or "250" (ml): whole.
    static func volumeValue(_ ml: Double, _ u: Units) -> String { whole(u.water.fromMl(ml)) }
    /// "8 fl oz", "250 ml"
    static func volume(_ ml: Double, _ u: Units) -> String { "\(volumeValue(ml, u)) \(u.water.symbol)" }

    /// The water card's total and goal: ("42", " / 101 fl oz") or ("1.25", " / 3.0 L").
    static func waterProgress(_ ml: Double, goal: Double, _ u: Units) -> (value: String, rest: String) {
        u.water == .ml ? (liters(ml), " / \(liters(goal, decimals: 1)) L")
                       : (volumeValue(ml, u), " / \(volumeValue(goal, u)) fl oz")
    }
    /// A water goal: "3.0 L" or "101 fl oz".
    static func waterGoal(_ ml: Double, _ u: Units) -> String {
        u.water == .ml ? "\(liters(ml, decimals: 1)) L" : volume(ml, u)
    }

    // Height

    /// "6′1″" or "185 cm". Inches round first, so 182.5 cm is 6′0″ rather than 5′12″.
    static func height(_ cm: Double, _ u: Units) -> String {
        guard u.height == .ftIn else { return "\(whole(cm)) cm" }
        let inches = Int(saturating: (cm / UnitFactor.cmPerInch).rounded())
        return "\(inches / 12)′\(inches % 12)″"
    }

    // Labels that are a bare measure ("100 g", "4 oz", "1 lb", "240 ml")

    private static let measurePattern = try! NSRegularExpression(
        pattern: #"^\s*(\d+(?:[.,]\d+)?)?\s*(g|grams?|kg|oz|ounces?|lbs?|ml|fl\.? ?oz)\s*$"#, options: [.caseInsensitive])

    /// The number and normalized unit ("g", "kg", "oz", "lb", "ml", "fl oz") of a bare-measure label.
    static func measure(_ label: String) -> (amount: Double, unit: String)? {
        let range = NSRange(label.startIndex..., in: label)
        guard let m = measurePattern.firstMatch(in: label, range: range) else { return nil }
        let amount = Range(m.range(at: 1), in: label).flatMap { parse(String(label[$0])) } ?? 1
        guard let unitRange = Range(m.range(at: 2), in: label) else { return nil }
        let raw = label[unitRange].lowercased()
        let unit = switch raw {
        case "g", "gram", "grams": "g"
        case "oz", "ounce", "ounces": "oz"
        case "lb", "lbs": "lb"
        case "kg", "ml": raw
        default: "fl oz"
        }
        return (amount, unit)
    }

    /// True for a label that is only a weight ("100 g", "4 oz"), which then needs no "(170 g)" after it.
    static func isWeightLabel(_ label: String) -> Bool {
        measure(label).map { ["g", "kg", "oz", "lb"].contains($0.unit) } ?? false
    }

    /// A food's serving or portion label in the chosen units. A bare measure from the other system is
    /// rewritten ("100 g" reads "3.5 oz" in US units, "4 oz" reads "113 g" in metric), from `grams` when
    /// it's known; one already in the chosen system, and any other label ("1 cup"), stays as it is.
    static func measureLabel(_ label: String, grams: Double? = nil, _ u: Units) -> String {
        guard let m = measure(label) else { return label }
        switch m.unit {
        case "g", "kg", "oz", "lb":
            let metricLabel = m.unit == "g" || m.unit == "kg"
            guard metricLabel != (u.food == .g) else { return label }
            let g = grams ?? (m.unit == "g" ? m.amount : m.unit == "kg" ? m.amount * 1000
                              : m.unit == "oz" ? m.amount * UnitFactor.gPerOz : m.amount * UnitFactor.kgPerLb * 1000)
            return foodWeight(g, u)
        default:
            guard (m.unit == "ml") != (u.water == .ml) else { return label }
            let ml = m.unit == "ml" ? m.amount : m.amount * UnitFactor.mlPerFlOz
            return u.water == .ml ? "\(whole(ml)) ml" : "\(decimal(u.water.fromMl(ml), decimals: 1)) fl oz"
        }
    }
}
