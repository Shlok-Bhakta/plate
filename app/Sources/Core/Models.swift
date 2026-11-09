// Synced rows (SPEC "Data model"). Decoding is lenient because tombstones can be sparse
// (`{"id", "deleted": true, "updated_at"}`), and unknown fields round-trip through `extra`.
import Foundation

enum Meal: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case breakfast, lunch, dinner, snack
    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snacks"
        }
    }
    /// For phrases like "Log lunch" and "Copy yesterday's lunch".
    var noun: String { self == .snack ? "snack" : rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Meal(rawValue: raw) ?? .snack
    }
}

enum Table: String, Codable, Sendable { case foods, entries, goals, healthDays = "health_days" }

func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

// MARK: - Food

struct Serving: Codable, Hashable, Sendable {
    var amount: Double = 1
    var unit: String = "serving"
    /// Grams in one serving, when known. Portions and grams scale only when this is set.
    var grams: Double?

    init(amount: Double = 1, unit: String = "serving", grams: Double? = nil) {
        self.amount = amount; self.unit = unit; self.grams = grams
    }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        amount = r.double("amount") ?? 1
        unit = r.string("unit") ?? "serving"
        grams = r.double("grams").flatMap { $0 > 0 ? $0 : nil }
    }
    func encode(to encoder: Encoder) throws {
        var w = RowWriter(encoder)
        try w.put("amount", amount); try w.put("unit", unit); try w.put("grams", grams)
    }
}

struct Portion: Codable, Hashable, Sendable {
    var label: String
    var grams: Double
    init(label: String, grams: Double) { self.label = label; self.grams = grams }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        label = r.string("label") ?? "portion"
        grams = r.double("grams") ?? 0
    }
}

struct Component: Codable, Hashable, Sendable {
    var foodID: String
    var servings: Double
    enum CodingKeys: String, CodingKey { case foodID = "food_id", servings }
    init(foodID: String, servings: Double) { self.foodID = foodID; self.servings = servings }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        foodID = r.string("food_id") ?? ""
        servings = r.double("servings") ?? 1
    }
}

enum FoodKind: String, Codable, Sendable { case food, recipe, quick }

struct Food: Codable, Hashable, Identifiable, Sendable {
    /// nil for catalog and Open Food Facts search results until they're logged.
    var id: String?
    var kind: FoodKind = .food
    var name: String = ""
    var brand: String?
    var barcode: String?
    var serving = Serving()
    var portions: [Portion] = []
    /// Per one serving.
    var nutrients: NutrientMap = [:]
    var components: [Component] = []
    var recipeServings: Double?
    /// usda | off | custom | agent | recipe
    var source: String?
    var sourceRef: String?
    var favorite = false
    var createdAt = 0
    var updatedAt = 0
    var deleted = false
    var version: Int?
    var extra: [String: JSONValue] = [:]

    /// Identity for lists, including unsaved search results.
    var listID: String { id ?? sourceRef ?? "\(name)|\(brand ?? "")" }
    var kcal: Double? { nutrients["kcal"] }

    static let known: Set<String> = ["id", "kind", "name", "brand", "barcode", "serving", "portions", "nutrients",
                                     "components", "recipe_servings", "source", "source_ref", "favorite",
                                     "created_at", "updated_at", "deleted", "version"]

    init(id: String? = UUID().uuidString.lowercased(), kind: FoodKind = .food, name: String, brand: String? = nil,
         barcode: String? = nil, serving: Serving = Serving(), portions: [Portion] = [], nutrients: NutrientMap,
         source: String? = "custom", sourceRef: String? = nil, favorite: Bool = false) {
        self.id = id; self.kind = kind; self.name = name; self.brand = brand; self.barcode = barcode
        self.serving = serving; self.portions = portions; self.nutrients = nutrients
        self.source = source; self.sourceRef = sourceRef; self.favorite = favorite
        let now = nowMs()
        createdAt = now; updatedAt = now
    }

    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        id = r.string("id")
        kind = r.string("kind").flatMap(FoodKind.init(rawValue:)) ?? .food
        name = r.string("name") ?? ""
        brand = r.string("brand").flatMap { $0.isEmpty ? nil : $0 }
        barcode = r.string("barcode").flatMap { $0.isEmpty ? nil : $0 }
        serving = r.value("serving") ?? Serving()
        portions = r.value("portions") ?? []
        nutrients = r.nutrients("nutrients")
        components = r.value("components") ?? []
        recipeServings = r.double("recipe_servings")
        source = r.string("source")
        sourceRef = r.string("source_ref").flatMap { $0.isEmpty ? nil : $0 }
        favorite = r.bool("favorite") ?? false
        createdAt = r.int("created_at") ?? 0
        updatedAt = r.int("updated_at") ?? 0
        deleted = r.bool("deleted") ?? false
        version = r.int("version")
        extra = r.extras(known: Food.known)
    }

    func encode(to encoder: Encoder) throws {
        var w = RowWriter(encoder)
        try w.putOrNull("id", id)
        try w.put("kind", kind); try w.put("name", name); try w.put("brand", brand); try w.put("barcode", barcode)
        try w.put("serving", serving); try w.put("portions", portions); try w.put("nutrients", nutrients)
        if !components.isEmpty { try w.put("components", components) }
        try w.put("recipe_servings", recipeServings)
        try w.put("source", source); try w.put("source_ref", sourceRef)
        try w.put("favorite", favorite); try w.put("created_at", createdAt); try w.put("updated_at", updatedAt)
        try w.put("deleted", deleted); try w.put("version", version)
        try w.extras(extra, known: Food.known)
    }
}

// MARK: - Entry

enum EntrySource: String, Sendable { case app, agent, barcode }

struct Entry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    /// Local day in the server's time zone, "2026-11-08".
    var day: String
    var meal: Meal
    var loggedAt: Int
    var foodID: String?
    var name: String
    var brand: String?
    var servings: Double = 1
    var servingLabel: String?
    var grams: Double?
    /// Snapshot of the total for this entry.
    var nutrients: NutrientMap = [:]
    var note: String?
    /// app | agent | barcode
    var source: String?
    var updatedAt: Int
    var deleted = false
    var version: Int?
    var extra: [String: JSONValue] = [:]

    static let known: Set<String> = ["id", "day", "meal", "logged_at", "food_id", "name", "brand", "servings",
                                     "serving_label", "grams", "nutrients", "note", "source", "updated_at",
                                     "deleted", "version"]

    var kcal: Double? { nutrients["kcal"] }
    var isWater: Bool { nutrients["water"] != nil && name.lowercased() == "water" }
    var isQuick: Bool { foodID == nil }

    init(id: String = UUID().uuidString.lowercased(), day: String, meal: Meal, loggedAt: Int = nowMs(),
         foodID: String? = nil, name: String, brand: String? = nil, servings: Double = 1,
         servingLabel: String? = nil, grams: Double? = nil, nutrients: NutrientMap, note: String? = nil,
         source: String? = "app") {
        self.id = id; self.day = day; self.meal = meal; self.loggedAt = loggedAt; self.foodID = foodID
        self.name = name; self.brand = brand; self.servings = servings; self.servingLabel = servingLabel
        self.grams = grams; self.nutrients = nutrients; self.note = note; self.source = source
        self.updatedAt = nowMs()
    }

    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        id = r.string("id") ?? UUID().uuidString.lowercased()
        day = r.string("day") ?? ""
        meal = r.string("meal").flatMap(Meal.init(rawValue:)) ?? .snack
        loggedAt = r.int("logged_at") ?? r.int("updated_at") ?? 0
        foodID = r.string("food_id")
        name = r.string("name") ?? ""
        brand = r.string("brand").flatMap { $0.isEmpty ? nil : $0 }
        servings = r.double("servings") ?? 1
        servingLabel = r.string("serving_label")
        grams = r.double("grams")
        nutrients = r.nutrients("nutrients")
        note = r.string("note")
        source = r.string("source")
        updatedAt = r.int("updated_at") ?? 0
        deleted = r.bool("deleted") ?? false
        version = r.int("version")
        extra = r.extras(known: Entry.known)
    }

    func encode(to encoder: Encoder) throws {
        var w = RowWriter(encoder)
        try w.put("id", id); try w.put("day", day); try w.put("meal", meal); try w.put("logged_at", loggedAt)
        try w.putOrNull("food_id", foodID); try w.put("name", name); try w.put("brand", brand)
        try w.put("servings", servings); try w.put("serving_label", servingLabel); try w.put("grams", grams)
        try w.put("nutrients", nutrients); try w.put("note", note); try w.put("source", source)
        try w.put("updated_at", updatedAt); try w.put("deleted", deleted); try w.put("version", version)
        try w.extras(extra, known: Entry.known)
    }
}

// MARK: - Goals

struct GoalBasis: Codable, Hashable, Sendable {
    var weightKg: Double?
    var heightCm: Double?
    var age: Double?
    var sex: String?
    var bmr: Double?
    var activeKcalAvg14: Double?
    var tdee: Double?
    var computedAt: Int?
    var note: String?
    var extra: [String: JSONValue] = [:]

    static let known: Set<String> = ["weight_kg", "height_cm", "age", "sex", "bmr", "active_kcal_avg14", "tdee",
                                     "computed_at", "note"]
    init() {}
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        weightKg = r.double("weight_kg"); heightCm = r.double("height_cm"); age = r.double("age")
        sex = r.string("sex"); bmr = r.double("bmr"); activeKcalAvg14 = r.double("active_kcal_avg14")
        tdee = r.double("tdee"); computedAt = r.int("computed_at"); note = r.string("note")
        extra = r.extras(known: GoalBasis.known)
    }
    func encode(to encoder: Encoder) throws {
        var w = RowWriter(encoder)
        try w.put("weight_kg", weightKg); try w.put("height_cm", heightCm); try w.put("age", age)
        try w.put("sex", sex); try w.put("bmr", bmr); try w.put("active_kcal_avg14", activeKcalAvg14)
        try w.put("tdee", tdee); try w.put("computed_at", computedAt); try w.put("note", note)
        try w.extras(extra, known: GoalBasis.known)
    }
}

struct Goals: Codable, Hashable, Sendable {
    var id = "current"
    /// auto | manual
    var mode = "auto"
    /// maintain | cut | bulk
    var plan = "maintain"
    var targets: [String: Double] = [:]
    var overrides: [String: Double] = [:]
    var limits: [String] = Array(Nutrients.defaultLimits)
    var basis: GoalBasis?
    var mealSplit: [String: Double] = [:]
    var waterMl: Double?
    var updatedAt = 0
    var deleted = false
    var version: Int?
    var extra: [String: JSONValue] = [:]

    static let known: Set<String> = ["id", "mode", "plan", "targets", "overrides", "limits", "basis", "meal_split",
                                     "water_ml", "updated_at", "deleted", "version"]

    init() {}
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        id = r.string("id") ?? "current"
        mode = r.string("mode") ?? "auto"
        plan = r.string("plan") ?? "maintain"
        targets = r.numberMap("targets")
        overrides = r.numberMap("overrides")
        limits = r.value("limits") ?? Array(Nutrients.defaultLimits)
        basis = r.value("basis")
        mealSplit = r.numberMap("meal_split")
        waterMl = r.double("water_ml")
        updatedAt = r.int("updated_at") ?? 0
        deleted = r.bool("deleted") ?? false
        version = r.int("version")
        extra = r.extras(known: Goals.known)
    }
    func encode(to encoder: Encoder) throws {
        var w = RowWriter(encoder)
        try w.put("id", id); try w.put("mode", mode); try w.put("plan", plan); try w.put("targets", targets)
        try w.put("overrides", overrides); try w.put("limits", limits); try w.put("basis", basis)
        try w.put("meal_split", mealSplit); try w.put("water_ml", waterMl); try w.put("updated_at", updatedAt)
        try w.put("deleted", deleted); try w.put("version", version)
        try w.extras(extra, known: Goals.known)
    }

    /// Targets with overrides applied (the server already does this; applying again is harmless).
    var effectiveTargets: [String: Double] { targets.merging(overrides) { _, o in o } }
    func target(_ key: String) -> Double? { effectiveTargets[key].flatMap { $0 > 0 ? $0 : nil } }
    func isLimit(_ key: String) -> Bool { limits.contains(key) }
    var kcal: Double? { target("kcal") }
    /// The kcal target for one meal (meal_split × kcal), or nil when either is missing.
    func mealTarget(_ meal: Meal) -> Double? {
        guard let kcal, let share = mealSplit[meal.rawValue] else { return nil }
        return kcal * share
    }
    var water: Double { waterMl ?? 3000 }
}

// MARK: - Health

struct HealthDay: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var day: String
    var weightKg: Double?
    var activeKcal: Double?
    var basalKcal: Double?
    var steps: Double?
    var exerciseMin: Double?
    var updatedAt = 0
    var deleted = false
    var version: Int?
    var extra: [String: JSONValue] = [:]

    static let known: Set<String> = ["id", "day", "weight_kg", "active_kcal", "basal_kcal", "steps", "exercise_min",
                                     "updated_at", "deleted", "version"]

    init(day: String, weightKg: Double? = nil, activeKcal: Double? = nil, basalKcal: Double? = nil,
         steps: Double? = nil, exerciseMin: Double? = nil) {
        id = day; self.day = day; self.weightKg = weightKg; self.activeKcal = activeKcal
        self.basalKcal = basalKcal; self.steps = steps; self.exerciseMin = exerciseMin
    }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        id = r.string("id") ?? r.string("day") ?? ""
        day = r.string("day") ?? id
        weightKg = r.double("weight_kg"); activeKcal = r.double("active_kcal"); basalKcal = r.double("basal_kcal")
        steps = r.double("steps"); exerciseMin = r.double("exercise_min")
        updatedAt = r.int("updated_at") ?? 0
        deleted = r.bool("deleted") ?? false
        version = r.int("version")
        extra = r.extras(known: HealthDay.known)
    }
    func encode(to encoder: Encoder) throws {
        var w = RowWriter(encoder)
        try w.put("id", id); try w.put("day", day)
        try w.putOrNull("weight_kg", weightKg); try w.putOrNull("active_kcal", activeKcal)
        try w.putOrNull("basal_kcal", basalKcal); try w.putOrNull("steps", steps)
        try w.putOrNull("exercise_min", exerciseMin)
        try w.put("updated_at", updatedAt); try w.put("deleted", deleted); try w.put("version", version)
        try w.extras(extra, known: HealthDay.known)
    }
}

// MARK: - Wire types

/// `GET /v1/sync` response.
struct SyncPayload: Codable, Sendable {
    var version: Int
    /// The server's database is behind `since` (restored): this is a full snapshot that replaces the cache.
    var reset = false
    var foods: [Food] = []
    var entries: [Entry] = []
    var goals: [Goals] = []
    var healthDays: [HealthDay] = []

    init(version: Int, reset: Bool = false, foods: [Food] = [], entries: [Entry] = [], goals: [Goals] = [],
         healthDays: [HealthDay] = []) {
        self.version = version; self.reset = reset; self.foods = foods; self.entries = entries; self.goals = goals; self.healthDays = healthDays
    }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        version = r.int("version") ?? 0
        reset = r.bool("reset") ?? false
        foods = r.value("foods") ?? []
        entries = r.value("entries") ?? []
        goals = r.value("goals") ?? []
        healthDays = r.value("health_days") ?? []
    }
    func encode(to encoder: Encoder) throws {
        var w = RowWriter(encoder)
        try w.put("version", version); if reset { try w.put("reset", reset) }
        try w.put("foods", foods); try w.put("entries", entries)
        try w.put("goals", goals); try w.put("health_days", healthDays)
    }
}

/// One element of `POST /v1/mutations`.
struct Mutation: Codable, Hashable, Sendable {
    var table: String
    /// upsert | delete
    var op: String
    var row: JSONValue

    /// "entries/<id>", used to coalesce repeated writes to one row.
    var key: String {
        if case .object(let o) = row, let id = o["id"]?.string { return "\(table)/\(id)" }
        return "\(table)/?"
    }

    /// Foods this row points at ("foods/<id>"): an entry's food_id and a recipe's components.
    var dependencies: Set<String> {
        guard case .object(let o) = row else { return [] }
        var out: Set<String> = []
        if let f = o["food_id"]?.string { out.insert("foods/\(f)") }
        if case .array(let parts)? = o["components"] {
            for p in parts { if let f = p.object?["food_id"]?.string { out.insert("foods/\(f)") } }
        }
        return out
    }

    static func upsert<T: Encodable>(_ table: Table, _ row: T) -> Mutation {
        Mutation(table: table.rawValue, op: "upsert", row: (try? JSONValue(encoding: row)) ?? .null)
    }
    static func delete(_ table: Table, id: String, at: Int = nowMs()) -> Mutation {
        Mutation(table: table.rawValue, op: "delete",
                 row: .object(["id": .string(id), "updated_at": .number(Double(at)), "deleted": .bool(true)]))
    }
}

/// `GET /v1/suggest` response.
struct Suggestions: Codable, Sendable {
    var recents: [Food] = []
    var frequent: [Food] = []
    var yesterday: [Entry] = []
    init(recents: [Food] = [], frequent: [Food] = [], yesterday: [Entry] = []) {
        self.recents = recents; self.frequent = frequent; self.yesterday = yesterday
    }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        recents = r.value("recents") ?? []
        frequent = r.value("frequent") ?? []
        yesterday = r.value("yesterday") ?? []
    }
}
