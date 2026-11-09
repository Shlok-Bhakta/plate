// DESIGN 3: the TabView (Today, Trends, Library, Search), the Quick Log bottom accessory, and the
// app-wide routing for the Add sheet, Entry edit and the scanner.
import SwiftUI

enum AppTab: Hashable { case today, trends, library, search }

/// Where the Add sheet starts.
enum AddStart: Hashable { case search, scanner, quickAdd, create, food(String) }

struct AddRequest: Identifiable, Hashable {
    let id = UUID()
    var meal: Meal
    var day: String
    var start: AddStart = .search
    /// The zoom transition's source (`quicklog`, or `meal-lunch`).
    var sourceID = "quicklog"
    var query = ""
}

struct EntryRef: Identifiable, Hashable { let id: String }

/// Pushed onto Today's stack.
enum TodayRoute: Hashable {
    case settings
    case nutrients(day: String)
}

@Observable
@MainActor
final class Router {
    static let shared = Router()
    var tab: AppTab = .today
    /// The day selected in Today; the Quick Log bar logs to it.
    var day = Days.today
    /// Today's key as of the last check. Views read it so they redraw when the day rolls over.
    private(set) var today = Days.today
    var add: AddRequest?
    var editing: EntryRef?
    var todayPath: [TodayRoute] = []
    /// Set when a health tile is tapped; Trends (wave 2) scrolls to that chart.
    var trendsFocus: String?
    /// A plate://setup link that was opened: onboarding fills it in, otherwise Change server opens with it.
    var setupLink: SetupLink?

    /// The meal the Quick Log bar logs to, from the time of day.
    var logMeal: Meal { Days.meal() }

    /// After midnight (or a clock or time zone change) a selection that was on today moves to the new today,
    /// so the app never keeps logging to yesterday.
    func rollDayIfNeeded() {
        let now = Days.today
        guard now != today else { return }
        if day == today { day = now }
        today = now
    }

    func openAdd(meal: Meal? = nil, day: String? = nil, start: AddStart = .search, sourceID: String = "quicklog") {
        add = AddRequest(meal: meal ?? logMeal, day: day ?? self.day, start: start, sourceID: sourceID)
    }
}

private struct ZoomNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    /// The namespace for zoom transitions from the Quick Log bar and meal buttons into the Add sheet.
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func zoomSource(_ id: String, _ ns: Namespace.ID?) -> some View {
        if let ns { matchedTransitionSource(id: id, in: ns) } else { self }
    }
    @ViewBuilder func zoomDestination(_ id: String, _ ns: Namespace.ID?) -> some View {
        if let ns { navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var phase
    @Namespace private var zoom

    var body: some View {
        @Bindable var router = router
        Group {
            if store.needsServer {
                OnboardingView()
                    .transition(.opacity)
            } else {
                TabView(selection: $router.tab) {
                    Tab("Today", systemImage: "fork.knife", value: AppTab.today) { TodayView() }
                    Tab("Trends", systemImage: "chart.xyaxis.line", value: AppTab.trends) { TrendsView() }
                    Tab("Library", systemImage: "books.vertical", value: AppTab.library) { LibraryView() }
                    Tab(value: AppTab.search, role: .search) { SearchTabView() }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
                .modifier(QuickLogAccessory(enabled: router.tab != .search))
                .agentHost(debug: true)
                .sheet(item: $router.setupLink) { link in
                    NavigationStack { ServerConnectView(mode: .change, link: link) }
                }
            }
        }
        .animation(Motion.smooth, value: store.needsServer)
        .onChange(of: store.needsServer) { _, needs in
            // Just connected: start live sync and offer the reminders intro that onboarding held back.
            if !needs { Reminders.shared.becameActive() }
        }
        .sheet(item: $router.add) { request in
            AddSheet(request: request)
                .zoomDestination(request.sourceID, zoom)
        }
        .sheet(item: $router.editing) { ref in
            EntryEditView(entryID: ref.id)
        }
        .environment(\.zoomNamespace, zoom)
        .onChange(of: phase, initial: true) { _, now in
            if now == .active { router.rollDayIfNeeded() }
            store.setActive(now == .active)
            if now == .active { Reminders.shared.becameActive() }
        }
        .onChange(of: phase) { _, now in
            // Apple Health: opening the app always syncs, as in the Personal Health app. It's a no-op
            // until launch has registered the observers, and while a sync is running. Without a health
            // server, the daily totals go to the food server instead (at most every 15 minutes).
            guard now == .active && !store.isDemo else { return }
            if BuildFeatures.healthServer {
                HealthSync.shared.syncEverything()
            } else {
                Task { await HealthDaysPush.shared.pushIfDue() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in router.rollDayIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            router.rollDayIfNeeded()
            Reminders.shared.reschedule()
        }
        .modifier(ReminderIntro())
        .onChange(of: router.today) { _, _ in Reminders.shared.reschedule() }
        .onChange(of: store.zoneChanges) { _, _ in
            // The server's time zone arrived or changed: "today" may be another day now.
            router.rollDayIfNeeded()
            Reminders.shared.reschedule()
        }
        .task(id: router.today) {
            // Midnight in the server's zone, which the system's day-change notice misses on a phone in another zone.
            while !Task.isCancelled {
                let midnight = Days.calendar.startOfDay(for: Days.date(Days.add(1, to: router.today)))
                let wait = min(3600, max(1, midnight.timeIntervalSince(Days.now()) + 1))
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                router.rollDayIfNeeded()
            }
        }
    }
}

/// The bottom accessory, hidden on the Search tab where the tab bar becomes the search field.
private struct QuickLogAccessory: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: enabled) { QuickLogBar() }
        } else {
            content.tabViewBottomAccessory { QuickLogBar() }
        }
    }
}

/// DESIGN 3 "Quick Log bar": (+) Log lunch / 1,110 kcal left, barcode, water.
struct QuickLogBar: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.zoomNamespace) private var zoom
    @Environment(\.units) private var units
    @Environment(\.agentLauncher) private var agent
    @State private var drops = 0

    private var expanded: Bool { placement != .inline }
    private var meal: Meal { router.logMeal }
    private var isToday: Bool { router.day == router.today }

    private var title: String {
        isToday ? "Log \(meal.noun)" : "Log to \(Days.weekdayShort(router.day))"
    }

    private var subtitle: String {
        let eaten = store.summary(for: router.day).kcal
        guard let goal = store.goals?.kcal else { return "\(Fmt.kcal(eaten)) kcal eaten" }
        let left = goal - eaten
        return left >= 0 ? "\(Fmt.kcal(left)) kcal left" : "\(Fmt.kcal(-left)) kcal over"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { router.openAdd(meal: meal, day: router.day) } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Palette.accent)
                        Image(systemName: "plus").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if expanded {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                .lineLimit(1).contentTransition(.numericText())
                        }
                    }
                    if expanded { Spacer(minLength: 0) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { longPressMenu }
            .accessibilityLabel("\(title), \(subtitle)")

            if expanded {
                Button { agent?(AgentCaptureRequest(meal: meal, day: router.day)) } label: {
                    Image(systemName: "camera.fill").font(.system(size: 17, weight: .medium))
                        .frame(width: 36, height: 36).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Snap a meal")
                .accessibilityHint("Logs a meal from a photo with AI")

                Button { router.openAdd(meal: meal, day: router.day, start: .scanner) } label: {
                    Image(systemName: "barcode.viewfinder").font(.system(size: 19, weight: .medium))
                        .frame(width: 36, height: 36).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan barcode")

                Menu {
                    ForEach(units.water.menu, id: \.self) { v in
                        Button("\(Fmt.whole(v)) \(units.water.symbol)") { Actions.water(units.water.toMl(v), day: router.day) }
                    }
                } label: {
                    Image(systemName: "drop.fill").font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Palette.water)
                        .frame(width: 36, height: 36).contentShape(Circle())
                } primaryAction: {
                    drops += 1
                    Actions.water(units.water.toMl(units.water.quickAdds[0]), day: router.day)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(Fmt.whole(units.water.quickAdds[0])) \(units.water.spoken) of water")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, expanded ? 8 : 14)
        .zoomSource("quicklog", zoom)
    }

    @ViewBuilder private var longPressMenu: some View {
        ForEach(store.favorites.prefix(4)) { food in
            Button { Actions.log(food, servings: 1, meal: meal, day: router.day) } label: {
                Label("\(food.name) · \(Fmt.kcal(food.kcal))", systemImage: "star.fill")
            }
        }
        Divider()
        Button { router.openAdd(meal: meal, day: router.day, start: .quickAdd) } label: {
            Label("Quick add", systemImage: "bolt.fill")
        }
        let yesterday = store.previousMeal(meal, before: router.day)
        if !yesterday.isEmpty {
            Button { Actions.again(yesterday, meal: meal, day: router.day) } label: {
                Label("Copy yesterday's \(meal.noun)", systemImage: "doc.on.doc")
            }
        }
        Button { router.openAdd(meal: meal, day: router.day, start: .scanner) } label: {
            Label("Scan barcode", systemImage: "barcode.viewfinder")
        }
        Button { agent?(AgentCaptureRequest(meal: meal, day: router.day)) } label: {
            Label("Snap a meal", systemImage: "camera")
        }
        Button { agent?(AgentCaptureRequest(mode: .text(""), meal: meal, day: router.day)) } label: {
            Label("Describe a meal", systemImage: "text.bubble")
        }
    }
}

/// DESIGN 4.11: a glass pill at top leading, only when sync isn't healthy.
struct SyncStatusPill: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @State private var explain = false
    var state: ConnectionState

    var body: some View {
        Button {
            if state == .authFailed { router.todayPath.append(.settings) } else { explain = true }
        } label: {
            HStack(spacing: 5) {
                switch state {
                case .syncing(let n):
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .semibold))
                        .symbolEffect(.rotate, options: .repeating)
                    if n > 0 { Text("\(n)").monospacedDigit() }
                case .offline(let n):
                    Image(systemName: "icloud.slash").font(.system(size: 12, weight: .semibold))
                    Text(n > 0 ? "Offline · \(n) pending" : "Offline")
                case .authFailed:
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
                        .foregroundStyle(Palette.over)
                    Text("Sign-in failed")
                default:
                    EmptyView()
                }
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 4)
        }
        .tint(.primary)
        .popover(isPresented: $explain) {
            Text(state == .syncing(pending: 0) ? "Connecting to your server…"
                 : "Changes are saved on this phone and will sync when your server is reachable.")
                .font(.subheadline)
                .padding()
                .frame(idealWidth: 260)
                .fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        switch state {
        case .syncing(let n): "Syncing, \(n) pending"
        case .offline(let n): "Offline, \(n) pending"
        case .authFailed: "Sign-in failed. Opens Settings."
        default: "Synced"
        }
    }
}
