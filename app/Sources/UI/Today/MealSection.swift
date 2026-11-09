// DESIGN 4.1 meal sections: header with eaten · target and ⊕, entry rows with swipe actions and a
// context menu, and the empty state (copy yesterday's meal, suggestion chips).
import SwiftUI

struct MealSection: View {
    var meal: Meal
    var day: String
    var summary: DaySummary
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.zoomNamespace) private var zoom

    private var entries: [Entry] { summary.entries(meal) }

    var body: some View {
        Section {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: Space.l, bottom: entries.isEmpty ? 4 : 0, trailing: 6))
            if entries.isEmpty {
                EmptyMealRows(meal: meal, day: day)
            } else {
                ForEach(entries) { entry in
                    EntryRow(entry: entry, isPastDay: day != Days.today)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(meal.title).font(.headline)
            Spacer(minLength: 8)
            let target = store.goals?.mealTarget(meal)
            Text(TwoTone(Fmt.whole(summary.kcal(meal)), target.map { " · \(Fmt.whole($0))" } ?? "", Palette.tertiaryLabel))
                .numberFont(17, .semibold, relativeTo: .headline)
                .contentTransition(.numericText(value: summary.kcal(meal)))
                .accessibilityLabel("\(Fmt.whole(summary.kcal(meal))) calories" + (target.map { " of \(Fmt.whole($0))" } ?? ""))
            LogPlusButton(size: 28, label: "Add to \(meal.title)") {
                router.openAdd(meal: meal, day: day, sourceID: "meal-\(meal.rawValue)")
            }
            .zoomSource("meal-\(meal.rawValue)", zoom)
        }
        .dayShifted()
    }
}

struct EntryRow: View {
    var entry: Entry
    var isPastDay: Bool
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.units) private var units
    @State private var highlight = false

    var body: some View {
        Button { router.editing = EntryRef(id: entry.id) } label: {
            EntryRowLabel(entry: entry)
                .dayShifted()
        }
        .buttonStyle(.plain)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 20 }
        .listRowInsets(EdgeInsets(top: 0, leading: Space.l - 4, bottom: 0, trailing: Space.l))
        .listRowBackground(
            ZStack {
                Palette.card
                Palette.accent.opacity(highlight ? 0.12 : 0)
            }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { Actions.delete([entry]) } label: { Label("Delete", systemImage: "trash") }
            Button { router.editing = EntryRef(id: entry.id) } label: { Label("Edit", systemImage: "pencil") }
                .tint(.gray)
        }
        .swipeActions(edge: .leading) {
            Button { Actions.again([entry], meal: Days.meal(), day: Days.today) } label: {
                Label("Again", systemImage: "arrow.clockwise")
            }
            .tint(Palette.accent)
        }
        .contextMenu { menu }
        .onAppear {
            guard store.isFreshArrival(entry.id) else { return }
            highlight = true
            withAnimation(.easeOut(duration: 1.2).delay(0.3)) { highlight = false }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the entry editor")
    }

    @ViewBuilder private var menu: some View {
        Button { router.editing = EntryRef(id: entry.id) } label: { Label("Edit", systemImage: "pencil") }
        Button { Actions.again([entry], meal: Days.meal(), day: Days.today) } label: {
            Label("Log again", systemImage: "arrow.clockwise")
        }
        Menu {
            ForEach(Meal.allCases) { meal in
                Button(meal.title) {
                    var e = entry
                    e.meal = meal
                    withAnimation(.smooth) { store.update(e) }
                }
                .disabled(meal == entry.meal)
            }
        } label: { Label("Move to", systemImage: "arrow.right.circle") }
        if isPastDay {
            Button { Actions.again([entry], meal: entry.meal, day: Days.today) } label: {
                Label("Copy to today", systemImage: "doc.on.doc")
            }
        }
        if let food = store.food(id: entry.foodID) {
            Button { store.setFavorite(food, !food.favorite) } label: {
                Label(food.favorite ? "Unfavorite food" : "Favorite food", systemImage: food.favorite ? "star.slash" : "star")
            }
        }
        Divider()
        Button(role: .destructive) { Actions.delete([entry]) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// An entry row's content (DESIGN 4.1): provenance glyph, name, detail line, kcal. Also the rows of an
/// AI draft, which can add a protein figure under the kcal.
struct EntryRowLabel: View {
    var entry: Entry
    var showsProtein = false
    @Environment(\.units) private var units

    var body: some View {
        HStack(spacing: 0) {
            ProvenanceGlyph(entry: entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                let detail = entry.detailLine(units)
                if !detail.isEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.kcal(entry.kcal))
                    .numberFont(17, relativeTo: .body)
                    .foregroundStyle(entry.kcal == nil ? .tertiary : .secondary)
                    .contentTransition(.numericText(value: entry.kcal ?? 0))
                if showsProtein {
                    Text(entry.nutrients["protein"].map { "P \(Fmt.grams($0)) g" } ?? "P \(Fmt.missing)")
                        .numberFont(13, .medium, relativeTo: .footnote)
                        .foregroundStyle(Palette.proteinInk)
                        .contentTransition(.numericText(value: entry.nutrients["protein"] ?? 0))
                }
            }
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

/// An empty meal: "Copy yesterday's lunch · 710 kcal ⊕" plus up to three suggestion chips,
/// or just "Add lunch" when there's no history.
struct EmptyMealRows: View {
    var meal: Meal
    var day: String
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        let yesterday = store.previousMeal(meal, before: day)
        let frequent = store.frequent(meal: meal, limit: 3)
        if !yesterday.isEmpty {
            Button {
                withAnimation(.smooth) { Actions.again(yesterday, meal: meal, day: day) }
            } label: {
                HStack {
                    Text(TwoTone("Copy yesterday's \(meal.noun)", " · \(Fmt.kcal(yesterday.compactMap(\.kcal).reduce(0, +))) kcal"))
                    Spacer(minLength: 8)
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Palette.accent)
                }
                .font(.subheadline)
                .monospacedDigit()
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Palette.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .contentShape(Rectangle())
                .dayShifted()
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: frequent.isEmpty ? 8 : 4, trailing: 8))
            .listRowSeparator(.hidden)
            .accessibilityHint("Logs all of yesterday's \(meal.noun)")
        }
        if !frequent.isEmpty {
            ChipRow(clip: true) {
                ForEach(frequent, id: \.id) { e in
                    FoodChip(name: e.name, kcal: e.kcal) {
                        withAnimation(.smooth) { Actions.again([e], meal: meal, day: day) }
                    }
                }
            }
            .dayShifted()
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 14, trailing: 0))
            .listRowSeparator(.hidden)
        }
        if yesterday.isEmpty && frequent.isEmpty {
            Button { router.openAdd(meal: meal, day: day, sourceID: "meal-\(meal.rawValue)") } label: {
                HStack {
                    Text("Add \(meal.noun)").foregroundStyle(Palette.accentInk)
                    Spacer()
                }
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: Space.l, bottom: 4, trailing: Space.l))
            .listRowSeparator(.hidden)
        }
    }
}
