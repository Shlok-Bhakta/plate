// DESIGN 4.6 Trends: a ScrollView of chart cards under a glass toolbar with the 7D / 30D / 90D range
// picker. Calories, macros, protein (with the streak), weight trend, activity, the weakest nutrients and
// the nutrient map. `Router.trendsFocus` (set by Today's health tiles) scrolls to the matching card.
//
// Debug: -PlateRange 7|30|90, -PlateTrendsFocus <card id>, -PlateTrendDetail <kind>, -PlateNutrient <key>.
import Charts
import SwiftUI

enum TrendKind: String, Hashable, CaseIterable {
    case calories, macros, protein, weight, activity
    var title: String { rawValue.capitalizedFirst }
}

enum TrendsRoute: Hashable {
    case detail(TrendKind)
    case nutrients(day: String)
}

/// A nutrient page request: for one day (from Nutrients detail) or for the Trends range.
struct NutrientPick: Identifiable, Hashable {
    var key: String
    var day: String?
    var id: String { key + "|" + (day ?? "range") }
}

struct TrendsView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @AppStorage("trendsRange") private var rangeRaw = TrendRange.week.rawValue
    @State private var activity: ActivityMode = .energy
    @State private var path: [TrendsRoute] = []
    @State private var pick: NutrientPick?
    @State private var appliedDebug = false

    private var range: TrendRange { TrendRange(rawValue: rangeRaw) ?? .week }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    let data = TrendData(store: store, range: range)
                    VStack(spacing: Space.l) {
                        CaloriesCard(data: data).id("calories")
                        MacrosCard(data: data).id("macros")
                        ProteinCard(data: data).id("protein")
                        if store.hasHealth {
                            WeightCard(data: data).id("weight")
                            ActivityCard(data: data, mode: $activity).id("activity")
                        }
                        WeakestCard(data: data) { pick = NutrientPick(key: $0) }.id("nutrients")
                        if range != .week {
                            NutrientMapCard(data: data) { pick = NutrientPick(key: $0) }
                                .id("map")
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.horizontal, Space.l)
                    .padding(.top, Space.s)
                    .padding(.bottom, Space.xl)
                }
                .background(Palette.background)
                .scrollEdgeEffectStyle(.hard, for: .top)
                .navigationTitle("Trends")
                .toolbar {
                    ToolbarItem(placement: .principal) { RangePicker(rangeRaw: $rangeRaw) }
                }
                .navigationDestination(for: TrendsRoute.self) { route in
                    switch route {
                    case .detail(let kind): TrendDetailView(kind: kind, rangeRaw: $rangeRaw, activity: $activity)
                    case .nutrients(let day): NutrientsView(day: day)
                    }
                }
                .onChange(of: router.trendsFocus, initial: true) { _, focus in
                    guard let focus else { return }
                    scroll(to: focus, proxy)
                }
                .task { applyDebug(proxy) }
            }
        }
        .sheet(item: $pick) { p in
            NutrientSheet(key: p.key, day: p.day, range: range)
        }
    }

    /// Health tiles send "weight", "active" or "steps"; any card id also works.
    private func scroll(to focus: String, _ proxy: ScrollViewProxy) {
        let id: String
        switch focus {
        case "active": id = "activity"; activity = .energy
        case "steps": id = "activity"; activity = .steps
        default: id = focus
        }
        path = []
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(Motion.smooth) { proxy.scrollTo(id, anchor: .top) }
            router.trendsFocus = nil
        }
    }

    private func applyDebug(_ proxy: ScrollViewProxy) {
        guard !appliedDebug else { return }
        appliedDebug = true
        let d = UserDefaults.standard
        if let r = d.string(forKey: "PlateRange").flatMap(Int.init), TrendRange(rawValue: r) != nil { rangeRaw = r }
        if let f = d.string(forKey: "PlateTrendsFocus") { scroll(to: f, proxy) }
        if let k = d.string(forKey: "PlateTrendDetail").flatMap(TrendKind.init(rawValue:)) { path = [.detail(k)] }
        if d.string(forKey: "PlateScreen") == "trends", let key = d.string(forKey: "PlateNutrient"), Nutrients.info(key) != nil {
            pick = NutrientPick(key: key)
        }
    }
}

/// The 7D / 30D / 90D segmented control in the toolbar's principal slot. Changes animate (.smooth, 0.35 s).
struct RangePicker: View {
    @Binding var rangeRaw: Int
    var body: some View {
        Picker("Range", selection: $rangeRaw.animation(Motion.smooth)) {
            ForEach(TrendRange.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .frame(width: 210)
        .sensoryFeedback(.selection, trigger: rangeRaw)
    }
}

// MARK: - Full-screen chart

/// A card's chart at 320 pt plus a table of daily values (DESIGN 4.6: tapping a card header).
struct TrendDetailView: View {
    var kind: TrendKind
    @Binding var rangeRaw: Int
    @Binding var activity: ActivityMode
    @Environment(Store.self) private var store
    @Environment(\.units) private var units

    private var range: TrendRange { TrendRange(rawValue: rangeRaw) ?? .week }

    var body: some View {
        let data = TrendData(store: store, range: range)
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(kind.title).font(.title2.bold())
                        Spacer(minLength: 8)
                        HeaderValue(attributed: headline(data))
                    }
                    chart(data)
                }
                .padding(.vertical, 8)
            } footer: {
                Text(footer(data)).monospacedDigit()
            }
            Section("Daily") {
                let rows = data.days.reversed().compactMap { day in row(day, data).map { (day, $0) } }
                if rows.isEmpty {
                    Text("Nothing in this range yet").foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.0) { day, value in
                    HStack(alignment: .firstTextBaseline) {
                        Text(ChartDay.title(day))
                        Spacer()
                        Text(value).numberFont(17, relativeTo: .body).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { RangePicker(rangeRaw: $rangeRaw) }
            if kind == .activity {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $activity) {
                            Text("Active energy").tag(ActivityMode.energy)
                            Text("Steps").tag(ActivityMode.steps)
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                }
            }
        }
    }

    @ViewBuilder private func chart(_ data: TrendData) -> some View {
        switch kind {
        case .calories: CaloriesChart(data: data, height: 320)
        case .macros: MacroStackChart(data: data, height: 320)
        case .protein: ProteinChart(data: data, height: 320)
        case .weight: WeightChart(data: data, height: 320)
        case .activity: ActivityChart(data: data, mode: activity, height: 320)
        }
    }

    /// The key number for the range, as on the card.
    private func headline(_ data: TrendData) -> AttributedString {
        switch kind {
        case .calories:
            return avgText(Fmt.kcal(TrendMath.mean(data.logged.map(\.kcal))), data.goals?.kcal.map { " / \(Fmt.whole($0))" } ?? "")
        case .protein:
            let avg = TrendMath.mean(data.logged.map { $0.totals["protein"] })
            return avgText(avg.map(Fmt.grams) ?? Fmt.missing, avg == nil ? "" : " g")
        case .macros:
            let s = TrendMath.macroSplit(data.summaries)
            return avgText("P \(Int(saturating: (s.protein * 100).rounded())) · C \(Int(saturating: (s.carbs * 100).rounded())) · F \(Int(saturating: (s.fat * 100).rounded()))", " %", prefix: "")
        case .weight:
            return avgText(data.weights.last.map { Fmt.bodyWeightValue($0.trend, units) } ?? Fmt.missing, " \(units.weight.symbol)", prefix: "trend ")
        case .activity:
            let h = data.healthInRange
            return activity == .energy
                ? avgText(Fmt.kcal(TrendMath.mean(h.map(\.activeKcal))), " kcal")
                : avgText(TrendMath.mean(h.map(\.steps)).map(Fmt.whole) ?? Fmt.missing, " steps")
        }
    }

    private func footer(_ data: TrendData) -> String {
        switch kind {
        case .weight: return "Dots are weigh-ins; the line is a smoothed trend (exponential moving average) that evens out water swings."
        case .activity: return "Active energy and steps come from Apple Health, one source per day."
        default: return data.loggedLine + ". Days with nothing logged are left blank, not counted as zero."
        }
    }

    private func row(_ day: String, _ data: TrendData) -> String? {
        let s = data.summary(day)
        switch kind {
        case .calories:
            guard let s, !s.isEmpty else { return nil }
            return "\(Fmt.whole(s.kcal)) kcal"
        case .protein:
            guard let s, !s.isEmpty else { return nil }
            return "\(Fmt.grams(s.totals["protein"] ?? 0)) g"
        case .macros:
            guard let s, !s.isEmpty else { return nil }
            return zip(["P", "C", "F"], ["protein", "carbs", "fat"]).map { "\($0) \(Fmt.grams(s.totals[$1] ?? 0))" }
                .joined(separator: "  ")
        case .weight:
            guard let p = data.weights.first(where: { $0.day == day }) else { return nil }
            return Fmt.bodyWeight(p.kg, units)
        case .activity:
            guard let h = data.health[day], h.activeKcal != nil || h.steps != nil else { return nil }
            return "\(h.activeKcal.map(Fmt.whole) ?? Fmt.missing) kcal · \(h.steps.map(Fmt.whole) ?? Fmt.missing)"
        }
    }
}
