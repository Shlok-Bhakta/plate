// Settings → App Icon: the E1 tomato linocut (the primary icon) and seven alternates, as a grid of
// thumbnails. The icons themselves are AppIcon-<ID> sets in Assets.xcassets, listed in CFBundleAlternateIcons
// by actool (build-env.sh); thumbnails are the IconPreview-<ID> imagesets, since an app icon set can't be
// loaded as a UIImage. Masters and the generator live in app/icon/ (make_icons.py).
import SwiftUI
import UIKit

struct AppIcon: Identifiable, Equatable {
    /// The concept id: E1 for the primary, else the suffix of its AppIcon-<id> set.
    let id: String
    let title: String
    /// The name `setAlternateIconName` takes; nil for the primary icon.
    var alternateName: String? { id == AppIcon.primary.id ? nil : "AppIcon-\(id)" }
    var preview: String { "IconPreview-\(id)" }

    static let primary = AppIcon(id: "E1", title: "Tomato")
    static let all: [AppIcon] = [
        primary,
        AppIcon(id: "D1", title: "Place Setting"),
        AppIcon(id: "D2", title: "Plate P"),
        AppIcon(id: "D3", title: "Steam Bowl"),
        AppIcon(id: "D4", title: "Simple Tomato"),
        AppIcon(id: "E2", title: "Market Bowl"),
        AppIcon(id: "E3", title: "Paper Plate"),
        AppIcon(id: "E4", title: "Steamy Bowl"),
    ]

    static func named(_ alternateName: String?) -> AppIcon {
        all.first { $0.alternateName == alternateName } ?? primary
    }
}

/// The current home-screen icon, shared by the picker and Settings → About.
@Observable
@MainActor
final class AppIconStore {
    static let shared = AppIconStore()
    private(set) var current = AppIcon.named(UIApplication.shared.alternateIconName)

    /// Re-reads the system's choice (it can only change through this app, but stay honest).
    func refresh() { current = AppIcon.named(UIApplication.shared.alternateIconName) }

    /// Shows the new selection at once and reverts it, with a toast, if iOS refuses.
    func select(_ icon: AppIcon) {
        guard icon != current else { return }
        Haptics.light()
        let previous = current
        withAnimation(Motion.snappy) { current = icon }
        guard UIApplication.shared.supportsAlternateIcons else {
            fail(revertTo: previous, "This device can't change app icons")
            return
        }
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(icon.alternateName)
                Breadcrumbs.drop("app icon \(icon.id)")
            } catch {
                Breadcrumbs.drop("app icon \(icon.id) failed: \(error.localizedDescription)")
                fail(revertTo: previous, "Couldn't change the icon. Try again.")
            }
        }
    }

    private func fail(revertTo previous: AppIcon, _ message: String) {
        withAnimation(Motion.snappy) { current = previous }
        Haptics.warning()
        Toasts.shared.message(message, symbol: "exclamationmark.triangle.fill")
    }
}

struct AppIconSection: View {
    private var icons: AppIconStore { .shared }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 4)

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(AppIcon.all) { icon in
                    Button { icons.select(icon) } label: {
                        AppIconTile(icon: icon, selected: icons.current == icon)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
        } header: {
            Text("App Icon")
        } footer: {
            Text("Tomato also has dark and tinted versions, which follow your home screen.")
        }
        .onAppear { icons.refresh() }
    }
}

private struct AppIconTile: View {
    var icon: AppIcon
    var selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            AppIconImage(icon: icon, size: 58)
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: 58 * 0.225 + 4, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 2.5)
                        .opacity(selected ? 1 : 0)
                }
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Palette.accent)
                            .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)).padding(-2))
                            .offset(x: 4, y: 4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            Text(icon.title)
                .font(.caption)
                .foregroundStyle(selected ? .primary : .secondary)
                .fontWeight(selected ? .semibold : .regular)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// An icon's preview at `size`, clipped to the home-screen rounded square with a hairline edge.
struct AppIconImage: View {
    var icon: AppIcon
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(icon.preview)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.12 : 0.06), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
