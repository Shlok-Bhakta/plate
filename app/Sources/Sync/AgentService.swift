// AI logging on the phone: the server's agent config (cached without the key, so the capture button knows
// at once whether it's set up), the model list, the connection test, and the job calls. In demo mode every
// call is simulated: a job steps through its texts for about 2 s and drafts a meal from the demo foods.
//
// Persisted: UserDefaults `agent.config` (AgentConfig JSON: has_key and key_hint only, never the key).
// Debug: -PlateAgent unconfigured (demo starts without a key), -PlateAgentError <kind> (demo jobs fail
// with noKey, invalidKey, outOfCredit, unknownModel, timeout, offline, dailyLimit, busy or server),
// -PlateAgentAutoLog YES (demo auto-logs), -PlateAgentSlow YES|<seconds> (demo jobs take 45 s, or that long,
// to see the timer, the taking-longer line and the Working pill).
import Foundation
import Observation

@Observable
@MainActor
final class AgentService {
    static let shared = AgentService()
    static let cacheKey = "agent.config"

    /// The last config the server sent (or the cache until then). nil before the first fetch.
    private(set) var config: AgentConfig?
    private(set) var loading = false
    /// Why the last config fetch failed (offline, or a server without AI logging).
    private(set) var loadError: AgentFailure?

    @ObservationIgnored private var store: Store { Store.shared }
    @ObservationIgnored private var demoJobs: [String: DemoJob] = [:]

    private init() {
        if Store.shared.isDemo {
            var c = DemoAgent.config(configured: UserDefaults.standard.string(forKey: "PlateAgent") != "unconfigured")
            if UserDefaults.standard.bool(forKey: "PlateAgentAutoLog") { c.autoLog = true }
            if let e = AgentEffort(wire: UserDefaults.standard.string(forKey: "PlateAgentEffort")) { c.reasoningEffort = e }
            config = c
        } else if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
                  let cached = try? JSONDecoder().decode(AgentConfig.self, from: data) {
            config = cached
        }
    }

    var isConfigured: Bool { config?.isConfigured ?? false }

    private func api() throws -> APIClient {
        guard let api = store.api else { throw AgentFailure(.offline, detail: "No server is set up") }
        return api
    }

    private func remember(_ c: AgentConfig) {
        var c = c
        if store.isDemo { c.defaultSystemPrompt = c.defaultSystemPrompt ?? DemoAgent.defaultPrompt }
        config = c
        loadError = nil
        guard !store.isDemo else { return }
        var cached = c
        // The instructions can be long and are fetched again with the config; keep the cache small.
        cached.defaultSystemPrompt = nil
        cached.systemPrompt = nil
        if let data = try? JSONEncoder().encode(cached) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
    }

    /// Forgets the cached config (sign out, change server).
    func reset() {
        config = nil
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    // MARK: Config

    @discardableResult
    func refresh() async -> AgentConfig? {
        if store.isDemo { return config }
        loading = true
        defer { loading = false }
        do {
            let c = try await api().agentConfig()
            remember(c)
            return c
        } catch let f as AgentFailure {
            loadError = f
        } catch {
            loadError = AgentFailure(.offline, detail: error.localizedDescription)
        }
        return config
    }

    /// PUTs a change and keeps the reply. The key, when there is one, exists only in `change`.
    @discardableResult
    func update(_ change: AgentConfigChange) async throws -> AgentConfig {
        if store.isDemo {
            try await Task.sleep(for: .milliseconds(450))
            var c = config ?? DemoAgent.config()
            if let b = change.baseURL { c.baseURL = b }
            if let m = change.model { c.model = m }
            if let k = change.apiKey {
                c.hasKey = !k.isEmpty
                c.keyHint = k.isEmpty ? nil : "…" + k.suffix(4)
            }
            if let a = change.autoLog { c.autoLog = a }
            if let n = change.maxJobsPerDay { c.maxJobsPerDay = n }
            if let p = change.systemPrompt { c.systemPrompt = p.flatMap { $0.isEmpty ? nil : $0 } }
            if let e = change.reasoningEffort { c.reasoningEffort = e }
            if let v = change.verifyMatches { c.verifyMatches = v }
            remember(c)
            return c
        }
        do {
            let c = try await api().updateAgentConfig(change)
            remember(c)
            return c
        } catch APIError.unauthorized {
            throw AgentFailure(.server, detail: "The server didn't accept this phone's token")
        }
    }

    func models(query: String) async throws -> [AgentModel] {
        if store.isDemo {
            try await Task.sleep(for: .milliseconds(300))
            let q = query.lowercased()
            return DemoAgent.models.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
        }
        return try await wrap { try await self.api().agentModels(query: query) }
    }

    func test() async throws -> AgentTestResult {
        if store.isDemo {
            try await Task.sleep(for: .milliseconds(900))
            if let kind = Self.debugError, kind != .offline && kind != .timeout { throw AgentFailure.classify(message: DemoAgent.errorMessage(kind)) }
            return AgentTestResult(ok: true, model: config?.model, latencyMs: 842)
        }
        return try await wrap { try await self.api().agentTest() }
    }

    // MARK: Jobs

    func start(_ input: AgentJobInput) async throws -> String {
        if store.isDemo {
            try await Task.sleep(for: .milliseconds(input.image == nil ? 150 : 400))
            // -PlateAgentError offline: the upload itself fails, as with no connection.
            if Self.debugError == .offline { throw AgentFailure(.offline, detail: "The Internet connection appears to be offline.") }
            let id = UUID().uuidString.lowercased()
            demoJobs[id] = DemoJob(input: input, started: Date())
            return id
        }
        return try await wrap { try await self.api().createAgentJob(input) }
    }

    /// One long-poll. Demo jobs advance a step every ~0.45 s.
    func poll(_ id: String) async throws -> AgentJob {
        if store.isDemo { return try await demoPoll(id) }
        return try await wrap { try await self.api().agentJob(id, wait: 25) }
    }

    /// Logs a draft (with the edited items, if any) and returns the logged entries.
    func confirm(_ id: String, items: [JSONValue]?, draft: AgentDraft) async throws -> [Entry] {
        if store.isDemo {
            try await Task.sleep(for: .milliseconds(350))
            demoJobs[id] = nil
            return draft.preview.map { e in
                var e = e
                e.id = UUID().uuidString.lowercased()
                e.loggedAt = nowMs()
                return e
            }
        }
        return try await wrap { try await self.api().confirmAgentJob(id, items: items).entries }
    }

    /// DELETE: the server stops the job (its status becomes `cancelled`).
    func cancel(_ id: String) async {
        if store.isDemo { demoJobs[id] = nil; return }
        await store.api?.cancelAgentJob(id)
    }

    private func wrap<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch APIError.unauthorized { throw AgentFailure(.server, detail: "The server didn't accept this phone's token") }
    }

    // MARK: Demo

    private struct DemoJob {
        var input: AgentJobInput
        var started: Date
    }

    /// `-PlateAgentSlow YES` (45 s) or a number of seconds: how long a demo job runs.
    static var demoDuration: TimeInterval? {
        guard let raw = UserDefaults.standard.string(forKey: "PlateAgentSlow") else { return nil }
        if let n = Double(raw), n > 0 { return n }
        return ["yes", "true", "1"].contains(raw.lowercased()) ? 45 : nil
    }

    static var debugError: AgentFailure.Kind? {
        UserDefaults.standard.string(forKey: "PlateAgentError").flatMap(AgentFailure.Kind.init(rawValue:))
    }

    private func demoPoll(_ id: String) async throws -> AgentJob {
        guard let job = demoJobs[id] else { return AgentJob(status: .cancelled) }
        let steps = job.input.image == nil ? DemoAgent.textSteps : DemoAgent.steps
        let hold = UserDefaults.standard.bool(forKey: "PlateAgentHold")
        let duration = Self.demoDuration ?? Double(steps.count) * 0.45
        // A slow job answers like a long-poll: when the step changes, or after a few seconds.
        let per = duration / Double(steps.count)
        let before = Date().timeIntervalSince(job.started)
        let wait = min(max(0.45, per - before.truncatingRemainder(dividingBy: per)), 5)
        try await Task.sleep(for: .seconds(wait))
        guard demoJobs[id] != nil else { return AgentJob(status: .cancelled) }
        let elapsed = Date().timeIntervalSince(job.started)
        let ms = Int(elapsed * 1000)
        let index = Int(elapsed / per)
        if hold || index < steps.count {
            var j = AgentJob(status: .running, step: steps[hold ? min(index, 2) : index])
            j.elapsedMs = ms
            return j
        }
        if let kind = Self.debugError {
            demoJobs[id] = nil
            return AgentJob(status: .failed, error: DemoAgent.errorMessage(kind))
        }
        let draft = DemoAgent.draft(text: job.input.trimmedText, hasPhoto: job.input.image != nil,
                                    meal: job.input.meal, day: job.input.day)
        let usage = AgentUsage(jobs: 1, promptTokens: 4_812, completionTokens: 611, cost: 0.0042)
        if config?.autoLog == true {
            demoJobs[id] = nil
            let entries = draft.preview.map { e -> Entry in
                var e = e
                e.id = UUID().uuidString.lowercased()
                return e
            }
            return AgentJob(status: .logged, draft: draft, usage: usage, entries: entries, elapsedMs: ms)
        }
        return AgentJob(status: .draft, draft: draft, usage: usage, elapsedMs: ms)
    }
}
