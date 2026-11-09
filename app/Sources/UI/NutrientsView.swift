// DESIGN 4.7 Nutrients detail for one day (or one entry): inset-grouped sections (Macros, Fats, Vitamins,
// Minerals, Other) with bars against targets. Limits are gray with a dashed limit tick and turn red only
// past it. Missing data is honest: "≥" amounts, "partial data", and a per-section footnote. Tapping a
// nutrient opens its page: history, the day's sources and your best sources.
import SwiftUI

struct NutrientsView: View {
    enum Source: Hashable { case day(String), entry(Entry) }
    var source: Source
    @Environment(Store.self) private var store
    @Environment(\.units) private var units
    @State private var pick: NutrientPick?

    init(day: String) { source = .day(day) }
    init(entry: Entry) { source = .entry(entry) }

    /// The day's summary, or a one-entry summary when showing an entry.
    private var summary: DaySummary {
        switch source {
        case .day(let d):
            return store.summary(for: d)
        case .entry(let e):
            var copy = e
            copy.deleted = false
            return DaySummary(day: e.day, entries: [copy])
        }
    }

    private var day: String? {
        if case .day(let d) = source { return d }
        return nil
    }

    var body: some View {
        let summary = summary
        let goals = store.goals
        ScrollViewReader { proxy in
        List {
            if let day {
                Section { DaySummaryHeader(summary: summary, goals: goals, day: day) }
            }
            ForEach(Nutrients.detailSections, id: \.group) { section in
                let rows = section.keys.map { summary.status($0, goals: goals) }
                    .filter { section.group != .other || $0.amount != nil || $0.target != nil }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.key) { status in
                            Group {
                            if day != nil {
                                Button { pick = NutrientPick(key: status.key, day: day) } label: {
                                    NutrientDetailRow(status: status)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Shows where it came from")
                            } else {
                                NutrientDetailRow(status: status)
                            }
                            }
                            .id(status.key)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            GroupDot(color: Palette.group(section.group))
                            Text(section.group.title)
                        }
                    } footer: {
                        if day != nil, let note = partialNote(rows) { Text(note) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(Space.l)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pick) { p in
            NutrientSheet(key: p.key, day: p.day, range: .month)
        }
        .task {
            // Debug: -PlateNutrientsScroll <key> scrolls to that row.
            guard let target = UserDefaults.standard.string(forKey: "PlateNutrientsScroll") else { return }
            try? await Task.sleep(for: .milliseconds(500))
            proxy.scrollTo(target, anchor: .top)
        }
        }
        .task {
            // Debug: -PlateNutrient <key> opens that nutrient's page.
            guard let d = day, pick == nil, UserDefaults.standard.string(forKey: "PlateScreen") == "nutrients",
                  let key = UserDefaults.standard.string(forKey: "PlateNutrient"), Nutrients.info(key) != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            pick = NutrientPick(key: key, day: d)
        }
    }

    private var title: String {
        switch source {
        case .day: "Nutrients"
        case .entry(let e): e.name
        }
    }

    private var subtitle: String {
        switch source {
        case .day(let d): Days.title(d)
        case .entry(let e): e.detailLine(units)
        }
    }

    /// "3 of 9 entries have no vitamin D data", or a summary when several rows are partial.
    private func partialNote(_ rows: [NutrientStatus]) -> String? {
        let partial = rows.filter(\.isPartial)
        guard let first = partial.first else { return nil }
        if partial.count == 1 {
            return "\(first.missing) of \(first.entryCount) entries have no \(Nutrients.info(first.key)?.shortName.lowercasedFirstWord ?? first.key) data, so its total is a minimum."
        }
        let worst = partial.max { $0.missing < $1.missing }!
        return "≥ marks partial data: some entries have no data for \(partial.count) of these (up to \(worst.missing) of \(worst.entryCount) entries), so those totals are minimums."
    }
}

extension String {
    /// "Vitamin D" → "vitamin D", "Omega-3" → "omega-3"; leaves acronyms alone.
    var lowercasedFirstWord: String {
        guard let f = first, count > 1, let second = dropFirst().first, second.isLowercase || second == "-" else { return self }
        return f.lowercased() + dropFirst()
    }
}

/// A small header: targets met out of the targets with data, the entry count, and any limit over.
private struct DaySummaryHeader: View {
    var summary: DaySummary
    var goals: Goals?
    var day: String

    var body: some View {
        let statuses = Nutrients.all.map { summary.status($0.key, goals: goals) }
        let targets = statuses.filter { $0.target != nil && !$0.isLimit && $0.key != "water" }
        let met = targets.filter(\.isMet).count
        let known = targets.filter { $0.amount != nil }.count
        let over = statuses.filter(\.isOver)
        HStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: targets.isEmpty ? 0 : Double(met) / Double(targets.count), lineWidth: 6)
                Text("\(met)").numberFont(15, .semibold, relativeTo: .subheadline).rolling(Double(met))
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                if summary.isEmpty {
                    Text("Nothing logged").font(.headline)
                    Text(day == Days.today ? "Log a meal to see nutrients" : "No entries on this day")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("\(met) of \(targets.count) targets met").font(.headline).monospacedDigit()
                    let parts = ["\(summary.foodEntryCount) \(summary.foodEntryCount == 1 ? "entry" : "entries")",
                                 known < targets.count ? "\(targets.count - known) with no data" : nil].compactMap { $0 }
                    Text(parts.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    if !over.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Palette.over)
                            Text(over.map { Nutrients.info($0.key)?.shortName ?? $0.key }.joined(separator: ", ") + " over the limit")
                                .font(.subheadline)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// DESIGN 4.7 row: name, a 120 pt bar with the 100% tick, and the percent; amounts on line 2.
struct NutrientDetailRow: View {
    var status: NutrientStatus
    @Environment(\.units) private var units

    var body: some View {
        let info = Nutrients.info(status.key)
        let unknown = status.amount == nil
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    Text(info?.name ?? status.key)
                    Text(info?.shortName ?? status.key)
                    Text(info?.compactName ?? status.key)
                }
                .foregroundStyle(unknown ? .tertiary : .primary)
                .lineLimit(1)
                .layoutPriority(1)
                Spacer(minLength: 6)
                if status.target != nil {
                    NutrientBar(fraction: status.fraction, isLimit: status.isLimit, fill: Palette.fill(status.key))
                        .frame(width: 120)
                    Text(Fmt.percent(status.percent))
                        .numberFont(15, .medium, relativeTo: .subheadline)
                        .foregroundStyle(unknown ? Palette.tertiaryLabel : (status.isOver ? Palette.overInk : Palette.label))
                        .frame(width: 44, alignment: .trailing)
                    glyph.frame(width: 14)
                } else {
                    Text(amountText)
                        .numberFont(15, .medium, relativeTo: .subheadline)
                        .foregroundStyle(unknown ? .tertiary : .secondary)
                }
            }
            if status.target != nil || status.isPartial { detailLine }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder private var glyph: some View {
        if status.isOver {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Palette.over)
        } else if status.isMet {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink(status.key))
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var unit: String { Nutrients.info(status.key)?.displayUnit(units) ?? "" }
    private var wireUnit: String { Nutrients.info(status.key)?.unit ?? "g" }

    private var amountText: String {
        guard let a = status.amount else { return Fmt.missing }
        return (status.isPartial ? "≥ " : "") + "\(nutrientAmount(a, unit: wireUnit, units: units)) \(unit)"
    }

    private var detailLine: some View {
        HStack(spacing: 4) {
            if let target = status.target {
                let amount = status.amount.map { (status.isPartial ? "≥ " : "") + nutrientAmount($0, unit: wireUnit, units: units) } ?? Fmt.missing
                Text("\(amount) / \(nutrientAmount(target, unit: wireUnit, units: units)) \(unit)\(status.isLimit ? " limit" : "")")
            }
            if status.isPartial {
                Text(status.target == nil ? "partial data" : "· partial data")
            }
            if let excess = status.excess {
                Text("·")
                Text("\(nutrientAmount(excess, unit: wireUnit, units: units)) over").foregroundStyle(Palette.overInk)
            }
        }
        .font(.subheadline)
        .foregroundStyle(status.amount == nil ? .tertiary : .secondary)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var accessibility: String {
        let name = Nutrients.info(status.key)?.name ?? status.key
        guard let a = status.amount else { return "\(name), no data" }
        var parts = ["\(name), \(status.isPartial ? "at least " : "")\(nutrientAmount(a, unit: wireUnit, units: units)) \(unit)"]
        if let t = status.target { parts.append("of \(nutrientAmount(t, unit: wireUnit, units: units)) \(status.isLimit ? "limit" : "target")") }
        if let p = status.percent { parts.append("\(p) percent") }
        if status.isOver { parts.append("over the limit") }
        if status.isPartial { parts.append("partial data") }
        return parts.joined(separator: ", ")
    }
}
