// AI logging while a job runs (SPEC "AI logging"): the progress sheet's timer, which ticks on the phone
// and is corrected by the server's `elapsed_ms`; what happens when a job that was hidden (swiped away or
// Hide) finishes; and the "Working…" pill for jobs running in the background. Pure Foundation, so the
// logic tests cover it on the Mac; AgentCenter (UI/Agent) applies it.
import Foundation

/// The elapsed time a job shows: local from Send, corrected by `elapsed_ms` from polls. It never runs
/// backwards: when a correction moves the start later, the display holds until real time catches up.
struct AgentClock: Equatable, Sendable {
    private(set) var start: Date
    /// The value shown when a correction moved the start later; elapsed never drops below it.
    private(set) var floor: TimeInterval = 0

    /// Differences smaller than this (upload time, poll latency) aren't corrected, so the timer doesn't jitter.
    static let tolerance: TimeInterval = 1.5
    /// After this the sheet says it's taking longer than usual.
    static let slowAfter: TimeInterval = 30
    /// Past this Cancel asks first (that much work would be thrown away).
    static let confirmCancelAfter: TimeInterval = 10

    init(start: Date = Date()) { self.start = start }

    func elapsed(at now: Date) -> TimeInterval { max(0, floor, now.timeIntervalSince(start)) }
    func seconds(at now: Date) -> Int { Int(elapsed(at: now)) }

    /// The server says the job has run `elapsedMs` as of `now`.
    mutating func correct(elapsedMs: Int, at now: Date) {
        guard elapsedMs >= 0 else { return }
        let server = Double(elapsedMs) / 1000
        let shown = elapsed(at: now)
        guard abs(server - now.timeIntervalSince(start)) > Self.tolerance else { return }
        if server < shown { floor = max(floor, shown) }
        start = now.addingTimeInterval(-server)
    }

    func isSlow(at now: Date) -> Bool { elapsed(at: now) >= Self.slowAfter }
    func confirmsCancel(at now: Date) -> Bool { elapsed(at: now) > Self.confirmCancelAfter }
    func label(at now: Date) -> String { Self.label(seconds(at: now)) }

    /// "0 s", "12 s", "1 min 5 s", "2 min".
    static func label(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) s" }
        let m = s / 60, r = s % 60
        return r == 0 ? "\(m) min" : "\(m) min \(r) s"
    }
}

/// Where a job stands, as the background logic needs it.
enum AgentRunState: Equatable, Sendable {
    case running
    /// A draft to check (kcal of the draft).
    case draft(kcal: Double)
    /// Auto-logged (kcal logged).
    case logged(kcal: Double)
    /// Failed, with the friendly title.
    case failed(String)
    case cancelled
    /// Logged by hand, discarded or closed: nothing left.
    case done

    var isRunning: Bool { self == .running }
    var isFinished: Bool { !isRunning }
}

/// What to do when a hidden job finishes.
enum AgentArrival: Equatable, Sendable {
    /// Foreground and nothing modal on screen: open the sheet again (the draft or the error).
    case reopen
    /// Auto-logged in the foreground: the usual undo toast.
    case toast
    /// A local notification; tapping it opens the draft (or the undo toast).
    case notify(title: String, body: String)
    /// Nothing can be shown now: the pill says it's ready, and it opens when the app is next in front.
    case later
    /// Cancelled: nothing to show.
    case drop

    static func decide(_ state: AgentRunState, meal: Meal, summary: String? = nil, foreground: Bool, modalOpen: Bool,
                       notificationsAllowed: Bool) -> AgentArrival {
        switch state {
        case .running: return .later
        case .cancelled, .done: return .drop
        default: break
        }
        if foreground && !modalOpen {
            if case .logged = state { return .toast }
            return .reopen
        }
        if notificationsAllowed, let n = notification(state, meal: meal, summary: summary) {
            return .notify(title: n.title, body: n.body)
        }
        if foreground, case .logged = state { return .toast }
        return .later
    }

    /// "Your lunch draft is ready" / "Logged lunch · 780 kcal" / "Couldn't draft your lunch".
    static func notification(_ state: AgentRunState, meal: Meal, summary: String?) -> (title: String, body: String)? {
        let summary = summary.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        switch state {
        case .draft:
            return ("Your \(meal.noun) draft is ready", summary ?? "Tap to check it and log it.")
        case .logged(let kcal):
            return ("Logged \(meal.noun) · \(Fmt.kcal(kcal)) kcal", (summary.map { $0 + " " } ?? "") + "Tap to undo.")
        case .failed(let title):
            return ("Couldn't draft your \(meal.noun)", "\(title). Tap to try again.")
        default:
            return nil
        }
    }
}

/// The pill on the Quick Log bar while hidden jobs exist: "Working…" while one runs, else "Ready".
struct AgentPill: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case working, ready, failed }
    var kind: Kind
    /// The run it opens (the newest that matters).
    var runID: UUID
    /// Hidden jobs that still need the person (running, a draft, a failure).
    var count: Int

    var title: String {
        switch kind {
        case .working: "Working…"
        case .ready: "Draft ready"
        case .failed: "Didn't work"
        }
    }

    /// `runs` oldest first. Logged, cancelled and done runs need nothing, so they don't count.
    static func make(_ runs: [(id: UUID, state: AgentRunState, hidden: Bool)]) -> AgentPill? {
        let open = runs.filter { r in
            guard r.hidden else { return false }
            switch r.state {
            case .running, .draft, .failed: return true
            default: return false
            }
        }
        // A finished draft beats a job still working: it's what needs the person now.
        if let ready = open.last(where: { if case .draft = $0.state { true } else { false } }) {
            return AgentPill(kind: .ready, runID: ready.id, count: open.count)
        }
        if let working = open.last(where: { $0.state == .running }) {
            return AgentPill(kind: .working, runID: working.id, count: open.count)
        }
        if let failed = open.last {
            return AgentPill(kind: .failed, runID: failed.id, count: open.count)
        }
        return nil
    }
}
