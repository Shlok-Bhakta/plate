// Recipe math (SPEC "foods": kind recipe). Mirrors the server's `recipe_math` in server/src/store.rs:
// each component is scaled by its servings, the totals are summed (a key known in any component is
// known in the total), then divided by `recipe_servings`. The serving weight is known only when every
// component's weight is. The server recomputes this whenever a recipe is written; the client computes
// the same numbers for the live preview and so the row it writes is already correct.
import Foundation

enum RecipeMath {
    struct Part: Sendable {
        var food: Food
        /// Servings of `food` in the whole recipe.
        var servings: Double
        init(food: Food, servings: Double) { self.food = food; self.servings = servings }
    }

    struct Totals: Equatable, Sendable {
        /// The whole recipe.
        var total = NutrientMap()
        /// One serving: `total / recipeServings`.
        var perServing = NutrientMap()
        var totalGrams: Double?
        var gramsPerServing: Double?
        /// Keys some components have and others lack: their amounts are a minimum ("≥", "partial data").
        var partial: Set<String> = []
        var isPartial: Bool { !partial.isEmpty }
    }

    /// Servings of `food` for an amount in grams, when the food's serving weight is known.
    static func servings(of food: Food, grams: Double) -> Double? { food.servings(forGrams: grams) }

    static func totals(_ parts: [Part], recipeServings: Double) -> Totals {
        let live = parts.filter { $0.servings > 0 && $0.servings.isFinite }
        var out = Totals()
        out.total = NutritionMath.sum(live.map { $0.food.nutrients(servings: $0.servings) })
        // Like the server: a missing or non-positive recipe_servings counts as 1.
        let per = recipeServings > 0 && recipeServings.isFinite ? recipeServings : 1
        out.perServing = NutritionMath.scale(out.total, by: 1 / per)
        var grams: Double? = live.isEmpty ? nil : 0
        for p in live { grams = grams.flatMap { sum in p.food.servingGrams.map { sum + $0 * p.servings } } }
        out.totalGrams = grams.flatMap { $0 > 0 ? NutritionMath.round3($0) : nil }
        out.gramsPerServing = out.totalGrams.map { NutritionMath.round3($0 / per) }
        let keys = Set(live.flatMap { $0.food.nutrients.keys })
        out.partial = keys.filter { k in live.contains { $0.food.nutrients[k] == nil } }
        return out
    }

    /// A recipe row ready to save: kind recipe, components by food id, `recipe_servings`, per-serving
    /// nutrients, and a one-serving serving with its weight when known (as the server writes it).
    /// `base` keeps the identity, favorite flag and unknown fields of a recipe being edited.
    static func recipe(name: String, parts: [Part], recipeServings: Double, base: Food? = nil) -> Food {
        let servings = recipeServings > 0 ? recipeServings : 1
        let t = totals(parts, recipeServings: servings)
        var f = base ?? Food(kind: .recipe, name: name, nutrients: [:], source: "recipe")
        f.kind = .recipe
        f.name = name
        f.source = "recipe"
        f.nutrients = t.perServing
        f.recipeServings = servings
        f.serving = Serving(amount: 1, unit: "serving", grams: t.gramsPerServing)
        f.components = parts.compactMap { p in
            guard let id = p.food.id, p.servings > 0 else { return nil }
            return Component(foodID: id, servings: NutritionMath.round3(p.servings))
        }
        f.deleted = false
        return f
    }
}
