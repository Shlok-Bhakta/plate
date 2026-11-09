// The recipe builder's editable state: name, servings, and ingredients (a food id plus an amount in
// servings, a portion, grams or ounces). Totals come from RecipeMath, the same math the server runs.
import SwiftUI

struct Ingredient: Identifiable, Equatable {
    let id = UUID()
    var foodID: String
    var unit: AmountUnit = .serving
    var amount: Double = 1
}

@Observable
@MainActor
final class RecipeDraft {
    let original: Food?
    var name: String
    var servings: Double
    var ingredients: [Ingredient]
    @ObservationIgnored private let initial: String

    init(editing recipe: Food?) {
        let name = recipe?.name ?? ""
        let servings = recipe?.recipeServings ?? 4
        let list = (recipe?.components ?? []).map { Ingredient(foodID: $0.foodID, unit: .serving, amount: $0.servings) }
        original = recipe
        self.name = name
        self.servings = servings
        ingredients = list
        initial = Self.fingerprint(name, servings, list)
    }

    private static func fingerprint(_ name: String, _ servings: Double, _ list: [Ingredient]) -> String {
        "\(name)|\(servings)|" + list.map { "\($0.foodID):\($0.amount):\($0.unit)" }.joined(separator: ",")
    }

    var isNew: Bool { original == nil }
    var isDirty: Bool { Self.fingerprint(name, servings, ingredients) != initial }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    func food(_ i: Ingredient, in store: Store) -> Food? { store.food(id: i.foodID) }

    /// Servings of the ingredient's food in the whole recipe.
    func servings(_ i: Ingredient, in store: Store) -> Double {
        food(i, in: store)?.servings(amount: i.amount, unit: i.unit) ?? i.amount
    }

    func parts(in store: Store) -> [RecipeMath.Part] {
        ingredients.compactMap { i in food(i, in: store).map { RecipeMath.Part(food: $0, servings: $0.servings(amount: i.amount, unit: i.unit)) } }
    }

    func totals(in store: Store) -> RecipeMath.Totals {
        RecipeMath.totals(parts(in: store), recipeServings: servings)
    }

    /// Ingredients whose food was deleted; the server won't accept a recipe that points at them.
    func missing(in store: Store) -> [Ingredient] { ingredients.filter { food($0, in: store) == nil } }

    func canSave(in store: Store) -> Bool {
        !trimmedName.isEmpty && !ingredients.isEmpty && missing(in: store).isEmpty && servings > 0
    }

    /// Adds a food, saving a catalog or Open Food Facts result first so the component has a food id.
    /// nil for the recipe itself or a deleted food.
    @discardableResult
    func add(_ food: Food, unit: AmountUnit = .serving, amount: Double = 1, store: Store) -> Ingredient? {
        guard let saved = store.materialize(food), let id = saved.id, id != original?.id else { return nil }
        let ingredient = Ingredient(foodID: id, unit: unit, amount: amount)
        ingredients.append(ingredient)
        return ingredient
    }

    func remove(_ id: Ingredient.ID) { ingredients.removeAll { $0.id == id } }

    func build(in store: Store) -> Food {
        RecipeMath.recipe(name: trimmedName, parts: parts(in: store), recipeServings: servings, base: original)
    }
}

extension Food {
    /// "600 g", "1 cup · 80 g", "2 × 1 cup · 490 g", or "1½ breast · 258 g"; in US units "21 oz",
    /// "1 cup · 2.8 oz". A weight entered in the other unit shows the preferred one after it: "600 g · 21 oz".
    func amountText(_ unit: AmountUnit, _ amount: Double, _ u: Units) -> String {
        let main: String
        let g = grams(per: unit).map { $0 * amount }
        switch unit {
        case .grams:
            main = "\(Fmt.grams(amount)) g"
            if u.food == .g { return main }
        case .ounces:
            main = "\(Fmt.foodInput(amount, .oz)) oz"
            if u.food == .oz { return main }
        case .portion:
            let label = unitName(unit, u)
            if Fmt.isWeightLabel(label), let g { return Fmt.foodWeight(g, u) }
            main = abs(amount - 1) < 0.001 ? label : "\(Fmt.servings(amount)) × \(label)"
        case .serving:
            let total = amount * serving.amount
            if Fmt.isWeightLabel(serving.unit) || Fmt.isWeightLabel(servingName) {
                if let g { return Fmt.foodWeight(g, u) }
                if let m = Fmt.measure(serving.unit), m.unit == "g" { return Fmt.foodWeight(total * m.amount, u) }
            }
            main = "\(Fmt.servings(total)) \(Self.plural(serving.unit, total))"
        }
        guard let g, g > 0 else { return main }
        return "\(main) · \(Fmt.foodWeight(g, u))"
    }

    /// "cup" → "cups" for countable serving nouns; other units ("tbsp", "medium", "oz") stay as they are.
    static func plural(_ unit: String, _ amount: Double) -> String {
        guard amount > 1 else { return unit }
        let nouns: Set<String> = ["cup", "slice", "scoop", "bar", "container", "bowl", "plate", "wrap", "fillet", "breast",
                                  "stack", "bottle", "serving", "tortilla", "jar", "egg", "half", "piece", "can", "thigh"]
        var words = unit.split(separator: " ").map(String.init)
        guard let last = words.last, nouns.contains(last) else { return unit }
        words[words.count - 1] = last == "half" ? "halves" : last + "s"
        return words.joined(separator: " ")
    }

    /// The part of a name before the first comma: "Chicken breast, grilled" → "Chicken breast".
    var shortName: String {
        name.split(separator: ",", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? name
    }
}
