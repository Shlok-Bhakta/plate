// "Add ingredient": the shared food search (FoodSearchView) in picker mode, as a sheet over the recipe
// builder. ⊕ adds one serving; a tapped row opens Food detail with "Add to recipe" for any amount. Catalog
// and Open Food Facts results are saved as foods first (Store.materialize) so every component has a
// food id. The sheet stays open for several ingredients, like the Add sheet's multi-add.
import SwiftUI

struct IngredientPickerSheet: View {
    var draft: RecipeDraft
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AddRoute] = []
    @State private var query = ""
    @State private var meal = Meal.lunch
    @State private var scanning = false
    @State private var added: [Ingredient.ID] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            FoodSearchView(meal: $meal, day: Days.today, query: $query, path: $path, isSheet: true,
                           onScan: { scanning = true }, pick: { add($0) })
                .searchable(text: $query, placement: .automatic, prompt: "Search foods")
                .searchFocused($searchFocused)
                .searchPresentationToolbarBehavior(.avoidHidingContent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .navigationDestination(for: AddRoute.self) { route in
                    switch route {
                    case .food(let food):
                        FoodDetailView(food: food, meal: $meal, day: Days.today, addToRecipe: { unit, amount in
                            add(food, unit: unit, amount: amount)
                        }) { path.removeAll() }
                    case .create(let name, let barcode):
                        CustomFoodForm(initialName: name, barcode: barcode) { saved in
                            path.removeAll()
                            add(saved)
                        }
                    case .quickAdd:
                        // Quick adds are entries, not foods, so they can't be ingredients.
                        CustomFoodForm(initialName: query) { saved in
                            path.removeAll()
                            add(saved)
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .fullScreenCover(isPresented: $scanning) {
            BarcodeCaptureView { code in
                scanning = false
                if let code { lookup(code) }
            }
        }
        .onAppear {
            guard UserDefaults.standard.string(forKey: "PlateScreen") != "picker" else {
                query = UserDefaults.standard.string(forKey: "PlateQuery") ?? ""
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                searchFocused = true
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let live = draft.ingredients.filter { added.contains($0.id) }
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: live.isEmpty ? "xmark" : "checkmark")
                    .contentTransition(.symbolEffect(.replace))
            }
            .tint(.primary)
            .accessibilityLabel(live.isEmpty ? "Close" : "Done")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text("Add ingredient").font(.headline)
                if !live.isEmpty {
                    let kcal = live.compactMap { i in draft.food(i, in: store).map { $0.nutrients(servings: draft.servings(i, in: store))["kcal"] ?? 0 } }.reduce(0, +)
                    Text("\(live.count) added · \(Fmt.kcal(kcal)) kcal")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: kcal))
                }
            }
            .animation(.snappy, value: live.count)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { scanning = true } label: { Image(systemName: "barcode.viewfinder") }
                .tint(.primary)
                .accessibilityLabel("Scan barcode")
        }
    }

    private func add(_ food: Food, unit: AmountUnit = .serving, amount: Double = 1) {
        guard let ing = draft.add(food, unit: unit, amount: amount, store: store) else {
            Haptics.warning()
            if store.isDeletedFood(food.id) {
                Toasts.shared.message("This food was deleted", symbol: "trash.fill")
            } else {
                Toasts.shared.message("A recipe can't include itself", symbol: "exclamationmark.circle.fill")
            }
            return
        }
        added.append(ing.id)
        Haptics.light()
        let saved = draft.food(ing, in: store) ?? food
        let kcal = saved.nutrients(servings: saved.servings(amount: amount, unit: unit))["kcal"]
        let d = draft
        Toasts.shared.show(ToastModel(symbol: "checkmark.circle.fill",
                                      text: "Added \(saved.shortName) · \(Fmt.kcal(kcal)) kcal",
                                      action: ToastAction {
            d.remove(ing.id)
            Haptics.soft()
        }))
    }

    private func lookup(_ code: String) {
        Task { @MainActor in
            do {
                if let found = try await store.lookup(barcode: code) {
                    path.append(.food(found))
                } else {
                    path.append(.create(name: "", barcode: code))
                }
            } catch {
                Toasts.shared.message("Couldn't look up \(code)", symbol: "exclamationmark.circle.fill")
            }
        }
    }
}

/// The picker's idle state: recent foods as chips, then your foods and recipes, each with ⊕ to add.
struct IngredientSuggestions: View {
    @Binding var path: [AddRoute]
    var pick: (Food) -> Void
    @Environment(Store.self) private var store

    var body: some View {
        let recents: [Food] = {
            var seen = Set<String>()
            return store.recentEntries.compactMap { store.food(id: $0.foodID) }
                .filter { seen.insert($0.id ?? "").inserted }
                .prefix(12).map { $0 }
        }()
        let foods = store.myFoods.filter { $0.kind != .quick }
        let recipes = store.recipes

        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent").sectionCaps().padding(.horizontal, Space.l + 4)
                ChipRow {
                    ForEach(recents) { food in
                        FoodChip(name: food.name, kcal: food.kcal, favorite: food.favorite) { pick(food) }
                            onLongPress: { path.append(.food(food)) }
                    }
                }
            }
        }
        if !foods.isEmpty { group("Your foods", foods) }
        if !recipes.isEmpty { group("Recipes", recipes) }
        Button { path.append(.create(name: "", barcode: nil)) } label: { ActionLabel(title: "Create food", symbol: "plus") }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.secondary)
            .padding(.horizontal, Space.l)
    }

    private func group(_ title: String, _ foods: [Food]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sectionCaps().padding(.horizontal, Space.l + 4)
            VStack(spacing: 0) {
                ForEach(Array(foods.enumerated()), id: \.element.listID) { i, food in
                    if i > 0 { Divider().padding(.leading, Space.l) }
                    FoodResultRow(food: food, actionLabel: "Add \(food.name) to recipe") { path.append(.food(food)) }
                        onLog: { pick(food) }
                }
            }
            .background(Palette.card, in: .rect(cornerRadius: Space.cardRadius, style: .continuous))
            .padding(.horizontal, Space.l)
        }
    }
}
