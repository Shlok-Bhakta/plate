// The fixed nutrient keys shared by the server, CLI, app and agents (SPEC "Nutrients"), embedded so the
// app works offline. Mirrors server/src/nutrients.rs and GET /v1/meta exactly.
import Foundation

/// `{ key: amount }`. A missing key means unknown, which is not the same as 0.
typealias NutrientMap = [String: Double]

enum NutrientGroup: String, Codable, CaseIterable, Sendable {
    case macro, fat, mineral, vitamin, other

    var title: String {
        switch self {
        case .macro: "Macros"
        case .fat: "Fats"
        case .mineral: "Minerals"
        case .vitamin: "Vitamins"
        case .other: "Other"
        }
    }
}

struct NutrientInfo: Hashable, Sendable, Identifiable {
    let key: String
    let name: String
    /// The wire unit: kcal, g, mg, ug or ml.
    let unit: String
    let group: NutrientGroup
    /// FDA daily value (2016 label rule), nil when there isn't one.
    let dv: Double?
    /// Adult RDA or AI (male, female) for ages 19 to 50, where it differs from the DV.
    let rda: (male: Double, female: Double)?
    var id: String { key }

    /// The unit as shown on screen ("µg" for "ug").
    var displayUnit: String { unit == "ug" ? "µg" : unit }
    /// Limits are ceilings (sodium, saturated fat, added sugar, cholesterol by default).
    var isDefaultLimit: Bool { Nutrients.defaultLimits.contains(key) }

    static func == (a: NutrientInfo, b: NutrientInfo) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }
}

enum Nutrients {
    private static func n(_ key: String, _ name: String, _ unit: String, _ group: NutrientGroup,
                          _ dv: Double?, _ rda: (Double, Double)? = nil) -> NutrientInfo {
        NutrientInfo(key: key, name: name, unit: unit, group: group, dv: dv, rda: rda.map { (male: $0.0, female: $0.1) })
    }

    static let all: [NutrientInfo] = [
        n("kcal", "Calories", "kcal", .macro, 2000),
        n("protein", "Protein", "g", .macro, 50),
        n("carbs", "Carbohydrates", "g", .macro, 275),
        n("fat", "Fat", "g", .macro, 78),
        n("fiber", "Fiber", "g", .macro, 28),
        n("sugar", "Sugars", "g", .macro, nil),
        n("added_sugar", "Added sugars", "g", .macro, 50),
        n("sat_fat", "Saturated fat", "g", .fat, 20),
        n("trans_fat", "Trans fat", "g", .fat, nil),
        n("mono_fat", "Monounsaturated fat", "g", .fat, nil),
        n("poly_fat", "Polyunsaturated fat", "g", .fat, nil),
        n("omega3", "Omega-3", "g", .fat, nil, (1.6, 1.1)),
        n("cholesterol", "Cholesterol", "mg", .fat, 300),
        n("sodium", "Sodium", "mg", .mineral, 2300),
        n("potassium", "Potassium", "mg", .mineral, 4700, (3400, 2600)),
        n("calcium", "Calcium", "mg", .mineral, 1300, (1000, 1000)),
        n("iron", "Iron", "mg", .mineral, 18, (8, 18)),
        n("magnesium", "Magnesium", "mg", .mineral, 420, (420, 320)),
        n("phosphorus", "Phosphorus", "mg", .mineral, 1250, (700, 700)),
        n("zinc", "Zinc", "mg", .mineral, 11, (11, 8)),
        n("copper", "Copper", "mg", .mineral, 0.9),
        n("manganese", "Manganese", "mg", .mineral, 2.3, (2.3, 1.8)),
        n("selenium", "Selenium", "ug", .mineral, 55),
        n("iodine", "Iodine", "ug", .mineral, 150),
        n("vit_a", "Vitamin A (RAE)", "ug", .vitamin, 900, (900, 700)),
        n("vit_c", "Vitamin C", "mg", .vitamin, 90, (90, 75)),
        n("vit_d", "Vitamin D", "ug", .vitamin, 20, (15, 15)),
        n("vit_e", "Vitamin E", "mg", .vitamin, 15),
        n("vit_k", "Vitamin K", "ug", .vitamin, 120, (120, 90)),
        n("thiamin", "Thiamin (B1)", "mg", .vitamin, 1.2, (1.2, 1.1)),
        n("riboflavin", "Riboflavin (B2)", "mg", .vitamin, 1.3, (1.3, 1.1)),
        n("niacin", "Niacin (B3)", "mg", .vitamin, 16, (16, 14)),
        n("pantothenic", "Pantothenic acid (B5)", "mg", .vitamin, 5),
        n("vit_b6", "Vitamin B6", "mg", .vitamin, 1.7, (1.3, 1.3)),
        n("biotin", "Biotin (B7)", "ug", .vitamin, 30),
        n("folate", "Folate (DFE)", "ug", .vitamin, 400),
        n("vit_b12", "Vitamin B12", "ug", .vitamin, 2.4),
        n("choline", "Choline", "mg", .vitamin, 550, (550, 425)),
        n("caffeine", "Caffeine", "mg", .other, nil),
        n("alcohol", "Alcohol", "g", .other, nil),
        n("water", "Water", "ml", .other, nil),
    ]

    static let byKey: [String: NutrientInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
    static let defaultLimits: Set<String> = ["sodium", "sat_fat", "added_sugar", "cholesterol"]
    static let macroKeys = ["protein", "carbs", "fat", "fiber"]

    static func info(_ key: String) -> NutrientInfo? { byKey[key] }
    static func group(_ group: NutrientGroup) -> [NutrientInfo] { all.filter { $0.group == group } }

    /// The order of the top of an FDA Nutrition Facts label (DESIGN 4.3), then the rest.
    static let labelOrder: [(key: String, indent: Bool)] = [
        ("fat", false), ("sat_fat", true), ("trans_fat", true), ("cholesterol", false), ("sodium", false),
        ("carbs", false), ("fiber", true), ("sugar", true), ("added_sugar", true), ("protein", false),
        ("vit_d", false), ("calcium", false), ("iron", false), ("potassium", false),
    ]

    /// Nutrients Detail section order (DESIGN 4.7): Macros, Fats, Vitamins, Minerals, Other.
    static let detailSections: [(group: NutrientGroup, keys: [String])] = [
        (.macro, ["kcal", "protein", "carbs", "fat", "fiber", "sugar", "added_sugar"]),
        (.fat, ["sat_fat", "trans_fat", "mono_fat", "poly_fat", "omega3", "cholesterol"]),
        (.vitamin, group(.vitamin).map(\.key)),
        (.mineral, group(.mineral).map(\.key)),
        (.other, ["caffeine", "alcohol", "water"]),
    ]
}
