// DESIGN 4.5 Entry edit: a medium/large sheet that saves live (servings, meal, day, time, note),
// with editable kcal and macros for quick entries, and delete with undo.
import SwiftUI

struct EntryEditView: View {
    var entryID: String
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let entry = store.entry(id: entryID) {
                EntryEditForm(entry: entry, close: { dismiss() })
            } else {
                ContentUnavailableView("Entry deleted", systemImage: "trash")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { dismiss() } label: { Image(systemName: "checkmark") }
                        }
                    }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct EntryEditForm: View {
    var entry: Entry
    var close: () -> Void
    @Environment(Store.self) private var store
    @Environment(\.units) private var units
    @State private var note = ""
    @State private var quick: [String: String] = [:]
    @State private var openFood = false

    private let macroKeys = ["kcal", "protein", "carbs", "fat"]

    var body: some View {
        Form {
            Section {
                if entry.isQuick && entry.servingLabel == nil {
                    ForEach(macroKeys, id: \.self) { quickField($0) }
                } else {
                    HStack {
                        Text("Servings")
                        Spacer()
                        ServingStepper(value: entry.servings) { store.update(entry.rescaled(servings: $0)) }
                    }
                    if let g = entry.grams, g > 0, entry.servings > 0 {
                        HStack {
                            Text("Weight")
                            Spacer()
                            // Scales the entry by weight; the snapshot keeps its grams exact.
                            WeightStepper(grams: g, unit: units.food) { new in
                                store.update(entry.rescaled(servings: entry.servings * new / g))
                            }
                        }
                    }
                }
                Picker("Meal", selection: Binding(get: { entry.meal }, set: { m in edit { $0.meal = m } })) {
                    ForEach(Meal.allCases) { Text($0 == .snack ? "Snack" : $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                DatePicker("Day", selection: dayBinding, in: ...Days.date(Days.today), displayedComponents: .date)
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                HStack {
                    Text("Note")
                    TextField("Add a note", text: $note)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .onSubmit { saveNote() }
                }
            } header: {
                VStack(alignment: .leading, spacing: 10) {
                    provenance
                    summary
                }
                .textCase(nil)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
            Section {
                NavigationLink {
                    NutrientsView(entry: entry)
                } label: {
                    Text("Nutrients")
                }
            }
            Section {
                Button(role: .destructive) {
                    close()
                    Actions.delete([entry])
                } label: {
                    Text("Delete entry").frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { saveNote(); close() } label: { Image(systemName: "checkmark") }
                    .accessibilityLabel("Done")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Actions.again([entry], meal: Days.meal(), day: Days.today) } label: {
                        Label("Log again now", systemImage: "arrow.clockwise")
                    }
                    if store.food(id: entry.foodID) != nil {
                        Button { openFood = true } label: { Label("Open food", systemImage: "fork.knife") }
                    }
                    Button(action: saveAsFood) { Label("Save as food", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "ellipsis") }
                .tint(.primary)
            }
        }
        .listSectionSpacing(.compact)
        .navigationDestination(isPresented: $openFood) {
            if let food = store.food(id: entry.foodID) {
                FoodDetailView(food: food, meal: .constant(entry.meal), day: entry.day) { openFood = false }
            }
        }
        .onAppear {
            note = entry.note ?? ""
            for k in macroKeys { quick[k] = entry.nutrients[k].map(Fmt.trim) ?? "" }
        }
        .onDisappear { saveNote() }
    }

    private var provenance: some View {
        let time = Date(timeIntervalSince1970: Double(entry.loggedAt) / 1000).formatted(date: .omitted, time: .shortened)
        let brand = entry.brand.map { "\($0) · " } ?? ""
        let line: Text
        if let symbol = ProvenanceGlyph.symbol(entry) {
            line = Text("\(brand)\(Image(systemName: symbol)) \(provenanceText) · \(time)")
        } else {
            line = Text("\(brand)Logged \(time)")
        }
        return line
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var provenanceText: String {
        switch entry.source {
        case "agent": (entry.note ?? "").lowercased().contains("photo") ? "Logged by agent from photo" : "Logged by agent"
        case "barcode": "Scanned barcode"
        default: ""
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.kcal(entry.kcal)).numberFont(28, .bold, relativeTo: .title)
                    .contentTransition(.numericText(value: entry.kcal ?? 0))
                Text("kcal").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach([("P", "protein"), ("C", "carbs"), ("F", "fat")], id: \.1) { letter, key in
                HStack(spacing: 3) {
                    Text(letter).foregroundStyle(Palette.ink(key)).fontWeight(.semibold)
                    Text(entry.nutrients[key].map(Fmt.grams) ?? Fmt.missing)
                        .contentTransition(.numericText(value: entry.nutrients[key] ?? 0))
                }
                .numberFont(17, .medium, relativeTo: .body)
            }
        }
        .animation(.snappy, value: entry.servings)
    }

    private func quickField(_ key: String) -> some View {
        let info = Nutrients.info(key)
        return HStack {
            Text(info?.name ?? key)
            TextField("–", text: Binding(get: { quick[key] ?? "" }, set: { v in
                quick[key] = v
                edit { e in
                    if let x = Double(v.replacingOccurrences(of: ",", with: ".")), x >= 0 { e.nutrients[key] = x }
                    else if v.isEmpty { e.nutrients[key] = nil }
                }
            }))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            Text(info?.displayUnit ?? "").foregroundStyle(.secondary)
        }
    }

    private func edit(_ change: (inout Entry) -> Void) {
        var e = entry
        change(&e)
        withAnimation(.smooth) { store.update(e) }
    }

    private func saveNote() {
        let trimmed = note.trimmingCharacters(in: .whitespaces)
        guard trimmed != (entry.note ?? ""), store.entry(id: entry.id) != nil else { return }
        edit { $0.note = trimmed.isEmpty ? nil : trimmed }
    }

    private var dayBinding: Binding<Date> {
        Binding(get: { Days.date(entry.day) }, set: { d in
            let key = Days.key(d)
            guard key != entry.day else { return }
            edit {
                $0.day = key
                $0.loggedAt = Days.moving(loggedAt: $0.loggedAt, to: key)
            }
        })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: Double(entry.loggedAt) / 1000) }, set: { d in
            edit { $0.loggedAt = Int(d.timeIntervalSince1970 * 1000) }
        })
    }

    private func saveAsFood() {
        let per = max(entry.servings, 0.0001)
        var label = entry.servingLabel ?? "serving"
        if let r = label.range(of: #" \([\d.,]+ ?g\)$"#, options: .regularExpression) { label.removeSubrange(r) }
        let food = Food(name: entry.name, brand: entry.brand,
                        serving: Serving(amount: 1, unit: label, grams: entry.grams.map { $0 / per }),
                        nutrients: NutritionMath.scale(entry.nutrients, by: 1 / per), source: "custom")
        store.save(food: food)
        var e = entry
        e.foodID = food.id
        store.update(e)
        Haptics.success()
        Toasts.shared.message("Saved \(food.name) as a food")
    }
}

/// [ − ] 9 oz [ + ]: an entry's weight in the food unit, stepping 0.5 oz or 5 g and snapping to that step.
struct WeightStepper: View {
    /// Metric, as stored.
    var grams: Double
    var unit: FoodWeightUnit
    var onChange: (Double) -> Void

    private var shown: Double { unit.fromGrams(grams) }
    /// Stepped values keep their half ounce above 10 oz ("10.5 oz"), unlike read-only weights.
    private var text: String { "\(Fmt.foodInput(shown, unit)) \(unit.symbol)" }

    var body: some View {
        HStack(spacing: 4) {
            button("minus") { move(-1) }.disabled(shown <= unit.step + 0.0001)
            Text(text)
                .numberFont(17, .semibold, relativeTo: .body)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 64)
                .contentTransition(.numericText(value: grams))
            button("plus") { move(1) }
        }
        .sensoryFeedback(.selection, trigger: grams)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weight")
        .accessibilityValue("\(Fmt.foodInput(shown, unit)) \(unit.name)")
        .accessibilityAdjustableAction { d in
            if d == .increment { move(1) } else if d == .decrement { move(-1) }
        }
    }

    /// One step in the shown unit, landing on a multiple of it (9.0 oz from 8.99 oz, not 9.49).
    private func move(_ direction: Double) {
        let step = unit.step
        let next = max(step, ((shown + direction * step) / step).rounded() * step)
        guard abs(next - shown) > 0.0001 else { return }
        onChange(NutritionMath.round3(unit.toGrams(next)))
    }

    private func button(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 32)
                .background(Palette.chip, in: Capsule())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }
}

/// [ − ] 1.5 [ + ] in 0.25 steps with selection haptics.
struct ServingStepper: View {
    var value: Double
    var step = 0.25
    var onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("minus") { onChange(max(step, value - step)) }.disabled(value <= step)
            Text(Fmt.trim(value))
                .numberFont(17, .semibold, relativeTo: .body)
                .frame(minWidth: 44)
                .contentTransition(.numericText(value: value))
            button("plus") { onChange(value + step) }
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Servings")
        .accessibilityValue(Fmt.trim(value))
        .accessibilityAdjustableAction { d in
            if d == .increment { onChange(value + step) } else if d == .decrement { onChange(max(step, value - step)) }
        }
    }

    private func button(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 32)
                .background(Palette.chip, in: Capsule())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }
}
