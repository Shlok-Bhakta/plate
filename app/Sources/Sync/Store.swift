// The app's single source of truth: an offline-first cache of every synced table, a persisted outbox
// with optimistic writes, a flush with backoff, and a foreground long-poll on /v1/sync. The server comes
// from ServerSettings (onboarding or a compiled-in Secrets.swift); `connect` and `signOut` change it.
//
// Views read derived, per-day data (`summary(for:)`), never the raw tables, so a change to one day
// recomputes only that day.
import Foundation
import Observation

enum ConnectionState: Equatable, Sendable {
    /// Long-poll healthy, nothing pending.
    case synced
    /// Reachable, with writes waiting or the first sync in progress.
    case syncing(pending: Int)
    case offline(pending: Int)
    case authFailed
    /// `-PlateDemo YES`: no networking.
    case demo

    /// DESIGN 4.11: no indicator at all when healthy.
    var isHealthy: Bool { self == .synced || self == .demo }
}

/// A one-tap logging suggestion: a food at its default serving, or a past entry at its last-used serving.
struct Pick: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case food(Food), entry(Entry) }
    var kind: Kind
    var id: String {
        switch kind {
        case .food(let f): "f:" + f.listID
        case .entry(let e): "e:" + (e.foodID ?? e.name.lowercased())
        }
    }
    var name: String {
        switch kind { case .food(let f): f.name; case .entry(let e): e.name }
    }
    var kcal: Double? {
        switch kind { case .food(let f): f.kcal; case .entry(let e): e.kcal }
    }
    var foodID: String? {
        switch kind { case .food(let f): f.id; case .entry(let e): e.foodID }
    }
}

@Observable
@MainActor
final class Store {
    // MARK: Observed state

    /// Per-day derived data. Only changed days are recomputed.
    private(set) var summaries: [String: DaySummary] = [:]
    /// Live foods by id.
    private(set) var foods: [String: Food] = [:]
    private(set) var goals: Goals?
    private(set) var healthDays: [String: HealthDay] = [:]
    private(set) var version = 0
    /// Live foods in display order (favorites, then most used, then name).
    private(set) var foodList: [Food] = []
    /// Distinct recent entries (by food or name), newest first; templates for one-tap re-logging.
    private(set) var recentEntries: [Entry] = []

    private(set) var pendingCount = 0
    private(set) var isOnline = true
    private(set) var authFailed = false
    private(set) var lastSyncAt: Date?
    private(set) var isLive = false
    /// True once anything has come from the cache or the server, so Today can drop its placeholder.
    private(set) var hasData = false
    /// Entries that arrived from the server while open, with arrival time (rows highlight briefly).
    private(set) var arrivals: [String: Date] = [:]
    /// Bumped when protein first crosses its goal today; the hero runs its sweep.
    private(set) var proteinCelebration = 0

    let isDemo: Bool
    /// nil until a server is configured (onboarding shows), and in demo mode.
    private(set) var api: APIClient?
    /// Bumped when the server's time zone changes day keys; RootView rolls "today" and reminders follow.
    private(set) var zoneChanges = 0

    // MARK: Internal state

    @ObservationIgnored private var db = LocalDatabase()
    @ObservationIgnored private var outbox = Outbox()
    @ObservationIgnored private var entriesByDay: [String: [String]] = [:]
    @ObservationIgnored private var usage: [String: (count: Int, meals: [Meal: Int], last: Entry)] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var flushing = false
    /// Bumped by connect and sign-out, so a sync that was in flight for the old server is dropped.
    @ObservationIgnored private var generation = 0
    /// GET /v1/meta is read once per launch (and after connecting) for the server's time zone.
    @ObservationIgnored private var metaFetched = false
    /// Set when the server refused a write; the flush ends with a full sync.
    @ObservationIgnored private var needsFullSync = false
    @ObservationIgnored private var flushBackoff = Backoff()
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The last `/v1/sync` queued; see `syncOnce`.
    @ObservationIgnored private var syncQueue: Task<Void, Never>?
    /// In the foreground (the long-poll may run).
    @ObservationIgnored private var active = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var cacheURL: URL { directory.appending(path: "cache.json") }
    /// Called after the log or the goals change, from this phone or from sync (meal reminders reschedule).
    @ObservationIgnored var onLogChange: (@MainActor () -> Void)?
    @ObservationIgnored private var outboxURL: URL { directory.appending(path: "outbox.json") }

    static let shared = Store()

    init(demo: Bool = UserDefaults.standard.bool(forKey: "PlateDemo")) {
        isDemo = demo
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Plate", directoryHint: .isDirectory)
        if demo {
            api = nil
            db = DemoData.database()
            hasData = true
        } else {
            api = ServerSettings.load().flatMap { APIClient(baseURL: $0.url, token: $0.token) }
            if let data = try? Data(contentsOf: directory.appending(path: "cache.json")),
               let cached = try? JSONDecoder().decode(LocalDatabase.self, from: data) {
                db = cached
                hasData = true
            }
            outbox = Outbox.load(from: directory.appending(path: "outbox.json"))
            // The cache is saved after a delay, so a crash can leave it behind the outbox.
            if !outbox.isEmpty {
                db.replay(outbox)
                hasData = true
            }
        }
        rebuildAll()
    }

    // MARK: - Reading

    /// Screenshot and debug override (`-PlateConnection offline|syncing|auth`).
    var debugConnection: ConnectionState?

    var connection: ConnectionState {
        if let debugConnection { return debugConnection }
        if isDemo { return .demo }
        if authFailed { return .authFailed }
        if !isOnline { return .offline(pending: pendingCount) }
        if pendingCount > 0 || !isLive || lastSyncAt == nil { return .syncing(pending: pendingCount) }
        return .synced
    }

    var serverLabel: String { api?.hostLabel ?? (isDemo ? "plate.example.com" : "Not connected") }
    /// The configured server's URL, to prefill Settings → Change server.
    var serverURL: String? { api?.base.absoluteString }
    /// No server yet: the app shows onboarding.
    var needsServer: Bool { !isDemo && api == nil }

    func summary(for day: String) -> DaySummary { summaries[day] ?? DaySummary(day: day, entries: []) }

    func entry(id: String) -> Entry? { db.entries[id].flatMap { $0.deleted ? nil : $0 } }
    /// A live food by id, following a merge tombstone to the food the server kept.
    func food(id: String?) -> Food? {
        guard let id else { return nil }
        if let f = foods[id] { return f }
        return db.mergedTarget(of: id).flatMap { foods[$0] }
    }
    /// The food was deleted (here or elsewhere), so a stale screen must not save it again.
    func isDeletedFood(_ id: String?) -> Bool { db.isDeletedFood(id) }
    func healthDay(_ day: String) -> HealthDay? { healthDays[day] }

    var favorites: [Food] { foodList.filter(\.favorite) }
    var recipes: [Food] { foodList.filter { $0.kind == .recipe } }
    var myFoods: [Food] { foodList.filter { $0.kind != .recipe } }
    var hasHealth: Bool { !healthDays.isEmpty }

    /// Days that have any food entries, newest first.
    var loggedDays: [String] { summaries.values.filter { !$0.isEmpty }.map(\.day).sorted(by: >) }
    var hasAnyHistory: Bool { !recentEntries.isEmpty }

    /// The latest known weight and its day.
    var latestWeight: (day: String, kg: Double)? {
        healthDays.values.compactMap { h in h.weightKg.map { (h.day, $0) } }.max { $0.0 < $1.0 }
    }

    /// kg per week from the trend line over the last 14 days.
    var weeklyWeightRate: Double? {
        let cutoff = Days.add(-60, to: Days.today)
        return NutritionMath.weeklyWeightRate(healthDays.values.compactMap { h in
            h.day >= cutoff ? h.weightKg.map { (day: h.day, kg: $0) } : nil
        })
    }

    /// Most-logged entries for a meal (weighted toward that meal), as templates, excluding `excluding`.
    func frequent(meal: Meal, limit: Int = 5, excluding: Set<String> = []) -> [Entry] {
        var scored: [(score: Double, entry: Entry)] = []
        for (key, item) in usage where !excluding.contains(key) && item.count >= 2 {
            let atMeal = Double(item.meals[meal] ?? 0)
            let score = atMeal * 3 + Double(item.count)
            if atMeal > 0 && score > 3 { scored.append((score, item.last)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.entry.name < b.entry.name }
        return scored.prefix(limit).map(\.entry)
    }

    /// The meal on the day before `day` (for "Copy yesterday's lunch").
    func previousMeal(_ meal: Meal, before day: String) -> [Entry] {
        summary(for: Days.add(-1, to: day)).entries(meal)
    }

    func usageKey(_ e: Entry) -> String { e.foodID ?? "n:" + e.name.lowercased() }

    /// How often a food was logged in the last 90 days and when last (Library's "12× · Tue" hint).
    func usage(of foodID: String?) -> (count: Int, lastDay: String)? {
        guard let foodID, let u = usage[foodID] else { return nil }
        return (u.count, u.last.day)
    }

    /// Recipes that use a food as an ingredient.
    func recipes(using foodID: String) -> [Food] {
        recipes.filter { $0.components.contains { $0.foodID == foodID } }
    }

    /// Own foods matching a query, instantly (favorites and frequently logged first).
    func searchLocal(_ query: String, limit: Int = 20) -> [Food] {
        let tokens = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        return foodList.filter { f in
            let hay = (f.name + " " + (f.brand ?? "")).lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }.prefix(limit).map { $0 }
    }

    // MARK: - Writing (optimistic)

    /// Saves an unsaved search result (id nil) as a food, reusing an existing one with the same source_ref.
    /// Returns nil for a deleted food: a stale detail screen must not bring it back.
    func materialize(_ food: Food) -> Food? {
        if let id = food.id {
            if let live = self.food(id: id) { return live }
            if db.isDeletedFood(id) { return nil }
            if let target = db.mergedTarget(of: id) {
                // The server kept another food; log against it until its row arrives.
                var f = food
                f.id = target
                return f
            }
        }
        if let ref = food.sourceRef, let existing = foodList.first(where: { $0.sourceRef == ref }) { return existing }
        var f = food
        if f.id == nil { f.id = UUID().uuidString.lowercased() }
        let now = nowMs()
        if f.createdAt == 0 { f.createdAt = now }
        f.updatedAt = now
        if f.source == nil { f.source = "custom" }
        save(food: f)
        return f
    }

    /// nil when the food was deleted.
    @discardableResult
    func log(_ food: Food, servings: Double, meal: Meal, day: String, source: String = "app") -> Entry? {
        guard let saved = materialize(food) else { return nil }
        let entry = saved.entry(servings: servings, meal: meal, day: day, source: source)
        write([entry])
        return entry
    }

    /// Re-logs an entry's snapshot (a Recent or Frequent chip, "Again", copy yesterday).
    @discardableResult
    func logAgain(_ entries: [Entry], meal: Meal? = nil, day: String) -> [Entry] {
        let copies = entries.map { $0.duplicated(day: day, meal: meal ?? $0.meal) }
        write(copies)
        return copies
    }

    @discardableResult
    func logQuick(name: String, nutrients: NutrientMap, meal: Meal, day: String) -> Entry {
        let e = Entry(day: day, meal: meal, loggedAt: Days.loggedAt(day: day, meal: meal), name: name,
                      nutrients: nutrients, source: "app")
        write([e])
        return e
    }

    @discardableResult
    func addWater(ml: Double, day: String) -> Entry {
        var e = Entry(day: day, meal: Days.meal(), loggedAt: Days.loggedAt(day: day, meal: Days.meal()), name: "Water",
                      servings: ml, servingLabel: "ml", nutrients: ["water": ml], source: "app")
        e.meal = day == Days.today ? Days.meal() : .snack
        write([e])
        return e
    }

    /// Entries the server logged for an AI job (confirm, or auto-log), shown at once instead of on the next
    /// sync. They merge as server rows, so the sync cursor doesn't move and nothing is sent back. In demo
    /// mode they're written locally. Returns the live copies (Undo deletes them).
    @discardableResult
    func ingestAgentEntries(_ entries: [Entry]) -> [Entry] {
        guard !entries.isEmpty else { return [] }
        if isDemo {
            write(entries)
            return entries
        }
        let proteinBefore = summary(for: Days.today).totals["protein"] ?? 0
        let result = db.merge(SyncPayload(version: db.version, entries: entries))
        if !result.changedDays.isEmpty { refresh(days: result.changedDays) }
        checkProtein(before: proteinBefore)
        scheduleSave()
        return entries.compactMap { entry(id: $0.id) }
    }

    /// Agent entries on `day` logged since `ms` (auto-logged jobs whose reply didn't list its entries).
    func agentEntries(day: String, since ms: Int) -> [Entry] {
        summary(for: day).meals.values.flatMap { $0 }.filter { $0.source == "agent" && $0.loggedAt >= ms - 5000 }
            .sorted { $0.loggedAt < $1.loggedAt }
    }

    /// Saves an edited entry (live edits from Entry edit).
    func update(_ entry: Entry) {
        var e = entry
        e.updatedAt = max(nowMs(), (db.entries[entry.id]?.updatedAt ?? 0) + 1)
        write([e], stamp: false)
    }

    func delete(_ ids: [String]) {
        let now = nowMs()
        var touched: Set<String> = []
        for id in ids {
            guard var e = db.entries[id], !e.deleted else { continue }
            e.deleted = true
            e.updatedAt = max(now, e.updatedAt + 1)
            touched.formUnion(db.put(e))
            enqueue(.delete(.entries, id: id, at: e.updatedAt))
        }
        refresh(days: touched)
        afterWrite()
    }

    /// Undo of a delete: the same rows come back with a newer timestamp.
    func restore(_ entries: [Entry]) {
        var copies = entries
        for i in copies.indices { copies[i].deleted = false }
        write(copies)
    }

    /// Saves a food. A deleted food is refused (returns false) unless `restoring` it (undo of a delete).
    @discardableResult
    func save(food: Food, restoring: Bool = false) -> Bool {
        guard food.id != nil else { return false }
        if !restoring && db.isDeletedFood(food.id) { return false }
        var f = food
        if restoring { f.deleted = false }
        f.updatedAt = max(nowMs(), (foods[f.id!]?.updatedAt ?? 0) + 1)
        db.put(f)
        enqueue(.upsert(.foods, f))
        rebuildFoods()
        afterWrite()
        return true
    }

    /// nil when the food was deleted.
    @discardableResult
    func setFavorite(_ food: Food, _ favorite: Bool) -> Food? {
        guard var f = materialize(food) else { return nil }
        f.favorite = favorite
        guard save(food: f) else { return nil }
        return self.food(id: f.id) ?? f
    }

    func deleteFood(id: String) {
        guard var f = db.foods[id] else { return }
        f.deleted = true
        f.updatedAt = max(nowMs(), f.updatedAt + 1)
        db.put(f)
        enqueue(.delete(.foods, id: id, at: f.updatedAt))
        rebuildFoods()
        afterWrite()
    }

    /// For Settings (wave 2): change mode, plan or overrides; the server recomputes targets.
    func updateGoals(_ change: (inout Goals) -> Void) {
        var g = goals ?? Goals()
        change(&g)
        g.updatedAt = max(nowMs(), (goals?.updatedAt ?? 0) + 1)
        db.goals = g
        goals = g
        enqueue(.upsert(.goals, g))
        afterWrite()
        onLogChange?()
    }

    private func write(_ entries: [Entry], stamp: Bool = true) {
        guard !entries.isEmpty else { return }
        let proteinBefore = summary(for: Days.today).totals["protein"] ?? 0
        var touched: Set<String> = []
        for var e in entries {
            if stamp { e.updatedAt = max(nowMs(), (db.entries[e.id]?.updatedAt ?? 0) + 1) }
            touched.formUnion(db.put(e))
            enqueue(.upsert(.entries, e))
        }
        refresh(days: touched)
        checkProtein(before: proteinBefore)
        afterWrite()
    }

    private func enqueue(_ m: Mutation) {
        guard !isDemo else { return }
        outbox.enqueue(m, protecting: inFlight)
        persistOutbox()
    }

    private func afterWrite() {
        scheduleSave()
        Task { await flush() }
    }

    /// True once per day, the first time protein reaches its goal.
    private(set) var proteinGoalJustHit = false
    private func checkProtein(before: Double) {
        proteinGoalJustHit = false
        guard let target = goals?.target("protein") else { return }
        let after = summary(for: Days.today).totals["protein"] ?? 0
        let key = "proteinCelebratedDay"
        guard before < target, after >= target, UserDefaults.standard.string(forKey: key) != Days.today else { return }
        UserDefaults.standard.set(Days.today, forKey: key)
        proteinGoalJustHit = true
        proteinCelebration += 1
    }

    /// Consecutive days with protein at or above goal, ending today or yesterday.
    var proteinStreak: Int {
        guard let target = goals?.target("protein") else { return 0 }
        var day = Days.today
        if (summary(for: day).totals["protein"] ?? 0) < target { day = Days.add(-1, to: day) }
        var n = 0
        while (summary(for: day).totals["protein"] ?? 0) >= target { n += 1; day = Days.add(-1, to: day) }
        return n
    }

    // MARK: - Network

    /// Called on scenePhase changes: long-poll only while in the foreground.
    func setActive(_ active: Bool) {
        self.active = active
        if active {
            startLive()
            Task { await flush() }
        } else {
            stopLive()
            saveNow()
        }
    }

    private func startLive() {
        guard let api, pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.pollLoop(api) }
    }

    private func stopLive() {
        pollTask?.cancel()
        pollTask = nil
        isLive = false
    }

    private func pollLoop(_ api: APIClient) async {
        var backoff = Backoff(cap: 30)
        var first = true
        while !Task.isCancelled {
            do {
                let wait = first ? 0 : 25
                let started = Date()
                let changed = try await syncOnce(api, wait: wait)
                if Task.isCancelled { break }
                first = false
                backoff.reset()
                isOnline = true
                authFailed = false
                isLive = true
                lastSyncAt = Date()
                if !metaFetched { await refreshMeta(api) }
                if !outbox.isEmpty { await flush() }
                // A long-poll that comes straight back with nothing new would spin; pace it.
                if wait > 0 && !changed && Date().timeIntervalSince(started) < 1 {
                    try? await Task.sleep(for: .seconds(2))
                }
            } catch is CancellationError {
                break
            } catch APIError.unauthorized {
                authFailed = true
                isLive = false
                try? await Task.sleep(for: .seconds(30))
            } catch {
                isOnline = false
                isLive = false
                try? await Task.sleep(for: .seconds(backoff.next()))
            }
        }
    }

    /// One `/v1/sync` at a time: each request waits for the one before it and is applied before the next
    /// starts, and reads the cursor only then. So an older response can't land after a newer one, and
    /// the cursor never moves backwards (except on a reset). Returns whether anything changed.
    @discardableResult
    private func syncOnce(_ api: APIClient, full: Bool = false, wait: Int) async throws -> Bool {
        let previous = syncQueue
        let generation = generation
        let task = Task { @MainActor [weak self] () async throws -> Bool in
            await previous?.value
            try Task.checkCancellation()
            guard let self, self.generation == generation else { return false }
            let payload = try await api.sync(since: full ? 0 : self.version, wait: wait)
            guard self.generation == generation else { return false }
            return self.apply(payload)
        }
        syncQueue = Task { _ = await task.result }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Pull to refresh: one immediate sync plus a flush. A long-poll in flight is cancelled rather than
    /// waited on (it can hold for 25 s) and restarted afterwards.
    func syncNow() async {
        guard let api else {
            try? await Task.sleep(for: .milliseconds(400))
            return
        }
        pollTask?.cancel()
        pollTask = nil
        defer { if active { startLive() } }
        await flush()
        do {
            try await syncOnce(api, wait: 0)
            isOnline = true
            authFailed = false
            lastSyncAt = Date()
        } catch APIError.unauthorized {
            authFailed = true
        } catch {
            isOnline = false
        }
    }

    func flush() async {
        guard let api, !flushing, !outbox.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        let generation = generation
        while !outbox.isEmpty {
            let batch = outbox.batch(max: 100)
            let ids = Set(batch.map(\.id))
            inFlight = ids
            do {
                let result = try await api.mutations(batch.map(\.mutation))
                // Signed out or switched servers while this was in flight.
                guard self.generation == generation else { return }
                inFlight = []
                outbox.remove(ids)
                handle(result, sent: batch)
                persistOutbox()
                flushBackoff.reset()
                isOnline = true
                authFailed = false
            } catch APIError.unauthorized {
                inFlight = []
                authFailed = true
                scheduleRetry()
                return
            } catch let error as APIError where error.isPermanent {
                // A row the server will never accept would block the queue forever; drop it.
                inFlight = []
                outbox.remove(ids)
                persistOutbox()
                print("Plate: dropped \(ids.count) mutations: \(error)")
            } catch {
                inFlight = []
                isOnline = false
                scheduleRetry()
                return
            }
        }
        if needsFullSync {
            needsFullSync = false
            await fullSync()
        }
    }

    /// Applies `ids` (the server kept an existing food for one we sent) and `errors` (rows it refused).
    /// Refused rows are already out of the outbox, so they can't wedge it; the local optimistic copies are
    /// dropped and a full sync brings back the server's copies.
    private func handle(_ result: MutationsResult, sent batch: [OutboxItem]) {
        var redirected = false
        for (sent, stored) in result.ids where sent != stored {
            guard batch.contains(where: { $0.mutation.key == "\(Table.foods.rawValue)/\(sent)" }) else { continue }
            for recipe in db.redirectFood(sent, to: stored) { outbox.enqueue(.upsert(.foods, recipe), protecting: inFlight) }
            redirected = true
        }
        var refused: [(name: String, error: String)] = []
        for failure in result.errors where batch.indices.contains(failure.index) {
            let m = batch[failure.index].mutation
            guard let id = m.row.object?["id"]?.string else { continue }
            refused.append((rowName(m.table, id) ?? m.row.object?["name"]?.string ?? "a change", failure.error))
            db.forget(table: m.table, id: id)
        }
        guard redirected || !refused.isEmpty else { return }
        rebuildAll()
        scheduleSave()
        if let first = refused.first {
            needsFullSync = true
            print("Plate: server refused \(refused.count) mutations: \(refused)")
            let text = refused.count == 1 ? "Couldn't save \(first.name): \(first.error)"
                : "Couldn't save \(refused.count) changes: \(first.error)"
            Toasts.shared.message(text, symbol: "exclamationmark.triangle.fill")
        }
    }

    private func rowName(_ table: String, _ id: String) -> String? {
        switch table {
        case Table.foods.rawValue: db.foods[id]?.name
        case Table.entries.rawValue: db.entries[id]?.name
        case Table.goals.rawValue: "goals"
        default: nil
        }
    }

    /// Everything from version 0, merged last-writer-wins (after the server refused a write).
    private func fullSync() async {
        guard let api else { return }
        do {
            try await syncOnce(api, full: true, wait: 0)
        } catch {
            print("Plate: full sync failed: \(error)")
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = flushBackoff.next()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func search(_ query: String) async throws -> [Food] {
        guard let api else {
            try await Task.sleep(for: .milliseconds(350))
            let q = query.lowercased()
            return DemoData.catalog.filter { $0.name.lowercased().contains(q) || ($0.brand ?? "").lowercased().contains(q) }
        }
        return try await api.search(query)
    }

    /// Own foods first (works offline), then the server (OFF cache, then Open Food Facts).
    func lookup(barcode: String) async throws -> Food? {
        if let own = foodList.first(where: { $0.barcode == barcode }) { return own }
        guard let api else {
            try await Task.sleep(for: .milliseconds(600))
            return nil
        }
        let found = try await api.barcode(barcode)
        if let f = found, let id = f.id, !db.isDeletedFood(id),
           LWW.serverRowWins(updatedAt: f.updatedAt, version: f.version, local: db.foods[id].map { ($0.updatedAt, $0.version) }) {
            db.put(f)
            foods[id] = f
            rebuildFoods()
        }
        return found
    }

    func serverSuggestions(meal: Meal, day: String) async -> Suggestions? {
        guard let api else { return nil }
        return try? await api.suggest(meal: meal, day: day)
    }

    // MARK: - Server

    /// GET /v1/meta: the server's time zone becomes the zone of every day key (cached for next launch).
    private func refreshMeta(_ api: APIClient) async {
        guard let meta = try? await api.meta() else { return }
        metaFetched = true
        applyZone(meta.timezone)
    }

    private func applyZone(_ identifier: String?) {
        guard Days.useServerZone(identifier) else { return }
        // "Today" and the 90-day usage window moved with the zone.
        rebuildUsage()
        zoneChanges += 1
        onLogChange?()
    }

    /// Saves a server that ServerCheck accepted and starts syncing with it. The same server again (a new
    /// token) keeps this phone's cache and unsent changes; a different one replaces them with its log.
    func connect(_ result: ServerCheckResult) {
        guard !isDemo else { return }
        let sameServer = api.map { $0.base.absoluteString == result.config.url } ?? false
        stopLive()
        retryTask?.cancel()
        generation += 1
        if !sameServer { resetLocal() }
        if !ServerSettings.save(result.config) {
            Toasts.shared.message("Couldn't save the token in the Keychain, so Plate will ask again next launch",
                                  symbol: "exclamationmark.triangle.fill")
        }
        api = APIClient(baseURL: result.config.url, token: result.config.token)
        authFailed = false
        isOnline = true
        metaFetched = result.timezone != nil
        applyZone(result.timezone)
        apply(result.payload)
        lastSyncAt = Date()
        if !sameServer {
            HealthDaysPush.shared.serverChanged()
            AgentService.shared.reset()
        }
        if active { startLive() }
        Task { await flush() }
    }

    /// Forgets the server and the token, and deletes this phone's copy of the log and its unsent changes.
    /// The log itself stays on the server.
    func signOut() {
        guard !isDemo else { return }
        stopLive()
        retryTask?.cancel()
        generation += 1
        ServerSettings.clear()
        api = nil
        authFailed = false
        isOnline = true
        metaFetched = false
        resetLocal()
        if Days.forgetServerZone() { zoneChanges += 1 }
        HealthDaysPush.shared.serverChanged()
        AgentService.shared.reset()
        onLogChange?()
    }

    /// Empties the cache and the outbox, in memory and on disk.
    private func resetLocal() {
        saveTask?.cancel()
        db = LocalDatabase()
        outbox = Outbox()
        inFlight = []
        needsFullSync = false
        flushBackoff.reset()
        arrivals = [:]
        lastSyncAt = nil
        hasData = false
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: outboxURL)
        rebuildAll()
    }

    // MARK: - Merging and indexes

    /// Returns whether anything changed (rows or the version).
    @discardableResult
    private func apply(_ payload: SyncPayload) -> Bool {
        if payload.reset { return applyReset(payload) }
        let before = db.version
        let wasEmpty = db.version == 0
        let result = db.merge(payload)
        version = db.version
        hasData = true
        if !result.changedDays.isEmpty { refresh(days: result.changedDays) }
        if result.foodsChanged { rebuildFoods() }
        if result.goalsChanged {
            goals = db.goals
            onLogChange?()
        }
        if result.healthChanged { healthDays = db.healthDays.filter { !$0.value.deleted } }
        if !wasEmpty && !result.arrivedEntryIDs.isEmpty {
            let now = Date()
            for id in result.arrivedEntryIDs { arrivals[id] = now }
            arrivals = arrivals.filter { now.timeIntervalSince($0.value) < 5 }
        }
        if !result.isEmpty { scheduleSave() }
        return !result.isEmpty || db.version != before
    }

    /// The server's database is behind ours (restored from a backup): take its snapshot and version, and
    /// send again whatever this phone has that the snapshot lacks or has older.
    private func applyReset(_ payload: SyncPayload) -> Bool {
        let resend = db.reset(to: payload)
        print("Plate: sync reset to version \(payload.version), sending \(resend.count) local rows again")
        if !isDemo && !resend.isEmpty {
            outbox.enqueue(contentsOf: resend, protecting: inFlight)
            persistOutbox()
        }
        arrivals = [:]
        hasData = true
        rebuildAll()
        scheduleSave()
        if !resend.isEmpty { Task { await flush() } }
        return true
    }

    /// `-PlateState loading`: show the first-launch placeholder.
    func debugHideData() { hasData = false }

    func isFreshArrival(_ id: String) -> Bool {
        arrivals[id].map { Date().timeIntervalSince($0) < 3 } ?? false
    }

    private func rebuildAll() {
        entriesByDay = [:]
        for e in db.entries.values { entriesByDay[e.day, default: []].append(e.id) }
        var s: [String: DaySummary] = [:]
        for (day, ids) in entriesByDay { s[day] = DaySummary(day: day, entries: ids.compactMap { db.entries[$0] }) }
        summaries = s
        goals = db.goals
        healthDays = db.healthDays.filter { !$0.value.deleted }
        version = db.version
        pendingCount = outbox.count
        rebuildUsage()
        rebuildFoods()
        onLogChange?()
    }

    private func refresh(days: Set<String>) {
        for day in days { entriesByDay[day] = nil }
        // Re-index only the touched days.
        for e in db.entries.values where days.contains(e.day) { entriesByDay[e.day, default: []].append(e.id) }
        var s = summaries
        for day in days { s[day] = DaySummary(day: day, entries: (entriesByDay[day] ?? []).compactMap { db.entries[$0] }) }
        summaries = s
        rebuildUsage()
        onLogChange?()
    }

    private func rebuildUsage() {
        var u: [String: (count: Int, meals: [Meal: Int], last: Entry)] = [:]
        let cutoff = Days.add(-90, to: Days.today)
        for e in db.entries.values where !e.deleted && !e.isWater && e.day >= cutoff {
            let key = usageKey(e)
            var item = u[key] ?? (0, [:], e)
            item.count += 1
            item.meals[e.meal, default: 0] += 1
            if e.loggedAt > item.last.loggedAt { item.last = e }
            u[key] = item
        }
        usage = u
        recentEntries = u.values.map(\.last).sorted { $0.loggedAt > $1.loggedAt }.prefix(30).map { $0 }
    }

    private func rebuildFoods() {
        foods = db.foods.filter { !$0.value.deleted }
        foodList = foods.values.sorted { a, b in
            if a.favorite != b.favorite { return a.favorite }
            let ua = usage[a.id ?? ""]?.count ?? 0, ub = usage[b.id ?? ""]?.count ?? 0
            if ua != ub { return ua > ub }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Persistence

    private func persistOutbox() {
        pendingCount = outbox.count
        guard !isDemo else { return }
        try? outbox.save(to: outboxURL)
    }

    private func scheduleSave() {
        guard !isDemo else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard !isDemo else { return }
        let snapshot = db
        let url = cacheURL
        let dir = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}
