// DESIGN 4.2 Quick add (kcal and macros) and 4.8 custom food form.
import SwiftUI

struct QuickAddView: View {
    var meal: Meal
    var day: String
    var initialName: String
    var onDone: () -> Void

    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var name = ""
    @FocusState private var focus: Field?
    private enum Field { case kcal, protein, carbs, fat, name }

    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")).flatMap { $0 >= 0 ? $0 : nil } }
    private var macroKcal: Double? { NutritionMath.kcalFromMacros(protein: num(protein), carbs: num(carbs), fat: num(fat)) }
    private var total: Double? { num(kcal) ?? macroKcal }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 2) {
                    TextField(macroKcal.map(Fmt.whole) ?? "0", text: $kcal)
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .kcal)
                        .multilineTextAlignment(.center)
                        .numberFont(34, .bold, relativeTo: .largeTitle)
                    Text("kcal").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                .card(padding: 20)

                HStack(spacing: 12) {
                    macroField("Protein", "protein", $protein, .protein)
                    macroField("Carbs", "carbs", $carbs, .carbs)
                    macroField("Fat", "fat", $fat, .fat)
                }

                TextField("Name (optional)", text: $name)
                    .focused($focus, equals: .name)
                    .submitLabel(.done)
                    .card()
            }
            .padding(.horizontal, Space.l)
            .padding(.top, 8)
        }
        .background(Palette.background)
        .navigationTitle("Quick add")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: add) {
                Text(total.map { "Add · \(Fmt.whole($0)) kcal" } ?? "Add")
                    .font(.headline).monospacedDigit()
                    .contentTransition(.numericText(value: total ?? 0))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .controlSize(.large)
            .disabled(total == nil)
            .padding(.horizontal, Space.l)
            .padding(.bottom, 8)
        }
        .onAppear {
            name = initialName
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                focus = .kcal
            }
        }
    }

    private func macroField(_ title: String, _ key: String, _ text: Binding<String>, _ field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink(key))
            HStack(spacing: 2) {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: field)
                    .numberFont(20, .semibold, relativeTo: .title3)
                Text("g").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: .rect(cornerRadius: 20, style: .continuous))
    }

    private func add() {
        guard let total else { return }
        var n: NutrientMap = ["kcal": total]
        if let p = num(protein) { n["protein"] = p }
        if let c = num(carbs) { n["carbs"] = c }
        if let f = num(fat) { n["fat"] = f }
        let title = name.trimmingCharacters(in: .whitespaces)
        Actions.quick(name: title.isEmpty ? "Quick add" : title, nutrients: n, meal: meal, day: day)
        onDone()
    }
}

/// DESIGN 4.8 custom food form. Creates, edits, or copies a food.
struct CustomFoodForm: View {
    var onSaved: (Food) -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units

    private let original: Food?
    @State private var name: String
    @State private var brand: String
    @State private var barcode: String
    @State private var servingAmount: String
    @State private var servingUnit: String
    @State private var servingGrams: String
    @State private var values: [String: String]
    @State private var portions: [EditablePortion]
    @State private var scanning = false
    /// Weights are typed in the food unit the form opened with (oz or g); unchanged fields keep their
    /// exact grams, so opening and saving a food never moves its weights.
    @State private var weightUnit: FoodWeightUnit?
    @State private var weightInput = MetricInput(nil, factor: 1)
    private let originalGrams: Double?

    struct EditablePortion: Identifiable {
        var id = UUID()
        var label: String
        /// The stored weight, nil for a new portion.
        var grams: Double?
        var text = ""
        var input = MetricInput(nil, factor: 1)
    }

    init(initialName: String = "", barcode: String? = nil, onSaved: @escaping (Food) -> Void) {
        self.init(food: nil, name: initialName, barcode: barcode, onSaved: onSaved)
    }
    init(editing food: Food, onSaved: @escaping (Food) -> Void) {
        self.init(food: food, name: food.name, barcode: food.barcode, onSaved: onSaved, keepIdentity: true)
    }
    init(copying food: Food, onSaved: @escaping (Food) -> Void) {
        self.init(food: food, name: food.name + " copy", barcode: nil, onSaved: onSaved)
    }
    private init(food: Food?, name: String, barcode: String?, onSaved: @escaping (Food) -> Void, keepIdentity: Bool = false) {
        self.onSaved = onSaved
        original = keepIdentity ? food : nil
        _name = State(initialValue: name)
        _brand = State(initialValue: food?.brand ?? "")
        _barcode = State(initialValue: barcode ?? "")
        _servingAmount = State(initialValue: Fmt.trim(food?.serving.amount ?? 1))
        _servingUnit = State(initialValue: food?.serving.unit ?? "serving")
        _servingGrams = State(initialValue: "")
        originalGrams = food?.servingGrams
        _values = State(initialValue: (food?.nutrients ?? [:]).mapValues(Fmt.trim))
        _portions = State(initialValue: (food?.portions ?? []).map { EditablePortion(label: $0.label, grams: $0.grams) })
    }

    /// Fills the weight fields in the current food unit, once.
    private func loadWeights() {
        guard weightUnit == nil else { return }
        let u = units.food
        weightUnit = u
        weightInput = MetricInput(grams: originalGrams, u)
        servingGrams = weightInput.initialText
        for i in portions.indices {
            portions[i].input = MetricInput(grams: portions[i].grams, u)
            portions[i].text = portions[i].input.initialText
        }
    }

    private var weightSymbol: String { (weightUnit ?? units.food).symbol }

    private func num(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        return Double(s.replacingOccurrences(of: ",", with: ".")).flatMap { $0 >= 0 ? $0 : nil }
    }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && num(values["kcal"]) != nil }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Brand", text: $brand)
                HStack {
                    TextField("Barcode", text: $barcode).keyboardType(.numberPad)
                    Button { scanning = true } label: { Image(systemName: "barcode.viewfinder") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Scan barcode")
                }
            }
            Section("Serving") {
                HStack {
                    TextField("1", text: $servingAmount).keyboardType(.decimalPad).frame(width: 60)
                    TextField("unit, e.g. cup", text: $servingUnit)
                }
                unitField("Weight (optional)", text: $servingGrams, unit: weightSymbol)
            }
            Section("Calories & macros") {
                ForEach(["kcal", "protein", "carbs", "fat", "fiber"], id: \.self) { key in
                    nutrientField(key)
                }
            }
            Section("More nutrients") {
                ForEach(Nutrients.detailSections, id: \.group) { section in
                    let keys = section.keys.filter { !["kcal", "protein", "carbs", "fat", "fiber"].contains($0) }
                    DisclosureGroup {
                        ForEach(keys, id: \.self) { nutrientField($0) }
                    } label: {
                        HStack(spacing: 8) {
                            GroupDot(color: Palette.group(section.group))
                            Text(section.group.title)
                        }
                    }
                }
            }
            Section {
                ForEach($portions) { $p in
                    HStack {
                        TextField("Label, e.g. 1 cup", text: $p.label)
                        TextField(weightSymbol, text: $p.text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                        Text(weightSymbol).foregroundStyle(.secondary)
                    }
                }
                .onDelete { portions.remove(atOffsets: $0) }
                Button { portions.append(EditablePortion(label: "", grams: nil)) } label: {
                    Label("Add portion", systemImage: "plus")
                }
            } header: {
                Text("Portions")
            } footer: {
                Text("Portions scale by weight, so they need the serving weight above.")
            }
        }
        .onAppear(perform: loadWeights)
        .navigationTitle(original == nil ? "New food" : "Edit food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) { Image(systemName: "checkmark") }
                    .disabled(!canSave)
                    .accessibilityLabel("Save")
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            BarcodeCaptureView { code in
                if let code { barcode = code }
                scanning = false
            }
        }
    }

    private func unitField(_ title: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(title)
            TextField("–", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func nutrientField(_ key: String) -> some View {
        let info = Nutrients.info(key)
        return unitField(info?.name ?? key, text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }),
                         unit: info?.displayUnit ?? "")
    }

    private func save() {
        var n = NutrientMap()
        for (k, v) in values { if let x = num(v) { n[k] = x } }
        var food = original ?? Food(name: name, nutrients: n)
        food.name = name.trimmingCharacters(in: .whitespaces)
        food.brand = brand.isEmpty ? nil : brand
        food.barcode = barcode.isEmpty ? nil : barcode
        food.serving = Serving(amount: num(servingAmount) ?? 1, unit: servingUnit.isEmpty ? "serving" : servingUnit,
                               grams: weightInput.metric(from: servingGrams).flatMap { $0 > 0 ? NutritionMath.round3($0) : nil })
        food.portions = portions.compactMap { p in
            guard let g = p.input.metric(from: p.text), g > 0 else { return nil }
            let typed = p.text.trimmingCharacters(in: .whitespaces)
            return Portion(label: p.label.isEmpty ? "\(typed) \(weightSymbol)" : p.label, grams: p.input.original == g ? g : NutritionMath.round3(g))
        }
        food.nutrients = n
        food.source = original?.source ?? "custom"
        guard store.save(food: food) else {
            Haptics.warning()
            Toasts.shared.message("This food was deleted", symbol: "trash.fill")
            onSaved(food)
            return
        }
        Haptics.success()
        Toasts.shared.message("Saved \(food.name)")
        onSaved(store.food(id: food.id) ?? food)
    }
}
