// The Apple Health daily totals the app sends to POST /v1/health_days when there's no separate health
// server (HealthDaysPush reads them from HealthKit): which days to read, and the request body.
import Foundation

/// One day's totals, as HealthKit's statistics computed them (sources de-duplicated). nil is unknown.
struct HealthDayTotals: Equatable, Sendable {
    var day: String
    var weightKg: Double?
    var activeKcal: Double?
    var basalKcal: Double?
    var steps: Double?
    var exerciseMin: Double?

    var isEmpty: Bool { weightKg == nil && activeKcal == nil && basalKcal == nil && steps == nil && exerciseMin == nil }
}

/// Body facts for the server's profile. Only known values are sent: a null would clear the server's copy.
struct HealthProfileFacts: Equatable, Sendable {
    /// "YYYY-MM-DD"
    var dob: String?
    /// "male" or "female"
    var sex: String?
    var heightCm: Double?

    var isEmpty: Bool { dob == nil && sex == nil && heightCm == nil }
}

enum HealthDaysPlan {
    /// The first push covers this many days, today included.
    static let firstRunDays = 30
    /// Later pushes start this many days before the last day sent, for late Watch syncs and edits.
    static let overlapDays = 2

    /// The first day to read: 30 days back on the first run, else a little before the last day sent
    /// (never further back than the first run would go, and never after today).
    static func startDay(lastSent: String?, today: String) -> String {
        let earliest = Days.add(-(firstRunDays - 1), to: today)
        guard let lastSent else { return earliest }
        let start = Days.add(-overlapDays, to: min(lastSent, today))
        return max(start, earliest)
    }

    /// `{"days": [...], "profile": {...}}`. Days without any value are left out: a pushed day replaces the
    /// server's row, so an empty one would wipe numbers that came from somewhere else.
    static func body(days: [HealthDayTotals], profile: HealthProfileFacts?) -> [String: Any] {
        func r(_ x: Double?, _ places: Double = 10) -> Any { x.map { ($0 * places).rounded() / places } ?? NSNull() }
        var body: [String: Any] = [
            "days": days.filter { !$0.isEmpty }.sorted { $0.day < $1.day }.map { d in
                ["day": d.day, "weight_kg": r(d.weightKg, 100), "active_kcal": r(d.activeKcal), "basal_kcal": r(d.basalKcal),
                 "steps": r(d.steps, 1), "exercise_min": r(d.exerciseMin)] as [String: Any]
            },
        ]
        if let profile, !profile.isEmpty {
            var p: [String: Any] = [:]
            if let dob = profile.dob { p["dob"] = dob }
            if let sex = profile.sex { p["sex"] = sex }
            if let h = profile.heightCm { p["height_cm"] = (h * 10).rounded() / 10 }
            body["profile"] = p
        }
        return body
    }
}
