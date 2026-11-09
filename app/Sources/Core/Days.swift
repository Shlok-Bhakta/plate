// Day keys ("2026-11-08") are local days in the server's time zone (SPEC "Server notes": `timezone` in
// GET /v1/meta), so a day here is the same day the server and its CLI use. Until the first sync has told
// the app the server's zone, it uses the phone's. Weeks start on Monday.
import Foundation

enum Days {
    /// UserDefaults key for the server's zone (an IANA name), cached from GET /v1/meta.
    static let zoneKey = "server.timezone"

    /// The zone every day key, "today" and wall-clock time uses.
    nonisolated(unsafe) private(set) static var zone: TimeZone = initialZone()
    nonisolated(unsafe) private(set) static var calendar: Calendar = makeCalendar(zone)
    nonisolated(unsafe) private static var keyFormatter: DateFormatter = makeFormatter(calendar)

    /// The cached server zone, else the phone's (before the first sync, or for a name this OS doesn't know).
    static func initialZone(_ stored: String? = UserDefaults.standard.string(forKey: zoneKey)) -> TimeZone {
        stored.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// Switches every day computation to `zone`. Returns whether it changed.
    @discardableResult
    static func setZone(_ zone: TimeZone) -> Bool {
        guard zone.identifier != self.zone.identifier else { return false }
        self.zone = zone
        calendar = makeCalendar(zone)
        keyFormatter = makeFormatter(calendar)
        return true
    }

    /// The server's zone from GET /v1/meta: cached for the next launch and applied now. An unknown or
    /// missing name changes nothing. Returns whether the zone changed.
    @discardableResult
    static func useServerZone(_ identifier: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let identifier, let zone = TimeZone(identifier: identifier) else { return false }
        defaults.set(identifier, forKey: zoneKey)
        return setZone(zone)
    }

    /// Forgets the server's zone (signed out): back to the phone's.
    @discardableResult
    static func forgetServerZone(defaults: UserDefaults = .standard) -> Bool {
        defaults.removeObject(forKey: zoneKey)
        return setZone(.current)
    }

    /// True once a server has told the app its zone.
    static func hasServerZone(defaults: UserDefaults = .standard) -> Bool { defaults.string(forKey: zoneKey) != nil }

    private static func makeCalendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.firstWeekday = 2
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private static func makeFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Overridable "now" for tests and screenshots.
    nonisolated(unsafe) static var now: () -> Date = { Date() }

    static func key(_ date: Date) -> String { keyFormatter.string(from: date) }
    static var today: String { key(now()) }

    /// Noon on that day, which is safe across DST changes.
    static func date(_ key: String) -> Date {
        guard let d = keyFormatter.date(from: key) else { return now() }
        return calendar.date(byAdding: .hour, value: 12, to: d) ?? d
    }

    static func add(_ days: Int, to key: String) -> String {
        Days.key(calendar.date(byAdding: .day, value: days, to: date(key)) ?? date(key))
    }

    static func between(_ a: String, _ b: String) -> Int {
        calendar.dateComponents([.day], from: date(a), to: date(b)).day ?? 0
    }

    /// The Monday that starts the week holding `key`.
    static func weekStart(_ key: String) -> String {
        let weekday = calendar.component(.weekday, from: date(key)) // 1 = Sunday
        let offset = (weekday + 5) % 7
        return add(-offset, to: key)
    }

    static func week(_ start: String) -> [String] { (0..<7).map { add($0, to: start) } }

    static func dayNumber(_ key: String) -> Int { calendar.component(.day, from: date(key)) }

    static func weekdayLetter(_ key: String) -> String {
        ["S", "M", "T", "W", "T", "F", "S"][calendar.component(.weekday, from: date(key)) - 1]
    }

    static func weekdayShort(_ key: String) -> String {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][calendar.component(.weekday, from: date(key)) - 1]
    }

    /// "Today", "Yesterday", or "Thu, Nov 6".
    static func title(_ key: String, today: String = Days.today) -> String {
        if key == today { return "Today" }
        if key == add(-1, to: today) { return "Yesterday" }
        if key == add(1, to: today) { return "Tomorrow" }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let month = months[calendar.component(.month, from: date(key)) - 1]
        return "\(weekdayShort(key)), \(month) \(dayNumber(key))"
    }

    /// The default meal for a moment (CLI rules): before 10:30 breakfast, before 15:00 lunch,
    /// before 21:00 dinner, otherwise snack.
    static func meal(at date: Date = Days.now()) -> Meal {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if minutes < 10 * 60 + 30 { return .breakfast }
        if minutes < 15 * 60 { return .lunch }
        if minutes < 21 * 60 { return .dinner }
        return .snack
    }

    static func hour(_ date: Date = Days.now()) -> Int { calendar.component(.hour, from: date) }

    /// `logged_at` moved to `day` at the same wall-clock time. Adding 24 h steps would drift an
    /// hour across a DST change and could land on the wrong day. 0 (unknown) stays unknown.
    static func moving(loggedAt: Int, to day: String) -> Int {
        guard loggedAt > 0 else { return loggedAt }
        let old = Date(timeIntervalSince1970: Double(loggedAt / 1000))
        let time = calendar.dateComponents([.hour, .minute, .second], from: old)
        let start = calendar.startOfDay(for: date(day))
        guard let moved = calendar.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: time.second ?? 0, of: start)
        else { return loggedAt }
        return Int(moved.timeIntervalSince1970) * 1000 + loggedAt % 1000
    }

    /// A `logged_at` for an entry put on `day`: now when it's today, otherwise a time typical of the meal.
    static func loggedAt(day: String, meal: Meal) -> Int {
        if day == today { return Int(now().timeIntervalSince1970 * 1000) }
        let hour: Int = switch meal { case .breakfast: 8; case .lunch: 12; case .dinner: 19; case .snack: 15 }
        let start = calendar.startOfDay(for: date(day))
        let at = calendar.date(byAdding: .hour, value: hour, to: start) ?? start
        return Int(at.timeIntervalSince1970 * 1000)
    }
}
