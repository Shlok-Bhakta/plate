// DESIGN 4.7 nutrient bars. Targets: a group-colored fill with a faint 100% tick at 80% of the width, so
// the bar can show up to 125%. Limits: an outlined track, a gray fill up to the limit, a dashed red limit
// tick, and red only for the part past the limit.
import SwiftUI

struct NutrientBar: View {
    /// amount / target, or nil when unknown (an empty track).
    var fraction: Double?
    var isLimit: Bool
    var fill: Color
    var height: CGFloat = 6
    /// Where 100% sits along the bar.
    var tickAt: CGFloat = 0.8

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let tickX = w * tickAt
            let f = max(0, fraction ?? 0)
            let fillW = f <= 0 ? 0 : max(height, min(w, tickX * CGFloat(f)))
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                if isLimit {
                    Capsule().strokeBorder(Palette.separator, lineWidth: 1)
                }
                HStack(spacing: 0) {
                    Rectangle().fill(isLimit ? Palette.limitFill : fill).frame(width: min(fillW, tickX))
                    if fillW > tickX {
                        Rectangle().fill(isLimit ? Palette.over : fill).frame(width: fillW - tickX)
                    }
                }
                .frame(width: fillW, alignment: .leading)
                .clipShape(Capsule())
                if tickAt < 1 { tick(x: tickX) }
            }
        }
        .frame(height: height)
        .animation(Motion.log, value: fraction)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func tick(x: CGFloat) -> some View {
        let extra: CGFloat = 3
        Path { p in
            p.move(to: CGPoint(x: x, y: -extra))
            p.addLine(to: CGPoint(x: x, y: height + extra))
        }
        .stroke(isLimit ? Palette.over : Palette.label.opacity(0.35),
                style: StrokeStyle(lineWidth: isLimit ? 1.5 : 1, dash: isLimit ? [2, 1.5] : []))
    }
}

/// A nutrient amount without its unit. Like `Fmt.amount`, but milligram amounts under 10 keep a decimal
/// (two under 1), so thiamin reads "1.2 mg" rather than "1 mg".
func nutrientAmount(_ x: Double?, unit: String) -> String {
    guard let x else { return Fmt.missing }
    if unit == "mg" && abs(x) < 10 && x != 0 {
        let places = abs(x) < 1 ? 2 : 1
        return x.formatted(.number.precision(.fractionLength(0...places)))
    }
    return Fmt.amount(x, unit: unit)
}

/// A nutrient amount in display units: water (wire unit ml) in fl oz or ml, the rest in their own unit.
func nutrientAmount(_ x: Double?, unit: String, units: Units) -> String {
    if unit == "ml", let x { return Fmt.volumeValue(x, units) }
    return nutrientAmount(x, unit: unit)
}

extension NutrientInfo {
    /// The unit as shown in display units: "fl oz" or "ml" for water, otherwise `displayUnit`.
    func displayUnit(_ u: Units) -> String { unit == "ml" ? u.water.symbol : displayUnit }

    /// "Vitamin A" for "Vitamin A (RAE)"; short enough for chart rows.
    var shortName: String {
        name.replacingOccurrences(of: #" \(.*\)"#, with: "", options: .regularExpression)
    }
    /// The last resort for narrow rows.
    var compactName: String {
        switch key {
        case "pantothenic": "Vitamin B5"
        case "mono_fat": "Mono fat"
        case "poly_fat": "Poly fat"
        case "carbs": "Carbs"
        default: shortName
        }
    }
}

/// A one-line Trends row: name, a 6 pt bar, and the average percent (DESIGN 4.6 card 6).
struct AverageRow: View {
    var average: NutrientAverage
    var isLimit: Bool

    var body: some View {
        let info = Nutrients.info(average.key)
        let over = isLimit && average.fraction > 1
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(info?.shortName ?? average.key)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: 128, alignment: .leading)
                NutrientBar(fraction: average.fraction, isLimit: isLimit, fill: Palette.fill(average.key), tickAt: isLimit ? 0.8 : 1)
                Text("\(average.percent)%")
                    .numberFont(15, .medium, relativeTo: .subheadline)
                    .foregroundStyle(over ? Palette.overInk : .primary)
                    .frame(width: 48, alignment: .trailing)
            }
            if isLimit {
                let unit = info?.displayUnit ?? ""
                HStack(spacing: 4) {
                    Text("avg \(nutrientAmount(average.average, unit: info?.unit ?? "g")) / \(nutrientAmount(average.target, unit: info?.unit ?? "g")) \(unit)")
                    if average.daysOver > 0 {
                        Text("·")
                        Text("over \(average.daysOver) of \(average.daysWithData) days")
                            .foregroundStyle(average.fraction > 1 ? Palette.overInk : Palette.secondaryLabel)
                    }
                }
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.9)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(info?.name ?? average.key), average \(average.percent) percent of \(isLimit ? "limit" : "target")"
                            + (average.daysOver > 0 && isLimit ? ", over on \(average.daysOver) days" : ""))
        .accessibilityAddTraits(.isButton)
    }
}
