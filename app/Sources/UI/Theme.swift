// DESIGN 2.2 to 2.4: the color tokens (fill and ink, light and dark), number typography,
// spacing, card styling and haptics.
import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// A color with Any and Dark appearances.
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

/// Color tokens, named as in DESIGN 2.2. `fill` is for rings, bars and marks; `ink` is for colored text.
enum Palette {
    static let accent = Color(light: 0xE8631A, dark: 0xFF8A3D)
    static let accentInk = Color(light: 0xC2470A, dark: 0xFF8A3D)
    static let accentDeep = Color(light: 0xB8430B, dark: 0xE0601C)
    static let protein = Color(light: 0x6457E8, dark: 0x8F84FF)
    static let proteinInk = Color(light: 0x4F3FD9, dark: 0x8F84FF)
    static let carbs = Color(light: 0x0E9FB8, dark: 0x35C8E0)
    static let carbsInk = Color(light: 0x0B7487, dark: 0x35C8E0)
    static let fat = Color(light: 0xC28400, dark: 0xFFCB3D)
    static let fatInk = Color(light: 0x8F6500, dark: 0xFFCB3D)
    static let fiber = Color(light: 0x3DA35A, dark: 0x5ED47C)
    static let fiberInk = Color(light: 0x277A3F, dark: 0x5ED47C)
    static let water = Color(light: 0x2F7DEB, dark: 0x5A9EFF)
    static let waterInk = Color(light: 0x1F60C4, dark: 0x5A9EFF)
    static let vitamin = Color(light: 0xB15AD6, dark: 0xD08BFF)
    static let vitaminInk = Color(light: 0x8A3AAE, dark: 0xD08BFF)
    static let mineral = Color(light: 0x6F8197, dark: 0x9EB0C7)
    static let mineralInk = Color(light: 0x52637A, dark: 0x9EB0C7)
    static let over = Color(light: 0xE5484D, dark: 0xFF6369)
    static let overInk = Color(light: 0xC2292E, dark: 0xFF6369)
    static let track = Color(light: 0x787880, dark: 0x787880, lightAlpha: 0.16, darkAlpha: 0.32)
    static let limitFill = Color(light: 0x8E8E93, dark: 0x98989F)

    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let chip = Color(uiColor: .secondarySystemFill)
    static let separator = Color(uiColor: .separator)
    static let label = Color(uiColor: .label)
    static let secondaryLabel = Color(uiColor: .secondaryLabel)
    static let tertiaryLabel = Color(uiColor: .tertiaryLabel)

    /// Fill and ink for a nutrient: macros use their own colors, then the group color.
    static func fill(_ key: String) -> Color {
        switch key {
        case "kcal": accent
        case "protein": protein
        case "carbs": carbs
        case "fat": fat
        case "fiber": fiber
        case "water": water
        default: group(Nutrients.info(key)?.group ?? .other)
        }
    }

    static func ink(_ key: String) -> Color {
        switch key {
        case "kcal": accentInk
        case "protein": proteinInk
        case "carbs": carbsInk
        case "fat": fatInk
        case "fiber": fiberInk
        case "water": waterInk
        default: groupInk(Nutrients.info(key)?.group ?? .other)
        }
    }

    static func group(_ g: NutrientGroup) -> Color {
        switch g {
        case .macro: accent
        case .fat: fat
        case .vitamin: vitamin
        case .mineral: mineral
        case .other: Color(uiColor: .secondaryLabel)
        }
    }

    static func groupInk(_ g: NutrientGroup) -> Color {
        switch g {
        case .macro: accentInk
        case .fat: fatInk
        case .vitamin: vitaminInk
        case .mineral: mineralInk
        case .other: Color(uiColor: .secondaryLabel)
        }
    }
}

/// DESIGN 2.4 spacing tokens.
enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    static let cardRadius: CGFloat = 26
    static let chipHeight: CGFloat = 36
}

// MARK: - Typography

/// SF Rounded with monospaced digits, scaling with Dynamic Type relative to a text style.
struct NumberFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let rounded: Bool

    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle, rounded: Bool = true) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.rounded = rounded
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: rounded ? .rounded : .default)).monospacedDigit()
    }
}

extension View {
    /// Rounded numbers for nutrition quantities (DESIGN 2.3).
    func numberFont(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(NumberFont(size: size, weight: weight, relativeTo: style))
    }
    /// SF Pro at a custom size, scaling relative to a text style.
    func scaledFont(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(NumberFont(size: size, weight: weight, relativeTo: style, rounded: false))
    }

    /// A number that rolls when it changes.
    func rolling(_ value: Double) -> some View { contentTransition(.numericText(value: value)) }

    /// The "RECENT" section caps used inside the Add sheet.
    func sectionCaps() -> some View {
        self.scaledFont(13, .semibold, relativeTo: .footnote).tracking(0.4).textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    /// An opaque content card: secondary grouped background, 26 pt continuous corners, no shadow.
    func card(padding: CGFloat = Space.l) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: Space.cardRadius, style: .continuous))
    }
}

// MARK: - Haptics

/// Imperative haptics for actions that don't map to a `sensoryFeedback` trigger.
@MainActor
enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Motion

enum Motion {
    static let snappy = Animation.snappy
    static let smooth = Animation.smooth(duration: 0.35)
    static let log = Animation.spring(response: 0.6, dampingFraction: 0.85)
    static let launch = Animation.spring(response: 0.9, dampingFraction: 0.85)
    static let toast = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let morph = Animation.bouncy(duration: 0.4)

    /// DESIGN 6: with Reduce Motion, springs become a 0.2 s cross-fade.
    static func adapt(_ a: Animation, reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.2) : a }
}

/// Two runs of text in one `Text`: a value in primary, then a suffix in a quieter style
/// ("96 / 150 g"). Replaces the `Text + Text` concatenation deprecated in iOS 26.
func TwoTone(_ a: String, _ b: String, _ second: Color = Color(uiColor: .secondaryLabel),
             first: Color = Color(uiColor: .label)) -> AttributedString {
    var x = AttributedString(a)
    x.foregroundColor = first
    var y = AttributedString(b)
    y.foregroundColor = second
    return x + y
}
