// DESIGN 4.6 cards 6 and 7: the weakest nutrients (average % of target over the range, limits listed
// separately) and the nutrient map (nutrient × day heatmap on a single accent hue).
import SwiftUI

struct WeakestCard: View {
    var data: TrendData
    var open: (String) -> Void

    var body: some View {
        let weak = data.goals.map { TrendMath.weakest(data.summaries, goals: $0) } ?? []
        let limits = data.goals.map { TrendMath.limits(data.summaries, goals: $0) } ?? []
        TrendCard(title: "Weakest nutrients", subtitle: weak.isEmpty ? nil : "Average % of target on days with data") {
            NavigationLink(value: TrendsRoute.nutrients(day: data.today)) {
                HStack(spacing: 4) {
                    Text("Today")
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today's nutrients")
        } content: {
            if weak.isEmpty {
                Text(data.goals == nil ? "Targets sync from the server" : "Log a few days to see which nutrients run low")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(weak, id: \.key) { a in
                        Button { open(a.key) } label: { AverageRow(average: a, isLimit: false) }.buttonStyle(.plain)
                    }
                    if !limits.isEmpty {
                        Divider().padding(.vertical, 2)
                        HStack(spacing: 6) {
                            Text("Limits").font(.subheadline.weight(.semibold))
                            Text("· lower is better").font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(limits, id: \.key) { a in
                            Button { open(a.key) } label: { AverageRow(average: a, isLimit: true) }.buttonStyle(.plain)
                        }
                    }
                    let partial = weak.filter { $0.partialDays > 0 }.count
                    if partial > 0 {
                        Text("Some entries have no data for \(partial == 1 ? "one of these" : "\(partial) of these"), so the real numbers may be higher.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Nutrient map

struct NutrientMapCard: View {
    var data: TrendData
    var open: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    private var weekly: Bool { data.range == .quarter }

    var body: some View {
        let keys = data.goals.map { TrendMath.heatmapKeys(data.summaries, goals: $0) } ?? []
        TrendCard(title: "Nutrient map",
                  subtitle: weekly ? "% of target, each column a week" : "% of target, each column a day") {
            EmptyView()
        } content: {
            if keys.isEmpty || data.logged.count < 3 {
                Text("Log a few days to see trends")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    grid(keys)
                    legend
                }
            }
        }
    }

    private var columns: [[DaySummary]] {
        weekly ? TrendMath.chunks(data.summaries, size: 7) : data.summaries.map { [$0] }
    }

    private func grid(_ keys: [String]) -> some View {
        let cols = columns
        let labelWidth: CGFloat = 92
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(keys, id: \.self) { key in
                let target = data.goals?.target(key) ?? 1
                Button { open(key) } label: {
                    HStack(spacing: 8) {
                        Text(Nutrients.info(key)?.shortName ?? key)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(width: labelWidth, alignment: .leading)
                        HeatStrip(values: cols.map { col in
                            TrendMath.mean(col.map { TrendMath.dayFraction($0, key, target: target) })
                        })
                        .frame(height: 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibility(key, target: target))
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: labelWidth, height: 1)
                HStack {
                    Text(ChartDay.short(data.first))
                    Spacer()
                    Text(ChartDay.short(Days.add(-(data.days.count / 2), to: data.today)))
                    Spacer()
                    Text("Today")
                }
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(.top, 2)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(Array(zip(HeatStrip.levels(scheme), ["<25%", "<50%", "<100%", "100%+"])), id: \.1) { level, label in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2.5).fill(Palette.accent.opacity(level)).frame(width: 10, height: 10)
                    Text(label)
                }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2.5).strokeBorder(Palette.separator, lineWidth: 1).frame(width: 10, height: 10)
                Text("No data")
            }
        }
        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    private func accessibility(_ key: String, target: Double) -> String {
        let fractions = data.summaries.compactMap { TrendMath.dayFraction($0, key, target: target) }
        let met = fractions.filter { $0 >= 1 }.count
        return "\(Nutrients.info(key)?.name ?? key): target met on \(met) of \(fractions.count) days with data"
    }
}

/// One heatmap row: rounded cells sized to fit the width, single-hue accent buckets, hollow when unknown.
struct HeatStrip: View {
    var values: [Double?]
    @Environment(\.colorScheme) private var scheme
    /// DESIGN 4.6 levels; on a dark card the low steps need more opacity to read as color at all.
    static let levels: [Double] = [0.10, 0.30, 0.55, 0.85]
    static let darkLevels: [Double] = [0.18, 0.38, 0.62, 0.95]
    static func levels(_ scheme: ColorScheme) -> [Double] { scheme == .dark ? darkLevels : levels }

    var body: some View {
        let levels = Self.levels(scheme)
        Canvas { ctx, size in
            let n = CGFloat(max(values.count, 1))
            let gap: CGFloat = values.count > 20 ? 1.5 : 3
            let w = (size.width - gap * (n - 1)) / n
            let h = min(size.height, max(w, 10))
            let y = (size.height - h) / 2
            let radius = min(2.5, w / 3)
            for (i, v) in values.enumerated() {
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: y, width: w, height: h)
                let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
                if let v {
                    ctx.fill(path, with: .color(Palette.accent.opacity(levels[TrendMath.heatBucket(v)])))
                } else {
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius, style: .continuous),
                               with: .color(Palette.separator), lineWidth: 1)
                }
            }
        }
    }
}
