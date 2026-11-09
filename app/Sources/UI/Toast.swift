// The shared undo toast (DESIGN 4.2) and `Actions`, the one place UI logs, deletes and undoes, so every
// surface gets the same toast, haptics and protein moment.
import SwiftUI

struct ToastModel: Equatable {
    var symbol = "checkmark.circle.fill"
    var isProtein = false
    var text: String
    var count = 0
    var kcal: Double = 0
    /// Entries this toast created (Undo deletes them).
    var created: [String] = []
    /// Entries this toast deleted (Undo restores them).
    var deleted: [Entry] = []
    var shownAt = Date()
    /// A custom trailing action ("Undo" for food edits, "Log a serving" after saving a recipe).
    var action: ToastAction?
    /// Set on "Logged …" toasts, the only ones later food logs stack onto (never water or a delete).
    var stacksLogs = false
    var hasUndo: Bool { !created.isEmpty || !deleted.isEmpty || action != nil }
}

/// A toast's trailing button that runs a closure; equal by identity so toasts stay Equatable.
struct ToastAction: Equatable {
    let id = UUID()
    var title = "Undo"
    var run: @MainActor () -> Void
    static func == (a: ToastAction, b: ToastAction) -> Bool { a.id == b.id }
}

@Observable
@MainActor
final class Toasts {
    static let shared = Toasts()
    private(set) var current: ToastModel?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ model: ToastModel) {
        withAnimation(Motion.toast) { current = model }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(Motion.toast) { current = nil }
    }

    /// "Logged Banana · 105 kcal"; quick successive logs stack into "Logged 3 items · 420 kcal".
    func logged(_ entries: [Entry], proteinHit: (grams: Double, streak: Int)? = nil) {
        guard !entries.isEmpty else { return }
        let kcal = entries.compactMap(\.kcal).reduce(0, +)
        var model: ToastModel
        if var stacked = current, stacked.stacksLogs, !stacked.created.isEmpty, Date().timeIntervalSince(stacked.shownAt) < 4 {
            stacked.count += entries.count
            stacked.kcal += kcal
            stacked.created += entries.map(\.id)
            stacked.text = "Logged \(stacked.count) items · \(Fmt.kcal(stacked.kcal)) kcal"
            stacked.shownAt = Date()
            model = stacked
        } else {
            let name = entries.count == 1 ? entries[0].name : "\(entries.count) items"
            model = ToastModel(text: "Logged \(name) · \(Fmt.kcal(kcal)) kcal", count: entries.count, kcal: kcal,
                               created: entries.map(\.id), stacksLogs: true)
        }
        if let hit = proteinHit {
            model.isProtein = true
            model.symbol = "checkmark.seal.fill"
            model.text = "Protein goal hit · \(Fmt.grams(hit.grams)) g"
                + (hit.streak >= 7 && hit.streak % 7 == 0 ? " · \(hit.streak)-day streak" : "")
        } else {
            model.isProtein = false
            model.symbol = "checkmark.circle.fill"
        }
        show(model)
    }

    func deleted(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        let name = entries.count == 1 ? entries[0].name : "\(entries.count) items"
        show(ToastModel(symbol: "trash.fill", text: "Deleted \(name)", deleted: entries))
    }

    func message(_ text: String, symbol: String = "checkmark.circle.fill") {
        show(ToastModel(symbol: symbol, text: text))
    }

    func undo(store: Store) {
        guard let model = current else { return }
        if let action = model.action {
            dismiss()
            action.run()
            return
        }
        if !model.created.isEmpty { store.delete(model.created) }
        if !model.deleted.isEmpty { store.restore(model.deleted) }
        Haptics.soft()
        dismiss()
    }
}

/// Logging, deleting and undo for every surface.
@MainActor
enum Actions {
    static var store: Store { Store.shared }

    /// nil (with a toast) when the food was deleted.
    @discardableResult
    static func log(_ food: Food, servings: Double, meal: Meal, day: String, source: String = "app") -> Entry? {
        guard let e = store.log(food, servings: servings, meal: meal, day: day, source: source) else {
            Haptics.warning()
            Toasts.shared.message("This food was deleted", symbol: "trash.fill")
            return nil
        }
        finishLog([e])
        return e
    }

    static func again(_ entries: [Entry], meal: Meal? = nil, day: String) {
        finishLog(store.logAgain(entries, meal: meal, day: day))
    }

    static func pick(_ pick: Pick, meal: Meal, day: String) {
        switch pick.kind {
        case .food(let f): log(f, servings: 1, meal: meal, day: day)
        case .entry(let e): again([e], meal: meal, day: day)
        }
    }

    static func quick(name: String, nutrients: NutrientMap, meal: Meal, day: String) {
        finishLog([store.logQuick(name: name, nutrients: nutrients, meal: meal, day: day)])
    }

    /// `ml` is exact: 8 fl oz logs 236.588 ml (three decimals, like every stored amount).
    static func water(_ ml: Double, day: String) {
        let e = store.addWater(ml: NutritionMath.round3(ml), day: day)
        Haptics.light()
        Toasts.shared.show(ToastModel(symbol: "drop.fill", text: "Added \(Fmt.volume(ml, Units.current)) water", created: [e.id]))
    }

    /// An AI log the server wrote (confirmed or auto-logged): the usual toast, and Undo deletes them.
    static func agentLogged(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        finishLog(entries)
    }

    static func delete(_ entries: [Entry]) {
        store.delete(entries.map(\.id))
        Toasts.shared.deleted(entries)
    }

    private static func finishLog(_ entries: [Entry]) {
        AddSession.current?.record(entries)
        var hit: (Double, Int)?
        if store.proteinGoalJustHit {
            hit = (store.summary(for: Days.today).totals["protein"] ?? 0, store.proteinStreak)
            Haptics.success()
        } else {
            Haptics.light()
        }
        Toasts.shared.logged(entries, proteinHit: hit.map { (grams: $0.0, streak: $0.1) })
    }
}

// MARK: - View

struct ToastView: View {
    @Environment(Toasts.self) private var toasts
    @Environment(Store.self) private var store
    @Environment(\.colorSchemeContrast) private var contrast
    @Namespace private var ns
    @State private var drag: CGFloat = 0

    var body: some View {
        GlassEffectContainer {
            if let t = toasts.current {
                HStack(spacing: 10) {
                    Image(systemName: t.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(t.isProtein ? Palette.protein : (t.symbol == "drop.fill" ? Palette.water : Palette.accent))
                        .symbolEffect(.bounce, value: t.isProtein)
                        .contentTransition(.symbolEffect(.replace))
                    Text(t.text)
                        .scaledFont(15, .medium, relativeTo: .subheadline)
                        .foregroundStyle(contrast == .increased ? Color.primary : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                    if t.hasUndo {
                        Spacer(minLength: 4)
                        Button(t.action?.title ?? "Undo") { toasts.undo(store: store) }
                            .scaledFont(15, .semibold, relativeTo: .subheadline)
                            .foregroundStyle(Palette.accentInk)
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, t.hasUndo ? 10 : 16)
                .frame(height: 44)
                .fixedSize(horizontal: !t.hasUndo, vertical: false)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("toast", in: ns)
                .offset(y: max(0, drag))
                .gesture(DragGesture().onChanged { drag = $0.translation.height }.onEnded { v in
                    if v.translation.height > 16 { toasts.dismiss() }
                    withAnimation(Motion.toast) { drag = 0 }
                })
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .offset(y: 12)))
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(Motion.morph, value: toasts.current?.text)
    }
}

extension View {
    /// Shows the undo toast 12 pt above the bottom of this view's safe area.
    func toastHost(bottom: CGFloat = 12) -> some View {
        overlay(alignment: .bottom) {
            ToastView().padding(.horizontal, Space.l).padding(.bottom, bottom)
        }
    }
}
