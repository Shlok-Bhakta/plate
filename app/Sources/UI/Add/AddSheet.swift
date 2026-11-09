// DESIGN 4.2 Add sheet and 4.9 Search tab. One search component (`FoodSearchView`) serves both:
// favorites and recent chips, frequent rows, yesterday's meal, quick add, create food, and debounced
// server search with own foods shown instantly first.
import SwiftUI

enum AddRoute: Hashable {
    case food(Food)
    case quickAdd
    case create(name: String, barcode: String?)
}

/// What the current Add sheet has logged, for "2 added · 290 kcal".
@Observable
@MainActor
final class AddSession {
    nonisolated(unsafe) static weak var current: AddSession?
    private(set) var ids: [String] = []
    func record(_ entries: [Entry]) { ids += entries.map(\.id) }
    func live(in store: Store) -> [Entry] { ids.compactMap { store.entry(id: $0) } }
}

struct AddSheet: View {
    var request: AddRequest
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var meal: Meal
    @State private var path: [AddRoute] = []
    @State private var query: String
    @State private var session = AddSession()
    @State private var scanning = false
    /// The start action runs once per presentation; onAppear fires again when the scanner cover closes.
    @State private var started = false
    @FocusState private var searchFocused: Bool

    init(request: AddRequest) {
        self.request = request
        _meal = State(initialValue: request.meal)
        _query = State(initialValue: request.query)
    }

    var body: some View {
        NavigationStack(path: $path) {
            FoodSearchView(meal: $meal, day: request.day, query: $query, path: $path, isSheet: true,
                           onScan: { scanning = true })
                .searchable(text: $query, placement: .automatic, prompt: "Search foods")
                .searchFocused($searchFocused)
                .searchPresentationToolbarBehavior(.avoidHidingContent)
                .toolbar { toolbar }
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: AddRoute.self) { route in
                    destination(route)
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .fullScreenCover(isPresented: $scanning) {
            BarcodeScannerView(meal: meal, day: request.day) { route in
                scanning = false
                if let route { path.append(route) }
            }
        }
        .onAppear {
            AddSession.current = session
            guard !started else { return }
            started = true
            switch request.start {
            case .search:
                if !UserDefaults.standard.bool(forKey: "PlateNoFocus") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        searchFocused = true
                    }
                }
            case .scanner: scanning = true
            case .quickAdd: path = [.quickAdd]
            case .create: path = [.create(name: request.query, barcode: nil)]
            case .food(let id): if let f = store.food(id: id) { path = [.food(f)] }
            }
        }
        .onDisappear {
            // The scanner cover hides the sheet without ending it; logs from the scanner still count here.
            if !scanning, AddSession.current === session { AddSession.current = nil }
        }
    }

    @ViewBuilder func destination(_ route: AddRoute) -> some View {
        switch route {
        case .food(let food):
            FoodDetailView(food: food, meal: $meal, day: request.day) { path.removeAll() }
        case .quickAdd:
            QuickAddView(meal: meal, day: request.day, initialName: "") { path.removeAll() }
        case .create(let name, let barcode):
            CustomFoodForm(initialName: name, barcode: barcode) { saved in
                path.removeAll()
                path.append(.food(saved))
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let added = session.live(in: store)
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: added.isEmpty ? "xmark" : "checkmark")
                    .contentTransition(.symbolEffect(.replace))
            }
            .tint(.primary)
            .accessibilityLabel(added.isEmpty ? "Close" : "Done")
        }
        ToolbarItem(placement: .principal) {
            MealMenu(meal: $meal, added: added)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { scanning = true } label: { Image(systemName: "barcode.viewfinder") }
                .tint(.primary)
                .accessibilityLabel("Scan barcode")
        }
    }
}

/// The principal meal menu, with "2 added · 290 kcal" under it after the first add.
struct MealMenu: View {
    @Binding var meal: Meal
    var added: [Entry] = []

    var body: some View {
        Menu {
            Picker("Meal", selection: $meal) {
                ForEach(Meal.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(meal.title).font(.headline).foregroundStyle(.primary)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                }
                if !added.isEmpty {
                    let kcal = added.compactMap(\.kcal).reduce(0, +)
                    Text("\(added.count) added · \(Fmt.kcal(kcal)) kcal")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: kcal))
                }
            }
            .animation(.snappy, value: added.count)
        }
        .tint(.primary)
        .sensoryFeedback(.selection, trigger: meal)
        .accessibilityLabel("Meal, \(meal.title)")
    }
}

// MARK: - The shared search component

struct FoodSearchView: View {
    @Binding var meal: Meal
    var day: String
    @Binding var query: String
    @Binding var path: [AddRoute]
    var isSheet: Bool
    var onScan: () -> Void
    /// Picker mode (recipe ingredients): ⊕ picks the food instead of logging it, and the idle state lists
    /// your own foods instead of one-tap logging suggestions.
    var pick: ((Food) -> Void)? = nil
    @Environment(Store.self) private var store

    @State private var serverResults: [Food] = []
    @State private var loading = false
    @State private var failed = false
    @State private var searchedQuery = ""

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if trimmed.isEmpty {
                    if let pick {
                        IngredientSuggestions(path: $path, pick: pick)
                    } else {
                        SuggestionsContent(meal: meal, day: day, path: $path, onScan: onScan)
                    }
                } else {
                    results
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 80)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Palette.background)
        .overlay(alignment: .top) {
            if loading && !trimmed.isEmpty { IndeterminateLine().transition(.opacity) }
        }
        .toastHost()
        .task(id: trimmed) { await runSearch(trimmed) }
    }

    private func runSearch(_ q: String) async {
        guard !q.isEmpty else { serverResults = []; loading = false; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        loading = true
        do {
            let found = try await store.search(q)
            guard !Task.isCancelled else { return }
            serverResults = found
            failed = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            serverResults = []
            failed = true
        }
        searchedQuery = q
        withAnimation(.smooth) { loading = false }
    }

    @ViewBuilder private var results: some View {
        let local = store.searchLocal(trimmed)
        let localIDs = Set(local.compactMap(\.id))
        let mine = local + serverResults.filter { f in
            guard let id = f.id else { return false }
            return !localIDs.contains(id)
        }
        let others = serverResults.filter { $0.id == nil || store.food(id: $0.id) == nil && !localIDs.contains($0.id ?? "") }
            .filter { $0.id == nil }
        let catalog = others.filter { !($0.sourceRef ?? "").hasPrefix("off:") && $0.source != "off" }
        let products = others.filter { ($0.sourceRef ?? "").hasPrefix("off:") || $0.source == "off" }

        if !mine.isEmpty { resultGroup("My foods", mine) }
        if !catalog.isEmpty { resultGroup("Foods", catalog) }
        if !products.isEmpty { resultGroup("Products", products) }

        if mine.isEmpty && catalog.isEmpty && products.isEmpty && !loading && searchedQuery == trimmed {
            NoResults(query: trimmed, path: $path, onScan: onScan, picking: pick != nil)
        }
        if failed || (!store.isDemo && store.connection != .synced && !store.isOnline) {
            Text("Offline: showing your foods only")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private func resultGroup(_ title: String, _ foods: [Food]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sectionCaps().padding(.horizontal, Space.l + 4)
            VStack(spacing: 0) {
                ForEach(Array(foods.enumerated()), id: \.element.listID) { i, food in
                    if i > 0 { Divider().padding(.leading, Space.l) }
                    FoodResultRow(food: food, actionLabel: pick == nil ? nil : "Add \(food.name) to recipe") {
                        path.append(.food(food))
                    } onLog: {
                        if let pick { pick(food) } else { Actions.log(food, servings: 1, meal: meal, day: day) }
                    }
                }
            }
            .background(Palette.card, in: .rect(cornerRadius: Space.cardRadius, style: .continuous))
            .padding(.horizontal, Space.l)
        }
    }
}

/// Favorites, Recent, Frequent at <meal>, Yesterday's <meal>, then Quick add and Create food.
private struct SuggestionsContent: View {
    var meal: Meal
    var day: String
    @Binding var path: [AddRoute]
    var onScan: () -> Void
    @Environment(Store.self) private var store
    @State private var serverFrequent: [Food] = []

    var body: some View {
        let favorites = Array(store.favorites.prefix(10))
        let recents = Array(store.recentEntries.prefix(15))
        let frequent = store.frequent(meal: meal, limit: 4)
        let yesterday = store.previousMeal(meal, before: day)

        if !favorites.isEmpty {
            section("Favorites") {
                ChipRow {
                    ForEach(favorites) { food in
                        FoodChip(name: food.name, kcal: food.kcal, favorite: true) {
                            Actions.log(food, servings: 1, meal: meal, day: day)
                        } onLongPress: { path.append(.food(food)) }
                    }
                }
            }
        }
        if !recents.isEmpty {
            section("Recent") {
                ChipRow {
                    ForEach(recents) { e in
                        FoodChip(name: e.name, kcal: e.kcal) {
                            Actions.again([e], meal: meal, day: day)
                        } onLongPress: {
                            if let f = store.food(id: e.foodID) { path.append(.food(f)) }
                        }
                    }
                }
            }
        }
        let extra = serverFrequent.filter { f in !frequent.contains { $0.foodID == f.id } }.prefix(max(0, 4 - frequent.count))
        if !frequent.isEmpty || !extra.isEmpty {
            section("Frequent at \(meal.noun)") {
                rows {
                    ForEach(Array(frequent.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider().padding(.leading, Space.l) }
                        SuggestionRow(title: e.name, subtitle: "\(Fmt.kcal(e.kcal)) kcal") {
                            if let f = store.food(id: e.foodID) { path.append(.food(f)) }
                        } onLog: { Actions.again([e], meal: meal, day: day) }
                    }
                    ForEach(Array(extra), id: \.listID) { f in
                        Divider().padding(.leading, Space.l)
                        SuggestionRow(title: f.name, subtitle: "\(Fmt.kcal(f.kcal)) kcal") {
                            path.append(.food(f))
                        } onLog: { Actions.log(f, servings: 1, meal: meal, day: day) }
                    }
                }
            }
        }
        if !yesterday.isEmpty {
            let kcal = yesterday.compactMap(\.kcal).reduce(0, +)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Yesterday's \(meal.noun)").sectionCaps()
                    Spacer()
                    Button { Actions.again(yesterday, meal: meal, day: day) } label: {
                        HStack(spacing: 4) {
                            Text("Copy all").font(.subheadline.weight(.semibold))
                            Image(systemName: "plus.circle.fill").font(.system(size: 17))
                                .symbolRenderingMode(.palette).foregroundStyle(.white, Palette.accent)
                        }
                        .foregroundStyle(Palette.accentInk)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Space.l + 4)
                rows {
                    SuggestionRow(title: yesterday.map(\.name).joined(separator: " · "),
                                  subtitle: "\(yesterday.count) item\(yesterday.count == 1 ? "" : "s") · \(Fmt.kcal(kcal)) kcal") {
                        Actions.again(yesterday, meal: meal, day: day)
                    } onLog: { Actions.again(yesterday, meal: meal, day: day) }
                }
            }
        }
        HStack(spacing: 10) {
            Button { path.append(.quickAdd) } label: { ActionLabel(title: "Quick add", symbol: "bolt.fill") }
            Button { path.append(.create(name: "", barcode: nil)) } label: { ActionLabel(title: "Create food", symbol: "plus") }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.secondary)
        .padding(.horizontal, Space.l)
        .task(id: meal) {
            serverFrequent = await store.serverSuggestions(meal: meal, day: day)?.frequent ?? []
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sectionCaps().padding(.horizontal, Space.l + 4)
            content()
        }
    }

    private func rows<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(Palette.card, in: .rect(cornerRadius: Space.cardRadius, style: .continuous))
            .padding(.horizontal, Space.l)
    }
}

/// A bordered-capsule label: accent symbol, primary text.
struct ActionLabel: View {
    var title: String
    var symbol: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Palette.accent)
            Text(title).foregroundStyle(.primary)
        }
        .font(.subheadline.weight(.semibold))
    }
}

/// A 52 pt row: name, kcal subline, trailing one-tap ⊕.
struct SuggestionRow: View {
    var title: String
    var subtitle: String
    var onOpen: () -> Void
    var onLog: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body).foregroundStyle(.primary).lineLimit(1)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            LogPlusButton(label: "Log \(title)", action: onLog)
        }
        .padding(.leading, Space.l)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
    }
}

/// A search result: name, brand and serving, kcal per serving, ⊕.
struct FoodResultRow: View {
    var food: Food
    /// VoiceOver label for ⊕ when it doesn't log (picker mode).
    var actionLabel: String? = nil
    var onOpen: () -> Void
    var onLog: () -> Void
    @Environment(\.units) private var units

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            if food.favorite {
                                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Palette.accent)
                            }
                            Text(food.name).font(.body).foregroundStyle(.primary).lineLimit(1)
                        }
                        Text([food.brand, food.servingSummary(units)].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(Fmt.kcal(food.kcal)).numberFont(17, relativeTo: .body).foregroundStyle(.secondary)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            LogPlusButton(label: actionLabel ?? "Log \(food.name)", action: onLog)
        }
        .padding(.leading, Space.l)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
    }
}

private struct NoResults: View {
    var query: String
    @Binding var path: [AddRoute]
    var onScan: () -> Void
    var picking = false

    var body: some View {
        VStack(spacing: 14) {
            Text("No match for ‘\(query)’").font(.headline)
            VStack(spacing: 10) {
                if !picking {
                    Button { path.append(.quickAdd) } label: { ActionLabel(title: "Quick add", symbol: "bolt.fill").frame(maxWidth: 240) }
                }
                Button { path.append(.create(name: query, barcode: nil)) } label: {
                    ActionLabel(title: "Create ‘\(query)’", symbol: "plus").lineLimit(1).frame(maxWidth: 240)
                }
                Button(action: onScan) { ActionLabel(title: "Scan barcode", symbol: "barcode.viewfinder").frame(maxWidth: 240) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// A thin indeterminate progress line.
struct IndeterminateLine: View {
    @State private var phase: CGFloat = -0.4
    var body: some View {
        GeometryReader { g in
            Capsule()
                .fill(Palette.accent)
                .frame(width: g.size.width * 0.35, height: 2)
                .offset(x: phase * g.size.width)
        }
        .frame(height: 2)
        .clipped()
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) { phase = 1.05 } }
        .accessibilityLabel("Searching")
    }
}

// MARK: - Search tab (DESIGN 4.9)

struct SearchTabView: View {
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var phase
    @State private var query = ""
    @State private var path: [AddRoute] = []
    @State private var meal = Days.meal()
    /// True once the user picks a meal; until then it follows the time of day.
    @State private var mealPicked = false
    @State private var scanning = false
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recentSearches: [String] { recentRaw.split(separator: "\n").map(String.init) }

    private var mealBinding: Binding<Meal> {
        Binding(get: { meal }, set: { meal = $0; mealPicked = true })
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if query.isEmpty && !recentSearches.isEmpty {
                    RecentSearches(items: recentSearches, onPick: { query = $0 }, onRemove: remove)
                }
                FoodSearchView(meal: mealBinding, day: router.day, query: $query, path: $path, isSheet: false,
                               onScan: { scanning = true })
            }
            .background(Palette.background)
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Meal", selection: mealBinding) { ForEach(Meal.allCases) { Text($0.title).tag($0) } }
                    } label: {
                        HStack(spacing: 4) {
                            Text(meal.title)
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)
                    }
                }
            }
            .navigationDestination(for: AddRoute.self) { route in
                switch route {
                case .food(let food): FoodDetailView(food: food, meal: mealBinding, day: router.day) { path.removeAll() }
                case .quickAdd: QuickAddView(meal: meal, day: router.day, initialName: "") { path.removeAll() }
                case .create(let name, let barcode):
                    CustomFoodForm(initialName: name, barcode: barcode) { saved in path = [.food(saved)] }
                }
            }
        }
        .onAppear { if !mealPicked { meal = Days.meal() } }
        .onChange(of: phase) { _, now in
            // A pick is for this visit; coming back later starts from the time of day again.
            if now == .background { mealPicked = false }
            if now == .active && !mealPicked { meal = Days.meal() }
        }
        .searchable(text: $query, prompt: "Search foods")
        .onSubmit(of: .search) { remember(query) }
        .fullScreenCover(isPresented: $scanning) {
            BarcodeScannerView(meal: meal, day: router.day) { route in
                scanning = false
                if let route { path.append(route) }
            }
        }
    }

    private func remember(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var list = recentSearches.filter { $0.lowercased() != t.lowercased() }
        list.insert(t, at: 0)
        recentRaw = list.prefix(8).joined(separator: "\n")
    }

    private func remove(_ q: String) {
        recentRaw = recentSearches.filter { $0 != q }.joined(separator: "\n")
    }
}

private struct RecentSearches: View {
    var items: [String]
    var onPick: (String) -> Void
    var onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent searches").sectionCaps().padding(.horizontal, Space.l + 4)
            ChipRow {
                ForEach(items, id: \.self) { q in
                    HStack(spacing: 6) {
                        Text(q).scaledFont(15, .medium, relativeTo: .subheadline)
                        Button { onRemove(q) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(q)")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Space.chipHeight)
                    .background(Palette.chip, in: Capsule())
                    .onTapGesture { onPick(q) }
                }
            }
        }
        .padding(.top, 8)
    }
}
