// Apple Health for builds without a separate health server (no HealthSecrets.swift): with the user's
// permission, reads a few HealthKit types as per-day totals (HKStatisticsCollectionQuery, so overlapping
// sources such as a Watch and a phone are de-duplicated by HealthKit) and sends them to the food server's
// POST /v1/health_days, where they drive the adaptive goals.
//
// Runs on launch, on foreground and from the reminders' background refresh: the last 30 days the first
// time, then from a couple of days before the last day sent. Never runs alongside HealthSync, which in
// builds with HealthSecrets.swift sends everything to the health server (and the food server pulls it).
// Its UserDefaults keys are all `healthDays.*`.
import Foundation
import HealthKit

@Observable
@MainActor
final class HealthDaysPush {
    static let shared = HealthDaysPush()

    private enum Key {
        static let requested = "healthDays.requested"
        static let lastSentDay = "healthDays.lastSentDay"
        static let lastPush = "healthDays.lastPush"
        static let daysSent = "healthDays.daysSent"
    }

    /// This build sends daily totals itself (it has no health server).
    static var isEnabled: Bool { !BuildFeatures.healthServer }
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// The user allowed (or at least answered) the Health sheet.
    private(set) var requested = UserDefaults.standard.bool(forKey: Key.requested)
    private(set) var busy = false
    private(set) var lastPush = UserDefaults.standard.object(forKey: Key.lastPush) as? Date
    /// The newest day sent, so the next push starts near it.
    private(set) var lastSentDay = UserDefaults.standard.string(forKey: Key.lastSentDay)
    /// Days the server stored as new or changed, since this server was set up.
    private(set) var daysSent = UserDefaults.standard.integer(forKey: Key.daysSent)
    /// The last outcome, for Settings ("Up to date", "Sent 30 days", or what went wrong).
    private(set) var status = ""
    private(set) var failed = false

    @ObservationIgnored private let health = HKHealthStore()

    nonisolated static let quantities: [(id: HKQuantityTypeIdentifier, unit: HKUnit, mostRecent: Bool)] = [
        (.bodyMass, .gramUnit(with: .kilo), true),
        (.activeEnergyBurned, .kilocalorie(), false),
        (.basalEnergyBurned, .kilocalorie(), false),
        (.stepCount, .count(), false),
        (.appleExerciseTime, .minute(), false),
    ]

    static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>(quantities.map { HKQuantityType($0.id) })
        types.insert(HKQuantityType(.height))
        types.insert(HKCharacteristicType(.dateOfBirth))
        types.insert(HKCharacteristicType(.biologicalSex))
        return types
    }

    /// Shows the Health sheet, then sends the first 30 days.
    func requestAccess() async {
        guard Self.isEnabled else { return }
        guard Self.isAvailable else {
            report("Apple Health isn't available on this device", failed: true)
            return
        }
        do {
            Breadcrumbs.drop("health days: requestAuthorization")
            try await health.requestAuthorization(toShare: [], read: Self.readTypes)
        } catch {
            let text = error.localizedDescription
            report(text.lowercased().contains("entitlement") ? "This build doesn't have the HealthKit capability" : "Health access failed: \(text)",
                   failed: true)
            return
        }
        requested = true
        UserDefaults.standard.set(true, forKey: Key.requested)
        await pushIfDue(force: true)
    }

    /// Sends the days since the last push. Without `force`, at most every 15 minutes within a day.
    func pushIfDue(force: Bool = false) async {
        let store = Store.shared
        guard Self.isEnabled, requested, Self.isAvailable, !busy, !store.isDemo, let api = store.api else { return }
        let today = Days.today
        if !force, let last = lastPush, lastSentDay == today, Date().timeIntervalSince(last) < 15 * 60 { return }
        busy = true
        defer { busy = false }
        let start = HealthDaysPlan.startDay(lastSent: lastSentDay, today: today)
        Breadcrumbs.drop("health days: reading \(start) to \(today)")
        do {
            let days = try await Self.dailyTotals(health, from: start, through: today)
            let profile = await Self.profile(health)
            let body = HealthDaysPlan.body(days: days, profile: profile)
            let hasDays = !((body["days"] as? [Any])?.isEmpty ?? true)
            var written = 0
            if hasDays || body["profile"] != nil {
                written = try await api.healthDays(body).written
            }
            guard store.api?.base == api.base else { return }  // the server changed meanwhile
            lastSentDay = today
            lastPush = Date()
            daysSent += written
            UserDefaults.standard.set(today, forKey: Key.lastSentDay)
            UserDefaults.standard.set(lastPush, forKey: Key.lastPush)
            UserDefaults.standard.set(daysSent, forKey: Key.daysSent)
            report(!hasDays ? "No Health data yet" : written > 0 ? "Sent \(written) day\(written == 1 ? "" : "s")" : "Up to date", failed: false)
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            report("Phone locked, will retry", failed: false)
        } catch APIError.unauthorized {
            report("The server didn't accept the token", failed: true)
        } catch is CancellationError {
            return
        } catch {
            report("Couldn't send: \(error.localizedDescription)", failed: true)
        }
    }

    /// A new server (or none): start over with 30 days.
    func serverChanged() {
        lastSentDay = nil
        lastPush = nil
        daysSent = 0
        status = ""
        failed = false
        for key in [Key.lastSentDay, Key.lastPush, Key.daysSent] { UserDefaults.standard.removeObject(forKey: key) }
        Task { await pushIfDue(force: true) }
    }

    private func report(_ text: String, failed: Bool) {
        status = text
        self.failed = failed
        Breadcrumbs.drop("health days: \(text)")
    }

    // MARK: Reading HealthKit
    // Not main-actor isolated: HealthKit calls the handlers on its own queues (see HealthSync).

    nonisolated private static func dailyTotals(_ health: HKHealthStore, from first: String, through last: String) async throws -> [HealthDayTotals] {
        var byDay: [String: HealthDayTotals] = [:]
        for q in quantities {
            let values = try await statistics(health, q.id, unit: q.unit, mostRecent: q.mostRecent, from: first, through: last)
            for (day, value) in values {
                var d = byDay[day] ?? HealthDayTotals(day: day)
                switch q.id {
                case .bodyMass: d.weightKg = value
                case .activeEnergyBurned: d.activeKcal = value
                case .basalEnergyBurned: d.basalKcal = value
                case .stepCount: d.steps = value
                case .appleExerciseTime: d.exerciseMin = value
                default: break
                }
                byDay[day] = d
            }
        }
        return byDay.values.filter { $0.day >= first && $0.day <= last }.sorted { $0.day < $1.day }
    }

    /// Per-day sums (or the day's last value, for weight), keyed by day in the server's zone.
    nonisolated private static func statistics(_ health: HKHealthStore, _ id: HKQuantityTypeIdentifier, unit: HKUnit, mostRecent: Bool,
                                               from first: String, through last: String) async throws -> [String: Double] {
        let start = Days.calendar.startOfDay(for: Days.date(first))
        let end = Days.calendar.startOfDay(for: Days.date(Days.add(1, to: last)))
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let query = HKStatisticsCollectionQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: predicate,
                                                options: mostRecent ? .mostRecent : .cumulativeSum,
                                                anchorDate: start, intervalComponents: DateComponents(day: 1))
        return try await withCheckedThrowingContinuation { continuation in
            query.initialResultsHandler = { @Sendable _, collection, error in
                if let error {
                    if (error as? HKError)?.code == .errorNoData { continuation.resume(returning: [:]) } else { continuation.resume(throwing: error) }
                    return
                }
                var out: [String: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    guard let quantity = mostRecent ? stats.mostRecentQuantity() : stats.sumQuantity() else { return }
                    // HealthKit steps the buckets in the phone's calendar; the middle of a bucket is on the
                    // right day even when the phone's zone (and its DST dates) differ from the server's.
                    let middle = stats.startDate.addingTimeInterval(stats.endDate.timeIntervalSince(stats.startDate) / 2)
                    out[Days.key(middle)] = quantity.doubleValue(for: unit)
                }
                continuation.resume(returning: out)
            }
            health.execute(query)
        }
    }

    nonisolated private static func profile(_ health: HKHealthStore) async -> HealthProfileFacts {
        var facts = HealthProfileFacts()
        if let dob = try? health.dateOfBirthComponents(), let y = dob.year, let m = dob.month, let d = dob.day {
            facts.dob = String(format: "%04d-%02d-%02d", y, m, d)
        }
        switch (try? health.biologicalSex())?.biologicalSex {
        case .male?: facts.sex = "male"
        case .female?: facts.sex = "female"
        default: break
        }
        facts.heightCm = await latest(health, .height, unit: .meterUnit(with: .centi))
        return facts
    }

    nonisolated private static func latest(_ health: HKHealthStore, _ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKQuantityType(id), predicate: nil, limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { @Sendable _, samples, _ in
                continuation.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            health.execute(query)
        }
    }
}
