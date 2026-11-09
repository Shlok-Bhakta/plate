// DESIGN 4.3 Food detail and serving picker: live preview, amount stepper and multiplier chips, unit
// menu (serving, portions, grams, ounces), FDA-style nutrition label, and "Add to Lunch · 135 kcal".
import SwiftUI

struct FoodDetailView: View {
    var food: Food
    @Binding var meal: Meal
    var day: String
    var source = "app"
    /// Recipe-ingredient mode: the bottom button reads "Add to recipe" and hands back the amount.
    var addToRecipe: ((AmountUnit, Double) -> Void)? = nil
    var onLogged: () -> Void

    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    @State private var unit: AmountUnit = .serving
    @State private var amount: Double = 1
    /// Set once the starting amount is picked from the units (a "100 g" serving starts in ounces in US units).
    @State private var started = false
    @State private var savedID: String?
    @State private var favoriteBounce = 0
    @State private var sheet: FoodSheet?
    /// Set when this screen deletes the food itself, so it doesn't also say "This food was deleted".
    @State private var deletingSelf = false

    private enum FoodSheet: Identifiable {
        case edit(Food), copy(Food), recipe(Food)
        var id: String {
            switch self {
            case .edit(let f): "e" + f.listID
            case .copy(let f): "c" + f.listID
            case .recipe(let f): "r" + f.listID
            }
        }
    }

    private var current: Food { store.food(id: savedID ?? food.id) ?? food }
    /// Deleted here, in Library, or on another device while this screen was open.
    private var wasDeleted: Bool { store.isDeletedFood(savedID ?? food.id) }
    private var servings: Double { current.servings(amount: amount, unit: unit) }
    private var scaled: NutrientMap { current.nutrients(servings: servings) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                PreviewCard(nutrients: scaled)
                AmountCard(food: current, unit: $unit, amount: $amount)
                if current.kind == .recipe { RecipeIngredientsCard(recipe: current) }
                NutritionLabel(nutrients: scaled, servingText: servingText, goals: store.goals,
                               knownCount: current.nutrients.count)
            }
            .padding(.horizontal, Space.l)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Palette.background)
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { addButton }
        .toolbar { toolbar }
        .onAppear {
            guard !started else { return }
            started = true
            (unit, amount) = current.defaultAmount(units)
            debugStartUnit()
        }
        .onChange(of: wasDeleted, initial: true) { _, gone in
            guard gone, !deletingSelf else { return }
            Haptics.warning()
            Toasts.shared.message("This food was deleted", symbol: "trash.fill")
            dismiss()
        }
        .sheet(item: $sheet) { s in
            NavigationStack {
                switch s {
                case .edit(let f): CustomFoodForm(editing: f) { _ in sheet = nil }
                case .copy(let f): CustomFoodForm(copying: f) { _ in sheet = nil }
                case .recipe(let f): RecipeBuilderView(editing: f) { _ in sheet = nil }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(current.name)
                .scaledFont(22, .bold, relativeTo: .title2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let brand = current.brand { Text(brand).foregroundStyle(.secondary) }
                if let badge = sourceBadge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Palette.chip, in: Capsule())
                }
            }
            .font(.subheadline)
        }
    }

    private var sourceBadge: String? {
        switch current.kind == .recipe ? "recipe" : current.source {
        case "usda": "USDA"
        case "off": "Open Food Facts"
        case "custom": "My food"
        case "agent": "Added by agent"
        case "recipe": "Recipe"
        default: nil
        }
    }

    /// Debug: -PlateAmountUnit ounces | grams | portion<n> starts in that unit (weights at 1.5 servings).
    private func debugStartUnit() {
        guard let raw = UserDefaults.standard.string(forKey: "PlateAmountUnit") else { return }
        let new: AmountUnit? = switch raw {
        case "ounces": .ounces
        case "grams": .grams
        default: raw.hasPrefix("portion") ? Int(raw.dropFirst(7)).map { .portion($0) } : nil
        }
        guard let new, current.offers(new) else { return }
        unit = new
        amount = new == .grams || new == .ounces ? current.amount(servings: 1.5, in: new) : 1
    }

    /// The label's serving line in display units: "1 cup (8.6 oz)", "1.5 container (9 oz)", "9 oz".
    /// A weight typed in the other unit shows the preferred one after it: "255 g (9 oz)".
    private var servingText: String {
        let weight = current.servingGrams.map { Fmt.foodWeight($0 * servings, units) }
        switch unit {
        case .grams:
            return "\(Fmt.grams(amount)) g" + (units.food == .oz ? weight.map { " (\($0))" } ?? "" : "")
        case .ounces:
            return "\(Fmt.foodInput(amount, .oz)) oz" + (units.food == .g ? weight.map { " (\($0))" } ?? "" : "")
        default:
            let name = current.unitName(unit, units)
            if Fmt.isWeightLabel(name), let weight { return weight }
            let main = name.first?.isNumber == true
                ? (abs(amount - 1) < 0.001 ? name : "\(Fmt.servings(amount)) × \(name)")
                : "\(Fmt.servings(amount)) \(name)"
            return main + (weight.map { " (\($0))" } ?? "")
        }
    }

    private var addButton: some View {
        Button {
            if let addToRecipe {
                addToRecipe(unit, amount)
                onLogged()
                return
            }
            guard let e = Actions.log(current, servings: servings, meal: meal, day: day, source: source) else {
                dismiss()
                return
            }
            savedID = e.foodID
            onLogged()
        } label: {
            Text("\(addToRecipe == nil ? "Add to \(meal.title)" : "Add to recipe") · \(Fmt.kcal(scaled["kcal"])) kcal")
                .font(.headline)
                .monospacedDigit()
                .contentTransition(.numericText(value: scaled["kcal"] ?? 0))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .tint(Palette.accent)
        .controlSize(.large)
        .padding(.horizontal, Space.l)
        .padding(.bottom, 8)
        .disabled(servings <= 0)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                guard let f = store.setFavorite(current, !current.favorite) else { return }
                savedID = f.id
                favoriteBounce += 1
                Haptics.light()
            } label: {
                Image(systemName: current.favorite ? "star.fill" : "star")
                    .foregroundStyle(current.favorite ? Palette.accent : Color.primary)
                    .symbolEffect(.bounce, value: favoriteBounce)
            }
            .accessibilityLabel(current.favorite ? "Unfavorite" : "Favorite")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if current.source == "custom", current.kind != .recipe, current.id != nil {
                    Button { sheet = .edit(current) } label: { Label("Edit food", systemImage: "pencil") }
                }
                if current.kind == .recipe, current.id != nil {
                    Button { sheet = .recipe(current) } label: { Label("Edit recipe", systemImage: "pencil") }
                }
                Button { sheet = .copy(current) } label: { Label("Copy as new food", systemImage: "doc.on.doc") }
                if let id = current.id, store.food(id: id) != nil {
                    Divider()
                    Button(role: .destructive) {
                        deletingSelf = true
                        store.deleteFood(id: id)
                        dismiss()
                    } label: { Label("Delete food", systemImage: "trash") }
                }
            } label: { Image(systemName: "ellipsis") }
            .tint(.primary)
            .accessibilityLabel("More")
        }
    }
}

/// The live preview: kcal, P/C/F/Fiber in macro inks, and a stacked kcal-share bar.
struct PreviewCard: View {
    var nutrients: NutrientMap

    var body: some View {
        let kcal = nutrients["kcal"] ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.whole(kcal))
                    .numberFont(34, .bold, relativeTo: .largeTitle)
                    .contentTransition(.numericText(value: kcal))
                Text("kcal").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                macro("P", "protein")
                macro("C", "carbs")
                macro("F", "fat")
                macro("Fiber", "fiber")
            }
            StackedMacroBar(nutrients: nutrients)
        }
        .card()
        .animation(.snappy, value: kcal)
    }

    private func macro(_ letter: String, _ key: String) -> some View {
        HStack(spacing: 3) {
            Text(letter).foregroundStyle(Palette.ink(key)).fontWeight(.semibold)
            Text(nutrients[key].map { "\(Fmt.grams($0)) g" } ?? Fmt.missing)
                .contentTransition(.numericText(value: nutrients[key] ?? 0))
        }
        .numberFont(15, .medium, relativeTo: .subheadline)
        .lineLimit(1)
    }
}

/// Each macro's share of kcal (P × 4, C × 4, F × 9), 6 pt tall with 2 pt gaps.
struct StackedMacroBar: View {
    var nutrients: NutrientMap
    var body: some View {
        let s = NutritionMath.macroKcalShares(nutrients)
        GeometryReader { g in
            let parts = [(s.protein, Palette.protein), (s.carbs, Palette.carbs), (s.fat, Palette.fat)].filter { $0.0 > 0 }
            let gaps = CGFloat(max(0, parts.count - 1)) * 2
            HStack(spacing: 2) {
                if parts.isEmpty {
                    Capsule().fill(Palette.track)
                } else {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        Capsule().fill(p.1).frame(width: max(3, (g.size.width - gaps) * p.0))
                    }
                }
            }
        }
        .frame(height: 6)
        .animation(.snappy, value: s.protein)
        .accessibilityHidden(true)
    }
}

/// Amount stepper (±0.25 servings or ±5 g), multiplier chips, and the unit menu.
struct AmountCard: View {
    var food: Food
    @Binding var unit: AmountUnit
    @Binding var amount: Double
    @Environment(\.units) private var units
    @State private var typing = false
    @State private var text = ""
    /// The text the field opened with; committing it unchanged keeps the exact amount (no drift).
    @State private var openedWith = ""
    @FocusState private var focused: Bool

    private var step: Double {
        switch unit { case .grams: FoodWeightUnit.g.step; case .ounces: FoodWeightUnit.oz.step; default: 0.25 }
    }

    /// The amount as shown: whole grams, ounces to 0.1, servings to 0.01.
    private var shown: String {
        switch unit {
        case .grams: Fmt.whole(amount)
        case .ounces: Fmt.foodInput(amount, .oz)
        default: Fmt.trim(amount)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Amount").font(.body)
                Spacer()
                stepper
            }
            if unit != .grams && unit != .ounces {
                HStack(spacing: 8) {
                    ForEach([0.5, 1, 1.5, 2, 3], id: \.self) { m in
                        let selected = abs(amount - m) < 0.001
                        Button {
                            withAnimation(.snappy) { amount = m }
                            Haptics.selection()
                        } label: {
                            Text(Fmt.servings(m))
                                .numberFont(15, .semibold, relativeTo: .subheadline)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .frame(maxWidth: .infinity, minHeight: Space.chipHeight)
                                .background(selected ? Palette.accent : Palette.chip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(Fmt.trim(m)) times")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            Divider()
            HStack {
                Text("Unit").font(.body)
                Spacer()
                Menu {
                    ForEach(food.amountUnits(units), id: \.self) { u in
                        Button(food.unitLabel(u, units)) { change(to: u) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(food.unitLabel(unit, units)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Palette.accentInk)
                }
            }
        }
        .card()
        .onChange(of: food.amountUnits(units), initial: true) { _, _ in
            // The serving weight went away (edited here or elsewhere): grams can't be counted as servings.
            let n = food.normalized(amount: amount, unit: unit)
            if n.unit != unit { unit = n.unit; amount = n.amount }
        }
    }

    private var stepper: some View {
        HStack(spacing: 4) {
            stepButton("minus") { amount = max(step, ((amount - step) / step).rounded() * step) }
                .disabled(amount <= step)
            Group {
                if typing {
                    TextField("", text: $text)
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .multilineTextAlignment(.center)
                        .onSubmit(commit)
                        .onChange(of: focused) { _, f in if !f { commit() } }
                } else {
                    Text(shown)
                        .contentTransition(.numericText(value: amount))
                        .lineLimit(1)
                        .onTapGesture {
                            text = shown
                            openedWith = shown
                            typing = true
                            focused = true
                        }
                }
            }
            .numberFont(20, .semibold, relativeTo: .title3)
            .frame(minWidth: 64)
            stepButton("plus") { amount = min(maxAmount, ((amount + step) / step).rounded() * step) }
        }
        .sensoryFeedback(.selection, trigger: amount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Amount")
        .accessibilityValue("\(shown) \(food.unitLabel(unit, units))")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: amount = min(maxAmount, amount + step)
            case .decrement: amount = max(step, amount - step)
            default: break
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 36)
                .background(Palette.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The most an amount can be: 100 servings or portions, 10 kg, or about the same weight in ounces.
    private static func limit(_ unit: AmountUnit) -> Double {
        switch unit { case .grams: 10_000; case .ounces: 350; default: 100 }
    }
    private var maxAmount: Double { Self.limit(unit) }

    private func commit() {
        if text != openedWith, let v = Fmt.parse(text), v > 0 {
            withAnimation(.snappy) { amount = min(v, maxAmount) }
        }
        typing = false
    }

    private func change(to new: AmountUnit) {
        guard new != unit else { return }
        let servings = food.servings(amount: amount, unit: unit)
        // Exact, so switching units never changes the weight; the display rounds. Servings and portions
        // round to 0.01 so the multiplier chips can match.
        var next = food.amount(servings: servings, in: new)
        if new != .grams && new != .ounces { next = (next * 100).rounded() / 100 }
        withAnimation(.snappy) {
            unit = new
            amount = min(Self.limit(new), max(next, new == .grams ? 1 : 0.05))
        }
    }
}

/// The FDA-style label (DESIGN 4.3): % of the user's own goals, "–" for unknown, expandable.
struct NutritionLabel: View {
    var nutrients: NutrientMap
    var servingText: String
    var goals: Goals?
    var knownCount: Int
    @Environment(\.units) private var units
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nutrition Facts").font(.system(size: 28, weight: .black)).padding(.bottom, 2)
            Text(servingText).font(.subheadline).monospacedDigit().padding(.bottom, 4)
            rule(8)
            HStack(alignment: .firstTextBaseline) {
                Text("Calories").font(.system(size: 22, weight: .black))
                Spacer()
                Text(Fmt.kcal(nutrients["kcal"])).font(.system(size: 28, weight: .black)).monospacedDigit()
                    .contentTransition(.numericText(value: nutrients["kcal"] ?? 0))
            }
            rule(4)
            HStack { Spacer(); Text("% of goal").font(.footnote.weight(.bold)) }.padding(.vertical, 3)
            rule(1)
            ForEach(Nutrients.labelOrder, id: \.key) { row in
                line(row.key, indent: row.indent)
                rule(1)
            }
            if showAll {
                ForEach(Nutrients.detailSections, id: \.group) { section in
                    let keys = section.keys.filter { k in k != "kcal" && !Nutrients.labelOrder.contains { $0.key == k } }
                    if !keys.isEmpty {
                        HStack(spacing: 6) {
                            GroupDot(color: Palette.group(section.group))
                            Text(section.group.title).font(.subheadline.weight(.bold))
                        }
                        .padding(.top, 10).padding(.bottom, 4)
                        rule(1)
                        ForEach(keys, id: \.self) { k in
                            line(k, indent: false)
                            rule(1)
                        }
                    }
                }
            }
            Button {
                withAnimation(.smooth) { showAll.toggle() }
            } label: {
                HStack {
                    Text(showAll ? "Show fewer" : "Show all nutrients (\(knownCount))")
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showAll ? 180 : 0))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.accentInk)
                .padding(.top, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Palette.card, in: .rect(cornerRadius: Space.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Space.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
        }
    }

    private func rule(_ height: CGFloat) -> some View {
        Rectangle().fill(Color.primary).frame(height: height)
    }

    private func line(_ key: String, indent: Bool) -> some View {
        let info = Nutrients.info(key)
        let value = nutrients[key]
        let pct = NutritionMath.percent(value, of: goals?.target(key))
        let name = labelName(key)
        return HStack(spacing: 4) {
            Text(name).fontWeight(indent ? .regular : .bold)
            Text(value.map { v in
                info?.unit == "ml" ? Fmt.volume(v, units) : "\(Fmt.amount(v, unit: info?.unit ?? "g")) \(info?.displayUnit ?? "")"
            } ?? Fmt.missing)
                .foregroundStyle(value == nil ? .tertiary : .primary)
            Spacer(minLength: 8)
            if value != nil, let pct { Text("\(pct)%").fontWeight(.bold) }
        }
        .font(.system(size: 15))
        .monospacedDigit()
        .padding(.leading, indent ? 16 : 0)
        .padding(.vertical, 4)
    }

    private func labelName(_ key: String) -> String {
        switch key {
        case "fat": "Total Fat"
        case "sat_fat": "Saturated Fat"
        case "trans_fat": "Trans Fat"
        case "carbs": "Total Carbohydrate"
        case "fiber": "Dietary Fiber"
        case "sugar": "Total Sugars"
        case "added_sugar": "Incl. Added Sugars"
        default: Nutrients.info(key)?.name ?? key
        }
    }
}
