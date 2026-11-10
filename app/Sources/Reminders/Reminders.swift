// Meal reminders: local notifications only (UNUserNotificationCenter), no push and no entitlements.
// ReminderPlan (Core) decides which should exist; this keeps the pending ones in step with it whenever
// the log changes (hand logs, and agent logs arriving through sync), on foreground, from a BGAppRefreshTask,
// and when a HealthKit background wake launches the app. Tapping a reminder opens the Add sheet for that
// meal; its "Same as yesterday" action logs yesterday's meal in the background and shows the undo toast
// on the next open. AI log notifications (AgentCenter, category `plate.agent`) share the delegate.
import BackgroundTasks
import SwiftUI
import UIKit
import UserNotifications

@Observable
@MainActor
final class Reminders {
    static let shared = Reminders()

    /// The background refresh task's identifier: the bundle id + ".reminders", as Info.plist's
    /// BGTaskSchedulerPermittedIdentifiers ("$(PRODUCT_BUNDLE_IDENTIFIER).reminders") says.
    nonisolated static let refreshTaskID = (Bundle.main.bundleIdentifier ?? "plate") + ".reminders"
    nonisolated static let mealCategory = "plate.meal"
    nonisolated static let mealAgainCategory = "plate.meal.again"
    nonisolated static let summaryCategory = "plate.summary"
    nonisolated static let sameAction = "plate.same-as-yesterday"
    private enum Key {
        /// The one-time "Meal reminders?" explanation was shown (or answered in Settings).
        static let introShown = "reminders.introShown"
        /// Entries "Same as yesterday" logged in the background; the next open shows their undo toast.
        static let pendingUndo = "reminders.pendingUndo"
        static let pendingUndoAt = "reminders.pendingUndoAt"
    }

    private(set) var settings: ReminderSettings
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Shows the one-time explanation before the system prompt.
    var showIntro = false

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let delegate = NotificationDelegate()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var store: Store { Store.shared }

    private init() {
        settings = ReminderSettings.load { UserDefaults.standard.object(forKey: $0) }
    }

    /// Notifications can be delivered.
    var isAllowed: Bool {
        if store.isDemo && UserDefaults.standard.string(forKey: "PlateReminders") != "denied" { return true }
        return [.authorized, .provisional, .ephemeral].contains(authorization)
    }

    var isDenied: Bool {
        if store.isDemo { return UserDefaults.standard.string(forKey: "PlateReminders") == "denied" }
        return authorization == .denied
    }

    /// Demo mode never schedules real reminders (its log is a fixture), except `-PlateTestReminder`.
    private var schedules: Bool { !store.isDemo }

    // MARK: Launch

    /// From didFinishLaunching, before it returns, so a tap or action that launched the app is delivered.
    func start() {
        guard !started else { return }
        started = true
        center.delegate = delegate
        let same = UNNotificationAction(identifier: Self.sameAction, title: "Same as yesterday", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "doc.on.doc"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.mealCategory, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.mealAgainCategory, actions: [same], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.summaryCategory, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: AgentCenter.category, actions: [], intentIdentifiers: []),
        ])
        Self.registerBackgroundRefresh()
        store.onLogChange = { [weak self] in self?.reschedule() }
        Task { await refreshAuthorization(); await apply() }
    }

    /// BGTaskScheduler needs the handler registered during launch. It runs on the main queue and hops to
    /// the main actor explicitly (a main-actor closure called on another queue kills the app; see HealthSync).
    nonisolated private static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: .main) { @Sendable task in
            let work = Task { @MainActor in
                await Reminders.shared.backgroundRefresh()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Asks for the next background refresh in about two hours (iOS decides when, if at all).
    private func submitBackgroundRefresh() {
        guard schedules else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(2 * 3600)
        do { try BGTaskScheduler.shared.submit(request) } catch { print("Plate: reminder refresh not scheduled: \(error)") }
    }

    /// A BGAppRefreshTask, or a HealthKit background wake that launched the app: one food sync so the
    /// agent's logs count, then reschedule from the fresh log. Without a separate health server, the
    /// Apple Health daily totals go to the food server too (HealthDaysPush; a no-op in builds with one).
    func backgroundRefresh() async {
        guard schedules else { return }
        Breadcrumbs.drop("reminders: background refresh")
        await store.syncNow()
        await apply()
        await HealthDaysPush.shared.pushIfDue()
        submitBackgroundRefresh()
    }

    // MARK: Foreground

    /// Called whenever the app becomes active.
    func becameActive() {
        Task {
            await refreshAuthorization()
            await apply()
            // Not over onboarding: the intro waits until a server is connected.
            if authorization == .notDetermined && !UserDefaults.standard.bool(forKey: Key.introShown) && !store.needsServer
                && (!store.isDemo || UserDefaults.standard.bool(forKey: "PlateRemindersIntro")) {
                try? await Task.sleep(for: .seconds(1.2))
                showIntro = true
            }
        }
        showPendingUndo()
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    // MARK: Settings

    func update(_ change: (inout ReminderSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        for (key, value) in s.stored { UserDefaults.standard.set(value, forKey: key) }
        reschedule()
    }

    /// The master switch. Turning it on the first time asks iOS once; if iOS already said no, it opens
    /// Plate's notification settings instead.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(true, forKey: Key.introShown)
        guard on else { update { $0.enabled = false }; return }
        if isDenied {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            return
        }
        update { $0.enabled = true }
        if authorization == .notDetermined && !store.isDemo { Task { await requestPermission() } }
    }

    /// The intro's "Turn on" (and the master switch's first use): the one system prompt.
    func requestPermission() async {
        UserDefaults.standard.set(true, forKey: Key.introShown)
        showIntro = false
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        Breadcrumbs.drop("reminders: permission \(granted ? "granted" : "declined")")
        await refreshAuthorization()
        if granted { update { $0.enabled = true } }
        await apply()
    }

    /// The intro's "Not now": never asks again; Settings → Reminders can still turn them on.
    func declineIntro() {
        UserDefaults.standard.set(true, forKey: Key.introShown)
        showIntro = false
    }

    /// What's coming next, for Settings: "Dinner · today 8:30 PM".
    func next(now: Date = Days.now()) -> PlannedReminder? {
        ReminderPlan.plan(settings, now: now, goals: store.goals, summary: store.summary(for:)).first
    }

    // MARK: Scheduling

    /// Coalesces bursts (a sync applies many rows) into one reschedule.
    func reschedule() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.apply()
        }
    }

    /// Makes the pending reminders match the plan, and clears delivered ones that no longer apply.
    func apply() async {
        guard schedules else { return }
        let now = Days.now()
        let plan = isAllowed ? ReminderPlan.plan(settings, now: now, goals: store.goals, summary: store.summary(for:)) : []
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(ReminderPlan.prefix) }
        let keep = Set(plan.map(\.id))
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { !keep.contains($0) })
        for reminder in plan {
            // Same identifier replaces the pending one, so changed times and summary numbers take effect.
            try? await center.add(request(for: reminder))
        }
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let stale = ReminderPlan.staleDelivered(delivered, now: now, summary: store.summary(for:))
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        if !plan.isEmpty { submitBackgroundRefresh() }
    }

    private func request(for r: PlannedReminder, trigger: UNNotificationTrigger? = nil, id: String? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.body = r.body
        content.threadIdentifier = "plate.reminders"
        content.userInfo = ["day": r.day, "meal": r.meal?.rawValue ?? ""]
        if r.meal != nil {
            content.sound = .default
            content.categoryIdentifier = r.sameAsYesterday ? Self.mealAgainCategory : Self.mealCategory
        } else {
            // A banner without a sound: it was asked for, but it's information, not a nudge.
            content.categoryIdentifier = Self.summaryCategory
        }
        // The device's calendar, so the trigger fires at the moment the plan chose (in the server's zone).
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireAt)
        return UNNotificationRequest(identifier: id ?? r.id, content: content,
                                     trigger: trigger ?? UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    // MARK: Responses

    /// A tap opens the Add sheet for that meal (the summary opens Today).
    func open(day: String, meal: Meal?) {
        let router = Router.shared
        router.editing = nil
        router.tab = .today
        router.todayPath = []
        router.day = min(day, Days.today)
        if let meal { router.openAdd(meal: meal, day: min(day, Days.today)) }
    }

    /// "Same as yesterday": copies the previous day's meal into this one, through the same path as the
    /// Add sheet's "Copy all". In the background the undo toast waits for the next open.
    func logSameAsYesterday(day: String, meal: Meal) async {
        var yesterday = store.previousMeal(meal, before: day)
        if yesterday.isEmpty && !store.isDemo {
            await store.syncNow()
            yesterday = store.previousMeal(meal, before: day)
        }
        guard !yesterday.isEmpty else { return }
        Breadcrumbs.drop("reminders: same as yesterday \(meal.rawValue) \(yesterday.count)")
        if UIApplication.shared.applicationState == .active {
            Actions.again(yesterday, meal: meal, day: day)
        } else {
            let copies = store.logAgain(yesterday, meal: meal, day: day)
            let ids = (UserDefaults.standard.stringArray(forKey: Key.pendingUndo) ?? []) + copies.map(\.id)
            UserDefaults.standard.set(ids, forKey: Key.pendingUndo)
            UserDefaults.standard.set(Date(), forKey: Key.pendingUndoAt)
            await store.flush()
        }
        await apply()
    }

    private func showPendingUndo() {
        let d = UserDefaults.standard
        guard let ids = d.stringArray(forKey: Key.pendingUndo), !ids.isEmpty else { return }
        let at = d.object(forKey: Key.pendingUndoAt) as? Date ?? .distantPast
        d.removeObject(forKey: Key.pendingUndo)
        d.removeObject(forKey: Key.pendingUndoAt)
        let entries = ids.compactMap(store.entry(id:))
        guard !entries.isEmpty, Date().timeIntervalSince(at) < 12 * 3600 else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            Toasts.shared.logged(entries)
        }
    }

    /// Foreground presentation: hide a meal reminder if that meal was logged in the last moments.
    func shouldPresent(day: String, meal: Meal?) -> Bool {
        guard let meal else { return true }
        return store.summary(for: day).entries(meal).isEmpty
    }

    // MARK: Debug

    /// `-PlateTestReminder breakfast|lunch|dinner|summary`: asks for permission if needed and delivers
    /// that reminder for today in 4 s, whatever the log says (works in demo mode, for screenshots).
    func sendTest(_ name: String) async {
        if authorization == .notDetermined { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        await refreshAuthorization()
        let today = Days.today
        var reminder: PlannedReminder
        if let meal = Meal(rawValue: name), meal != .snack {
            reminder = PlannedReminder(kind: .meal(meal), day: today, fireAt: Date(), title: ReminderPlan.mealTitle(meal),
                                       body: ReminderPlan.mealBody,
                                       sameAsYesterday: !store.previousMeal(meal, before: today).isEmpty)
        } else {
            reminder = PlannedReminder(kind: .summary, day: today, fireAt: Date(), title: "Today",
                                       body: ReminderPlan.summaryLine(store.summary(for: today), goals: store.goals))
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 4, repeats: false)
        try? await center.add(request(for: reminder, trigger: trigger, id: "plate.test.\(name)"))
        print("Plate: test reminder \(name) in 4 s (authorization \(authorization.rawValue))")
    }
}

/// UNUserNotificationCenter's delegate. Its callbacks can arrive on any queue, so it isn't main-actor
/// isolated; each one hops to the main actor explicitly.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // An AI log that finished behind a sheet: always show it.
        if notification.request.content.categoryIdentifier == AgentCenter.category {
            completionHandler([.banner, .list, .sound])
            return
        }
        let (day, meal) = Self.target(notification.request.content.userInfo)
        let test = notification.request.identifier.hasPrefix("plate.test.")
        Task { @MainActor in
            let show = test || Reminders.shared.shouldPresent(day: day, meal: meal)
            completionHandler(show ? [.banner, .list] : [])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == AgentCenter.category {
            let info = response.notification.request.content.userInfo
            let id = info[AgentCenter.runKey] as? String
            Task { @MainActor in
                if let id { AgentCenter.shared.openNotification([AgentCenter.runKey: id]) }
                completionHandler()
            }
            return
        }
        let (day, meal) = Self.target(response.notification.request.content.userInfo)
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case Reminders.sameAction:
                if let meal { await Reminders.shared.logSameAsYesterday(day: day, meal: meal) }
            case UNNotificationDefaultActionIdentifier:
                Reminders.shared.open(day: day, meal: meal)
            default:
                break
            }
            completionHandler()
        }
    }

    private static func target(_ info: [AnyHashable: Any]) -> (day: String, meal: Meal?) {
        let day = info["day"] as? String ?? Days.today
        let meal = (info["meal"] as? String).flatMap(Meal.init(rawValue:))
        return (day.count == 10 ? day : Days.today, meal)
    }
}
