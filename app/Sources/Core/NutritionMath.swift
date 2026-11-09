// Serving math, sums and percentages. Pure functions, covered by the logic tests.
import Foundation

enum NutritionMath {
    /// Three decimals, like the server: enough for micrograms of B12 and whole kcal alike.
    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// Every known amount times `factor`. Unknown stays unknown.
    static func scale(_ map: NutrientMap, by factor: Double) -> NutrientMap {
        map.mapValues { round3($0 * factor) }
    }

    /// Sums maps. A key known in any map is known in the result.
    static func sum<S: Sequence>(_ maps: S) -> NutrientMap where S.Element == NutrientMap {
        var out = NutrientMap()
        for map in maps { for (k, v) in map { out[k, default: 0] += v } }
        return out.mapValues(round3)
    }

    /// kcal from macros with 4/4/9 (used by Quick add when kcal is empty).
    static func kcalFromMacros(protein: Double?, carbs: Double?, fat: Double?) -> Double? {
        if protein == nil && carbs == nil && fat == nil { return nil }
        return (protein ?? 0) * 4 + (carbs ?? 0) * 4 + (fat ?? 0) * 9
    }

    /// Each macro's share of kcal (P×4, C×4, F×9), for the stacked preview bar. Sums to 1 when any is known.
    static func macroKcalShares(_ map: NutrientMap) -> (protein: Double, carbs: Double, fat: Double) {
        let p = (map["protein"] ?? 0) * 4, c = (map["carbs"] ?? 0) * 4, f = (map["fat"] ?? 0) * 9
        let total = p + c + f
        guard total > 0 else { return (0, 0, 0) }
        return (p / total, c / total, f / total)
    }

    /// amount / target, or nil without a positive target.
    static func fraction(_ amount: Double?, of target: Double?) -> Double? {
        guard let amount, let target, target > 0 else { return nil }
        return amount / target
    }

    static func percent(_ amount: Double?, of target: Double?) -> Int? {
        fraction(amount, of: target).map { Int(saturating: ($0 * 100).rounded()) }
    }

    /// Exponentially weighted moving average (DESIGN 4.6 weight trend, alpha 0.1).
    static func ewma(_ values: [Double], alpha: Double = 0.1) -> [Double] {
        var out: [Double] = []
        for v in values { out.append(out.last.map { $0 + alpha * (v - $0) } ?? v) }
        return out
    }

    /// Weekly weight rate from the trend line: the trend change over the last 14 days × 0.5.
    /// `points` are (day key, kg) in any order.
    static func weeklyWeightRate(_ points: [(day: String, kg: Double)]) -> Double? {
        let sorted = points.sorted { $0.day < $1.day }
        guard sorted.count >= 3, let last = sorted.last else { return nil }
        let trend = ewma(sorted.map(\.kg))
        let cutoff = Days.add(-14, to: last.day)
        guard let startIndex = sorted.firstIndex(where: { $0.day >= cutoff }), startIndex < sorted.count - 1 else { return nil }
        return (trend[trend.count - 1] - trend[startIndex]) * 0.5
    }
}

// MARK: - Foods and servings

/// How an amount is expressed in the serving picker.
enum AmountUnit: Hashable, Sendable {
    case serving
    case portion(Int)
    case grams
    case ounces
}

extension Food {
    var servingGrams: Double? { serving.grams.flatMap { $0 > 0 ? $0 : nil } }

    /// "container" or "2 slices".
    var servingName: String {
        serving.amount == 1 ? serving.unit : "\(Fmt.trim(serving.amount)) \(serving.unit)"
    }

    /// The serving label stored on entries: "container (170 g)".
    var servingLabel: String {
        if let g = servingGrams, serving.unit != "g" { return "\(servingName) (\(Fmt.grams(g)) g)" }
        return servingName
    }

    /// The serving's name in display units: "container", "2 slices", or "3.5 oz" for a "100 g" serving.
    func servingName(_ u: Units) -> String { Fmt.measureLabel(servingName, grams: servingGrams, u) }

    /// One serving for menus and the scanner, in display units: "container (6 oz)", "3.5 oz".
    /// (`servingLabel` is the stored, metric form.)
    func servingLabel(_ u: Units) -> String {
        let name = servingName(u)
        if let g = servingGrams, !Fmt.isWeightLabel(name) { return "\(name) (\(Fmt.foodWeight(g, u)))" }
        return name
    }

    /// "1 medium · 4.2 oz" for list sublines.
    func servingSummary(_ u: Units) -> String {
        let raw = serving.unit.first?.isNumber == true && serving.amount == 1 ? serving.unit : "\(Fmt.trim(serving.amount)) \(serving.unit)"
        let base = Fmt.measureLabel(raw, grams: servingGrams, u)
        if let g = servingGrams, !Fmt.isWeightLabel(base) { return "\(base) · \(Fmt.foodWeight(g, u))" }
        return base
    }

    func nutrients(servings: Double) -> NutrientMap { NutritionMath.scale(nutrients, by: servings) }

    /// Servings for a weight, when the serving's weight is known.
    func servings(forGrams grams: Double) -> Double? { servingGrams.map { grams / $0 } }

    /// Units the serving picker offers, in DESIGN 4.3 order: serving, portions, then the two weights with
    /// the preferred one first (ounces, grams in US units).
    func amountUnits(_ u: Units) -> [AmountUnit] {
        var out: [AmountUnit] = [.serving]
        if servingGrams != nil {
            out += portions.indices.filter { portions[$0].grams > 0 }.map { .portion($0) }
            out += u.food == .oz ? [.ounces, .grams] : [.grams, .ounces]
        }
        return out
    }

    /// The unit menu's label: "container (6 oz)", "1 cup", "ounces".
    func unitLabel(_ unit: AmountUnit, _ u: Units) -> String {
        switch unit {
        case .serving: servingLabel(u)
        case .portion: unitName(unit, u)
        case .grams: "grams"
        case .ounces: "ounces"
        }
    }

    /// A unit's name without its weight: "container", "1 cup", "3.5 oz" for a "100 g" portion.
    func unitName(_ unit: AmountUnit, _ u: Units) -> String {
        switch unit {
        case .serving: servingName(u)
        case .portion(let i): portions.indices.contains(i) ? Fmt.measureLabel(portions[i].label, grams: portions[i].grams, u) : "portion"
        case .grams: "g"
        case .ounces: "oz"
        }
    }

    /// Where the serving picker starts: one serving, unless the serving is a bare weight in the other
    /// system ("100 g" in US units), which starts at the same weight in the preferred unit (3.53 oz).
    func defaultAmount(_ u: Units) -> (unit: AmountUnit, amount: Double) {
        guard let g = servingGrams, Fmt.isWeightLabel(servingName), servingName(u) != servingName else { return (.serving, 1) }
        return (u.food == .oz ? .ounces : .grams, u.food.fromGrams(g))
    }

    /// Grams in one of `unit`, or nil when unknown.
    func grams(per unit: AmountUnit) -> Double? {
        switch unit {
        case .serving: servingGrams
        case .portion(let i): portions.indices.contains(i) ? portions[i].grams : nil
        case .grams: 1
        case .ounces: 28.349523125
        }
    }

    /// Whether `unit` can be converted to servings (grams, ounces and portions need the serving weight).
    func offers(_ unit: AmountUnit) -> Bool { unit == .serving || amountUnits(.metric).contains(unit) }

    /// The amount and unit to keep when the food no longer offers `unit` (its serving weight went away):
    /// one serving, so grams are never counted as servings.
    func normalized(amount: Double, unit: AmountUnit) -> (amount: Double, unit: AmountUnit) {
        offers(unit) ? (amount, unit) : (1, .serving)
    }

    /// Servings for `amount` of `unit`. A unit that needs the missing serving weight falls back to one serving.
    func servings(amount: Double, unit: AmountUnit) -> Double {
        let n = normalized(amount: amount, unit: unit)
        if n.unit == .serving { return n.amount }
        guard let g = grams(per: n.unit), let per = servingGrams else { return 1 }
        return n.amount * g / per
    }

    /// The amount of `unit` that keeps the same total grams as `servings` (unit changes keep weight).
    func amount(servings: Double, in unit: AmountUnit) -> Double {
        if unit == .serving { return servings }
        guard let g = grams(per: unit), let per = servingGrams, g > 0 else { return servings }
        return servings * per / g
    }

    /// A new entry for `servings` of this food. The food must have an id (save search results first).
    func entry(servings: Double, meal: Meal, day: String, source: String = "app", note: String? = nil) -> Entry {
        let grams = servingGrams.map { NutritionMath.round3($0 * servings) }
        return Entry(day: day, meal: meal, loggedAt: Days.loggedAt(day: day, meal: meal), foodID: id, name: name,
                     brand: brand, servings: NutritionMath.round3(servings), servingLabel: servingLabel, grams: grams,
                     nutrients: nutrients(servings: servings), note: note, source: source)
    }
}

extension Entry {
    /// Scales the snapshot to new servings (SPEC: editing servings scales the snapshot).
    func rescaled(servings newServings: Double) -> Entry {
        guard newServings > 0, newServings.isFinite else { return self }
        let old = servings > 0 ? servings : 1
        let factor = newServings / old
        var e = self
        e.nutrients = NutritionMath.scale(nutrients, by: factor)
        e.servings = NutritionMath.round3(newServings)
        if let g = grams { e.grams = NutritionMath.round3(g * factor) }
        return e
    }

    /// A copy logged again: a new id, on `day` and `meal`, logged now.
    func duplicated(day: String, meal: Meal) -> Entry {
        var e = self
        e.id = UUID().uuidString.lowercased()
        e.day = day
        e.meal = meal
        e.loggedAt = Days.loggedAt(day: day, meal: meal)
        e.updatedAt = nowMs()
        e.deleted = false
        e.version = nil
        e.source = "app"
        e.note = nil
        return e
    }

    /// "1.5 container · 9 oz", "1 medium · 4.2 oz", "8 fl oz" for water, in display units.
    func detailLine(_ u: Units) -> String {
        var parts: [String] = []
        var weightShown = false
        if var label = servingLabel, !label.isEmpty {
            if let r = label.range(of: #" \([\d.,]+ ?g\)$"#, options: .regularExpression) { label.removeSubrange(r) }
            if label == "grams" { label = "g" }
            if let m = Fmt.measure(label) {
                // A bare measure ("g", "100 g", "ml" for water): the line is just the total.
                switch m.unit {
                case "ml", "fl oz":
                    parts.append(Fmt.volume(servings * m.amount * (m.unit == "ml" ? 1 : UnitFactor.mlPerFlOz), u))
                default:
                    let per = m.unit == "g" ? 1 : m.unit == "kg" ? 1000 : m.unit == "oz" ? UnitFactor.gPerOz : UnitFactor.kgPerLb * 1000
                    parts.append(Fmt.foodWeight(grams.flatMap { $0 > 0 ? $0 : nil } ?? servings * m.amount * per, u))
                }
                weightShown = true
            } else if label.first?.isNumber == true {
                parts.append(servings == 1 ? label : "\(Fmt.trim(servings)) × \(label)")
            } else {
                parts.append("\(Fmt.trim(servings)) \(label)")
            }
        } else if servings != 1 {
            parts.append("\(Fmt.trim(servings)) servings")
        }
        if !weightShown, let grams, grams > 0 { parts.append(Fmt.foodWeight(grams, u)) }
        if parts.isEmpty { return note ?? "" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Day summaries

/// Everything Today needs for one day, computed once whenever that day's entries change.
struct DaySummary: Sendable, Equatable {
    var day: String
    /// Food entries (water excluded) per meal, ordered by logged_at.
    var meals: [Meal: [Entry]] = [:]
    var mealTotals: [Meal: NutrientMap] = [:]
    /// All entries including water.
    var totals = NutrientMap()
    /// How many food entries carry each nutrient (for "partial data").
    var coverage: [String: Int] = [:]
    var foodEntryCount = 0
    var waterMl: Double = 0
    var firstLoggedAt: Int?
    var lastLoggedAt: Int?

    var kcal: Double { totals["kcal"] ?? 0 }
    var isEmpty: Bool { foodEntryCount == 0 }
    func entries(_ meal: Meal) -> [Entry] { meals[meal] ?? [] }
    func kcal(_ meal: Meal) -> Double { mealTotals[meal]?["kcal"] ?? 0 }
    /// True when some food entry lacks the nutrient.
    func isPartial(_ key: String) -> Bool { (coverage[key] ?? 0) < foodEntryCount }

    init(day: String, entries: [Entry]) {
        self.day = day
        let live = entries.filter { !$0.deleted && $0.day == day }
        totals = NutritionMath.sum(live.map(\.nutrients))
        for entry in live {
            if entry.isWater {
                waterMl += entry.nutrients["water"] ?? 0
                continue
            }
            meals[entry.meal, default: []].append(entry)
            foodEntryCount += 1
            for key in entry.nutrients.keys { coverage[key, default: 0] += 1 }
            firstLoggedAt = min(firstLoggedAt ?? entry.loggedAt, entry.loggedAt)
            lastLoggedAt = max(lastLoggedAt ?? entry.loggedAt, entry.loggedAt)
        }
        for meal in Meal.allCases {
            meals[meal]?.sort { ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id) }
            mealTotals[meal] = NutritionMath.sum((meals[meal] ?? []).map(\.nutrients))
        }
    }

    /// The lowest target nutrients by percent of target that have data in at least `minEntries` entries.
    func lowest(goals: Goals, count: Int = 3, minEntries: Int = 2) -> [(info: NutrientInfo, percent: Int)] {
        let skip: Set<String> = ["kcal", "protein", "carbs", "fat", "water"]
        let candidates = Nutrients.all.compactMap { info -> (NutrientInfo, Int)? in
            guard !skip.contains(info.key), !goals.isLimit(info.key), (coverage[info.key] ?? 0) >= minEntries,
                  let pct = NutritionMath.percent(totals[info.key], of: goals.target(info.key)) else { return nil }
            return (info, pct)
        }
        return candidates.sorted { $0.1 < $1.1 }.prefix(count).filter { $0.1 < 100 }.map { (info: $0.0, percent: $0.1) }
    }

    /// Limit nutrients past their limit.
    func exceededLimits(goals: Goals) -> [(info: NutrientInfo, amount: Double, limit: Double)] {
        goals.limits.compactMap { key in
            guard let info = Nutrients.info(key), let limit = goals.target(key), let amount = totals[key],
                  amount > limit else { return nil }
            return (info: info, amount: amount, limit: limit)
        }
    }
}

// MARK: - Trends and nutrient detail (wave 2)

/// A Trends range in days (DESIGN 4.6).
enum TrendRange: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case week = 7, month = 30, quarter = 90
    var id: Int { rawValue }
    var label: String { "\(rawValue)D" }
    /// Day keys oldest first, ending on `end`.
    func days(endingAt end: String) -> [String] { (0..<rawValue).reversed().map { Days.add(-$0, to: end) } }
}

/// One nutrient averaged over a range, counting only days that have data for it.
struct NutrientAverage: Sendable, Equatable {
    var key: String
    /// Mean daily amount over `daysWithData`.
    var average: Double
    var target: Double
    var daysWithData: Int
    /// Days whose amount passed the target (for limits: days over the limit).
    var daysOver: Int
    /// Days where some entries lacked the nutrient (the average is then a minimum).
    var partialDays: Int
    var fraction: Double { target > 0 ? average / target : 0 }
    var percent: Int { Int(saturating: (fraction * 100).rounded()) }
}

/// One food's contribution to a nutrient, for "Today's sources".
struct NutrientSource: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var foodID: String?
    var amount: Double
    /// Share of the known total, 0...1.
    var share: Double
    var entries: Int
}

/// Where a nutrient row stands for one day (DESIGN 4.7).
struct NutrientStatus: Sendable, Equatable {
    var key: String
    /// nil when no entry has the nutrient (unknown, not zero).
    var amount: Double?
    var target: Double?
    var isLimit: Bool
    /// Food entries lacking the nutrient, out of `entryCount`.
    var missing: Int
    var entryCount: Int

    var isPartial: Bool { amount != nil && missing > 0 }
    var fraction: Double? { NutritionMath.fraction(amount, of: target) }
    var percent: Int? { NutritionMath.percent(amount, of: target) }
    var isOver: Bool { isLimit && (fraction ?? 0) > 1 }
    var isMet: Bool { !isLimit && (fraction ?? 0) >= 1 }
    /// Amount past a limit.
    var excess: Double? { isOver ? (amount ?? 0) - (target ?? 0) : nil }
}

enum TrendMath {
    /// Mean of the known values, or nil when there are none.
    static func mean(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
    }

    /// Nutrients that sit on Trends' and Today's insight lists: no energy, big macros or water.
    static let insightSkip: Set<String> = ["kcal", "protein", "carbs", "fat", "water"]

    /// Average of `key` over the days with any data for it, or nil without a target or data.
    static func average(_ key: String, over summaries: [DaySummary], goals: Goals) -> NutrientAverage? {
        guard let target = goals.target(key) else { return nil }
        let withData = summaries.filter { !$0.isEmpty && ($0.coverage[key] ?? 0) > 0 }
        guard !withData.isEmpty else { return nil }
        let amounts = withData.map { $0.totals[key] ?? 0 }
        return NutrientAverage(key: key, average: amounts.reduce(0, +) / Double(amounts.count), target: target,
                               daysWithData: withData.count, daysOver: amounts.filter { $0 > target }.count,
                               partialDays: withData.filter { $0.isPartial(key) }.count)
    }

    /// DESIGN 4.6 "Weakest nutrients": the lowest target nutrients by average % of target, limits excluded,
    /// needing data on at least `minDays` days (or on every logged day, when fewer were logged).
    static func weakest(_ summaries: [DaySummary], goals: Goals, count: Int = 5, minDays: Int = 2) -> [NutrientAverage] {
        let logged = summaries.filter { !$0.isEmpty }.count
        let need = max(1, min(minDays, logged))
        return Nutrients.all.compactMap { info -> NutrientAverage? in
            guard !insightSkip.contains(info.key), !goals.isLimit(info.key),
                  let a = average(info.key, over: summaries, goals: goals), a.daysWithData >= need else { return nil }
            return a
        }
        .sorted { ($0.fraction, $0.key) < ($1.fraction, $1.key) }
        .prefix(count).map { $0 }
    }

    /// The limit nutrients (sodium, saturated fat, …) averaged against their limits, in the goals' order.
    static func limits(_ summaries: [DaySummary], goals: Goals) -> [NutrientAverage] {
        goals.limits.compactMap { average($0, over: summaries, goals: goals) }
    }

    /// DESIGN 4.6 nutrient map buckets: 0 below 25%, 1 below 50%, 2 below 100%, 3 at or past the target.
    static func heatBucket(_ fraction: Double) -> Int {
        fraction < 0.25 ? 0 : fraction < 0.5 ? 1 : fraction < 1 ? 2 : 3
    }

    /// Rows for the nutrient map: target nutrients (not limits) most often below target, by the share of
    /// days with data that fell short, then by the lower average. A nutrient needs data on `minCoverage` of
    /// the logged days (and at least two), so rows aren't mostly empty cells.
    static func heatmapKeys(_ summaries: [DaySummary], goals: Goals, count: Int = 12, minCoverage: Double = 0.4) -> [String] {
        let logged = summaries.filter { !$0.isEmpty }.count
        let need = max(2, Int(saturating: (Double(logged) * minCoverage).rounded(.up)))
        let scored = Nutrients.all.compactMap { info -> (key: String, short: Double, frac: Double)? in
            guard !insightSkip.contains(info.key), !goals.isLimit(info.key), let target = goals.target(info.key) else { return nil }
            let withData = summaries.filter { !$0.isEmpty && ($0.coverage[info.key] ?? 0) > 0 }
            guard withData.count >= min(need, max(logged, 1)) else { return nil }
            let below = withData.filter { ($0.totals[info.key] ?? 0) < target }.count
            let frac = withData.map { ($0.totals[info.key] ?? 0) / target }.reduce(0, +) / Double(withData.count)
            return (info.key, Double(below) / Double(withData.count), frac)
        }
        return scored.sorted { a, b in a.short != b.short ? a.short > b.short : (a.frac, a.key) < (b.frac, b.key) }
            .prefix(count).map(\.key)
    }

    /// The fraction of target for one day, or nil when the day has no data for the nutrient.
    static func dayFraction(_ summary: DaySummary, _ key: String, target: Double) -> Double? {
        guard !summary.isEmpty, (summary.coverage[key] ?? 0) > 0, target > 0 else { return nil }
        return (summary.totals[key] ?? 0) / target
    }

    /// Groups consecutive days into weeks ending on the last day (the 90-day nutrient map shows weeks).
    static func chunks<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0, !items.isEmpty else { return [] }
        var out: [[T]] = []
        var end = items.count
        while end > 0 {
            out.insert(Array(items[max(0, end - size)..<end]), at: 0)
            end -= size
        }
        return out
    }

    /// The weight trend (EWMA, alpha 0.1) over every weigh-in, oldest first, so a short range starts from
    /// a trend seeded by earlier history.
    static func weightTrend(_ points: [(day: String, kg: Double)], alpha: Double = 0.1) -> [(day: String, kg: Double, trend: Double)] {
        let sorted = points.sorted { $0.day < $1.day }
        let trend = NutritionMath.ewma(sorted.map(\.kg), alpha: alpha)
        return zip(sorted, trend).map { (day: $0.0.day, kg: $0.0.kg, trend: $0.1) }
    }

    /// The average macro split over logged days, as shares of macro kcal (P×4, C×4, F×9).
    static func macroSplit(_ summaries: [DaySummary]) -> (protein: Double, carbs: Double, fat: Double) {
        NutritionMath.macroKcalShares(NutritionMath.sum(summaries.filter { !$0.isEmpty }.map(\.totals)))
    }

    /// Entries ranked by their contribution to `key`, grouped by food (or by name for quick entries).
    static func topSources(_ entries: [Entry], key: String, limit: Int = 8) -> [NutrientSource] {
        var groups: [String: NutrientSource] = [:]
        var order: [String] = []
        for e in entries where !e.deleted {
            guard let v = e.nutrients[key], v > 0 else { continue }
            let id = e.foodID ?? "n:" + e.name.lowercased()
            if groups[id] == nil {
                groups[id] = NutrientSource(id: id, name: e.name, foodID: e.foodID, amount: 0, share: 0, entries: 0)
                order.append(id)
            }
            groups[id]!.amount += v
            groups[id]!.entries += 1
        }
        let total = groups.values.map(\.amount).reduce(0, +)
        return order.compactMap { groups[$0] }
            .map { var s = $0; s.share = total > 0 ? s.amount / total : 0; return s }
            .sorted { ($0.amount, $1.name) > ($1.amount, $0.name) }
            .prefix(limit).map { $0 }
    }

    /// DESIGN 4.7 "Your best sources": own foods and recipes by amount of `key` per 100 kcal.
    static func bestSources(_ foods: [Food], key: String, limit: Int = 8) -> [(food: Food, per100kcal: Double)] {
        foods.compactMap { f -> (food: Food, per100kcal: Double)? in
            guard !f.deleted, let amount = f.nutrients[key], amount > 0, let kcal = f.kcal, kcal >= 10 else { return nil }
            return (f, amount / kcal * 100)
        }
        .sorted { ($0.per100kcal, $1.food.name) > ($1.per100kcal, $0.food.name) }
        .prefix(limit).map { $0 }
    }
}

extension DaySummary {
    /// Every food entry of the day (water excluded), in meal order.
    var foodEntries: [Entry] { Meal.allCases.flatMap { entries($0) } }

    /// The DESIGN 4.7 row state for one nutrient. Water counts water entries; nothing else does.
    func status(_ key: String, goals: Goals?) -> NutrientStatus {
        if key == "water" {
            let ml = totals["water"]
            return NutrientStatus(key: key, amount: ml, target: goals?.target("water") ?? goals?.waterMl,
                                  isLimit: false, missing: 0, entryCount: foodEntryCount)
        }
        let covered = coverage[key] ?? 0
        return NutrientStatus(key: key, amount: covered > 0 ? (totals[key] ?? 0) : nil, target: goals?.target(key),
                              isLimit: goals?.isLimit(key) ?? false, missing: max(0, foodEntryCount - covered),
                              entryCount: foodEntryCount)
    }
}
