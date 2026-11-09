// A realistic, deterministic fixture for `-PlateDemo YES`: 90 days of entries across meals with
// micronutrients (with gaps, light days and macro-only quick adds), auto goals with a basis, 120 health
// days with a slow weight drift, foods, recipes and a small search catalog.
import Foundation

enum DemoData {
    private struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
        mutating func chance(_ p: Double) -> Bool { next() < p }
    }

    private static func food(_ id: String, _ name: String, brand: String? = nil, unit: String, amount: Double = 1,
                             grams: Double?, portions: [Portion] = [], source: String = "usda", ref: String? = nil,
                             fav: Bool = false, barcode: String? = nil, _ n: NutrientMap) -> Food {
        var f = Food(id: "demo-\(id)", name: name, brand: brand, barcode: barcode,
                     serving: Serving(amount: amount, unit: unit, grams: grams), portions: portions,
                     nutrients: n, source: source, sourceRef: ref, favorite: fav)
        f.createdAt = 1_760_000_000_000
        f.updatedAt = 1_760_000_000_000
        return f
    }

    static let foods: [Food] = [
        food("yogurt", "Greek yogurt, plain nonfat", brand: "Fage", unit: "container", grams: 170,
             portions: [Portion(label: "1 cup", grams: 245), Portion(label: "100 g", grams: 100)],
             source: "off", ref: "off:0689544001737", fav: true, barcode: "0689544001737",
             ["kcal": 90, "protein": 18, "carbs": 6, "fat": 0, "sugar": 6, "added_sugar": 0, "sat_fat": 0,
              "cholesterol": 10, "sodium": 65, "calcium": 200, "potassium": 240, "vit_b12": 1.3, "riboflavin": 0.4,
              "phosphorus": 230, "selenium": 16, "zinc": 1, "iodine": 50]),
        food("banana", "Banana", unit: "medium", grams: 118,
             portions: [Portion(label: "1 large", grams: 136), Portion(label: "1 cup sliced", grams: 150)],
             ref: "fdc:173944",
             ["kcal": 105, "protein": 1.3, "carbs": 27, "fat": 0.4, "fiber": 3.1, "sugar": 14.4, "potassium": 422,
              "magnesium": 32, "vit_c": 10.3, "vit_b6": 0.43, "folate": 24, "manganese": 0.32, "sodium": 1]),
        food("oats", "Rolled oats", brand: "Bob's Red Mill", unit: "cup", amount: 0.5, grams: 40,
             portions: [Portion(label: "1 cup", grams: 80)], source: "off", ref: "off:0039978003829", fav: true,
             ["kcal": 150, "protein": 5, "carbs": 27, "fat": 3, "fiber": 4, "sugar": 1, "iron": 1.8,
              "magnesium": 55, "phosphorus": 180, "zinc": 1.5, "thiamin": 0.2, "manganese": 1.9, "sodium": 0]),
        food("whey", "Whey protein, vanilla", brand: "Optimum Nutrition", unit: "scoop", grams: 31,
             source: "off", ref: "off:0748927028669", fav: true,
             ["kcal": 120, "protein": 24, "carbs": 3, "fat": 1.5, "sugar": 1, "added_sugar": 1, "sat_fat": 0.5,
              "cholesterol": 35, "sodium": 130, "calcium": 130, "potassium": 160]),
        food("eggs", "Egg, whole, scrambled", unit: "large egg", grams: 61, ref: "fdc:172186",
             ["kcal": 91, "protein": 6.1, "carbs": 1, "fat": 6.7, "sat_fat": 2, "cholesterol": 169, "sodium": 88,
              "vit_d": 1.1, "vit_b12": 0.5, "choline": 128, "selenium": 13, "riboflavin": 0.23, "vit_a": 80,
              "iron": 0.8, "phosphorus": 100, "folate": 22]),
        food("toast", "Sourdough toast", unit: "slice", grams: 50, ref: "fdc:172686",
             ["kcal": 130, "protein": 5, "carbs": 25, "fat": 1, "fiber": 1, "sugar": 1, "sodium": 270, "iron": 1.6,
              "thiamin": 0.25, "folate": 60, "selenium": 15]),
        food("avocado", "Avocado", unit: "half", grams: 68, ref: "fdc:171705",
             ["kcal": 114, "protein": 1.3, "carbs": 6, "fat": 10.5, "fiber": 4.6, "sat_fat": 1.5, "mono_fat": 6.7,
              "poly_fat": 1.2, "potassium": 345, "vit_k": 14, "folate": 55, "vit_e": 1.4, "magnesium": 20,
              "vit_c": 6, "vit_b6": 0.18, "pantothenic": 0.95, "sodium": 5]),
        food("coffee", "Latte, oat milk", brand: "Starbucks", unit: "grande", grams: 473, source: "off",
             ref: "off:starbucks-oat-latte",
             ["kcal": 270, "protein": 3, "carbs": 37, "fat": 11, "fiber": 2, "sugar": 18, "added_sugar": 8,
              "sat_fat": 1, "sodium": 180, "calcium": 350, "potassium": 300, "caffeine": 150, "vit_d": 2.5]),
        food("chipotle", "Chicken burrito bowl", brand: "Chipotle", unit: "bowl", grams: 520, source: "agent",
             ["kcal": 710, "protein": 54, "carbs": 70, "fat": 23, "fiber": 13, "sugar": 5, "sat_fat": 8,
              "cholesterol": 125, "sodium": 1890, "potassium": 1100, "iron": 6, "calcium": 220, "vit_c": 25,
              "vit_a": 120, "magnesium": 110]),
        food("wrap", "Turkey wrap", unit: "wrap", grams: 250, source: "custom",
             ["kcal": 480, "protein": 32, "carbs": 44, "fat": 18, "fiber": 4, "sugar": 4, "sat_fat": 6,
              "cholesterol": 70, "sodium": 1240, "potassium": 420, "calcium": 180, "iron": 3]),
        food("salmon", "Atlantic salmon, baked", unit: "fillet", grams: 154,
             portions: [Portion(label: "3 oz", grams: 85)], ref: "fdc:175168",
             ["kcal": 280, "protein": 39, "carbs": 0, "fat": 12.5, "sat_fat": 2, "mono_fat": 4.2, "poly_fat": 4.5,
              "omega3": 2.6, "cholesterol": 109, "sodium": 86, "potassium": 960, "vit_d": 17, "vit_b12": 4.4,
              "selenium": 63, "niacin": 13, "vit_b6": 1.4, "phosphorus": 400, "magnesium": 50]),
        food("rice", "Jasmine rice, cooked", unit: "cup", grams: 158, portions: [Portion(label: "100 g", grams: 100)],
             ref: "fdc:169756",
             ["kcal": 205, "protein": 4.3, "carbs": 45, "fat": 0.4, "fiber": 0.6, "sodium": 2, "iron": 1.9,
              "thiamin": 0.26, "folate": 92, "manganese": 0.7, "selenium": 12, "magnesium": 19]),
        food("broccoli", "Broccoli, steamed", unit: "cup", grams: 156, ref: "fdc:169967",
             ["kcal": 55, "protein": 3.7, "carbs": 11, "fat": 0.6, "fiber": 5.1, "sugar": 2.2, "vit_c": 101,
              "vit_k": 220, "folate": 168, "potassium": 457, "calcium": 62, "vit_a": 120, "iron": 1, "sodium": 64,
              "manganese": 0.3]),
        food("chicken", "Chicken breast, grilled", unit: "breast", grams: 172,
             portions: [Portion(label: "100 g", grams: 100), Portion(label: "4 oz", grams: 113)], ref: "fdc:171477",
             ["kcal": 284, "protein": 53, "carbs": 0, "fat": 6.2, "sat_fat": 1.7, "cholesterol": 146, "sodium": 127,
              "potassium": 440, "niacin": 23, "vit_b6": 1, "selenium": 47, "phosphorus": 390, "zinc": 1.7]),
        food("pasta", "Spaghetti with marinara", unit: "plate", grams: 350, source: "agent",
             ["kcal": 620, "protein": 21, "carbs": 104, "fat": 13, "fiber": 8, "sugar": 14, "sat_fat": 2.5,
              "sodium": 980, "potassium": 760, "iron": 5, "vit_c": 18, "vit_a": 90, "calcium": 90]),
        food("apple", "Apple", unit: "medium", grams: 182, ref: "fdc:171688",
             ["kcal": 95, "protein": 0.5, "carbs": 25, "fat": 0.3, "fiber": 4.4, "sugar": 19, "vit_c": 8.4,
              "potassium": 195, "vit_k": 4, "sodium": 2]),
        food("almonds", "Almonds", unit: "oz", grams: 28, portions: [Portion(label: "23 almonds", grams: 28)],
             ref: "fdc:170567", fav: true,
             ["kcal": 164, "protein": 6, "carbs": 6, "fat": 14, "fiber": 3.5, "sugar": 1.2, "sat_fat": 1.1,
              "mono_fat": 8.8, "poly_fat": 3.5, "vit_e": 7.3, "magnesium": 77, "calcium": 76, "riboflavin": 0.3,
              "manganese": 0.6, "copper": 0.3, "potassium": 208, "sodium": 0]),
        food("bar", "Protein bar, chocolate chip", brand: "RXBAR", unit: "bar", grams: 52, source: "off",
             ref: "off:0857777004019", barcode: "0857777004019",
             ["kcal": 210, "protein": 12, "carbs": 24, "fat": 9, "fiber": 5, "sugar": 13, "added_sugar": 0,
              "sat_fat": 2, "sodium": 260, "potassium": 250, "iron": 1.5, "calcium": 40]),
        food("milk", "Milk, 2%", unit: "cup", grams: 244, ref: "fdc:171265",
             ["kcal": 122, "protein": 8, "carbs": 12, "fat": 4.8, "sugar": 12, "sat_fat": 3, "cholesterol": 20,
              "sodium": 115, "calcium": 293, "vit_d": 2.9, "vit_b12": 1.3, "potassium": 342, "riboflavin": 0.45,
              "vit_a": 134, "iodine": 85]),
        food("pizza", "Pizza, cheese, regular crust", unit: "slice", grams: 107, ref: "fdc:2344717",
             ["kcal": 285, "protein": 12, "carbs": 36, "fat": 10, "fiber": 2.5, "sugar": 3.8, "sat_fat": 4.5,
              "cholesterol": 18, "sodium": 640, "calcium": 190, "iron": 2.6, "potassium": 180]),
        food("berries", "Blueberries", unit: "cup", grams: 148, ref: "fdc:171711",
             ["kcal": 84, "protein": 1.1, "carbs": 21, "fat": 0.5, "fiber": 3.6, "sugar": 15, "vit_c": 14,
              "vit_k": 29, "manganese": 0.5, "potassium": 114, "sodium": 1]),
        food("cheese", "Cheddar cheese", unit: "slice", grams: 28, ref: "fdc:173414",
             ["kcal": 113, "protein": 7, "carbs": 0.4, "fat": 9.3, "sat_fat": 5.3, "cholesterol": 29, "sodium": 182,
              "calcium": 200, "vit_a": 74, "phosphorus": 128, "zinc": 1]),
    ]

    /// Recipes and the extra Library foods live in DemoLibrary.swift.
    static var allFoods: [Food] { foods + libraryFoods + recipes }

    /// Search results the demo "server" returns for catalog and product queries.
    static let catalog: [Food] = {
        func c(_ name: String, brand: String? = nil, unit: String, grams: Double, source: String, ref: String,
               _ n: NutrientMap) -> Food {
            var f = Food(id: nil, name: name, brand: brand, serving: Serving(amount: 1, unit: unit, grams: grams),
                         portions: [Portion(label: "100 g", grams: 100)], nutrients: n, source: source, sourceRef: ref)
            f.createdAt = 0; f.updatedAt = 0
            return f
        }
        return [
            c("Banana, raw", unit: "cup sliced", grams: 150, source: "usda", ref: "fdc:173945",
              ["kcal": 134, "protein": 1.6, "carbs": 34, "fat": 0.5, "fiber": 3.9, "potassium": 537]),
            c("Banana bread", unit: "slice", grams: 60, source: "usda", ref: "fdc:174987",
              ["kcal": 196, "protein": 2.6, "carbs": 33, "fat": 6.3, "fiber": 0.7, "sugar": 19]),
            c("Banana chips", unit: "oz", grams: 28, source: "usda", ref: "fdc:171928",
              ["kcal": 147, "protein": 0.6, "carbs": 17, "fat": 9.5, "fiber": 2.2]),
            c("Protein shake, banana", brand: "Fairlife", unit: "bottle", grams: 340, source: "off", ref: "off:0811620021586",
              ["kcal": 150, "protein": 30, "carbs": 4, "fat": 2.5, "calcium": 700]),
            c("Banana Nut Cheerios", brand: "General Mills", unit: "cup", grams: 37, source: "off", ref: "off:0016000124790",
              ["kcal": 140, "protein": 2, "carbs": 30, "fat": 1.5, "fiber": 2, "added_sugar": 12]),
            c("Chicken thigh, roasted", unit: "thigh", grams: 116, source: "usda", ref: "fdc:172384",
              ["kcal": 255, "protein": 29, "carbs": 0, "fat": 15, "sodium": 100]),
            c("Chicken noodle soup", unit: "cup", grams: 248, source: "usda", ref: "fdc:174546",
              ["kcal": 62, "protein": 3.2, "carbs": 7.4, "fat": 2.4, "sodium": 865]),
            c("Oatmeal, cooked", unit: "cup", grams: 234, source: "usda", ref: "fdc:173905",
              ["kcal": 166, "protein": 5.9, "carbs": 28, "fat": 3.6, "fiber": 4]),
            c("Coffee, brewed", unit: "cup", grams: 237, source: "usda", ref: "fdc:171890",
              ["kcal": 2, "protein": 0.3, "carbs": 0, "fat": 0, "caffeine": 95]),
        ]
    }()

    static var goals: Goals {
        var g = Goals()
        g.mode = "auto"
        g.plan = "maintain"
        var targets: [String: Double] = ["kcal": 2350, "protein": 150, "carbs": 260, "fat": 78, "fiber": 33]
        for info in Nutrients.all where !["kcal", "protein", "carbs", "fat", "fiber"].contains(info.key) {
            if let v = info.rda?.male ?? info.dv { targets[info.key] = v }
        }
        g.targets = targets
        g.overrides = [:]
        g.limits = ["sodium", "sat_fat", "added_sugar", "cholesterol"]
        var b = GoalBasis()
        b.weightKg = 72.1; b.heightCm = 178; b.age = 22; b.sex = "male"; b.bmr = 1720
        b.activeKcalAvg14 = 520; b.tdee = 2400; b.computedAt = nowMs() - 12 * 60_000
        g.basis = b
        g.mealSplit = ["breakfast": 0.25, "lunch": 0.35, "dinner": 0.3, "snack": 0.1]
        g.waterMl = 3000
        g.updatedAt = nowMs()
        return g
    }

    /// Entries for the 13 days before today plus a partly logged today.
    static func entries(today: String = Days.today) -> [Entry] {
        var rng = RNG(state: 42)
        let byID = Dictionary(uniqueKeysWithValues: allFoods.map { ($0.id!, $0) })
        func log(_ id: String, _ servings: Double, _ meal: Meal, _ day: String, hour: Double,
                 source: String = "app", note: String? = nil) -> Entry {
            var e = byID["demo-" + id]!.entry(servings: servings, meal: meal, day: day, source: source, note: note)
            let start = Days.calendar.startOfDay(for: Days.date(day))
            e.loggedAt = Int(start.addingTimeInterval(hour * 3600).timeIntervalSince1970 * 1000)
            e.updatedAt = e.loggedAt
            return e
        }
        func water(_ ml: Double, _ day: String, hour: Double) -> Entry {
            var e = Entry(day: day, meal: .snack, name: "Water", servingLabel: "ml", nutrients: ["water": ml])
            e.servings = ml
            let start = Days.calendar.startOfDay(for: Days.date(day))
            e.loggedAt = Int(start.addingTimeInterval(hour * 3600).timeIntervalSince1970 * 1000)
            e.updatedAt = e.loggedAt
            return e
        }

        var out: [Entry] = []
        let breakfasts: [[(String, Double)]] = [[("yogurt", 1.5), ("banana", 1)], [("oats", 1), ("whey", 1), ("berries", 0.5)],
                                                [("eggs", 3), ("toast", 2), ("avocado", 1)], [("recipe-oats", 1)],
                                                [("yogurt", 1), ("almonds", 1), ("coffee", 1)]]
        let lunches: [[(String, Double)]] = [[("chipotle", 1)], [("wrap", 1), ("apple", 1)], [("recipe-bowl", 1)],
                                             [("pizza", 2)], [("chicken", 1), ("rice", 1), ("broccoli", 1)]]
        let dinners: [[(String, Double)]] = [[("salmon", 1), ("rice", 1), ("broccoli", 1)], [("pasta", 1)],
                                             [("recipe-bowl", 1.5)], [("chicken", 1), ("rice", 1.5)],
                                             [("pizza", 3)], [("chipotle", 1)]]
        let snacks: [[(String, Double)]] = [[("bar", 1)], [("almonds", 1)], [("apple", 1), ("cheese", 1)],
                                            [("whey", 1), ("milk", 1)], [("berries", 1)]]

        for back in stride(from: 13, through: 1, by: -1) {
            let day = Days.add(-back, to: today)
            let skipDay = back == 9 // one gap day, so trends show a blank
            if skipDay { continue }
            let b = breakfasts[Int(rng.range(0, Double(breakfasts.count)))]
            for (id, s) in b { out.append(log(id, s, .breakfast, day, hour: rng.range(7.5, 9.5))) }
            let l = lunches[Int(rng.range(0, Double(lunches.count)))]
            for (id, s) in l {
                let agent = id == "chipotle" || rng.chance(0.3)
                out.append(log(id, s, .lunch, day, hour: rng.range(12, 13.5), source: agent ? "agent" : "app",
                               note: agent ? "from photo" : nil))
            }
            let d = dinners[Int(rng.range(0, Double(dinners.count)))]
            for (id, s) in d {
                let agent = rng.chance(0.4)
                out.append(log(id, s, .dinner, day, hour: rng.range(18.5, 20), source: agent ? "agent" : "app",
                               note: agent ? (rng.chance(0.6) ? "from photo" : "from description") : nil))
            }
            if rng.chance(0.75) {
                let s = snacks[Int(rng.range(0, Double(snacks.count)))]
                for (id, n) in s { out.append(log(id, n, .snack, day, hour: rng.range(15, 16.5))) }
            }
            var ml = 0.0
            while ml < rng.range(1800, 3200) {
                let amount = [250.0, 500, 330][Int(rng.range(0, 3))]
                out.append(water(amount, day, hour: 8 + ml / 300))
                ml += amount
            }
        }
        // Older history (wave 2 Trends): days 14 to 89 back, from its own generator so the recent two weeks
        // above stay the same. A long weekend off, a few random gaps, light days, and macro-only quick adds
        // (partial micronutrient data).
        var hist = RNG(state: 2026)
        for back in stride(from: 89, through: 14, by: -1) {
            let day = Days.add(-back, to: today)
            if (41...43).contains(back) || hist.chance(0.06) { continue }
            let light = hist.chance(0.12)
            if !light {
                let b = breakfasts[Int(hist.range(0, Double(breakfasts.count)))]
                for (id, s) in b { out.append(log(id, s, .breakfast, day, hour: hist.range(7.5, 9.5))) }
            }
            let l = lunches[Int(hist.range(0, Double(lunches.count)))]
            for (id, s) in l { out.append(log(id, s, .lunch, day, hour: hist.range(12, 13.5), source: "agent", note: "from photo")) }
            if hist.chance(0.15) {
                var q = Entry(day: day, meal: .dinner, name: "Dinner out", nutrients: ["kcal": hist.range(750, 1100).rounded(),
                              "protein": hist.range(35, 60).rounded(), "carbs": hist.range(70, 110).rounded(),
                              "fat": hist.range(25, 45).rounded()], source: "agent")
                let start = Days.calendar.startOfDay(for: Days.date(day))
                q.loggedAt = Int(start.addingTimeInterval(19.5 * 3600).timeIntervalSince1970 * 1000)
                q.updatedAt = q.loggedAt
                out.append(q)
            } else {
                let d = dinners[Int(hist.range(0, Double(dinners.count)))]
                for (id, s) in d { out.append(log(id, s, .dinner, day, hour: hist.range(18.5, 20))) }
            }
            if !light && hist.chance(0.7) {
                let s = snacks[Int(hist.range(0, Double(snacks.count)))]
                for (id, n) in s { out.append(log(id, n, .snack, day, hour: hist.range(15, 16.5))) }
            }
        }
        // A protein shake on the evenings of the last five days, so Trends has a streak to show.
        for back in 1...5 { out.append(log("whey", 1, .snack, Days.add(-back, to: today), hour: 21)) }
        // The day before today always has a dinner, so "Copy yesterday's dinner" shows on today.
        let yesterday = Days.add(-1, to: today)
        if !out.contains(where: { $0.day == yesterday && $0.meal == .dinner }) {
            out.append(log("salmon", 1, .dinner, yesterday, hour: 19))
        }
        // Today: breakfast and lunch are in, dinner is still empty.
        out.append(log("yogurt", 1.5, .breakfast, today, hour: 8.6, source: "agent", note: "from photo"))
        out.append(log("banana", 1, .breakfast, today, hour: 8.7))
        out.append(log("coffee", 1, .breakfast, today, hour: 9.1, source: "barcode"))
        out.append(log("wrap", 1, .lunch, today, hour: 12.4, source: "agent", note: "from description"))
        out.append(log("apple", 1, .lunch, today, hour: 12.5))
        out.append(log("almonds", 1, .snack, today, hour: 15.5))
        out.append(water(500, today, hour: 8))
        out.append(water(500, today, hour: 11))
        out.append(water(250, today, hour: 13))
        return out
    }

    static func healthDays(today: String = Days.today) -> [HealthDay] {
        var rng = RNG(state: 7)
        var out: [HealthDay] = []
        for back in stride(from: 119, through: 0, by: -1) {
            let day = Days.add(-back, to: today)
            // A slow cut: about 74.6 kg four months ago down to 72.1 today, with a plateau in the middle.
            let t = Double(119 - back)
            let trend = 74.6 - min(t, 50) * 0.022 - max(0, t - 70) * 0.0255
            let travelling = (50...58).contains(back)
            let weighed = back == 0 || (!travelling && rng.chance(0.72))
            let weight: Double? = weighed ? (trend + rng.range(-0.4, 0.4)).rounded(toPlaces: 1) : nil
            let watchOff = back == 12 || back == 33
            var h = HealthDay(day: day, weightKg: back == 0 ? 72.1 : weight,
                              activeKcal: back == 0 ? 540 : (watchOff ? nil : rng.range(320, 720).rounded()),
                              basalKcal: 1700, steps: back == 0 ? 9123 : (watchOff ? nil : rng.range(4800, 13500).rounded()),
                              exerciseMin: rng.range(10, 60).rounded())
            h.updatedAt = nowMs()
            out.append(h)
        }
        return out
    }

    static func database(today: String = Days.today) -> LocalDatabase {
        var db = LocalDatabase()
        db.version = 18_204
        for f in allFoods { db.put(f) }
        for e in entries(today: today) { db.put(e) }
        db.goals = goals
        for h in healthDays(today: today) { db.healthDays[h.id] = h }
        return db
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let m = pow(10, Double(places))
        return (self * m).rounded() / m
    }
}
