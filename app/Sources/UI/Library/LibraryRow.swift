// A Library row (DESIGN 4.8): 60 pt, the name with a favorite star and a provenance glyph, a subline
// (brand · serving, or a recipe's servings and ingredients), kcal per serving with a "12× · Tue" usage
// hint under it, and a trailing ⊕ that logs to the current meal.
import SwiftUI

struct LibraryRow: View {
    var food: Food
    var usage: (count: Int, lastDay: String)?
    var subline: String
    var logLabel: String
    var onOpen: () -> Void
    var onLog: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if food.favorite {
                            Image(systemName: "star.fill").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.accent)
                        }
                        Text(food.name).font(.body).foregroundStyle(.primary).lineLimit(1)
                            .layoutPriority(1)
                        if let glyph = Self.provenance(food) {
                            Image(systemName: glyph).font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                                .accessibilityLabel(glyph == "sparkles" ? "Added by agent" : "Scanned product")
                        }
                        Spacer(minLength: 8)
                        Text(Fmt.kcal(food.kcal)).numberFont(17, relativeTo: .body).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(subline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        if let usage, usage.count > 0 {
                            Text(Self.usageText(usage)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                                .lineLimit(1).fixedSize()
                        }
                    }
                }
                .frame(minHeight: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens details")
            LogPlusButton(label: logLabel, action: onLog)
        }
    }

    /// The provenance glyph for a food: sparkles for the agent's, a barcode for scanned products.
    static func provenance(_ food: Food) -> String? {
        if food.source == "agent" { return "sparkles" }
        if food.barcode != nil { return "barcode" }
        return nil
    }

    /// "12× · today", "3× · yesterday", "5× · Tue", "2× · Oct 3".
    static func usageText(_ usage: (count: Int, lastDay: String)) -> String {
        let today = Days.today
        let ago = Days.between(usage.lastDay, today)
        let when: String
        switch ago {
        case ...0: when = "today"
        case 1: when = "yesterday"
        case 2...6: when = Days.weekdayShort(usage.lastDay)
        default: when = Days.date(usage.lastDay).formatted(.dateTime.month(.abbreviated).day())
        }
        return "\(usage.count)× · \(when)"
    }
}
