// DESIGN 4.8 Library: Favorites, My foods (grouped by where they came from) and Recipes, with search,
// swipe to favorite or delete (undo from the toast), one-tap ⊕ logging, Food detail on tap, and the
// recipe builder from "+" or a recipe's Edit action.
import SwiftUI

struct LibraryView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case favorites, foods, recipes
        var id: String { rawValue }
        var title: String {
            switch self { case .favorites: "Favorites"; case .foods: "My foods"; case .recipes: "Recipes" }
        }
    }

    private struct FoodGroup: Identifiable {
        var title: String
        var footer: String?
        var foods: [Food]
        var id: String { title }
        init(_ title: String, _ footer: String?, _ foods: [Food]) { self.title = title; self.footer = footer; self.foods = foods }
    }

    private struct RecipeRequest: Identifiable {
        let id = UUID()
        var recipe: Food?
    }

    @Environment(Store.self) private var store
    @Environment(\.units) private var units
    @Environment(Router.self) private var router
    @AppStorage("librarySegment") private var segment = Segment.favorites
    @State private var query = ""
    @State private var path: [AddRoute] = []
    @State private var meal = Days.meal()
    /// True once the user picks a meal (in Food detail); until then it follows the time of day.
    @State private var mealPicked = false
    @Environment(\.scenePhase) private var phase
    @State private var recipeRequest: RecipeRequest?
    @State private var favoriteBump = 0

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ f: Food) -> Bool {
        let tokens = trimmed.split(separator: " ")
        guard !tokens.isEmpty else { return true }
        let hay = (f.name + " " + (f.brand ?? "")).lowercased()
        return tokens.allSatisfy { hay.contains($0) }
    }

    private func items(_ s: Segment) -> [Food] {
        let base: [Food] = switch s {
        case .favorites: store.favorites
        case .foods: store.myFoods
        case .recipes: store.recipes
        }
        return base.filter(matches)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                let list = items(segment)
                if list.isEmpty {
                    emptyState
                } else {
                    switch segment {
                    case .foods: foodSections(list)
                    default:
                        Section { rows(list) } footer: { countFooter(list) }
                    }
                    if segment == .recipes && trimmed.isEmpty {
                        Section {
                            Button { recipeRequest = RecipeRequest() } label: {
                                Label("New recipe", systemImage: "plus")
                                    .foregroundStyle(Palette.accentInk).fontWeight(.medium)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(Space.l)
            .animation(.smooth, value: segment)
            .searchable(text: $query, prompt: "Search your library")
            .searchToolbarBehavior(.minimize)
            .navigationTitle("Library")
            .toolbar { toolbar }
            .navigationDestination(for: AddRoute.self) { route in
                switch route {
                case .food(let food):
                    FoodDetailView(food: food, meal: Binding(get: { meal }, set: { meal = $0; mealPicked = true }),
                                   day: router.day) { path.removeAll() }
                case .quickAdd: QuickAddView(meal: meal, day: router.day, initialName: "") { path.removeAll() }
                case .create(let name, let barcode):
                    CustomFoodForm(initialName: name, barcode: barcode) { saved in path = [.food(saved)] }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: favoriteBump)
            .toastHost()
        }
        .sheet(item: $recipeRequest) { request in
            NavigationStack {
                RecipeBuilderView(editing: request.recipe) { saved in
                    recipeRequest = nil
                    if saved != nil, request.recipe == nil { segment = .recipes }
                }
            }
        }
        .task { applyDebugScreen() }
        .onAppear { if !mealPicked { meal = Days.meal() } }
        .onChange(of: phase) { _, now in
            if now == .background { mealPicked = false }
            if now == .active && !mealPicked { meal = Days.meal() }
        }
    }

    // MARK: Sections and rows

    @ViewBuilder private func foodSections(_ list: [Food]) -> some View {
        let groups: [FoodGroup] = [
            FoodGroup("Made by you", nil, list.filter { $0.source == "custom" || ($0.source == nil && $0.kind == .quick) }),
            FoodGroup("From the agent", "Logged by the agent from a photo or a description. Log them again in one tap.",
             list.filter { $0.source == "agent" }),
            FoodGroup("Scanned products", nil, list.filter { $0.source == "off" || ($0.barcode != nil && $0.source != "agent" && $0.source != "custom") }),
            FoodGroup("From USDA", "Catalog foods you've logged or used in a recipe.", list.filter { $0.source == "usda" }),
        ]
        let shown = Set(groups.flatMap { $0.foods.compactMap(\.id) })
        let rest = list.filter { !shown.contains($0.id ?? "") }
        ForEach(groups.filter { !$0.foods.isEmpty }) { g in
            Section {
                rows(sortedByUse(g.foods))
            } header: {
                sectionHeader(g.title, g.foods.count)
            } footer: {
                if let f = g.footer { Text(f) }
            }
        }
        if !rest.isEmpty {
            Section { rows(sortedByUse(rest)) } header: { sectionHeader("Other", rest.count) }
        }
    }

    private func sectionHeader(_ title: String, _ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text("\(count)").monospacedDigit()
        }
    }

    @ViewBuilder private func countFooter(_ list: [Food]) -> some View {
        switch segment {
        case .favorites: Text("Favorites also appear at the top of the Add sheet and in the Log button's long-press menu.")
        case .recipes: Text("Nutrients are per serving. Log a recipe like any food, by servings or \(units.food.name).")
        case .foods: EmptyView()
        }
    }

    /// Most logged first, then by name.
    private func sortedByUse(_ foods: [Food]) -> [Food] {
        let counts: [String: Int] = Dictionary(uniqueKeysWithValues: foods.map { f -> (String, Int) in
            (f.listID, store.usage(of: f.id)?.count ?? 0)
        })
        return foods.sorted { (a: Food, b: Food) -> Bool in
            let ca = counts[a.listID] ?? 0, cb = counts[b.listID] ?? 0
            if ca != cb { return ca > cb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func rows(_ list: [Food]) -> some View {
        ForEach(list) { food in
            LibraryRow(food: food, usage: store.usage(of: food.id), subline: subline(food),
                       logLabel: "Log \(food.name) to \(router.logMeal.title)") {
                path.append(.food(food))
            } onLog: {
                Actions.log(food, servings: 1, meal: router.logMeal, day: router.day)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: Space.l, bottom: 0, trailing: 6))
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { toggleFavorite(food) } label: {
                    Label(food.favorite ? "Unfavorite" : "Favorite", systemImage: food.favorite ? "star.slash.fill" : "star.fill")
                }
                .tint(Palette.accent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { delete(food) } label: { Label("Delete", systemImage: "trash") }
                if food.kind == .recipe {
                    Button { recipeRequest = RecipeRequest(recipe: food) } label: { Label("Edit", systemImage: "pencil") }
                        .tint(.gray)
                }
            }
            .contextMenu { menu(food) }
        }
    }

    @ViewBuilder private func menu(_ food: Food) -> some View {
        Button { Actions.log(food, servings: 1, meal: router.logMeal, day: router.day) } label: {
            Label("Log to \(router.logMeal.title)", systemImage: "plus.circle")
        }
        if food.kind == .recipe {
            Button { recipeRequest = RecipeRequest(recipe: food) } label: { Label("Edit recipe", systemImage: "pencil") }
        }
        Button { toggleFavorite(food) } label: {
            Label(food.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: food.favorite ? "star.slash" : "star")
        }
        Divider()
        Button(role: .destructive) { delete(food) } label: { Label("Delete", systemImage: "trash") }
    }

    private func subline(_ food: Food) -> String {
        if food.kind == .recipe {
            let names = food.components.compactMap { store.food(id: $0.foodID)?.shortName }
            let serves = "Serves \(Fmt.trim(food.recipeServings ?? 1))"
            return names.isEmpty ? serves : "\(serves) · \(names.joined(separator: ", "))"
        }
        if food.kind == .quick { return [food.brand, "Calories and macros only"].compactMap { $0 }.joined(separator: " · ") }
        return [food.brand, food.servingSummary(units)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Actions

    private func toggleFavorite(_ food: Food) {
        let before = food
        guard let after = store.setFavorite(food, !food.favorite) else {
            Toasts.shared.message("This food was deleted", symbol: "trash.fill")
            return
        }
        favoriteBump += 1
        Toasts.shared.show(ToastModel(symbol: after.favorite ? "star.fill" : "star.slash.fill",
                                      text: after.favorite ? "Added \(food.shortName) to Favorites" : "Removed \(food.shortName) from Favorites",
                                      action: ToastAction {
            Store.shared.save(food: before)
            Haptics.soft()
        }))
    }

    private func delete(_ food: Food) {
        guard let id = food.id else { return }
        let usedIn = store.recipes(using: id).count
        store.deleteFood(id: id)
        let before = food
        Toasts.shared.show(ToastModel(symbol: "trash.fill",
                                      text: usedIn > 0 ? "Deleted \(food.shortName) · in \(usedIn) recipe\(usedIn == 1 ? "" : "s")" : "Deleted \(food.shortName)",
                                      action: ToastAction {
            Store.shared.save(food: before, restoring: true)
            Haptics.soft()
        }))
    }

    // MARK: Empty states and toolbar

    @ViewBuilder private var emptyState: some View {
        Section {
            VStack(spacing: 14) {
                if !trimmed.isEmpty {
                    Image(systemName: "magnifyingglass").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text("No \(segment.title.lowercased()) match ‘\(query)’").font(.headline)
                    let elsewhere = Segment.allCases.filter { $0 != segment && !items($0).isEmpty }
                    ForEach(elsewhere) { s in
                        Button { segment = s } label: {
                            Text("\(items(s).count) in \(s.title)").fontWeight(.medium)
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.secondary)
                    }
                } else {
                    switch segment {
                    case .favorites:
                        Image(systemName: "star").font(.system(size: 44)).foregroundStyle(.tertiary)
                        Text("Star a food to keep it one tap away").font(.subheadline).foregroundStyle(.secondary)
                    case .recipes:
                        Image(systemName: "frying.pan").font(.system(size: 44)).foregroundStyle(.tertiary)
                        Text("Build a recipe from foods you eat").font(.subheadline).foregroundStyle(.secondary)
                        Button { recipeRequest = RecipeRequest() } label: { ActionLabel(title: "New recipe", symbol: "plus") }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).tint(.secondary)
                    case .foods:
                        Image(systemName: "fork.knife").font(.system(size: 44)).foregroundStyle(.tertiary)
                        Text("Foods you create, scan or log show up here").font(.subheadline).foregroundStyle(.secondary)
                        Button { path.append(.create(name: "", barcode: nil)) } label: { ActionLabel(title: "New food", symbol: "plus") }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).tint(.secondary)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 56)
            .listRowBackground(Color.clear)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $segment.animation(.smooth)) {
                ForEach(Segment.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .sensoryFeedback(.selection, trigger: segment)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { path.append(.create(name: "", barcode: nil)) } label: { Label("New food", systemImage: "carrot") }
                Button { recipeRequest = RecipeRequest() } label: { Label("New recipe", systemImage: "frying.pan") }
            } label: { Image(systemName: "plus") }
            .tint(.primary)
            .accessibilityLabel("New")
        }
    }

    /// `-PlateScreen recipes | foods | favorites | recipe | newrecipe | picker | ingredient | recipedetail`.
    private func applyDebugScreen() {
        let first = store.recipes.first { $0.id == "demo-recipe-chili" } ?? store.recipes.first
        switch UserDefaults.standard.string(forKey: "PlateScreen") {
        case "recipes": segment = .recipes
        case "foods": segment = .foods
        case "favorites", "library": if UserDefaults.standard.string(forKey: "PlateSegment") == nil { segment = .favorites }
        case "recipe", "ingredient", "picker":
            segment = .recipes
            recipeRequest = RecipeRequest(recipe: first)
        case "newrecipe":
            segment = .recipes
            recipeRequest = RecipeRequest()
        case "recipedetail":
            segment = .recipes
            if let first { path = [.food(first)] }
        default: break
        }
        if let s = UserDefaults.standard.string(forKey: "PlateSegment").flatMap(Segment.init(rawValue:)) { segment = s }
        if let q = UserDefaults.standard.string(forKey: "PlateLibraryQuery") { query = q }
    }
}
