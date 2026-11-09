// DESIGN 4.8 Recipe builder: name, "Makes N servings", a live per-serving card pinned at the top, and
// the ingredient list (tap for the amount editor, swipe to delete, drag to reorder, "Add ingredient"
// opens the shared food search in picker mode). Saved as kind "recipe" with components and
// recipe_servings; the server recomputes the nutrients, and the client writes the same numbers.
import SwiftUI

struct RecipeBuilderView: View {
    var onDone: (Food?) -> Void
    @Environment(Store.self) private var store
    @Environment(\.units) private var units
    @Environment(Router.self) private var router
    @State private var draft: RecipeDraft
    @State private var picking = false
    @State private var editing: Ingredient.ID?
    @State private var confirmDiscard = false
    @FocusState private var nameFocused: Bool

    init(editing recipe: Food? = nil, onDone: @escaping (Food?) -> Void) {
        self.onDone = onDone
        _draft = State(initialValue: RecipeDraft(editing: recipe))
    }

    var body: some View {
        let totals = draft.totals(in: store)
        List {
            Section {
                TextField("Recipe name", text: $draft.name)
                    .scaledFont(20, .semibold, relativeTo: .title3)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .padding(.vertical, 4)
                HStack {
                    Text("Makes")
                    Spacer()
                    ServingsStepper(value: $draft.servings)
                }
            }
            .listSectionMargins(.top, Space.s)
            Section {
                ForEach(draft.ingredients) { ing in
                    IngredientRow(ingredient: ing, food: draft.food(ing, in: store)) { editing = ing.id }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { remove(ing) } label: { Label("Remove", systemImage: "trash") }
                        }
                }
                .onMove { draft.ingredients.move(fromOffsets: $0, toOffset: $1) }
                Button { picking = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Palette.accent)
                        Text("Add ingredient").foregroundStyle(Palette.accentInk).fontWeight(.medium)
                    }
                    .frame(minHeight: 36)
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Ingredients")
                    Spacer()
                    if !draft.ingredients.isEmpty {
                        Text("\(Fmt.kcal(totals.total["kcal"] ?? 0)) kcal total")
                            .monospacedDigit()
                            .contentTransition(.numericText(value: totals.total["kcal"] ?? 0))
                    }
                }
            } footer: {
                footer(totals)
            }
            if !draft.isNew, let id = draft.original?.id {
                Section {
                    Button(role: .destructive) { delete(id) } label: {
                        Text("Delete recipe").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.smooth, value: draft.ingredients)
        .safeAreaBar(edge: .top) {
            PerServingCard(totals: totals, servings: draft.servings, empty: draft.ingredients.isEmpty)
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.s)
        }
        .navigationTitle(draft.isNew ? "New recipe" : "Edit recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    if draft.isDirty { confirmDiscard = true } else { onDone(nil) }
                } label: { Image(systemName: "xmark") }
                .tint(.primary)
                .accessibilityLabel("Cancel")
                .confirmationDialog("Discard this recipe's changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard changes", role: .destructive) { onDone(nil) }
                    Button("Keep editing", role: .cancel) {}
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) { Image(systemName: "checkmark") }
                    .tint(.primary)
                    .disabled(!draft.canSave(in: store))
                    .accessibilityLabel("Save recipe")
            }
        }
        .interactiveDismissDisabled(draft.isDirty)
        .sheet(isPresented: $picking) {
            IngredientPickerSheet(draft: draft)
        }
        .sheet(item: Binding(get: { editing.map(IngredientRef.init) }, set: { editing = $0?.id })) { ref in
            if let ing = draft.ingredients.first(where: { $0.id == ref.id }), let food = draft.food(ing, in: store) {
                let d = draft
                IngredientAmountSheet(food: food, ingredient: Binding(
                    get: { d.ingredients.first { $0.id == ref.id } ?? ing },
                    set: { new in if let i = d.ingredients.firstIndex(where: { $0.id == ref.id }) { d.ingredients[i] = new } }
                )) {
                    editing = nil
                    remove(ing)
                }
            }
        }
        .onAppear {
            if draft.isNew && draft.name.isEmpty && UserDefaults.standard.string(forKey: "PlateScreen") == nil { nameFocused = true }
            switch UserDefaults.standard.string(forKey: "PlateScreen") {
            case "picker": picking = true
            case "ingredient": editing = draft.ingredients.first?.id
            default: break
            }
        }
    }

    @ViewBuilder private func footer(_ totals: RecipeMath.Totals) -> some View {
        let missing = draft.missing(in: store)
        if !missing.isEmpty {
            Text("Remove the unavailable ingredient\(missing.count == 1 ? "" : "s") to save.")
                .foregroundStyle(Palette.overInk)
        } else if draft.ingredients.isEmpty {
            Text("Add foods you've logged, anything from the USDA catalog, or a packaged product. Amounts can be servings, portions or \(units.food.name).")
        } else if totals.isPartial {
            let names = totals.partial.compactMap { Nutrients.info($0) }
                .sorted { a, b in (Nutrients.all.firstIndex(of: a) ?? 0) < (Nutrients.all.firstIndex(of: b) ?? 0) }
                .prefix(3).map { $0.name.lowercased() }
            Text("Partial data: some ingredients don't list \(names.joined(separator: ", "))\(totals.partial.count > 3 ? " and more" : ""), so those totals are a minimum.")
        } else {
            Text("Tap an ingredient to change its amount. Drag to reorder.")
        }
    }

    private func remove(_ ing: Ingredient) {
        guard let index = draft.ingredients.firstIndex(where: { $0.id == ing.id }) else { return }
        let name = draft.food(ing, in: store)?.shortName ?? "ingredient"
        var removed = ing
        withAnimation(.smooth) { removed = draft.ingredients.remove(at: index) }
        let ing = removed
        let d = draft
        Toasts.shared.show(ToastModel(symbol: "minus.circle.fill", text: "Removed \(name)", action: ToastAction {
            withAnimation(.smooth) { d.ingredients.insert(ing, at: min(index, d.ingredients.count)) }
            Haptics.soft()
        }))
    }

    private func save() {
        let recipe = draft.build(in: store)
        guard store.save(food: recipe) else {
            Haptics.warning()
            Toasts.shared.message("This recipe was deleted", symbol: "trash.fill")
            onDone(nil)
            return
        }
        Haptics.success()
        let day = router.day
        Toasts.shared.show(ToastModel(symbol: "checkmark.circle.fill", text: "Recipe saved",
                                      action: ToastAction(title: "Log a serving") {
            Actions.log(recipe, servings: 1, meal: Days.meal(), day: day)
        }))
        onDone(store.food(id: recipe.id) ?? recipe)
    }

    private func delete(_ id: String) {
        guard let before = store.food(id: id) else { return }
        store.deleteFood(id: id)
        Haptics.light()
        Toasts.shared.show(ToastModel(symbol: "trash.fill", text: "Deleted \(before.name)", action: ToastAction {
            Store.shared.save(food: before, restoring: true)
            Haptics.soft()
        }))
        onDone(nil)
    }
}

private struct IngredientRef: Identifiable { let id: Ingredient.ID }

/// One ingredient: name, amount ("600 g", "1½ breast · 258 g") and its kcal in the whole recipe.
private struct IngredientRow: View {
    var ingredient: Ingredient
    var food: Food?
    var onTap: () -> Void
    @Environment(\.units) private var units

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let food {
                        Text(food.name).foregroundStyle(.primary).lineLimit(1)
                        Text(food.amountText(ingredient.unit, ingredient.amount, units))
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    } else {
                        Label("Unavailable food", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                        Text("It was deleted from your foods").font(.subheadline).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if let food {
                    let kcal = food.nutrients(servings: food.servings(amount: ingredient.amount, unit: ingredient.unit))["kcal"]
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Fmt.kcal(kcal)).numberFont(17, relativeTo: .body)
                            .contentTransition(.numericText(value: kcal ?? 0))
                        Text("kcal").font(.footnote).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(food == nil)
        .accessibilityHint("Changes the amount")
    }
}

/// [−] 4 servings [+], whole servings from 1 to 50.
struct ServingsStepper: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 6) {
            step("minus") { value = max(1, (value - 1).rounded()) }.disabled(value <= 1)
            Text("\(Fmt.trim(value)) serving\(value == 1 ? "" : "s")")
                .numberFont(17, .semibold, relativeTo: .body)
                .contentTransition(.numericText(value: value))
                .frame(minWidth: 96)
            step("plus") { value = min(50, (value + 1).rounded()) }.disabled(value >= 50)
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Makes")
        .accessibilityValue("\(Fmt.trim(value)) servings")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(50, value + 1)
            case .decrement: value = max(1, value - 1)
            default: break
            }
        }
    }

    private func step(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 32)
                .background(Palette.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The live per-serving preview: kcal, P / C / F / fiber and the kcal-share bar. "≥" marks partial data.
struct PerServingCard: View {
    var totals: RecipeMath.Totals
    var servings: Double
    var empty: Bool
    @Environment(\.units) private var units

    var body: some View {
        let n = totals.perServing
        let kcal = n["kcal"] ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Per serving").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let g = totals.gramsPerServing {
                    Text("\(Fmt.foodWeight(g, units)) each").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if totals.partial.contains("kcal") { Text("≥").font(.title3).foregroundStyle(.secondary) }
                    Text(empty ? Fmt.missing : Fmt.whole(kcal))
                        .numberFont(30, .bold, relativeTo: .largeTitle)
                        .foregroundStyle(empty ? .tertiary : .primary)
                        .contentTransition(.numericText(value: kcal))
                    Text("kcal").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                macro("P", "protein")
                macro("C", "carbs")
                macro("F", "fat")
            }
            StackedMacroBar(nutrients: n)
        }
        .padding(Space.l)
        .background(Palette.card, in: .rect(cornerRadius: Space.cardRadius, style: .continuous))
        .animation(.snappy, value: kcal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(empty ? "Per serving, no ingredients yet" :
            "Per serving \(Fmt.whole(kcal)) kilocalories, protein \(Fmt.grams(n["protein"] ?? 0)) grams, carbs \(Fmt.grams(n["carbs"] ?? 0)) grams, fat \(Fmt.grams(n["fat"] ?? 0)) grams")
    }

    private func macro(_ letter: String, _ key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(letter).foregroundStyle(Palette.ink(key)).fontWeight(.semibold)
            Text(totals.perServing[key].map { (totals.partial.contains(key) ? "≥" : "") + Fmt.grams($0) } ?? Fmt.missing)
                .contentTransition(.numericText(value: totals.perServing[key] ?? 0))
        }
        .numberFont(15, .medium, relativeTo: .subheadline)
        .lineLimit(1)
    }
}

/// Tapping an ingredient: the live preview and the shared amount card (servings, portions, grams, ounces).
private struct IngredientAmountSheet: View {
    var food: Food
    @Binding var ingredient: Ingredient
    var onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PreviewCard(nutrients: food.nutrients(servings: food.servings(amount: ingredient.amount, unit: ingredient.unit)))
                    AmountCard(food: food, unit: $ingredient.unit, amount: $ingredient.amount)
                    Button(role: .destructive) { onRemove() } label: {
                        Label("Remove from recipe", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
                .padding(.horizontal, Space.l)
                .padding(.top, 4)
            }
            .background(Palette.background)
            .navigationTitle(food.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark") }
                        .tint(.primary)
                        .accessibilityLabel("Done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The ingredient list on a recipe's food detail page.
struct RecipeIngredientsCard: View {
    var recipe: Food
    @Environment(Store.self) private var store
    @Environment(\.units) private var units

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ingredients").font(.headline)
                Spacer()
                Text("Makes \(Fmt.trim(recipe.recipeServings ?? 1))").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            ForEach(Array(recipe.components.enumerated()), id: \.offset) { i, c in
                if i > 0 { Divider() }
                let food = store.food(id: c.foodID)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(food?.name ?? "Unavailable food").lineLimit(1)
                            .foregroundStyle(food == nil ? .secondary : .primary)
                        if let food {
                            Text(food.amountText(.serving, c.servings, units))
                                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(Fmt.kcal(food?.nutrients(servings: c.servings)["kcal"]))
                        .numberFont(17, relativeTo: .body).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .card()
    }
}
