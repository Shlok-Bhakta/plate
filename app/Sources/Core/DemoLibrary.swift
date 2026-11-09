// The Library side of the `-PlateDemo YES` fixture: extra custom, agent and barcode foods, and recipes
// whose nutrients come from their components (RecipeMath), as the server would compute them.
import Foundation

extension DemoData {
    private static func libraryFood(_ id: String, _ name: String, brand: String? = nil, kind: FoodKind = .food,
                                    unit: String, amount: Double = 1, grams: Double?, portions: [Portion] = [],
                                    source: String, ref: String? = nil, fav: Bool = false, barcode: String? = nil,
                                    created daysAgo: Int, _ n: NutrientMap) -> Food {
        var f = Food(id: "demo-\(id)", kind: kind, name: name, brand: brand, barcode: barcode,
                     serving: Serving(amount: amount, unit: unit, grams: grams), portions: portions,
                     nutrients: n, source: source, sourceRef: ref, favorite: fav)
        f.createdAt = 1_762_600_000_000 - daysAgo * 86_400_000
        f.updatedAt = f.createdAt
        return f
    }

    /// Ingredients for the demo recipes, plus foods made by hand, by the agent, and from barcodes.
    static let libraryFoods: [Food] = [
        libraryFood("turkey", "Ground turkey, 93% lean", brand: "Jennie-O", unit: "oz", amount: 4, grams: 112,
                    portions: [Portion(label: "1 lb pack", grams: 454)], source: "off", ref: "off:0042222101107",
                    barcode: "0042222101107", created: 20,
                    ["kcal": 170, "protein": 22, "carbs": 0, "fat": 9, "sat_fat": 2.5, "cholesterol": 80, "sodium": 90,
                     "iron": 1.2, "zinc": 2.6, "niacin": 6, "vit_b12": 1.5, "selenium": 25, "potassium": 280]),
        libraryFood("beans", "Black beans, canned, drained", unit: "cup", amount: 0.5, grams: 130,
                    portions: [Portion(label: "1 can (drained)", grams: 260)], source: "usda", ref: "fdc:175188", created: 20,
                    ["kcal": 114, "protein": 7.6, "carbs": 20, "fat": 0.5, "fiber": 7.5, "sugar": 0.3, "sodium": 200,
                     "potassium": 305, "iron": 1.8, "magnesium": 60, "folate": 128, "zinc": 1]),
        libraryFood("tomatoes", "Crushed tomatoes", brand: "Muir Glen", unit: "cup", amount: 0.5, grams: 121,
                    portions: [Portion(label: "1 can", grams: 794)], source: "off", ref: "off:0725342260416",
                    barcode: "0725342260416", created: 20,
                    ["kcal": 40, "protein": 2, "carbs": 8, "fat": 0, "fiber": 2, "sugar": 5, "sodium": 220,
                     "potassium": 400, "vit_c": 10, "iron": 1.4]),
        libraryFood("onion", "Yellow onion", unit: "medium", grams: 110, source: "usda", ref: "fdc:170000", created: 20,
                    ["kcal": 44, "protein": 1.2, "carbs": 10, "fat": 0.1, "fiber": 1.9, "sugar": 4.7, "vit_c": 8,
                     "potassium": 160, "sodium": 4, "folate": 21, "vit_b6": 0.13]),
        libraryFood("oil", "Olive oil, extra virgin", unit: "tbsp", grams: 13.5, source: "usda", ref: "fdc:171413", created: 30,
                    ["kcal": 119, "protein": 0, "carbs": 0, "fat": 13.5, "sat_fat": 1.9, "mono_fat": 9.9, "poly_fat": 1.4,
                     "vit_e": 1.9, "vit_k": 8.1, "sodium": 0]),
        libraryFood("spinach", "Baby spinach", unit: "cup", grams: 30, source: "usda", ref: "fdc:168462", created: 12,
                    ["kcal": 7, "protein": 0.9, "carbs": 1.1, "fat": 0.1, "fiber": 0.7, "iron": 0.8, "vit_k": 145,
                     "vit_a": 141, "folate": 58, "potassium": 167, "magnesium": 24, "vit_c": 8.4, "sodium": 24]),
        libraryFood("pb", "Peanut butter, creamy", brand: "Smucker's Natural", unit: "tbsp", amount: 2, grams: 32,
                    source: "off", ref: "off:0051500255162", barcode: "0051500255162", created: 12,
                    ["kcal": 190, "protein": 7, "carbs": 7, "fat": 16, "fiber": 2, "sugar": 2, "sat_fat": 2.5,
                     "sodium": 110, "magnesium": 50, "niacin": 4.3, "vit_e": 2.9, "potassium": 210]),
        libraryFood("granola", "Homemade granola", unit: "cup", amount: 0.5, grams: 60, source: "custom", created: 8,
                    ["kcal": 280, "protein": 7, "carbs": 32, "fat": 14, "fiber": 4, "sugar": 10]),
        libraryFood("dal", "Mom's masoor dal", unit: "bowl", grams: 300, source: "agent", ref: "agent:moms-masoor-dal",
                    created: 6,
                    ["kcal": 330, "protein": 18, "carbs": 48, "fat": 8, "fiber": 12, "sodium": 540, "iron": 5,
                     "potassium": 700, "folate": 250, "magnesium": 70]),
        libraryFood("matcha", "Iced matcha latte, oat milk", kind: .quick, unit: "serving", grams: nil, source: "agent",
                    ref: "agent:iced-matcha-latte", created: 4,
                    ["kcal": 190, "protein": 3, "carbs": 30, "fat": 6]),
        libraryFood("pancakes", "Protein pancakes", unit: "stack", grams: 220, source: "agent",
                    ref: "agent:protein-pancakes", created: 3,
                    ["kcal": 420, "protein": 32, "carbs": 48, "fat": 11, "fiber": 4, "sugar": 9, "sodium": 690,
                     "calcium": 250]),
        libraryFood("skyr", "Icelandic skyr, vanilla", brand: "Siggi's", unit: "container", grams: 150, source: "off",
                    ref: "off:0898248001336", barcode: "0898248001336", created: 10,
                    ["kcal": 110, "protein": 15, "carbs": 11, "fat": 0, "sugar": 9, "added_sugar": 5, "calcium": 150,
                     "sodium": 55, "potassium": 210]),
        libraryFood("kombucha", "Kombucha, ginger lemon", brand: "GT's", unit: "bottle", grams: 480, source: "off",
                    ref: "off:0722430240169", barcode: "0722430240169", created: 5,
                    ["kcal": 50, "protein": 0, "carbs": 12, "fat": 0, "sugar": 10, "sodium": 20]),
        libraryFood("tortilla", "Flour tortilla, large", brand: "Mission", unit: "tortilla", grams: 70, source: "off",
                    ref: "off:0073731001059", barcode: "0073731001059", created: 15,
                    ["kcal": 210, "protein": 6, "carbs": 35, "fat": 5, "fiber": 2, "sodium": 490, "calcium": 80, "iron": 2]),
        libraryFood("cottage", "Cottage cheese bowl", unit: "bowl", grams: 280, source: "custom", created: 9,
                    ["kcal": 310, "protein": 30, "carbs": 26, "fat": 9, "fiber": 3, "sugar": 18, "sodium": 640,
                     "calcium": 220]),
    ]

    /// Recipes built from the demo foods; their nutrients are computed the way the server does.
    static var recipes: [Food] {
        let byID = Dictionary(uniqueKeysWithValues: (foods + libraryFoods).map { ($0.id!, $0) })
        func recipe(_ id: String, _ name: String, serves: Double, fav: Bool = false, created daysAgo: Int,
                    _ parts: [(String, Double)]) -> Food {
            var base = Food(id: "demo-\(id)", kind: .recipe, name: name, nutrients: [:], source: "recipe", favorite: fav)
            base.createdAt = 1_762_600_000_000 - daysAgo * 86_400_000
            base.updatedAt = base.createdAt
            return RecipeMath.recipe(name: name, parts: parts.compactMap { p in
                byID["demo-" + p.0].map { RecipeMath.Part(food: $0, servings: p.1) }
            }, recipeServings: serves, base: base)
        }
        return [
            recipe("recipe-bowl", "Chicken rice bowl", serves: 4, created: 40,
                   [("chicken", 3.5), ("rice", 7), ("broccoli", 2), ("oil", 2)]),
            recipe("recipe-oats", "Overnight oats", serves: 2, fav: true, created: 40,
                   [("oats", 2), ("yogurt", 2), ("milk", 1), ("berries", 1), ("whey", 1)]),
            recipe("recipe-chili", "Turkey black bean chili", serves: 6, created: 18,
                   [("turkey", 4), ("beans", 6), ("tomatoes", 6), ("onion", 2), ("oil", 1)]),
            recipe("recipe-smoothie", "PB banana protein smoothie", serves: 1, fav: true, created: 11,
                   [("whey", 1), ("banana", 1), ("milk", 1), ("pb", 1), ("spinach", 1)]),
            recipe("recipe-toast", "Avocado egg toast", serves: 1, created: 7,
                   [("toast", 2), ("eggs", 2), ("avocado", 1)]),
        ]
    }
}
