// Shared building blocks: rings, capsule bars, chips, provenance glyphs, stat tiles and small rows.
import SwiftUI

// MARK: - Rings

/// A progress ring that starts at 12 o'clock, runs clockwise, and draws an overflow lap past 100%.
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat
    var fill: Color = Palette.accent
    var overflow: Color = Palette.accentDeep
    var glow = false

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(fill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: glow ? fill.opacity(0.7) : .clear, radius: glow ? 12 : 0)
            if progress > 1 {
                Circle()
                    .trim(from: 0, to: min(progress - 1, 0.999))
                    .stroke(overflow, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(0.22), radius: lineWidth * 0.18)
                    .transition(.opacity)
            }
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - Bars

/// A capsule bar on a visible track. The fill caps at 100% visually.
struct CapsuleBar: View {
    var fraction: Double
    var height: CGFloat
    var fill: Color
    var track: Color = Palette.track

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill)
                    .frame(width: fraction <= 0 ? 0 : max(height, g.size.width * min(fraction, 1)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Chips

/// A one-tap logging chip (DESIGN 4.2): 36 pt capsule on secondarySystemFill.
struct FoodChip: View {
    var name: String
    var kcal: Double?
    var favorite = false
    var action: () -> Void
    var onLongPress: (() -> Void)?
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 6) {
            if favorite {
                Image(systemName: "star.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
            }
            Text(name.count > 18 ? String(name.prefix(17)) + "…" : name)
                .scaledFont(15, .medium, relativeTo: .subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let kcal {
                Text(Fmt.kcal(kcal)).numberFont(15, relativeTo: .subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: Space.chipHeight)
        .background(Palette.chip, in: Capsule())
        .contentShape(Capsule())
        .scaleEffect(pressed ? 0.92 : 1)
        .onTapGesture {
            withAnimation(.snappy(duration: 0.12)) { pressed = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.bouncy(duration: 0.3)) { pressed = false }
            }
            action()
        }
        .onLongPressGesture(minimumDuration: 0.45) { onLongPress?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Logs one tap. Long-press for details.")
        .accessibilityAction { action() }
    }
}

/// A horizontally scrolling chip row with 16 pt leading inset.
struct ChipRow<Content: View>: View {
    /// Inside a card the row clips to the card; on open backgrounds it can scroll past the edges.
    var clip = false
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) { content }
                .padding(.horizontal, Space.l)
                .padding(.vertical, 2)
        }
        .scrollClipDisabled(!clip)
    }
}

// MARK: - Entry bits

/// The 15 pt provenance glyph (DESIGN 4.1): photo, other agent, barcode, or nothing.
struct ProvenanceGlyph: View {
    var entry: Entry
    static func symbol(_ entry: Entry) -> String? {
        switch entry.source {
        case "agent": (entry.note ?? "").lowercased().contains("photo") ? "camera.fill" : "sparkles"
        case "barcode": "barcode"
        default: nil
        }
    }
    var body: some View {
        Group {
            if let s = Self.symbol(entry) {
                Image(systemName: s).font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
            } else {
                Color.clear
            }
        }
        .frame(width: 20, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// A plus.circle.fill one-tap log button in accent.
struct LogPlusButton: View {
    var size: CGFloat = 28
    var label = "Log"
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: size))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Palette.accent)
                .frame(width: max(44, size), height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Tiles

/// A health stat tile (DESIGN 4.1): 84 pt, radius 20, 12 pt padding.
struct StatTile: View {
    var label: String
    var value: String
    var unit: String?
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).numberFont(22, .semibold, relativeTo: .title2)
                    .foregroundStyle(value == Fmt.missing ? .tertiary : .primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let unit, value != Fmt.missing { Text(unit).font(.footnote).foregroundStyle(.secondary) }
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .background(Palette.card, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// An 8 pt dot in a group color followed by a title (section headers in Nutrients).
struct GroupDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

extension String {
    /// "lunch" → "Lunch"
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
