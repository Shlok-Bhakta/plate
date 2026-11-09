// DESIGN 4.6 cards 4 and 5: Weight (raw weigh-ins plus a smoothed EWMA trend line and the weekly rate)
// and Activity (active energy bars or a steps line, from health_days).
import Charts
import SwiftUI

// MARK: - Weight

struct WeightCard: View {
    var data: TrendData
    @Environment(\.units) private var units
    var body: some View {
        let points = data.weightsInRange
        let latest = data.weights.last
        TrendCard(title: "Weight", subtitle: subtitle(points), link: data.weights.isEmpty ? nil : .detail(.weight)) {
            if let latest {
                HStack(spacing: 8) {
                    HeaderValue(Fmt.bodyWeightValue(latest.trend, units), " \(units.weight.symbol)")
                    if let rate = Fmt.weightRate(data.weeklyWeightRate, units) {
                        Text(rate).numberFont(15, .medium, relativeTo: .subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        } content: {
            WeightChart(data: data)
        }
    }

    private func subtitle(_ points: [(day: String, kg: Double, trend: Double)]) -> String {
        guard let first = points.first, let last = points.last, points.count >= 2 else {
            return data.weights.isEmpty ? "From Apple Health" : "Trend weight, smoothed"
        }
        let change = last.trend - first.trend
        let shown = units.weight.fromKg(change)
        let sign = shown < -0.05 ? "−" : (shown > 0.05 ? "+" : "±")
        return "Trend \(sign)\(Fmt.bodyWeight(abs(change), units)) over \(data.range.rawValue) days · \(points.count) weigh-ins"
    }
}

struct WeightChart: View {
    var data: TrendData
    var height: CGFloat = 200
    @Environment(\.units) private var units
    @State private var selected: String?

    var body: some View {
        // Plotted in the shown unit (lb or kg) so the axis ticks are round numbers in it; `kg` holds that value.
        let w = units.weight
        let points = data.weightsInRange.map { (day: $0.day, kg: w.fromKg($0.kg), trend: w.fromKg($0.trend)) }
        let values = points.flatMap { [$0.kg, $0.trend] }
        // The data range ± 1 kg, or ± 2 lb.
        let pad = w == .lb ? 2.0 : 1.0
        let lo = (values.min() ?? w.fromKg(70)) - pad, hi = (values.max() ?? w.fromKg(74)) + pad
        Chart {
            ForEach(points, id: \.day) { p in
                PointMark(x: .value("Day", ChartDay.mid(p.day)), y: .value("Weight", p.kg))
                    .symbolSize(data.range == .quarter ? 16 : 26)
                    .foregroundStyle(Palette.secondaryLabel.opacity(selected == p.day ? 1 : 0.6))
            }
            ForEach(points, id: \.day) { p in
                LineMark(x: .value("Day", ChartDay.mid(p.day)), y: .value("Trend", p.trend), series: .value("Series", "trend"))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Palette.accent)
            }
            selectionRule(selected) { day in
                ChartCallout(day: day) {
                    if let p = nearest(day, in: points) {
                        if p.day == day {
                            CalloutValue(value: shown(p.kg), unit: w.symbol)
                        } else {
                            Text("No weigh-in").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("Trend \(shown(p.trend)) \(w.symbol)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .trendAxes(data, y: lo...hi, yFormat: { shown($0) })
        .daySelection($selected, in: data)
        .frame(height: height)
        .chartEmpty(points.count < 3, data.weights.isEmpty ? "Weight syncs from Health on the server" : "Weigh in a few more times to see a trend")
        .accessibilityLabel("Weight chart")
        .accessibilityValue(points.last.map { "Trend weight \(shown($0.trend)) \(w == .lb ? "pounds" : "kilograms")" } ?? "No weigh-ins")
    }

    /// A value already in the shown unit, to 0.1.
    private func shown(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) }

    /// The weigh-in on `day`, or the latest one before it (for the trend value on days without one).
    private func nearest(_ day: String, in points: [(day: String, kg: Double, trend: Double)]) -> (day: String, kg: Double, trend: Double)? {
        points.last { $0.day <= day } ?? points.first
    }
}

// MARK: - Activity

enum ActivityMode: String, Hashable { case energy, steps }

struct ActivityCard: View {
    var data: TrendData
    @Binding var mode: ActivityMode

    var body: some View {
        let h = data.healthInRange
        let active = TrendMath.mean(h.map(\.activeKcal))
        let steps = TrendMath.mean(h.map(\.steps))
        let line = [active.map { "\(Fmt.whole($0)) kcal active" }, steps.map { "\(Fmt.whole($0)) steps" }]
            .compactMap { $0 }.joined(separator: " · ")
        TrendCard(title: "Activity", subtitle: line.isEmpty ? "From Apple Health" : "Daily average: " + line,
                  link: h.isEmpty ? nil : .detail(.activity)) {
            CardToggle(options: [(ActivityMode.energy, "Energy"), (ActivityMode.steps, "Steps")], selection: $mode)
        } content: {
            ActivityChart(data: data, mode: mode)
        }
    }
}

struct ActivityChart: View {
    var data: TrendData
    var mode: ActivityMode
    var height: CGFloat = 180
    @State private var selected: String?

    var body: some View {
        let h = data.healthInRange
        let energy = h.compactMap { d in d.activeKcal.map { (day: d.day, v: $0) } }
        let steps = h.compactMap { d in d.steps.map { (day: d.day, v: $0) } }
        let series = mode == .energy ? energy : steps
        let top = max(series.map(\.v).max() ?? 0, mode == .energy ? 400 : 5000) * 1.12
        Chart {
            if mode == .energy {
                ForEach(energy, id: \.day) { p in
                    BarMark(x: .value("Day", ChartDay.start(p.day), unit: .day), y: .value("Active", p.v), width: .ratio(0.7))
                        .foregroundStyle(Palette.accent.opacity(selected.map { $0 == p.day ? 1 : 0.3 } ?? (p.day == data.today ? 1 : 0.7)))
                        .cornerRadius(barRadius(data.range))
                }
            } else {
                ForEach(steps, id: \.day) { p in
                    AreaMark(x: .value("Day", ChartDay.mid(p.day)), y: .value("Steps", p.v))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Palette.secondaryLabel.opacity(0.16), Palette.secondaryLabel.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", ChartDay.mid(p.day)), y: .value("Steps", p.v))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Palette.secondaryLabel)
                }
                if let today = steps.last, data.range == .week || selected == nil {
                    PointMark(x: .value("Day", ChartDay.mid(today.day)), y: .value("Steps", today.v))
                        .symbolSize(30)
                        .foregroundStyle(Palette.label)
                }
            }
            selectionRule(selected) { day in
                ChartCallout(day: day) {
                    let d = data.health[day]
                    if d?.activeKcal == nil && d?.steps == nil {
                        Text("No Health data").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        CalloutValue(value: d?.activeKcal.map(Fmt.whole) ?? Fmt.missing, unit: "kcal",
                                     color: mode == .energy ? Palette.label : Palette.secondaryLabel)
                        CalloutValue(value: d?.steps.map(Fmt.whole) ?? Fmt.missing, unit: "steps",
                                     color: mode == .steps ? Palette.label : Palette.secondaryLabel)
                    }
                }
            }
        }
        .trendAxes(data, y: 0...top, yFormat: compactAxis)
        .daySelection($selected, in: data)
        .frame(height: height)
        .chartEmpty(series.count < 3, h.isEmpty ? "Activity syncs from Health on the server" : "Log a few days to see trends")
        .accessibilityLabel(mode == .energy ? "Active energy chart" : "Steps chart")
    }
}
