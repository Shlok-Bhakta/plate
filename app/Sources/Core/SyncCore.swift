// The pure half of sync: the local copy of every synced table, last-writer-wins merging, and the
// persisted outbox. No networking or UI here, so the logic tests can cover it on the Mac.
import Foundation

/// Last writer wins by `updated_at`; ties go to the incoming row (the server applies ties too).
enum LWW {
    static func incomingWins(incoming: Int, local: Int?) -> Bool {
        guard let local else { return true }
        return incoming >= local
    }

    /// A row from `/v1/sync` replaces the local copy unless it's an older server version than the one we
    /// have (a sync response that arrived after a newer one: the server recomputes goals and recipes
    /// without changing `updated_at`, so the timestamp alone can't tell), or older by `updated_at` than
    /// the local copy (an optimistic write the server hasn't acknowledged). nil versions are unknown.
    static func serverRowWins(updatedAt: Int, version: Int?, local: (updatedAt: Int, version: Int?)?) -> Bool {
        guard let local else { return true }
        if let version, let known = local.version, version < known { return false }
        return incomingWins(incoming: updatedAt, local: local.updatedAt)
    }
}

struct MergeResult: Sendable {
    var changedDays: Set<String> = []
    /// Live entries that weren't in the cache before (agent rows animate in).
    var arrivedEntryIDs: Set<String> = []
    var foodsChanged = false
    var goalsChanged = false
    var healthChanged = false
    var isEmpty: Bool { changedDays.isEmpty && !foodsChanged && !goalsChanged && !healthChanged }
}

/// Every synced row, tombstones included (so a stale copy can't resurrect a deleted row).
struct LocalDatabase: Codable, Sendable {
    var version = 0
    var foods: [String: Food] = [:]
    var entries: [String: Entry] = [:]
    var goals: Goals?
    var healthDays: [String: HealthDay] = [:]

    init() {}

    // Stored as arrays so the file reads like the sync payload.
    private enum CodingKeys: String, CodingKey { case version, foods, entries, goals, healthDays = "health_days" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        let f = (try? c.decode([Food].self, forKey: .foods)) ?? []
        foods = Dictionary(f.compactMap { food in food.id.map { ($0, food) } }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        let e = (try? c.decode([Entry].self, forKey: .entries)) ?? []
        entries = Dictionary(e.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        goals = try? c.decodeIfPresent(Goals.self, forKey: .goals)
        let h = (try? c.decode([HealthDay].self, forKey: .healthDays)) ?? []
        healthDays = Dictionary(h.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(Array(foods.values), forKey: .foods)
        try c.encode(Array(entries.values), forKey: .entries)
        try c.encodeIfPresent(goals, forKey: .goals)
        try c.encode(Array(healthDays.values), forKey: .healthDays)
    }

    /// Applies a sync payload with last-writer-wins per row, and advances `version`.
    @discardableResult
    mutating func merge(_ payload: SyncPayload) -> MergeResult {
        var result = MergeResult()
        for food in payload.foods {
            guard let id = food.id else { continue }
            if LWW.serverRowWins(updatedAt: food.updatedAt, version: food.version, local: foods[id].map { ($0.updatedAt, $0.version) }) {
                if foods[id] != food { foods[id] = food; result.foodsChanged = true }
            }
        }
        for entry in payload.entries {
            let local = entries[entry.id]
            guard LWW.serverRowWins(updatedAt: entry.updatedAt, version: entry.version, local: local.map { ($0.updatedAt, $0.version) })
            else { continue }
            if local == entry { continue }
            if let local, !local.day.isEmpty { result.changedDays.insert(local.day) }
            if !entry.day.isEmpty { result.changedDays.insert(entry.day) }
            if !entry.deleted && (local == nil || local!.deleted) { result.arrivedEntryIDs.insert(entry.id) }
            // A sparse tombstone keeps the fields we knew, so the row can still be shown in undo.
            if entry.deleted, var known = local {
                known.deleted = true
                known.updatedAt = entry.updatedAt
                known.version = entry.version
                entries[entry.id] = known
            } else {
                entries[entry.id] = entry
            }
        }
        for g in payload.goals where g.id == "current" {
            if LWW.serverRowWins(updatedAt: g.updatedAt, version: g.version, local: goals.map { ($0.updatedAt, $0.version) }),
               goals != g {
                goals = g
                result.goalsChanged = true
            }
        }
        for h in payload.healthDays {
            if LWW.serverRowWins(updatedAt: h.updatedAt, version: h.version, local: healthDays[h.id].map { ($0.updatedAt, $0.version) }),
               healthDays[h.id] != h {
                healthDays[h.id] = h
                result.healthChanged = true
            }
        }
        version = max(version, payload.version)
        return result
    }

    /// `reset: true` (SPEC "Server notes"): the server's database is older than this cache, so its snapshot
    /// replaces the tables and `version` goes back to the server's. Local rows the snapshot lacks, or has an
    /// older copy of, are kept and returned as mutations to send again, so nothing written here is lost.
    /// Ingredient foods come before recipes, and foods before entries, so references resolve in order.
    /// Kept rows drop their version: it came from the newer database, and the restored one numbers lower.
    mutating func reset(to payload: SyncPayload) -> [Mutation] {
        var fresh = LocalDatabase()
        fresh.merge(payload)
        fresh.version = payload.version
        var resend: [Mutation] = []
        func keep(_ local: Int, over server: Int?) -> Bool { server.map { local > $0 } ?? true }
        let localFoods = foods.values.sorted { a, b in
            (a.kind == .recipe ? 1 : 0, a.updatedAt) < (b.kind == .recipe ? 1 : 0, b.updatedAt)
        }
        for f in localFoods {
            guard let id = f.id, keep(f.updatedAt, over: fresh.foods[id]?.updatedAt) else { continue }
            if f.deleted && fresh.foods[id] == nil { continue }  // nothing to delete on the server
            var f = f
            f.version = nil
            fresh.foods[id] = f
            resend.append(f.deleted ? .delete(.foods, id: id, at: f.updatedAt) : .upsert(.foods, f))
        }
        for e in entries.values.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            guard keep(e.updatedAt, over: fresh.entries[e.id]?.updatedAt) else { continue }
            if e.deleted && fresh.entries[e.id] == nil { continue }
            var e = e
            e.version = nil
            fresh.entries[e.id] = e
            resend.append(e.deleted ? .delete(.entries, id: e.id, at: e.updatedAt) : .upsert(.entries, e))
        }
        if var g = goals, keep(g.updatedAt, over: fresh.goals?.updatedAt) {
            g.version = nil
            fresh.goals = g
            resend.append(.upsert(.goals, g))
        }
        self = fresh
        return resend
    }

    /// The food a merge tombstone points at (`merged_into`, SPEC "Server notes").
    func mergedTarget(of id: String) -> String? {
        guard let f = foods[id], f.deleted else { return nil }
        return f.extra["merged_into"]?.string
    }

    /// True when the food was deleted (not merged into another), so a stale copy must not be saved again.
    func isDeletedFood(_ id: String?) -> Bool {
        guard let id, let f = foods[id], f.deleted else { return false }
        return mergedTarget(of: id) == nil
    }

    /// The server kept `stored` instead of the food we sent as `sent` (a repeated source_ref). Entries and
    /// recipes are pointed at the stored food and the sent one becomes a tombstone that redirects to it.
    /// Returns the recipes whose components changed; they need sending again (the server only fixes entries).
    mutating func redirectFood(_ sent: String, to stored: String) -> [Food] {
        guard sent != stored else { return [] }
        for (id, e) in entries where e.foodID == sent { entries[id]?.foodID = stored }
        var recipes: [Food] = []
        for (id, f) in foods where f.components.contains(where: { $0.foodID == sent }) {
            var r = f
            for i in r.components.indices where r.components[i].foodID == sent { r.components[i].foodID = stored }
            r.updatedAt = max(nowMs(), r.updatedAt + 1)
            foods[id] = r
            if !r.deleted { recipes.append(r) }
        }
        if var dup = foods[sent] {
            dup.deleted = true
            dup.extra["merged_into"] = .string(stored)
            foods[sent] = dup
        }
        return recipes
    }

    /// Drops a row the server refused, so the next full sync brings back the server's copy (or nothing).
    mutating func forget(table: String, id: String) {
        switch table {
        case Table.foods.rawValue: foods[id] = nil
        case Table.entries.rawValue: entries[id] = nil
        case Table.goals.rawValue: goals = nil
        case Table.healthDays.rawValue: healthDays[id] = nil
        default: break
        }
    }

    /// Applies the outbox's writes again on launch. The outbox is saved on every write but the cache only
    /// after a short delay, so after a crash the cache can lack a write the outbox still holds; without
    /// this, the next edit of that row would start from the stale copy and replace the queued write.
    /// A queued write never overrides a newer copy of the row (one synced from another device).
    mutating func replay(_ outbox: Outbox) {
        let decoder = JSONDecoder()
        for item in outbox.items {
            let m = item.mutation
            guard let data = try? JSONEncoder().encode(m.row), let id = m.row.object?["id"]?.string else { continue }
            let at = Int(saturating: m.row.object?["updated_at"]?.double ?? 0)
            switch (m.table, m.op) {
            case (Table.entries.rawValue, "delete"):
                guard var e = entries[id], LWW.incomingWins(incoming: at, local: e.updatedAt) else { continue }
                e.deleted = true
                e.updatedAt = at
                entries[id] = e
            case (Table.foods.rawValue, "delete"):
                guard var f = foods[id], LWW.incomingWins(incoming: at, local: f.updatedAt) else { continue }
                f.deleted = true
                f.updatedAt = at
                foods[id] = f
            case (Table.entries.rawValue, _):
                guard let e = try? decoder.decode(Entry.self, from: data),
                      LWW.incomingWins(incoming: e.updatedAt, local: entries[id]?.updatedAt) else { continue }
                put(e)
            case (Table.foods.rawValue, _):
                guard let f = try? decoder.decode(Food.self, from: data),
                      LWW.incomingWins(incoming: f.updatedAt, local: foods[id]?.updatedAt) else { continue }
                put(f)
            case (Table.goals.rawValue, _):
                guard let g = try? decoder.decode(Goals.self, from: data),
                      LWW.incomingWins(incoming: g.updatedAt, local: goals?.updatedAt) else { continue }
                goals = g
            default: continue
            }
        }
    }

    /// Applies a local write (optimistic). Returns the days it touched.
    @discardableResult
    mutating func put(_ entry: Entry) -> Set<String> {
        var days: Set<String> = [entry.day]
        if let old = entries[entry.id] { days.insert(old.day) }
        entries[entry.id] = entry
        return days
    }

    mutating func put(_ food: Food) {
        guard let id = food.id else { return }
        foods[id] = food
    }

    var liveEntries: [Entry] { entries.values.filter { !$0.deleted } }
    var liveFoods: [Food] { foods.values.filter { !$0.deleted } }
}

// MARK: - Outbox

struct OutboxItem: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var mutation: Mutation
    var createdAt: Int
}

/// Mutations waiting for `POST /v1/mutations`, persisted so nothing is lost if the app is killed.
struct Outbox: Codable, Sendable {
    var items: [OutboxItem] = []

    init() {}

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// Adds a mutation. An older queued write to the same row is replaced in place (each mutation carries
    /// the whole row), so rows still go out in the order they were first written: an ingredient before the
    /// recipe that uses it. The new copy moves to the end only when it points at a food queued after it.
    /// An in-flight write is never replaced; the newer one is queued behind it so it still goes out.
    mutating func enqueue(_ mutation: Mutation, protecting inFlight: Set<UUID> = []) {
        let key = mutation.key
        let item = OutboxItem(id: UUID(), mutation: mutation, createdAt: nowMs())
        guard let i = items.firstIndex(where: { $0.mutation.key == key && !inFlight.contains($0.id) }) else {
            items.append(item)
            return
        }
        let deps = mutation.dependencies
        if deps.isEmpty || !items[(i + 1)...].contains(where: { deps.contains($0.mutation.key) }) {
            items[i] = item
        } else {
            items.remove(at: i)
            items.append(item)
        }
    }

    /// Queues a reset's re-sends in order. Rows already queued are skipped: the queued copy is the
    /// latest local write of that row.
    mutating func enqueue(contentsOf mutations: [Mutation], protecting inFlight: Set<UUID> = []) {
        let queued = Set(items.filter { !inFlight.contains($0.id) }.map(\.mutation.key))
        let now = nowMs()
        items += mutations.filter { !queued.contains($0.key) }.map { OutboxItem(id: UUID(), mutation: $0, createdAt: now) }
    }

    func batch(max: Int = 100) -> [OutboxItem] { Array(items.prefix(max)) }

    mutating func remove(_ ids: Set<UUID>) { items.removeAll { ids.contains($0.id) } }

    static func load(from url: URL) -> Outbox {
        guard let data = try? Data(contentsOf: url),
              let outbox = try? JSONDecoder().decode(Outbox.self, from: data) else { return Outbox() }
        return outbox
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Retry delays for flushes and the long-poll: 1, 2, 4 … seconds, capped.
struct Backoff: Sendable {
    var failures = 0
    var cap: Double = 60
    mutating func next() -> Double {
        failures += 1
        return min(cap, pow(2, Double(failures - 1)))
    }
    mutating func reset() { failures = 0 }
}
