// Meal reminders, the pure part: the settings (UserDefaults `reminders.*`), and which local notifications
// should exist for a log and a moment. Sources/Reminders schedules them with UNUserNotificationCenter and
// calls `plan` again whenever the log changes (hand logs, agent logs arriving by sync), on foreground and on
// background wakes. iOS can't run code at 14:30, so each reminder is scheduled ahead and cancelled once its
// meal has an entry. Copy stays short and kind: no guilt, no calorie warnings (DESIGN 6 "Copy tone").
import Foundation

struct ReminderSettings: Equatable, Sendable {
    struct Slot: Equatable, Sendable {
        var on: Bool
        /// Minutes after midnight, wall-clock time in the server's zone (Days.zone).
        var minutes: Int
    }

    /// The master switch. On by default, so it takes effect as soon as notifications are allowed.
    var enabled = true
    var breakfast = Slot(on: true, minutes: 10 * 60 + 30)
    var lunch = Slot(on: true, minutes: 14 * 60 + 30)
    var dinner = Slot(on: true, minutes: 20 * 60 + 30)
    /// The evening "Today: 1,850 / 2,190 kcal · 92 / 160 g protein". Off by default.
    var summary = Slot(on: false, minutes: 21 * 60 + 30)

    /// The meals that get a reminder (snacks never do).
    static let meals: [Meal] = [.breakfast, .lunch, .dinner]

    subscript(meal: Meal) -> Slot? {
        get {
            switch meal {
            case .breakfast: breakfast
            case .lunch: lunch
            case .dinner: dinner
            case .snack: nil
            }
        }
        set {
            guard let newValue else { return }
            switch meal {
            case .breakfast: breakfast = newValue
            case .lunch: lunch = newValue
            case .dinner: dinner = newValue
            case .snack: break
            }
        }
    }

    enum Key {
        static let enabled = "reminders.enabled"
        static func on(_ slot: String) -> String { "reminders.\(slot).on" }
        static func time(_ slot: String) -> String { "reminders.\(slot).time" }
    }

    private static let slotNames = ["breakfast", "lunch", "dinner", "summary"]
    private var slots: [Slot] { [breakfast, lunch, dinner, summary] }

    /// Reads `reminders.*`; anything missing or out of range keeps its default.
    static func load(_ read: (String) -> Any?) -> ReminderSettings {
        var s = ReminderSettings()
        if let on = read(Key.enabled) as? Bool { s.enabled = on }
        var slots = s.slots
        for (i, name) in slotNames.enumerated() {
            if let on = read(Key.on(name)) as? Bool { slots[i].on = on }
            if let m = read(Key.time(name)) as? Int, (0..<1440).contains(m) { slots[i].minutes = m }
        }
        s.breakfast = slots[0]; s.lunch = slots[1]; s.dinner = slots[2]; s.summary = slots[3]
        return s
    }

    var stored: [String: Any] {
        var out: [String: Any] = [Key.enabled: enabled]
        for (name, slot) in zip(Self.slotNames, slots) {
            out[Key.on(name)] = slot.on
            out[Key.time(name)] = slot.minutes
        }
        return out
    }
}

struct PlannedReminder: Equatable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case meal(Meal)
        case summary
    }

    var kind: Kind
    /// The day it's about (a day key).
    var day: String
    var fireAt: Date
    var title: String
    var body: String
    /// Offers "Same as yesterday": the day before has entries in this meal.
    var sameAsYesterday = false

    var id: String { ReminderPlan.id(day: day, kind: kind) }
    var meal: Meal? { if case .meal(let m) = kind { m } else { nil } }
}

enum ReminderPlan {
    /// Every reminder's identifier starts with this, so rescheduling never touches anything else.
    static let prefix = "plate.reminder."

    static func id(day: String, kind: PlannedReminder.Kind) -> String {
        switch kind {
        case .meal(let m): "\(prefix)\(day).\(m.rawValue)"
        case .summary: "\(prefix)\(day).summary"
        }
    }

    static func parse(_ id: String) -> (day: String, kind: PlannedReminder.Kind)? {
        guard id.hasPrefix(prefix) else { return nil }
        let parts = id.dropFirst(prefix.count).split(separator: ".")
        guard parts.count == 2, parts[0].count == 10 else { return nil }
        let day = String(parts[0])
        if parts[1] == "summary" { return (day, .summary) }
        guard let meal = Meal(rawValue: String(parts[1])), meal != .snack else { return nil }
        return (day, .meal(meal))
    }

    /// The moment `minutes` after midnight on `day`, in Days.zone (a skipped DST hour moves forward).
    static func fireDate(day: String, minutes: Int) -> Date {
        let start = Days.calendar.startOfDay(for: Days.date(day))
        let m = min(max(minutes, 0), 1439)
        return Days.calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: start)
            ?? start.addingTimeInterval(Double(m * 60))
    }

    /// The reminders that should be pending at `now`: today and the next `days - 1` days (a rolling window,
    /// so they keep coming if the app isn't opened for a day). A meal reminder is left out once its time has
    /// passed or once that meal has any food entry that day (water doesn't count). The summary is only for
    /// today, and only once today has entries, because its numbers are fixed when it's scheduled.
    static func plan(_ settings: ReminderSettings, now: Date, goals: Goals?,
                     summary: (String) -> DaySummary, days: Int = 2) -> [PlannedReminder] {
        guard settings.enabled else { return [] }
        let today = Days.key(now)
        var out: [PlannedReminder] = []
        for offset in 0..<max(days, 1) {
            let day = Days.add(offset, to: today)
            let log = summary(day)
            for meal in ReminderSettings.meals {
                guard let slot = settings[meal], slot.on else { continue }
                let at = fireDate(day: day, minutes: slot.minutes)
                guard at > now, log.entries(meal).isEmpty else { continue }
                let yesterday = summary(Days.add(-1, to: day)).entries(meal)
                out.append(PlannedReminder(kind: .meal(meal), day: day, fireAt: at, title: mealTitle(meal),
                                           body: mealBody, sameAsYesterday: !yesterday.isEmpty))
            }
            if offset == 0, settings.summary.on, !log.isEmpty {
                let at = fireDate(day: day, minutes: settings.summary.minutes)
                if at > now {
                    out.append(PlannedReminder(kind: .summary, day: day, fireAt: at, title: "Today",
                                               body: summaryLine(log, goals: goals)))
                }
            }
        }
        return out.sorted { $0.fireAt < $1.fireAt }
    }

    /// Delivered reminders to clear from Notification Center: any from an earlier day, and a meal's once
    /// it has been logged (so a "Lunch?" doesn't linger after the agent logs lunch).
    static func staleDelivered(_ ids: [String], now: Date, summary: (String) -> DaySummary) -> [String] {
        let today = Days.key(now)
        return ids.filter { id in
            guard let (day, kind) = parse(id) else { return false }
            if day < today { return true }
            if case .meal(let meal) = kind { return !summary(day).entries(meal).isEmpty }
            return false
        }
    }

    static func mealTitle(_ meal: Meal) -> String {
        switch meal {
        case .breakfast: "Breakfast? 🍳"
        case .lunch: "Lunch? 🍽"
        case .dinner: "Dinner? 🍲"
        case .snack: "Snack?"
        }
    }

    static let mealBody = "Snap a photo or tap to log."

    /// "1,850 / 2,190 kcal · 92 / 160 g protein". Without goals, just the amounts; "≥" when some entry
    /// lacks the nutrient (unknown is not zero).
    static func summaryLine(_ s: DaySummary, goals: Goals?) -> String {
        func part(_ key: String, _ value: String, unit: String, target: Double?, format: (Double) -> String) -> String {
            let shown = (s.isPartial(key) ? "≥ " : "") + value
            if let target { return "\(shown) / \(format(target)) \(unit)" }
            return "\(shown) \(unit)"
        }
        let kcal = part("kcal", Fmt.kcal(s.kcal), unit: "kcal", target: goals?.kcal) { Fmt.kcal($0) }
        let protein = part("protein", Fmt.grams(s.totals["protein"] ?? 0), unit: "g protein",
                           target: goals?.target("protein")) { Fmt.grams($0) }
        return "\(kcal) · \(protein)"
    }

    /// "10:30 AM" for minutes after midnight.
    static func timeLabel(_ minutes: Int) -> String {
        let m = min(max(minutes, 0), 1439)
        let h = m / 60
        let hour12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", hour12, m % 60, h < 12 ? "AM" : "PM")
    }
}
