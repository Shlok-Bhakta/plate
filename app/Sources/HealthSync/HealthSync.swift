// Reads every Health type with anchored queries and posts new samples to the health server (HealthSecrets).
// Only builds with HealthSecrets.swift run it (BuildFeatures.healthServer). An anchor only moves
// forward after the server answers 200, so nothing is skipped when the phone is locked or offline.
import Foundation
import HealthKit
import UIKit
import UserNotifications

enum SyncError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self { case .server(let body): return "server said \(body.prefix(200))" }
    }
}

@MainActor
final class HealthSync: ObservableObject {
    static let shared = HealthSync()
    static let batchSize = 20000

    @Published private(set) var status = "Idle"
    @Published private(set) var sent = UserDefaults.standard.integer(forKey: "sent")
    @Published private(set) var lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date
    @Published private(set) var log: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var requested = UserDefaults.standard.bool(forKey: "requested")
    // Progress of the current full sync, for the UI.
    @Published private(set) var typesDone = Set<String>()
    @Published private(set) var currentType: String?
    @Published private(set) var currentThrough: Date?
    @Published private(set) var runSent = 0
    @Published private(set) var runStarted: Date?
    @Published private(set) var finished = false
    private var failures = 0
    private var lockedDuringRun = false
    private var reruns = 0
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private let store = HKHealthStore()
    private var units: [HKQuantityType: HKUnit] = [:]
    private var queue: Task<Void, Never>?
    private var observing = false

    static let sampleTypes: [HKSampleType] = {
        var types: [HKSampleType] = HealthTypes.quantityIdentifiers.compactMap {
            HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: $0))
        }
        types += HealthTypes.categoryIdentifiers.compactMap {
            HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: $0))
        }
        types.append(HKObjectType.workoutType())
        return types
    }()

    static var readTypes: Set<HKObjectType> {
        var types = Set(sampleTypes.map { $0 as HKObjectType })
        for id in [HKCharacteristicTypeIdentifier.dateOfBirth, .biologicalSex, .bloodType, .wheelchairUse] {
            if let type = HKObjectType.characteristicType(forIdentifier: id) { types.insert(type) }
        }
        return types
    }

    // MARK: Access and observers

    func requestAccess() async {
        do {
            Breadcrumbs.drop("requestAuthorization")
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
            Breadcrumbs.drop("requestAuthorization returned")
            requested = true
            UserDefaults.standard.set(true, forKey: "requested")
            note("Health access answered for \(Self.readTypes.count) types")
            startObserving()
            syncEverything()
        } catch {
            note("Health access failed: \(error.localizedDescription)")
        }
    }

    /// Call at launch. Background delivery only wakes the app for observers set up during launch.
    func startObserving() {
        guard requested, !observing else { return }
        observing = true
        Breadcrumbs.drop("registering observers")
        Self.registerObservers(store: store, types: Self.sampleTypes)
        Breadcrumbs.drop("observers registered")
        note("Watching \(Self.sampleTypes.count) types for new data")
    }

    /// Deliberately not main-actor isolated. HealthKit calls these handlers on its own queues, and a
    /// main-actor closure called off the main thread makes Swift's runtime kill the app. That was
    /// the crash right after granting access, and on every launch after it.
    nonisolated private static func registerObservers(store: HKHealthStore, types: [HKSampleType]) {
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { @Sendable _, done, error in
                Breadcrumbs.drop("observer fired \(type.identifier) error=\(error != nil)")
                guard error == nil else { done(); return }
                Task { @MainActor in
                    await HealthSync.shared.wake(for: type)
                    done()
                }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { @Sendable _, _ in }
        }
    }

    // MARK: Syncing

    /// Posts the previous run's breadcrumbs to the health service (`kind: "diag"`), waiting up to 5 s.
    func sendDiagnostics(_ steps: String) async {
        var request = URLRequest(url: HealthSecrets.url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(HealthSecrets.token)", forHTTPHeaderField: "Authorization")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["kind": "diag", "label": "build \(build)", "text": steps])
        _ = try? await URLSession.shared.data(for: request)
        if let last = steps.split(separator: "\n").last { note("Previous run ended after: \(last)") }
    }

    // MARK: Daily schedule

    /// Health can't be read while the phone is locked, so "3 AM" can't mean 3 AM. The daily sync runs
    /// on the first background wake after 3 AM that finds the phone unlocked, usually the morning pickup.
    var dailySyncDue: Bool {
        let calendar = Calendar.current
        let now = Date()
        var cutoff = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: now) ?? now
        if now < cutoff { cutoff = calendar.date(byAdding: .day, value: -1, to: cutoff) ?? cutoff }
        let last = UserDefaults.standard.object(forKey: "lastDailySync") as? Date ?? .distantPast
        return last < cutoff
    }

    var lastDailySync: Date? { UserDefaults.standard.object(forKey: "lastDailySync") as? Date }

    /// Called for every HealthKit wake. On screen, sync that type now. In the background, only run
    /// the once-a-day full sync, and only when it's due.
    func wake(for type: HKSampleType) async {
        if UIApplication.shared.applicationState == .active {
            await enqueue(type)
        } else if dailySyncDue && !busy {
            Breadcrumbs.drop("daily sync from background wake")
            await runFullSync()
        }
    }

    func syncEverything() {
        guard requested, observing, !busy else { return }
        Task { @MainActor in await runFullSync() }
    }

    private func runFullSync() async {
        guard requested, observing, !busy else { return }
        Breadcrumbs.drop("full sync")
        busy = true
        finished = false
        typesDone = []
        runSent = 0
        runStarted = Date()
        failures = 0
        lockedDuringRun = false
        UIApplication.shared.isIdleTimerDisabled = true
        // Time to finish the current batch after leaving the app. The handler runs on the main thread.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "health-sync") { [weak self] in
            self?.backgroundTimeEnded()
        }
        do {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            for type in Self.sampleTypes { await enqueue(type) }
            do {
                try await upload(Batch(label: "profile", profile: profile()))
            } catch {
                note("profile: \(error.localizedDescription)")
            }
            UIApplication.shared.isIdleTimerDisabled = false
            busy = false
            finished = true
            currentType = nil
            if status.hasPrefix("Sent") || status == "Syncing" { status = failures == 0 ? "Up to date" : "\(failures) types will retry" }
            endBackgroundTime()
            if failures == 0 && !lockedDuringRun {
                reruns = 0
                UserDefaults.standard.set(Date(), forKey: "lastDailySync")
                // Only big catch-ups get a notification, not the quiet daily sync.
                if runSent >= 50_000 { await notifyDone() }
            } else if failures > 0, reruns < 3, UIApplication.shared.applicationState == .active {
                // Anchors only move after a 200, so a rerun picks up exactly what failed.
                reruns += 1
                try? await Task.sleep(for: .seconds(5))
                syncEverything()
            }
        }
    }

    private func backgroundTimeEnded() {
        status = "Paused, resumes when you open the app"
        Breadcrumbs.drop("background time ended")
        endBackgroundTime()
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Runs one type's sync after any already queued, so uploads never overlap.
    func enqueue(_ type: HKSampleType) async {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await self.sync(type)
        }
        queue = task
        await task.value
    }

    private func sync(_ type: HKSampleType) async {
        do {
            Breadcrumbs.drop("sync \(type.identifier)")
            currentType = Self.prettyName(type)
            if units.isEmpty {
                Breadcrumbs.drop("loading units")
                await loadUnits()
                Breadcrumbs.drop("units loaded: \(units.count)")
            }
            // While batch N uploads, batch N+1 is read and built. An anchor is saved only once its
            // own upload has succeeded, so a failure resends from the last confirmed batch.
            var anchor = self.anchor(for: type)
            var inFlight: (upload: Task<Void, Error>, anchor: HKQueryAnchor, count: Int, through: Date?)?
            while true {
                let descriptor = HKAnchoredObjectQueryDescriptor(
                    predicates: [.sample(type: type)], anchor: anchor, limit: Self.batchSize)
                let result = try await descriptor.result(for: store)
                let added = result.addedSamples
                Breadcrumbs.drop("query \(type.identifier): \(added.count) samples")
                var batch = Batch(label: type.identifier)
                if type == HKObjectType.workoutType() {
                    batch.workouts = added.compactMap { $0 as? HKWorkout }.map(workoutRecord)
                } else {
                    batch.samples = added.map(sampleRecord)
                }
                if let previous = inFlight {
                    try await previous.upload.value
                    confirm(type, anchor: previous.anchor, count: previous.count, through: previous.through)
                    inFlight = nil
                }
                if added.isEmpty {
                    save(result.newAnchor, for: type)
                    typesDone.insert(type.identifier)
                    return
                }
                let upload = Task.detached { try await HealthSync.send(batch) }
                inFlight = (upload, result.newAnchor, added.count, added.map(\.endDate).max())
                anchor = result.newAnchor
                if added.count < Self.batchSize {
                    try await upload.value
                    confirm(type, anchor: result.newAnchor, count: added.count, through: inFlight?.through)
                    typesDone.insert(type.identifier)
                    return
                }
            }
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            lockedDuringRun = true
            status = "Phone locked, will retry"
        } catch {
            typesDone.insert(type.identifier)
            failures += 1
            Breadcrumbs.drop("error \(type.identifier): \(error)")
            if UIApplication.shared.applicationState == .active {
                note("\(Self.shortName(type)): \(error.localizedDescription), will retry")
            } else {
                status = "Paused, resumes when you open the app"
            }
        }
    }

    private func confirm(_ type: HKSampleType, anchor: HKQueryAnchor, count: Int, through: Date?) {
        save(anchor, for: type)
        sent += count
        runSent += count
        currentThrough = through
        lastSync = Date()
        UserDefaults.standard.set(sent, forKey: "sent")
        UserDefaults.standard.set(lastSync, forKey: "lastSync")
        status = "Sent \(count.formatted()) \(Self.shortName(type))"
    }

    private func loadUnits() async {
        let quantityTypes = Set(Self.sampleTypes.compactMap { $0 as? HKQuantityType })
        units = (try? await store.preferredUnits(for: quantityTypes)) ?? [:]
    }

    private func upload(_ batch: Batch) async throws {
        try await Self.send(batch)
    }

    /// JSON, compressed with raw DEFLATE (about a tenth the size), posted off the main thread.
    /// Network errors and server 5xx are retried twice, after 1 s and 4 s.
    nonisolated static func send(_ batch: Batch) async throws {
        let json = try JSONEncoder().encode(batch)
        let body = try (json as NSData).compressed(using: .zlib) as Data
        Breadcrumbs.drop("encoded \(json.count) bytes, sending \(body.count)")
        var request = URLRequest(url: HealthSecrets.url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("raw-deflate", forHTTPHeaderField: "X-Body-Encoding")
        request.setValue("Bearer \(HealthSecrets.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        for attempt in 1...3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { return }
                if code < 500 || attempt == 3 { throw SyncError.server(String(decoding: data, as: UTF8.self)) }
            } catch let error as URLError {
                if attempt == 3 { throw error }
            }
            Breadcrumbs.drop("upload attempt \(attempt) failed, retrying")
            try await Task.sleep(for: .seconds(attempt == 1 ? 1 : 4))
        }
    }

    // MARK: Anchors

    private func anchor(for type: HKSampleType) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: "anchor." + type.identifier) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func save(_ anchor: HKQueryAnchor, for type: HKSampleType) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: "anchor." + type.identifier)
        }
    }

    // MARK: Records

    private func sampleRecord(_ sample: HKSample) -> SampleRecord {
        var value: Double?
        var category: String?
        var unit: String?
        if let quantity = sample as? HKQuantitySample {
            if let preferred = units[quantity.quantityType], quantity.quantity.is(compatibleWith: preferred) {
                value = quantity.quantity.doubleValue(for: preferred)
                unit = preferred.unitString
            } else {
                category = String(describing: quantity.quantity)
            }
        } else if let item = sample as? HKCategorySample {
            category = Self.categoryName(item)
        }
        return SampleRecord(
            type: sample.sampleType.identifier, start: HealthFormat.date(sample.startDate), end: HealthFormat.date(sample.endDate),
            value: value, category: category, unit: unit, source: sample.sourceRevision.source.name,
            device: sample.device?.name, metadata: HealthFormat.metadata(sample.metadata))
    }

    private func workoutRecord(_ workout: HKWorkout) -> WorkoutRecord {
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let distanceTypes: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming,
                                                          .distanceDownhillSnowSports, .distanceWheelchair]
        let distance = distanceTypes.lazy
            .compactMap { workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter()) }
            .first
        let statistics: [[String: String]] = workout.allStatistics.map { type, stats in
            var row = ["type": type.identifier, "startDate": HealthFormat.date(stats.startDate),
                       "endDate": HealthFormat.date(stats.endDate)]
            if let unit = units[type] {
                row["unit"] = unit.unitString
                let pairs: [(String, HKQuantity?)] = [("average", stats.averageQuantity()), ("minimum", stats.minimumQuantity()),
                                                      ("maximum", stats.maximumQuantity()), ("sum", stats.sumQuantity())]
                for (key, quantity) in pairs {
                    if let quantity, quantity.is(compatibleWith: unit) { row[key] = String(quantity.doubleValue(for: unit)) }
                }
            }
            return row
        }
        return WorkoutRecord(
            activity_type: Self.activityName(workout.workoutActivityType),
            start: HealthFormat.date(workout.startDate), end: HealthFormat.date(workout.endDate),
            duration: workout.duration / 60, duration_unit: "min",
            distance: distance, distance_unit: distance == nil ? nil : "m",
            energy: energy, energy_unit: energy == nil ? nil : "kcal",
            statistics: statistics.isEmpty ? nil : statistics, metadata: HealthFormat.metadata(workout.metadata),
            source: workout.sourceRevision.source.name, device: workout.device?.name)
    }

    private func profile() -> [String: String] {
        var profile: [String: String] = [:]
        if let birth = try? store.dateOfBirthComponents(), let year = birth.year, let month = birth.month, let day = birth.day {
            profile["HKCharacteristicTypeIdentifierDateOfBirth"] = String(format: "%04d-%02d-%02d", year, month, day)
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            let names: [HKBiologicalSex: String] = [.female: "Female", .male: "Male", .other: "Other"]
            if let name = names[sex] { profile["HKCharacteristicTypeIdentifierBiologicalSex"] = "HKBiologicalSex" + name }
        }
        if let blood = try? store.bloodType().bloodType, blood != .notSet {
            let names: [HKBloodType: String] = [.aPositive: "APositive", .aNegative: "ANegative", .bPositive: "BPositive",
                                                .bNegative: "BNegative", .abPositive: "ABPositive", .abNegative: "ABNegative",
                                                .oPositive: "OPositive", .oNegative: "ONegative"]
            if let name = names[blood] { profile["HKCharacteristicTypeIdentifierBloodType"] = "HKBloodType" + name }
        }
        if let wheelchair = try? store.wheelchairUse().wheelchairUse, wheelchair != .notSet {
            profile["HKCharacteristicTypeIdentifierWheelchairUse"] = wheelchair == .yes ? "HKWheelchairUseYes" : "HKWheelchairUseNo"
        }
        return profile
    }

    // MARK: Names, matching export.xml so app and export rows line up

    static func categoryName(_ sample: HKCategorySample) -> String {
        let value = sample.value
        switch sample.categoryType.identifier {
        case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
            let names = [0: "InBed", 1: "AsleepUnspecified", 2: "Awake", 3: "AsleepCore", 4: "AsleepDeep", 5: "AsleepREM"]
            return "HKCategoryValueSleepAnalysis" + (names[value] ?? String(value))
        case HKCategoryTypeIdentifier.appleStandHour.rawValue:
            return value == 0 ? "HKCategoryValueAppleStandHourStood" : "HKCategoryValueAppleStandHourIdle"
        default:
            return value == HKCategoryValue.notApplicable.rawValue ? "HKCategoryValueNotApplicable" : String(value)
        }
    }

    static func activityName(_ type: HKWorkoutActivityType) -> String {
        let names: [HKWorkoutActivityType: String] = [
            .running: "Running", .walking: "Walking", .cycling: "Cycling", .swimming: "Swimming", .hiking: "Hiking",
            .functionalStrengthTraining: "FunctionalStrengthTraining", .traditionalStrengthTraining: "TraditionalStrengthTraining",
            .highIntensityIntervalTraining: "HighIntensityIntervalTraining", .yoga: "Yoga", .elliptical: "Elliptical",
            .rowing: "Rowing", .coreTraining: "CoreTraining", .mixedCardio: "MixedCardio", .stairClimbing: "StairClimbing",
            .stairs: "Stairs", .stepTraining: "StepTraining", .soccer: "Soccer", .basketball: "Basketball", .tennis: "Tennis",
            .pickleball: "Pickleball", .badminton: "Badminton", .tableTennis: "TableTennis", .volleyball: "Volleyball",
            .golf: "Golf", .climbing: "Climbing", .martialArts: "MartialArts", .boxing: "Boxing", .kickboxing: "Kickboxing",
            .jumpRope: "JumpRope", .crossTraining: "CrossTraining", .flexibility: "Flexibility", .pilates: "Pilates",
            .cooldown: "Cooldown", .cardioDance: "CardioDance", .socialDance: "SocialDance", .mindAndBody: "MindAndBody",
            .preparationAndRecovery: "PreparationAndRecovery", .wheelchairWalkPace: "WheelchairWalkPace",
            .wheelchairRunPace: "WheelchairRunPace", .snowboarding: "Snowboarding", .downhillSkiing: "DownhillSkiing",
            .crossCountrySkiing: "CrossCountrySkiing", .skatingSports: "SkatingSports", .paddleSports: "PaddleSports",
            .surfingSports: "SurfingSports", .waterFitness: "WaterFitness", .other: "Other",
        ]
        return "HKWorkoutActivityType" + (names[type] ?? String(type.rawValue))
    }

    /// "HKQuantityTypeIdentifierActiveEnergyBurned" -> "Active Energy Burned".
    static func prettyName(_ type: HKSampleType) -> String {
        shortName(type).replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }

    private func notifyDone() async {
        let content = UNMutableNotificationContent()
        content.title = "Health sync done"
        content.body = "Sent \(runSent.formatted()) samples to your health server. Everything is up to date."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "sync-done", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func shortName(_ type: HKSampleType) -> String {
        type.identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutTypeIdentifier", with: "Workouts")
    }

    /// No print(): every crash so far (builds 3 to 6) died in the first call to this, and print()
    /// went through GalaReporter's stdout capture. Breadcrumbs carry the messages instead.
    private func note(_ message: String) {
        Breadcrumbs.drop("note: \(message)")
        log.append("\(Date().formatted(date: .omitted, time: .shortened))  \(message)")
        if log.count > 50 { log.removeFirst(log.count - 50) }
        Breadcrumbs.drop("note shown")
    }

    // MARK: Self-test, run in the simulator by ios-test.sh

    /// The phone's launch path after access was granted: observers, background delivery and a full
    /// sync, for 20 seconds. Without Health access in the simulator the queries fail, but any crash
    /// in that path still happens.
    func runStartupTest() {
        requested = true
        startObserving()
        syncEverything()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            print("STARTUP OK \(log.count) log lines; last: \(log.last ?? "none")")
            exit(0)
        }
    }

    /// Asks HealthKit whether it would accept a read request for every type, without showing any UI.
    /// A type HealthKit refuses to read throws an Objective-C exception here, which crashes the test.
    static func selfTest() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { print("SELFTEST FAIL health data unavailable"); return false }
        do {
            let status = try await HKHealthStore().statusForAuthorizationRequest(toShare: [], read: readTypes)
            print("SELFTEST OK \(readTypes.count) types, status \(status.rawValue)")
            return true
        } catch {
            print("SELFTEST FAIL \(error)")
            return false
        }
    }
}
