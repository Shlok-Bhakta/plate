// DESIGN 4.1 Today: week strip, hero ring and macros, meal sections, water, the nutrients insight
// and health tiles, in an inset-grouped List so swipe actions are native.
import SwiftUI

/// The slide and fade applied to day-dependent rows when the selected day changes.
struct DayShift: Equatable { var x: CGFloat = 0; var opacity: Double = 1 }
private struct DayShiftKey: EnvironmentKey { static let defaultValue = DayShift() }
extension EnvironmentValues {
    var dayShift: DayShift {
        get { self[DayShiftKey.self] }
        set { self[DayShiftKey.self] = newValue }
    }
}

private struct DayShifted: ViewModifier {
    @Environment(\.dayShift) private var shift
    func body(content: Content) -> some View { content.offset(x: shift.x).opacity(shift.opacity) }
}
extension View { func dayShifted() -> some View { modifier(DayShifted()) } }

struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("heroShowsEaten") private var showsEaten = false
    @State private var shift = DayShift()

    private var day: String { router.day }
    private var today: String { router.today }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.todayPath) {
            ScrollViewReader { proxy in
            List {
                Section {
                    WeekStrip(day: $router.day, today: today)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                .listSectionMargins(.top, 0)
                if store.hasData {
                    content
                } else {
                    LoadingPlaceholder()
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(Space.l)
            .scrollContentBackground(.hidden)
            .background { TodayBackground() }
            .environment(\.dayShift, shift)
            .navigationTitle(Days.title(day))
            .toolbar { toolbar }
            .refreshable { await store.syncNow() }
            .navigationDestination(for: TodayRoute.self) { route in
                switch route {
                case .settings: SettingsView()
                case .nutrients(let d): NutrientsView(day: d)
                }
            }
            .toastHost()
            .task {
                // Debug: -PlateScrollTo breakfast|lunch|dinner|snack|water|nutrients|health
                guard let target = UserDefaults.standard.string(forKey: "PlateScrollTo") else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(target, anchor: .top)
            }
            }
        }
        .onChange(of: router.day) { old, new in
            let direction: CGFloat = new > old ? 1 : -1
            Haptics.selection()
            if reduceMotion {
                shift = DayShift(x: 0, opacity: 0)
                withAnimation(.easeInOut(duration: 0.2)) { shift = DayShift() }
            } else {
                shift = DayShift(x: direction * 12, opacity: 0)
                withAnimation(.easeOut(duration: 0.25)) { shift = DayShift() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        let summary = store.summary(for: day)
        Section {
            HeroCard(summary: summary, goals: store.goals, showsEaten: $showsEaten,
                     celebration: day == today ? store.proteinCelebration : 0)
                .dayShifted()
                .listRowInsets(EdgeInsets(top: 20, leading: Space.l, bottom: Space.l, trailing: Space.l))
                .simultaneousGesture(daySwipe)
        }
        ForEach(Meal.allCases) { meal in
            MealSection(meal: meal, day: day, summary: summary).id(meal.rawValue)
        }
        Section { WaterCard(day: day, ml: summary.waterMl, goalMl: store.goals?.water ?? 3000) }.id("water")
        if let goals = store.goals, !summary.isEmpty {
            Section { NutrientsInsightCard(day: day, summary: summary, goals: goals) }.id("nutrients")
        }
        if store.hasHealth {
            Section {
                HealthTiles(day: day)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            .id("health")
        }
    }

    /// Swipe the hero left or right to move between days.
    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { v in
                guard abs(v.translation.width) > 60, abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                let next = Days.add(v.translation.width < 0 ? 1 : -1, to: day)
                if next <= today { router.day = next }
            }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !store.connection.isHealthy {
            ToolbarItem(placement: .topBarLeading) { SyncStatusPill(state: store.connection) }
        }
        if day != today {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Today") { router.day = today }.tint(.primary)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink(value: TodayRoute.settings) {
                Image(systemName: "gearshape")
            }
            .tint(.primary)
            .accessibilityLabel("Settings")
        }
    }
}

/// DESIGN 2.2: the warm accent wash behind the hero, only on Today.
struct TodayBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { g in
            ZStack {
                Palette.background
                RadialGradient(colors: [Palette.accent.opacity(scheme == .dark ? 0.14 : 0.10), Palette.accent.opacity(0)],
                               center: UnitPoint(x: 0.5, y: (g.safeAreaInsets.top + 120) / max(g.size.height + g.safeAreaInsets.top, 1)),
                               startRadius: 0, endRadius: 320)
            }
            .ignoresSafeArea()
        }
    }
}

/// First launch with no cache: the hero and meals as redacted placeholders with a slow pulse.
private struct LoadingPlaceholder: View {
    @State private var dim = false
    var body: some View {
        Group {
            Section {
                HeroCard(summary: DaySummary(day: Days.today, entries: []), goals: DemoData.goals,
                         showsEaten: .constant(false), celebration: 0)
                    .listRowInsets(EdgeInsets(top: 20, leading: Space.l, bottom: Space.l, trailing: Space.l))
            }
            ForEach([Meal.breakfast, .lunch, .dinner]) { meal in
                Section {
                    HStack { Text(meal.title).font(.headline); Spacer(); Text("000 · 000") }
                    HStack { Text("Placeholder entry name"); Spacer(); Text("000") }.frame(minHeight: 52)
                }
            }
        }
        .redacted(reason: .placeholder)
        .opacity(dim ? 0.5 : 1)
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true } }
        .accessibilityLabel("Loading")
    }
}
