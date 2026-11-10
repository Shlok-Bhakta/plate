// AI logs that outlive their sheet. Every run registers here when it starts; swiping its sheet away (or
// Hide) only hides it, and it keeps polling. When a hidden run finishes, AgentArrival (Core) decides: the
// sheet opens again if the app is in front with nothing modal on screen, otherwise a local notification
// ("Your lunch draft is ready", or "Logged lunch · 780 kcal" with auto-log) that opens it, and the undo
// toast for an auto-log. While hidden runs exist, the Quick Log bar shows a pill that reopens them.
//
// In the background iOS gives a running job about half a minute (a background task) to finish and notify;
// after that polling resumes when the app comes back. Notifications use the Reminders delegate
// (`plate.agent` category, `agentRun` in userInfo).
import SwiftUI
import UIKit
import UserNotifications

@Observable
@MainActor
final class AgentCenter {
    static let shared = AgentCenter()
    nonisolated static let category = "plate.agent"
    nonisolated static let runKey = "agentRun"

    /// Live runs, oldest first (running, or holding a draft or an error).
    private(set) var runs: [AgentRun] = []
    /// Set to ask the root AgentHost to present this run again (it clears it).
    var reopen: AgentRun?

    @ObservationIgnored private var openOnReturn: Set<UUID> = []
    @ObservationIgnored private var pendingUndo: (entries: [Entry], at: Date)?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var center: UNUserNotificationCenter { .current() }

    private init() {}

    var pill: AgentPill? { AgentPill.make(runs.map { (id: $0.id, state: $0.state, hidden: $0.isHidden) }) }
    func run(_ id: UUID) -> AgentRun? { runs.first { $0.id == id } }

    // MARK: Lifecycle

    func track(_ run: AgentRun) {
        if !runs.contains(where: { $0 === run }) { runs.append(run) }
        updateBackgroundTask()
    }

    /// Cancelled, discarded, closed or logged by hand: forget it.
    func ended(_ run: AgentRun) {
        runs.removeAll { $0 === run }
        openOnReturn.remove(run.id)
        removeNotification(run)
        updateBackgroundTask()
    }

    /// The sheet went away without ending the run (swipe down or Hide).
    func hide(_ run: AgentRun) {
        guard runs.contains(where: { $0 === run }) else { return }
        run.isHidden = true
        Haptics.soft()
        // The first time, ask for notifications, so "we'll notify you" can come true.
        Task { await askForNotificationsIfNeeded() }
        // Finished while its sheet was closing (a draft or an error): it waits in the pill.
    }

    /// Its sheet is on screen again.
    func shown(_ run: AgentRun) {
        run.isHidden = false
        openOnReturn.remove(run.id)
        removeNotification(run)
    }

    /// A run reached a draft, a failure, a log or a cancellation.
    func finished(_ run: AgentRun) {
        defer { updateBackgroundTask() }
        guard run.isHidden else {
            switch run.state {
            case .logged, .done: ended(run)
            case .cancelled:
                ended(run)
                Toasts.shared.message("This AI log was cancelled", symbol: "xmark.circle.fill")
            default: break
            }
            return
        }
        let app = UIApplication.shared.applicationState
        let arrival = AgentArrival.decide(run.state, meal: run.meal, summary: run.draft?.summary,
                                          foreground: app == .active, modalOpen: Self.isModalOpen,
                                          notificationsAllowed: Reminders.shared.isAllowed)
        switch arrival {
        case .reopen:
            reopen = run
        case .toast:
            ended(run)
            Actions.agentLogged(run.logged)
        case .notify(let title, let body):
            if case .logged = run.state {
                // Logged: the run is over; Undo waits for the next open.
                pendingUndo = (run.logged, Date())
                ended(run)
            } else {
                openOnReturn.remove(run.id)
            }
            post(title: title, body: body, for: run)
        case .later:
            if case .logged = run.state {
                pendingUndo = (run.logged, Date())
                ended(run)
            } else if app != .active {
                openOnReturn.insert(run.id)
            }
        case .drop:
            ended(run)
        }
    }

    /// The pill or a notification: open the run's sheet, closing whatever sheet is in the way.
    func open(_ id: UUID) {
        if let undo = pendingUndo, run(id) == nil {
            pendingUndo = nil
            showUndo(undo)
            return
        }
        guard let run = run(id) else { return }
        if Self.isModalOpen {
            let router = Router.shared
            router.add = nil
            router.editing = nil
            router.setupLink = nil
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                reopen = run
            }
        } else {
            reopen = run
        }
    }

    /// The app came to the front: show a pending undo toast, or a draft that finished while it was away.
    func becameActive() {
        updateBackgroundTask()
        if let undo = pendingUndo {
            pendingUndo = nil
            showUndo(undo)
        }
        guard let next = runs.last(where: { openOnReturn.contains($0.id) && $0.isHidden && $0.state.isFinished }) else { return }
        openOnReturn.removeAll()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Self.isModalOpen, UIApplication.shared.applicationState == .active else { return }
            reopen = next
        }
    }

    func enteredBackground() { updateBackgroundTask() }

    private func showUndo(_ undo: (entries: [Entry], at: Date)) {
        guard Date().timeIntervalSince(undo.at) < 6 * 3600 else { return }
        let live = undo.entries.compactMap { Store.shared.entry(id: $0.id) }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            Toasts.shared.logged(live.isEmpty ? undo.entries : live)
        }
    }

    // MARK: Background time

    /// While a job runs and the app isn't in front, hold a background task so polling can finish it.
    private func updateBackgroundTask() {
        let running = runs.contains { $0.state.isRunning }
        let app = UIApplication.shared
        if running && app.applicationState != .active {
            guard backgroundTask == .invalid else { return }
            backgroundTask = app.beginBackgroundTask(withName: "ai-log") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        } else {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Notifications

    private func askForNotificationsIfNeeded() async {
        guard !Store.shared.isDemo else { return }
        await Reminders.shared.refreshAuthorization()
        guard Reminders.shared.authorization == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await Reminders.shared.refreshAuthorization()
    }

    private func post(title: String, body: String, for run: AgentRun) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "plate.agent"
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.runKey: run.id.uuidString]
        let request = UNNotificationRequest(identifier: Self.identifier(run), content: content, trigger: nil)
        center.add(request) { error in
            if let error { print("Plate: AI log notification not posted: \(error)") }
        }
    }

    private func removeNotification(_ run: AgentRun) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(run)])
    }

    private static func identifier(_ run: AgentRun) -> String { "plate.agent.\(run.id.uuidString)" }

    /// A notification tap (from the Reminders delegate).
    func openNotification(_ info: [AnyHashable: Any]) {
        guard let raw = info[Self.runKey] as? String, let id = UUID(uuidString: raw) else { return }
        open(id)
    }

    // MARK: Screen

    /// Something is presented over the tabs (a sheet, a cover, a popover, an alert).
    static var isModalOpen: Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let root = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return false }
        return root.presentedViewController != nil
    }
}
