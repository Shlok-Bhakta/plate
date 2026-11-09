// Shared pieces for the Trends charts (DESIGN 4.6 "Chart rules"): the range data, day ↔ date mapping
// for Swift Charts, axes, the card chrome, the selection callout, and empty states.
import Charts
import SwiftUI

/// Everything the Trends cards read for one range, built once per render from the Store.
struct TrendData {
    var range: TrendRange
    var today: String
    /// Day keys, oldest first.
    var days: [String]
    /// One summary per day in `days` (empty days included).
    var summaries: [DaySummary]
    var goals: Goals?
    var health: [String: HealthDay]
    /// Every weigh-in with its trend, oldest first (seeded by history before the range).
    var weights: [(day: String, kg: Double, trend: Double)]
    var proteinStreak: Int
    var weeklyWeightRate: Double?

    /// `end` is the last day shown (and the highlighted bar); it's today on Trends.
    @MainActor
    init(store: Store, range: TrendRange, end: String = Days.today) {
        self.range = range
        today = end
        days = range.days(endingAt: end)
        summaries = days.map { store.summary(for: $0) }
        goals = store.goals
        health = store.healthDays
        weights = TrendMath.weightTrend(store.healthDays.values.compactMap { h in
            h.weightKg.map { (day: h.day, kg: $0) }
        }.filter { $0.day <= end })
        proteinStreak = store.proteinStreak
        weeklyWeightRate = store.weeklyWeightRate
    }

    var logged: [DaySummary] { summaries.filter { !$0.isEmpty } }
    var first: String { days.first ?? today }
    func summary(_ day: String) -> DaySummary? { summaries.first { $0.day == day } }
    var weightsInRange: [(day: String, kg: Double, trend: Double)] { weights.filter { $0.day >= first } }
    var healthInRange: [HealthDay] { days.compactMap { health[$0] } }

    /// "6 of 7 days logged", the honest denominator under every average.
    var loggedLine: String {
        let n = logged.count
        return n == days.count ? "Every day logged" : "\(n) of \(days.count) days logged"
    }
}

// MARK: - Days on a chart

enum ChartDay {
    /// The start of the day: bars use `unit: .day`, so they fill the day's slot centered on its label.
    static func start(_ key: String) -> Date { Days.calendar.startOfDay(for: Days.date(key)) }
    /// Noon: points, lines, rules and axis labels sit at the center of the day's slot.
    static func mid(_ key: String) -> Date { Days.date(key) }
    static func key(_ date: Date) -> String { Days.key(date) }

    static func domain(_ days: [String]) -> ClosedRange<Date> {
        let a = start(days.first ?? Days.today)
        let b = start(Days.add(1, to: days.last ?? Days.today))
        return a...b
    }

    /// 7D shows every weekday letter; 30D labels every 7 days and 90D every 30, counted back from today.
    static func axisDays(_ data: TrendData) -> [String] {
        let step = data.range == .week ? 1 : (data.range == .month ? 7 : 30)
        return stride(from: 0, to: data.days.count, by: step).map { Days.add(-$0, to: data.today) }.reversed()
    }

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    /// "Nov 8"
    static func short(_ key: String) -> String {
        "\(months[Days.calendar.component(.month, from: Days.date(key)) - 1]) \(Days.dayNumber(key))"
    }
    static func axisLabel(_ key: String, range: TrendRange) -> String {
        range == .week ? Days.weekdayLetter(key) : short(key)
    }
    /// "Today", "Yesterday", "Thu, Nov 6".
    static func title(_ key: String) -> String { Days.title(key) }
}

extension View {
    /// DESIGN 4.6 axes: three 0.5 pt horizontal gridlines in separator, no vertical gridlines, caption2 labels
    /// in tertiaryLabel, and day labels per the range. The goal's label ("goal" or "limit") sits in the axis
    /// column at the goal's height, so it never collides with a bar.
    func trendAxes(_ data: TrendData, y domain: ClosedRange<Double>, goal: Double? = nil, goalLabel: String = "goal",
                   yFormat: @escaping (Double) -> String = { Fmt.whole($0) }) -> some View {
        let ticks = niceTicks(domain, avoiding: goal)
        return self
            .chartXScale(domain: ChartDay.domain(data.days))
            .chartYScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: ChartDay.axisDays(data).map(ChartDay.mid)) { v in
                    AxisValueLabel(collisionResolution: .disabled) {
                        if let d = v.as(Date.self) {
                            Text(ChartDay.axisLabel(ChartDay.key(d), range: data.range))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: ticks) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.separator)
                    AxisValueLabel {
                        if let y = v.as(Double.self) { Text(yFormat(y)).font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
                if let goal {
                    AxisMarks(values: [goal]) { _ in
                        AxisValueLabel {
                            Text(goalLabel).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .environment(\.timeZone, Days.zone)
    }
}

/// About `count` round tick values inside `domain` (1, 2, 2.5 or 5 × 10ⁿ apart), dropping any that would sit
/// on top of the goal's label.
func niceTicks(_ domain: ClosedRange<Double>, count: Int = 3, avoiding goal: Double? = nil) -> [Double] {
    let span = domain.upperBound - domain.lowerBound
    guard span > 0, span.isFinite else { return [domain.lowerBound] }
    let raw = span / Double(count)
    let mag = pow(10, floor(log10(raw)))
    let n = raw / mag
    let step = (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * mag
    var out: [Double] = []
    var v = (domain.lowerBound / step).rounded(.up) * step
    while v <= domain.upperBound + step * 1e-6 { out.append(v); v += step }
    if let goal { out.removeAll { abs($0 - goal) < span * 0.09 } }
    return out
}

/// Compact axis numbers: "2,000" stays, "12,000" becomes "12k".
func compactAxis(_ y: Double) -> String {
    abs(y) >= 10_000 ? "\(Fmt.whole(y / 1000))k" : Fmt.whole(y)
}

// MARK: - Marks

/// The goal rule: 1 pt dashed [4, 3] in secondaryLabel. Its "goal" label lives in the y-axis (`trendAxes`).
@ChartContentBuilder
func goalRule(_ value: Double?) -> some ChartContent {
    if let value {
        RuleMark(y: .value("Goal", value))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(Palette.secondaryLabel)
    }
}

/// The selection rule: a vertical 1 pt line in label color, with the callout above the plot.
@ChartContentBuilder
func selectionRule<C: View>(_ day: String?, @ViewBuilder callout: @escaping (String) -> C) -> some ChartContent {
    if let day {
        RuleMark(x: .value("Selected", ChartDay.mid(day)))
            .lineStyle(StrokeStyle(lineWidth: 1))
            .foregroundStyle(Palette.label.opacity(0.55))
            .zIndex(-1)
            .annotation(position: .top, spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                callout(day)
            }
    }
}

/// The glass-free popover card: radius 12, secondary grouped background, an 8% shadow.
struct ChartCallout<Content: View>: View {
    var day: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ChartDay.title(day)).font(.caption).foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.card, in: .rect(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.separator.opacity(0.4), lineWidth: 0.5))
        .fixedSize()
    }
}

/// A callout value line: "2,180 kcal" in rounded semibold with a quieter unit.
struct CalloutValue: View {
    var value: String
    var unit: String
    var color: Color = Palette.label
    var body: some View {
        Text(TwoTone(value, unit.isEmpty ? "" : " " + unit, Palette.secondaryLabel, first: color))
            .numberFont(15, .semibold, relativeTo: .subheadline)
    }
}

extension View {
    /// chartXSelection mapped to a day key inside the range, with `.selection` haptics on each day crossed.
    func daySelection(_ day: Binding<String?>, in data: TrendData) -> some View {
        modifier(DaySelection(day: day, days: data.days))
    }
}

private struct DaySelection: ViewModifier {
    @Binding var day: String?
    var days: [String]
    @State private var raw: Date?
    func body(content: Content) -> some View {
        content
            .chartXSelection(value: $raw)
            .onAppear {
                // Debug: -PlateSelectDaysAgo <n> shows every chart's callout for that day.
                if let n = UserDefaults.standard.string(forKey: "PlateSelectDaysAgo").flatMap(Int.init), let last = days.last {
                    day = Days.add(-n, to: last)
                }
            }
            .onChange(of: raw) { _, d in
                guard let d else { day = nil; return }
                let k = ChartDay.key(d)
                day = days.contains(k) ? k : (k < (days.first ?? k) ? days.first : days.last)
            }
            .sensoryFeedback(.selection, trigger: day) { _, new in new != nil }
    }
}

// MARK: - Card chrome

/// A Trends card: title, trailing key average, optional accessory and subline, then the content.
/// Tapping the title row pushes the full-screen version when `link` is set.
struct TrendCard<Trailing: View, Content: View>: View {
    var title: String
    var subtitle: String?
    var link: TrendsRoute?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                header
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            content
        }
        .card()
    }

    @ViewBuilder private var header: some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                if link != nil {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            trailing
        }
        if let link {
            NavigationLink(value: link) { row.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            row
        }
    }
}

/// The trailing key number of a card header ("avg 2,180 / 2,350"): rounded 17 semibold, secondary.
struct HeaderValue: View {
    var text: AttributedString
    init(_ value: String, _ suffix: String = "") {
        text = TwoTone(value, suffix, Palette.secondaryLabel, first: Palette.label)
    }
    init(attributed: AttributedString) { text = attributed }
    var body: some View {
        Text(text).numberFont(17, .semibold, relativeTo: .headline).lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// DESIGN 4.6 empty state: the chart frame stays, dimmed, with a centered message.
struct ChartEmptyOverlay: ViewModifier {
    var isEmpty: Bool
    var message: String
    func body(content: Content) -> some View {
        content
            .opacity(isEmpty ? 0.35 : 1)
            .allowsHitTesting(!isEmpty)
            .overlay {
                if isEmpty {
                    Text(message)
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Palette.card.opacity(0.9), in: Capsule())
                }
            }
    }
}

extension View {
    func chartEmpty(_ isEmpty: Bool, _ message: String = "Log a few days to see trends") -> some View {
        modifier(ChartEmptyOverlay(isEmpty: isEmpty, message: message))
    }
}

/// A small segmented toggle for a card header (Macros kcal/g, Activity energy/steps). Content, not glass.
struct CardToggle<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        Picker("", selection: $selection.animation(Motion.smooth)) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

/// Bar opacity per DESIGN 2.2: today at 100%, past days at 55% (dimmer still while another day is selected).
func barOpacity(_ day: String, today: String, selected: String?) -> Double {
    if let selected { return day == selected ? 1 : 0.3 }
    return day == today ? 1 : 0.55
}

/// Bar corner radius: 4 pt, or 2 pt at 90 days.
func barRadius(_ range: TrendRange) -> CGFloat { range == .quarter ? 2 : 4 }
