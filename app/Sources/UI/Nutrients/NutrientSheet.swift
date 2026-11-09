// DESIGN 4.7 nutrient page, shown as a sheet from Nutrients detail (for one day) or from Trends (for the
// range): the amount, a bar chart per day against the target or limit, the top sources (entries ranked by
// contribution), and "Your best sources" from your own foods, each logging in one tap.
import Charts
import SwiftUI

struct NutrientSheet: View {
    var key: String
    /// The day the page is about; nil means the Trends range ending today.
    var day: String?
    var range: TrendRange
    @Environment(Store.self) private var store
    @Environment(\.units) private var units
    @Environment(\.dismiss) private var dismiss

    private var info: NutrientInfo? { Nutrients.info(key) }
    private var unit: String { info?.displayUnit(units) ?? "" }
    private var wireUnit: String { info?.unit ?? "g" }
    private var isLimit: Bool { store.goals?.isLimit(key) ?? false }
    private var showsBest: Bool {
        !isLimit && key != "kcal" && key != "water" && info?.group != .other
    }

    var body: some View {
        let historyRange: TrendRange = day == nil ? range : .month
        let data = TrendData(store: store, range: historyRange, end: day ?? Days.today)
        NavigationStack {
            List {
                Section { hero(data) }
                Section {
                    NutrientHistoryChart(key: key, data: data, isLimit: isLimit)
                        .padding(.vertical, 8)
                } header: {
                    Text(day == nil ? "Last \(historyRange.rawValue) days" : "30 days to \(ChartDay.title(day!))")
                } footer: {
                    if let avg = store.goals.flatMap({ TrendMath.average(key, over: data.summaries, goals: $0) }) {
                        Text("Average \(nutrientAmount(avg.average, unit: wireUnit, units: units)) \(unit) (\(avg.percent)%) on \(avg.daysWithData) days with data. Days without data are left blank.")
                            .monospacedDigit()
                    }
                }
                sources(data)
                if showsBest { bestSources }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(Space.l)
            .navigationTitle(info?.name ?? key)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(.primary)
                        .accessibilityLabel("Close")
                }
            }
            .toastHost()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Hero

    @ViewBuilder private func hero(_ data: TrendData) -> some View {
        if let day {
            let status = store.summary(for: day).status(key, goals: store.goals)
            heroBody(value: status.amount, prefix: status.isPartial ? "≥ " : "", caption: ChartDay.title(day),
                     fraction: status.fraction, target: status.target, partial: status.isPartial,
                     footnote: status.isPartial ? "\(status.missing) of \(status.entryCount) entries have no data" : nil)
        } else {
            let avg = store.goals.flatMap { TrendMath.average(key, over: data.summaries, goals: $0) }
            heroBody(value: avg?.average, prefix: "", caption: "Daily average, \(range.rawValue) days",
                     fraction: avg?.fraction, target: avg?.target ?? store.goals?.target(key),
                     partial: (avg?.partialDays ?? 0) > 0,
                     footnote: avg.map { a in
                         a.partialDays > 0 ? "\(a.partialDays) of \(a.daysWithData) days had entries without data" : nil
                     } ?? nil)
        }
    }

    private func heroBody(value: Double?, prefix: String, caption: String, fraction: Double?, target: Double?,
                          partial: Bool, footnote: String?) -> some View {
        let over = isLimit && (fraction ?? 0) > 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                GroupDot(color: Palette.group(info?.group ?? .other))
                Text(caption).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.map { prefix + nutrientAmount($0, unit: wireUnit, units: units) } ?? Fmt.missing)
                    .numberFont(34, .bold, relativeTo: .largeTitle)
                    .foregroundStyle(value == nil ? .tertiary : .primary)
                Text(unit).font(.headline).foregroundStyle(.secondary)
                Spacer()
                if let target {
                    Text(Fmt.percent(NutritionMath.percent(value, of: target)))
                        .numberFont(22, .semibold, relativeTo: .title2)
                        .foregroundStyle(over ? Palette.overInk : (value == nil ? Palette.tertiaryLabel : Palette.label))
                }
            }
            if let target {
                NutrientBar(fraction: fraction, isLimit: isLimit, fill: Palette.fill(key), height: 8)
                HStack(spacing: 4) {
                    Text("\(isLimit ? "Limit" : "Target") \(nutrientAmount(target, unit: wireUnit, units: units)) \(unit)")
                    if partial { Text("· partial data") }
                    if over, let value {
                        Text("·")
                        Text("\(nutrientAmount(value - target, unit: wireUnit, units: units)) over").foregroundStyle(Palette.overInk)
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("No daily target").font(.subheadline).foregroundStyle(.secondary)
            }
            if let footnote {
                Text(footnote).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sources

    @ViewBuilder private func sources(_ data: TrendData) -> some View {
        let entries = day.map { store.summary(for: $0).foodEntries } ?? data.summaries.flatMap(\.foodEntries)
        let top = TrendMath.topSources(entries, key: key, limit: day == nil ? 8 : 10)
        let missing = entries.filter { $0.nutrients[key] == nil }.count
        Section {
            if top.isEmpty {
                Text(entries.isEmpty ? "Nothing logged" : "None of these entries have \(info?.shortName.lowercasedFirstWord ?? key) data")
                    .foregroundStyle(.secondary)
            }
            ForEach(top) { s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.name).lineLimit(1)
                        if s.entries > 1 {
                            Text("×\(s.entries)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer(minLength: 8)
                        Text(TwoTone(nutrientAmount(s.amount, unit: wireUnit, units: units), " \(unit)"))
                            .numberFont(17, relativeTo: .body)
                    }
                    HStack(spacing: 8) {
                        CapsuleBar(fraction: s.share, height: 4, fill: isLimit ? Palette.limitFill : Palette.fill(key))
                        Text("\(Int(saturating: (s.share * 100).rounded()))%")
                            .numberFont(13, relativeTo: .footnote).foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(day.map { $0 == Days.today ? "Today's sources" : "Sources on \(ChartDay.title($0))" } ?? "Top sources, \(range.rawValue) days")
        } footer: {
            let note = [day == nil && !top.isEmpty ? "Totals over the range; ×8 means logged 8 times." : nil,
                        missing > 0 && !top.isEmpty ? "\(missing) of \(entries.count) entries have no \(info?.shortName.lowercasedFirstWord ?? key) data." : nil]
                .compactMap { $0 }.joined(separator: " ")
            if !note.isEmpty { Text(note) }
        }
    }

    private var bestSources: some View {
        let best = TrendMath.bestSources(store.foodList, key: key)
        return Section {
            if best.isEmpty {
                Text("None of your foods list \(info?.shortName.lowercasedFirstWord ?? key) yet").foregroundStyle(.secondary)
            }
            ForEach(best, id: \.food.listID) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.food.name).lineLimit(1)
                        Text("\(nutrientAmount(item.food.nutrients[key], unit: wireUnit, units: units)) \(unit) per \(item.food.servingName(units)) · \(nutrientAmount(item.per100kcal, unit: wireUnit, units: units)) per 100 kcal")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 4)
                    LogPlusButton(label: "Log \(item.food.name)") {
                        Actions.log(item.food, servings: 1, meal: Days.meal(), day: Days.today)
                    }
                }
                .frame(minHeight: 52)
            }
        } header: {
            Text("Your best sources")
        } footer: {
            if !best.isEmpty { Text("Your foods ranked by \(info?.shortName.lowercasedFirstWord ?? key) per 100 kcal. ⊕ logs one serving to \(Days.meal().noun).") }
        }
    }
}

/// Bars per day against the target (or limit) for one nutrient. Limit days over the line turn red.
struct NutrientHistoryChart: View {
    var key: String
    var data: TrendData
    var isLimit: Bool
    @Environment(\.units) private var units
    @State private var selected: String?

    var body: some View {
        let info = Nutrients.info(key)
        // Water charts in the shown unit (fl oz or ml), so the axis ticks are round numbers in it.
        let scale = info?.unit == "ml" ? units.water.fromMl(1) : 1
        let target = data.goals?.target(key).map { $0 * scale }
        let points = data.summaries.compactMap { s -> (day: String, v: Double)? in
            if key == "water" { return s.waterMl > 0 ? (s.day, s.waterMl * scale) : nil }
            guard !s.isEmpty, (s.coverage[key] ?? 0) > 0 else { return nil }
            return (s.day, s.totals[key] ?? 0)
        }
        let top = max(target ?? 0, points.map(\.v).max() ?? 0, 0.001) * 1.15
        Chart {
            ForEach(points, id: \.day) { p in
                let over = isLimit && target.map { p.v > $0 } == true
                BarMark(x: .value("Day", ChartDay.start(p.day), unit: .day), y: .value("Amount", p.v), width: .ratio(0.7))
                    .foregroundStyle((over ? Palette.over : (isLimit ? Palette.limitFill : Palette.fill(key)))
                        .opacity(barOpacity(p.day, today: data.today, selected: selected)))
                    .cornerRadius(barRadius(data.range))
            }
            goalRule(target)
            selectionRule(selected) { day in
                ChartCallout(day: day) {
                    if let p = points.first(where: { $0.day == day }) {
                        CalloutValue(value: nutrientAmount(p.v, unit: info?.unit ?? "g"), unit: info?.displayUnit(units) ?? "")
                        if let target { Text("\(Int(saturating: (p.v / target * 100).rounded()))% of \(isLimit ? "limit" : "target")").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("No data").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .trendAxes(data, y: 0...top, goal: target, goalLabel: isLimit ? "limit" : "goal",
                   yFormat: { y in nutrientAmount(y, unit: info?.unit ?? "g") })
        .daySelection($selected, in: data)
        .frame(height: 180)
        .chartEmpty(points.count < 3, points.isEmpty ? "No data in this range" : "Log a few days to see trends")
        .accessibilityLabel("\(info?.name ?? key) per day")
    }
}
