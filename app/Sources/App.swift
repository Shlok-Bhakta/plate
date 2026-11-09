// Plate: the app entry point, crash breadcrumbs and Gala reporting, the Apple Health launch path (HealthSync
// to a separate health server in builds with HealthSecrets.swift, otherwise HealthDaysPush to the food
// server), setup links (plate://setup?url=...&token=...), and the debug launch arguments used for demo
// mode and screenshots.
//
//   -PlateDemo YES            seed the demo fixture and disable networking
//   -PlateScreen <name>       open a screen at launch: add, quickadd, create, food, scanner, entry,
//                             settings, nutrients, trends, library, search
//   -PlateQuery <text>        prefill the Add sheet search
//   -PlateFood <id>           the food -PlateScreen food opens (e.g. demo-yogurt)
//   -PlateAmountUnit <unit>   Food detail starts in: ounces, grams or portion0, portion1, …
//   -PlateClock HH:mm         pretend it's this time today (in the server's zone)
//   -PlateUnits us|metric     save that unit system (Settings → Units) before the first screen draws
//   -PlateDaysAgo <n>         select the day n days before today in Today
//   -PlateScrollTo <section>  scroll Today to breakfast, lunch, dinner, snack, water, nutrients or health
//   -PlateConnection <state>  force the sync pill: offline, syncing, auth
//   -PlateState loading       show the first-launch placeholder
//   -PlateOnboarding <url|link> prefill onboarding (a build without Secrets.swift); -PlateOnboardingScroll form,
//                             -PlateOnboardingConnect YES (tap Connect), -PlateOnboardingHealth skip (no Health step)
//   -PlateToast YES           show a sample undo toast
//   -PlateNoFocus YES         don't focus the Add sheet's search field
//   -heroShowsEaten YES       start the hero in "eaten" mode
//   -PlateRange 7|30|90       Trends range
//   -PlateTrendsFocus <card>  scroll Trends to calories, macros, protein, weight, activity, nutrients or map
//                             (also active and steps, as the health tiles send)
//   -PlateTrendDetail <kind>  push a Trends chart full screen: calories, macros, protein, weight, activity
//   -PlateNutrient <key>      open a nutrient's page (with -PlateScreen trends or nutrients)
//   -PlateNutrientsScroll <key> scroll Nutrients detail to that nutrient's row
//   -PlateSelectDaysAgo <n>   select the day n days back in every Trends chart (shows the callouts)
//   Library (wave 2): -PlateScreen recipes | foods | recipe (edit a recipe) | newrecipe | picker
//                     (ingredient picker) | ingredient (amount editor) | recipedetail;
//                     -PlateSegment favorites|foods|recipes; -PlateLibraryQuery <text>
//   Settings (wave 2): -PlateScreen goals | basis | appicon | units | about | health (scroll) | micros | mealsplit |
//                     limits | healthlog (Apple Health activity);
//                     -PlateSetIcon E1|D1|D2|D3|D4|E2|E3|E4 switches the home-screen icon a second after launch;
//                     -PlateGoalEdit <key> opens a goal's inline editor;
//                     -PlateHealth syncing|retry|none shows another Apple Health state in demo mode
//   AI logging: -PlateScreen agentsettings | agentinstructions | agentmodels (Settings → AI logging) |
//              capture (the camera; -PlateCaptureReview YES starts on the demo shot) | capturetext |
//              agentprogress (-PlateAgentHold YES stays on it) | agentdraft | agenterror (with
//              -PlateAgentError noKey|invalidKey|outOfCredit|unknownModel|timeout|offline|dailyLimit|busy|server) |
//              agenttext (a text job for -PlateQuery) | agentsetup (the not-set-up sheet);
//              -PlateAgent unconfigured, -PlateAgentAutoLog YES, -PlateDemoPhoto <file in Documents>,
//              -PlateInstructionsCollapsed YES
//   Reminders: -PlateScreen reminders (Settings, scrolled to Reminders); -PlateReminders denied shows the
//              "off in iOS Settings" state in demo mode; -PlateRemindersIntro YES shows the one-time intro in
//              demo mode; -PlateTestReminder breakfast|lunch|dinner|summary delivers one in 4 s
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The previous run's breadcrumbs, shown in Settings → Apple Health → Activity.
    static private(set) var previousRun: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Health self-tests, run in a throwaway simulator by ios-test.sh.
        if CommandLine.arguments.contains("--selftest") {
            Task { exit(await HealthSync.selfTest() ? 0 : 1) }
            return true
        }
        if CommandLine.arguments.contains("--startup-test") {
            HealthSync.shared.runStartupTest()
            return true
        }
        let previous = Breadcrumbs.start()
        Self.previousRun = previous
        GalaReporter.start(captureOutput: false, screenshotAfter: 8)
        Breadcrumbs.drop("launch")
        if let previous, previous.contains("FATAL") {
            GalaReporter.log("Plate previous run:\n" + previous.split(separator: "\n").suffix(60).joined(separator: "\n"))
        }
        // Meal reminders: the notification delegate and the background refresh handler must be set up
        // before launch ends, so a tapped reminder or a refresh that launched the app is delivered.
        Reminders.shared.start()
        // Demo mode never touches Health or the network.
        guard !UserDefaults.standard.bool(forKey: "PlateDemo") else { return true }
        if application.applicationState == .background {
            // A HealthKit background wake (or a reminder action) launched the app: sync the food log once so
            // the reminders see what the agent logged. Its own background time, apart from the Health sync's.
            Task { @MainActor in
                let id = application.beginBackgroundTask(withName: "reminders") {}
                await Reminders.shared.backgroundRefresh()
                application.endBackgroundTask(id)
            }
        }
        guard BuildFeatures.healthServer else {
            // No health server: daily totals go to the food server, if Health access was allowed.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                await HealthDaysPush.shared.pushIfDue()
            }
            return true
        }
        // The health sync's launch path, unchanged from the Personal Health app. Background delivery only
        // wakes the app for observers registered during launch.
        Task { @MainActor in
            // Send the previous run's last steps to the health server first, and wait for it, so a run that
            // gets killed still leaves a report behind. Then start the Health work.
            if let previous, !previous.isEmpty {
                let tail = previous.split(separator: "\n").suffix(60).joined(separator: "\n")
                await HealthSync.shared.sendDiagnostics(tail)
            }
            try? await Task.sleep(for: .seconds(1))
            HealthSync.shared.startObserving()
            HealthSync.shared.syncEverything()
        }
        return true
    }
}

@main
struct PlateApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        DebugLaunch.applyClock()
        DebugLaunch.applyUnits()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(Store.shared)
                .environment(Router.shared)
                .environment(Toasts.shared)
                .modifier(UnitsProvider())
                .tint(Palette.accentInk)
                .task { DebugLaunch.apply() }
                .onOpenURL { url in
                    if let link = SetupLink.parse(url.absoluteString) { Router.shared.setupLink = link }
                }
        }
    }
}

@MainActor
enum DebugLaunch {
    private static var defaults: UserDefaults { .standard }

    /// Runs before the Store exists, so demo data lands on the pretend "today".
    nonisolated static func applyClock() {
        guard let clock = UserDefaults.standard.string(forKey: "PlateClock") else { return }
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        let launch = Date()
        let start = Days.calendar.startOfDay(for: launch)
        let pretend = start.addingTimeInterval(Double(parts[0] * 3600 + parts[1] * 60))
        Days.now = { pretend.addingTimeInterval(Date().timeIntervalSince(launch)) }
    }

    /// -PlateUnits us|metric: sets all four units, as the US / Metric switch does.
    nonisolated static func applyUnits() {
        guard let raw = UserDefaults.standard.string(forKey: "PlateUnits"), let system = UnitSystem(rawValue: raw) else { return }
        Units(system).save()
    }

    static func apply() {
        let store = Store.shared, router = Router.shared
        if let back = defaults.string(forKey: "PlateDaysAgo").flatMap(Int.init), back > 0 {
            router.day = Days.add(-back, to: Days.today)
        }
        switch defaults.string(forKey: "PlateConnection") {
        case "offline": store.debugConnection = .offline(pending: 3)
        case "syncing": store.debugConnection = .syncing(pending: 2)
        case "auth": store.debugConnection = .authFailed
        default: break
        }
        if defaults.string(forKey: "PlateState") == "loading" { store.debugHideData() }
        if let id = defaults.string(forKey: "PlateSetIcon"), let icon = AppIcon.all.first(where: { $0.id == id }) {
            Task {
                // iOS only changes the icon while the app is active and on screen.
                try? await Task.sleep(for: .seconds(1))
                AppIconStore.shared.select(icon)
            }
        }
        if let name = defaults.string(forKey: "PlateTestReminder") {
            Task { await Reminders.shared.sendTest(name) }
        }
        if defaults.bool(forKey: "PlateToast"), let e = store.summary(for: Days.today).entries(.breakfast).last {
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                Toasts.shared.logged([e])
            }
        }
        let query = defaults.string(forKey: "PlateQuery") ?? ""
        switch defaults.string(forKey: "PlateScreen") {
        case "add": router.add = AddRequest(meal: router.logMeal, day: router.day, query: query)
        case "quickadd": router.openAdd(start: .quickAdd)
        case "create": router.openAdd(start: .create)
        case "food":
            let id = defaults.string(forKey: "PlateFood") ?? store.favorites.first?.id ?? store.foodList.first?.id ?? ""
            router.openAdd(start: .food(id))
        case "scanner": router.openAdd(start: .scanner)
        case "entry":
            if let e = store.summary(for: router.day).entries(.breakfast).first { router.editing = EntryRef(id: e.id) }
        case "agentsettings", "agentinstructions", "agentmodels":
            router.todayPath = [.settings]
        case "settings", "goals", "basis", "appicon", "units", "reminders", "about", "health", "healthlog", "micros", "mealsplit", "limits":
            router.todayPath = [.settings]
        case "nutrients": router.todayPath = [.nutrients(day: router.day)]
        case "trends": router.tab = .trends
        case "library", "recipes", "foods", "recipe", "newrecipe", "picker", "ingredient", "recipedetail":
            router.tab = .library
        case "search": router.tab = .search
        default: break
        }
    }
}
