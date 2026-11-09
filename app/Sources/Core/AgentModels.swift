// AI logging (SPEC "AI logging"): the wire types for /v1/agent/config, /models, /test and /jobs, the draft
// a job proposes, the editing math for that draft (it mirrors the server's `rescale_entry`), and the
// friendly classification of agent errors. Pure Foundation, so the logic tests cover it on the Mac.
//
// The API key is write-only: it goes to the server once in `PUT /v1/agent/config` and the app only ever
// reads back `has_key` and `key_hint`. Nothing here stores it.
import Foundation

enum AgentProvider: String, CaseIterable, Identifiable, Sendable {
    case openRouter, custom
    var id: String { rawValue }
    static let openRouterURL = "https://openrouter.ai/api/v1"

    init(baseURL: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces).lowercased()
        self = trimmed.isEmpty || trimmed.hasPrefix("https://openrouter.ai") ? .openRouter : .custom
    }

    var title: String { self == .openRouter ? "OpenRouter" : "Custom" }
}

/// One period of `usage` in the config ("today" or "month"), or a job's usage.
struct AgentUsage: Codable, Hashable, Sendable {
    var jobs: Int = 0
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    /// USD when the provider reports it (OpenRouter does), otherwise nil.
    var cost: Double?

    init(jobs: Int = 0, promptTokens: Int = 0, completionTokens: Int = 0, cost: Double? = nil) {
        self.jobs = jobs; self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.cost = cost
    }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        jobs = r.int("jobs") ?? 0
        promptTokens = r.int("prompt_tokens") ?? 0
        completionTokens = r.int("completion_tokens") ?? 0
        cost = r.double("cost")
    }
    func encode(to encoder: Encoder) throws {
        var w = RowWriter(encoder)
        try w.put("jobs", jobs); try w.put("prompt_tokens", promptTokens)
        try w.put("completion_tokens", completionTokens); try w.putOrNull("cost", cost)
    }
    var tokens: Int { promptTokens + completionTokens }
}

/// `GET /v1/agent/config` (and the reply to `PUT`).
struct AgentConfig: Codable, Hashable, Sendable {
    var baseURL = AgentProvider.openRouterURL
    var model = ""
    var hasKey = false
    /// "…1234": the last characters of the key, for recognising it.
    var keyHint: String?
    var autoLog = false
    var maxJobsPerDay = 60
    var today = AgentUsage()
    var month = AgentUsage()
    /// The user's own instructions, or nil while the built-in ones are used.
    var systemPrompt: String?
    /// The server's built-in instructions.
    var defaultSystemPrompt: String?

    static let promptLimit = 32 * 1024

    init() {}
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        baseURL = r.string("base_url").flatMap { $0.isEmpty ? nil : $0 } ?? AgentProvider.openRouterURL
        model = r.string("model") ?? ""
        hasKey = r.bool("has_key") ?? false
        keyHint = r.string("key_hint").flatMap { $0.isEmpty ? nil : $0 }
        autoLog = r.bool("auto_log") ?? false
        maxJobsPerDay = r.int("max_jobs_per_day") ?? 60
        struct Usage: Decodable { var today: AgentUsage?; var month: AgentUsage? }
        let usage = r.value("usage", as: Usage.self)
        today = usage?.today ?? AgentUsage()
        month = usage?.month ?? AgentUsage()
        systemPrompt = r.string("system_prompt").flatMap { $0.isEmpty ? nil : $0 }
        defaultSystemPrompt = r.string("default_system_prompt")
    }
    func encode(to encoder: Encoder) throws {
        var w = RowWriter(encoder)
        try w.put("base_url", baseURL); try w.put("model", model); try w.put("has_key", hasKey)
        try w.put("key_hint", keyHint); try w.put("auto_log", autoLog); try w.put("max_jobs_per_day", maxJobsPerDay)
        try w.put("usage", ["today": today, "month": month])
        try w.putOrNull("system_prompt", systemPrompt)
        try w.put("default_system_prompt", defaultSystemPrompt)
    }

    var provider: AgentProvider { AgentProvider(baseURL: baseURL) }
    /// A key and a model: jobs can run.
    var isConfigured: Bool { hasKey && !model.trimmingCharacters(in: .whitespaces).isEmpty }
    /// "••1234" from "…1234" (or whatever the server sends).
    var keyDots: String {
        guard let hint = keyHint else { return "••••" }
        let tail = hint.filter { $0 != "…" && $0 != "." && $0 != "*" && $0 != "•" }
        return "••" + tail.suffix(4)
    }
    /// What the agent runs with: the user's instructions, else the built-in ones.
    var effectivePrompt: String { systemPrompt ?? defaultSystemPrompt ?? "" }
    var usesDefaultPrompt: Bool { systemPrompt == nil }
}

/// The body of `PUT /v1/agent/config`: only the fields being changed.
struct AgentConfigChange: Sendable {
    var baseURL: String?
    var model: String?
    /// "" clears the key.
    var apiKey: String?
    var autoLog: Bool?
    var maxJobsPerDay: Int?
    /// .some(nil) or .some("") resets to the default instructions.
    var systemPrompt: String??

    init(baseURL: String? = nil, model: String? = nil, apiKey: String? = nil, autoLog: Bool? = nil,
         maxJobsPerDay: Int? = nil, systemPrompt: String?? = nil) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey; self.autoLog = autoLog
        self.maxJobsPerDay = maxJobsPerDay; self.systemPrompt = systemPrompt
    }

    var json: [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        if let baseURL { o["base_url"] = .string(baseURL) }
        if let model { o["model"] = .string(model) }
        if let apiKey { o["api_key"] = .string(apiKey) }
        if let autoLog { o["auto_log"] = .bool(autoLog) }
        if let maxJobsPerDay { o["max_jobs_per_day"] = .number(Double(maxJobsPerDay)) }
        if let prompt = systemPrompt {
            o["system_prompt"] = prompt.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null
        }
        return o
    }
    func body() throws -> Data { try JSONEncoder().encode(JSONValue.object(json)) }
}

/// One model from `GET /v1/agent/models`. Other providers may send bare ids.
struct AgentModel: Decodable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var contextLength: Int?
    /// USD per 1M tokens, when known.
    var promptPrice: Double?
    var completionPrice: Double?

    init(id: String, name: String? = nil, contextLength: Int? = nil, promptPrice: Double? = nil, completionPrice: Double? = nil) {
        self.id = id; self.name = name ?? id; self.contextLength = contextLength
        self.promptPrice = promptPrice; self.completionPrice = completionPrice
    }
    init(from decoder: Decoder) throws {
        if let id = try? decoder.singleValueContainer().decode(String.self) {
            self.init(id: id)
            return
        }
        let r = try RowReader(decoder)
        let id = r.string("id") ?? ""
        self.init(id: id, name: r.string("name").flatMap { $0.isEmpty ? nil : $0 }, contextLength: r.int("context_length"),
                  promptPrice: r.double("prompt_price"), completionPrice: r.double("completion_price"))
    }

    /// "$0.30 · $2.50" per 1M input and output tokens, or nil when the provider doesn't say.
    var priceLine: String? {
        guard promptPrice != nil || completionPrice != nil else { return nil }
        return "\(AgentFormat.price(promptPrice)) in · \(AgentFormat.price(completionPrice)) out"
    }
}

struct AgentModelList: Decodable, Sendable {
    var models: [AgentModel]
    init(models: [AgentModel]) { self.models = models }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        models = (r.value("models", as: [AgentModel].self) ?? []).filter { !$0.id.isEmpty }
    }
}

/// `POST /v1/agent/test`.
struct AgentTestResult: Decodable, Hashable, Sendable {
    var ok: Bool
    var model: String?
    var latencyMs: Int?
    var error: String?
    init(ok: Bool, model: String? = nil, latencyMs: Int? = nil, error: String? = nil) {
        self.ok = ok; self.model = model; self.latencyMs = latencyMs; self.error = error
    }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        ok = r.bool("ok") ?? false
        model = r.string("model")
        latencyMs = r.int("latency_ms")
        error = r.string("error")
    }
}

// MARK: - Jobs

/// `POST /v1/agent/jobs`. At least one of image or text.
struct AgentJobInput: Sendable {
    /// A re-encoded JPEG (AgentImage.prepare), never the original photo.
    var image: Data?
    var text: String?
    var barcodes: [String] = []
    var meal: Meal
    var day: String

    var trimmedText: String? {
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
    var isEmpty: Bool { image == nil && trimmedText == nil }

    func body() throws -> Data {
        var o: [String: JSONValue] = ["meal": .string(meal.rawValue), "date": .string(day)]
        if let image { o["image"] = .string(image.base64EncodedString()) }
        if let t = trimmedText { o["text"] = .string(t) }
        if !barcodes.isEmpty { o["barcodes"] = .array(barcodes.map(JSONValue.string)) }
        return try JSONEncoder().encode(JSONValue.object(o))
    }
}

struct AgentJobCreated: Decodable, Sendable {
    var job: String
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        guard let id = r.string("job") ?? r.string("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no job id"))
        }
        job = id
    }
}

enum AgentJobStatus: String, Sendable {
    case running, draft, logged, failed
}

/// The meal a job proposes: batch items (as for `food log --json`), the entries they'd make, and a line.
struct AgentDraft: Codable, Hashable, Sendable {
    var items: [JSONValue]
    var preview: [Entry]
    var summary: String

    init(items: [JSONValue], preview: [Entry], summary: String) {
        self.items = items; self.preview = preview; self.summary = summary
    }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        items = r.value("items") ?? []
        preview = r.value("preview") ?? []
        summary = r.string("summary") ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var w = RowWriter(encoder)
        try w.put("items", items); try w.put("preview", preview); try w.put("summary", summary)
    }

    var totals: NutrientMap { NutritionMath.sum(preview.map(\.nutrients)) }
    var kcal: Double { totals["kcal"] ?? 0 }
    var isEmpty: Bool { preview.isEmpty }
    /// Each item has its preview entry, so rows can be edited one by one.
    var isEditable: Bool { items.count == preview.count }

    /// Item `index` at `servings` (the preview's unit). Returns nil for a bad index or amount.
    func settingServings(_ servings: Double, at index: Int) -> AgentDraft? {
        guard preview.indices.contains(index), servings > 0, servings.isFinite else { return nil }
        let old = preview[index].servings > 0 ? preview[index].servings : 1
        return scaling(index, by: servings / old)
    }

    /// Item `index` at `grams`; nil when its entry has no weight.
    func settingGrams(_ grams: Double, at index: Int) -> AgentDraft? {
        guard preview.indices.contains(index), let old = preview[index].grams, old > 0, grams > 0, grams.isFinite else { return nil }
        return scaling(index, by: grams / old)
    }

    /// Scales one row's entry snapshot and its batch item by the same factor, as the server's
    /// `rescale_entry` does when the edited item is logged.
    func scaling(_ index: Int, by factor: Double) -> AgentDraft? {
        guard preview.indices.contains(index), factor > 0, factor.isFinite else { return nil }
        var d = self
        let entry = preview[index]
        d.preview[index] = entry.rescaled(servings: (entry.servings > 0 ? entry.servings : 1) * factor)
        if items.indices.contains(index) {
            d.items[index] = Self.scale(item: items[index], by: factor, entry: entry)
        }
        return d
    }

    func removing(_ index: Int) -> AgentDraft {
        var d = self
        if d.preview.indices.contains(index) { d.preview.remove(at: index) }
        if d.items.indices.contains(index) { d.items.remove(at: index) }
        return d
    }

    /// Every item and entry moved to another meal.
    func moving(to meal: Meal) -> AgentDraft {
        var d = self
        for i in d.preview.indices { d.preview[i].meal = meal }
        for i in d.items.indices {
            if case .object(var o) = d.items[i] {
                o["meal"] = .string(meal.rawValue)
                d.items[i] = .object(o)
            }
        }
        return d
    }

    /// The batch item fields the server takes (`food log --json`); it rejects any other key.
    static let itemKeys: Set<String> = ["catalog", "food", "name", "grams", "servings", "nutrients", "meal", "date", "note",
                                        "brand", "serving_unit", "source"]

    /// The items to confirm: objects with only the documented fields.
    var confirmItems: [JSONValue] {
        items.map { item in
            guard case .object(let o) = item else { return item }
            return .object(o.filter { Self.itemKeys.contains($0.key) })
        }
    }

    /// An item's `servings` and `grams`, whichever it has, times `factor`. An item with neither (a named
    /// item defaults to one serving) gets `servings` from its entry.
    static func scale(item: JSONValue, by factor: Double, entry: Entry) -> JSONValue {
        guard case .object(var o) = item else { return item }
        var touched = false
        for key in ["servings", "grams"] {
            if let v = o[key]?.double {
                o[key] = .number(NutritionMath.round3(v * factor))
                touched = true
            }
        }
        if !touched {
            o["servings"] = .number(NutritionMath.round3((entry.servings > 0 ? entry.servings : 1) * factor))
        }
        return .object(o)
    }
}

/// `GET /v1/agent/jobs/ID?wait=25`.
struct AgentJob: Decodable, Sendable {
    var status: AgentJobStatus
    var step: String?
    var draft: AgentDraft?
    var error: String?
    var usage: AgentUsage?
    /// Once logged (auto-log), the entries the server wrote, for the undo toast, and the sync version.
    var entries: [Entry] = []
    var version: Int?
    /// The defaults the job filled in, and when it started (ms).
    var meal: Meal?
    var date: String?
    var createdAt: Int?

    init(status: AgentJobStatus, step: String? = nil, draft: AgentDraft? = nil, error: String? = nil,
         usage: AgentUsage? = nil, entries: [Entry] = []) {
        self.status = status; self.step = step; self.draft = draft; self.error = error; self.usage = usage
        self.entries = entries
    }
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        let raw = r.string("status") ?? "running"
        status = AgentJobStatus(rawValue: raw) ?? (raw == "error" ? .failed : .running)
        step = r.string("step").flatMap { $0.isEmpty ? nil : $0 }
        draft = r.value("draft")
        error = r.string("error")
        usage = r.value("usage")
        version = r.int("version")
        meal = r.string("meal").flatMap(Meal.init(rawValue:))
        date = r.string("date")
        createdAt = r.int("created_at")
        if let list = r.value("entries", as: [Entry].self) {
            entries = list
        } else if let logged = r.value("logged", as: [LoggedItem].self) {
            entries = logged.compactMap(\.entry)
        }
    }
    /// `{"entry": {...}}`, as `food log --json` prints a logged item.
    private struct LoggedItem: Decodable { var entry: Entry? }
}

/// `POST /v1/agent/jobs/ID/confirm`.
struct AgentConfirmed: Decodable, Sendable {
    var entries: [Entry]
    var version: Int?
    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        struct LoggedItem: Decodable { var entry: Entry? }
        entries = r.value("entries", as: [Entry].self)
            ?? r.value("logged", as: [LoggedItem].self)?.compactMap(\.entry) ?? []
        version = r.int("version")
    }
}

// MARK: - Errors

/// What went wrong, in words a person can act on. Built from an HTTP status and the server's message,
/// or from a failed job's `error`.
struct AgentFailure: Error, Hashable, Sendable {
    enum Kind: String, Sendable {
        case noKey, noModel, invalidKey, outOfCredit, unknownModel, timeout, offline, dailyLimit, busy, server
    }
    var kind: Kind
    /// The server's own words, shown small under the friendly copy.
    var detail: String?

    init(_ kind: Kind, detail: String? = nil) { self.kind = kind; self.detail = detail }

    /// From a job's error text or an HTTP error body. `status` 0 means unknown.
    static func classify(status: Int = 0, message: String?) -> AgentFailure {
        let m = (message ?? "").lowercased()
        let detail = message.flatMap { $0.isEmpty ? nil : $0 }
        func has(_ words: String...) -> Bool { words.contains { m.contains($0) } }
        if has("no api key", "no key", "key is not set", "not configured", "missing api key", "needs an api key", "set an api key") {
            return AgentFailure(.noKey, detail: detail)
        }
        if has("needs a model", "no model is set", "pick a model first", "model is not set") { return AgentFailure(.noModel, detail: detail) }
        if has("invalid", "unauthorized", "incorrect api key") && has("key", "auth", "401") || has("api key is invalid") {
            return AgentFailure(.invalidKey, detail: detail)
        }
        if has("credit", "402", "insufficient", "quota", "billing", "payment") { return AgentFailure(.outOfCredit, detail: detail) }
        if has("unknown model", "model not found", "no such model", "not a valid model", "no endpoints", "image input and tool") {
            return AgentFailure(.unknownModel, detail: detail)
        }
        if has("daily", "per day", "max_jobs", "jobs today", "limit of") { return AgentFailure(.dailyLimit, detail: detail) }
        if has("timed out", "timeout", "took too long") { return AgentFailure(.timeout, detail: detail) }
        switch status {
        case 401: return AgentFailure(.invalidKey, detail: detail)
        case 402: return AgentFailure(.outOfCredit, detail: detail)
        case 404: return AgentFailure(.unknownModel, detail: detail)
        case 408, 504: return AgentFailure(.timeout, detail: detail)
        case 429: return AgentFailure(.busy, detail: detail)
        case 503: return AgentFailure(.busy, detail: detail)
        default: break
        }
        if has("busy", "rate limit", "too many") { return AgentFailure(.busy, detail: detail) }
        return AgentFailure(.server, detail: detail)
    }

    var title: String {
        switch kind {
        case .noKey: "Add an API key first"
        case .noModel: "Pick a model first"
        case .invalidKey: "The API key didn't work"
        case .outOfCredit: "Out of credit"
        case .unknownModel: "Pick another model"
        case .timeout: "That took too long"
        case .offline: "Can't reach your server"
        case .dailyLimit: "Today's limit is reached"
        case .busy: "The model is busy"
        case .server: "Something went wrong"
        }
    }

    var message: String {
        switch kind {
        case .noKey: "AI logging needs a key from your provider. It's saved on your server, never on this phone."
        case .invalidKey: "Your provider turned the key down. Replace it in Settings → AI logging."
        case .outOfCredit: "Your provider account needs more credit. Add some, then try again."
        case .noModel: "Choose the model that reads your photos in Settings → AI logging."
        case .unknownModel: "The chosen model isn't available, or can't read photos and use tools. Pick another in Settings → AI logging."
        case .timeout: "The model didn't answer in time. Your photo is still here, so you can try again."
        case .offline: "Your photo is still here. Try again when you're back online."
        case .dailyLimit: "Plate stops after the daily number of AI logs set on your server. It resets at midnight."
        case .busy: "Try again in a moment. Your photo is still here."
        case .server: "Your photo is still here, so you can try again."
        }
    }

    var symbol: String {
        switch kind {
        case .noKey, .invalidKey: "key.slash"
        case .outOfCredit: "creditcard"
        case .noModel, .unknownModel: "cpu"
        case .timeout: "clock.badge.exclamationmark"
        case .offline: "wifi.slash"
        case .dailyLimit: "calendar.badge.clock"
        case .busy: "hourglass"
        case .server: "exclamationmark.triangle"
        }
    }

    /// Transient: the same request may work again (the input is kept for that).
    var canRetry: Bool { [.timeout, .offline, .busy, .server].contains(kind) }
    /// Fixed in Settings → AI logging.
    var needsSettings: Bool { [.noKey, .noModel, .invalidKey, .unknownModel].contains(kind) }
}

// MARK: - Formatting

enum AgentFormat {
    /// "$0.30", "$12", "$0.075" (per 1M tokens), "–" when unknown.
    static func price(_ usd: Double?) -> String {
        guard let usd else { return Fmt.missing }
        if usd == 0 { return "free" }
        if usd >= 10 { return "$" + Fmt.decimal(usd, decimals: usd.rounded() == usd ? 0 : 1) }
        if usd < 0.1 { return "$" + String(format: "%.3f", usd) }
        return "$" + String(format: "%.2f", usd)
    }

    /// "$0.19" spent; under 10 cents keeps a third decimal ("$0.012").
    static func cost(_ usd: Double?) -> String? {
        guard let usd else { return nil }
        if usd == 0 { return "$0" }
        if usd < 0.1 { return "$" + String(format: "%.3f", usd) }
        return "$" + String(format: "%.2f", usd)
    }

    /// "3 logs · $0.04" or "3 logs · 12.4k tokens" when the cost isn't known.
    static func usage(_ u: AgentUsage) -> String {
        let jobs = "\(u.jobs) log\(u.jobs == 1 ? "" : "s")"
        if let c = cost(u.cost) { return "\(jobs) · \(c)" }
        if u.tokens > 0 { return "\(jobs) · \(tokens(u.tokens)) tokens" }
        return jobs
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return Fmt.decimal(Double(n) / 1_000_000, decimals: 1) + "M" }
        if n >= 1000 { return Fmt.decimal(Double(n) / 1000, decimals: 1) + "k" }
        return "\(n)"
    }

    /// "1.2 KB" style size for the instructions counter.
    static func bytes(_ n: Int) -> String {
        n < 1024 ? "\(n) bytes" : Fmt.decimal(Double(n) / 1024, decimals: 1) + " KB"
    }
}
