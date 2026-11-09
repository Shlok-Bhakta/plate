// The HTTP API from SPEC "HTTP API (the app)": async URLSession calls with the bearer token.
import Foundation

enum APIError: Error, Equatable, LocalizedError {
    case unauthorized
    case notFound
    case http(Int, String)
    case offline(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Sign-in failed"
        case .notFound: "Not found"
        case .http(let code, let message): "Server error \(code): \(message)"
        case .offline(let message): message
        case .decoding(let message): "Unexpected response: \(message)"
        }
    }
    /// 4xx that will never succeed on retry (bad rows), as opposed to auth or transient failures.
    var isPermanent: Bool {
        if case .http(let code, _) = self { return (400..<500).contains(code) && ![408, 409, 425, 429].contains(code) }
        return false
    }
}

/// `POST /v1/mutations` response (SPEC "Server notes"): `ids` maps a sent id to the stored one when the
/// server kept an existing food, and `errors` lists the mutations it skipped.
struct MutationsResult: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        var index: Int
        var error: String
        init(from decoder: Decoder) throws {
            let r = try RowReader(decoder)
            index = r.int("index") ?? -1
            error = r.string("error") ?? "rejected by the server"
        }
    }
    var version: Int
    var applied: Int
    var ids: [String: String] = [:]
    var errors: [Failure] = []

    init(from decoder: Decoder) throws {
        let r = try RowReader(decoder)
        version = r.int("version") ?? 0
        applied = r.int("applied") ?? 0
        ids = r.value("ids") ?? [:]
        errors = r.value("errors") ?? []
    }
}

struct APIClient: Sendable {
    let base: URL
    let token: String
    let session: URLSession
    /// AI logging: a job upload (up to 90 s) and its long-poll (`wait=25`) outlast the 40 s default.
    let longSession: URLSession

    init?(baseURL: String, token: String) {
        guard let url = URL(string: baseURL), url.scheme != nil else { return nil }
        base = url
        self.token = token
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 40
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
        let long = URLSessionConfiguration.default
        long.waitsForConnectivity = false
        long.timeoutIntervalForRequest = 95
        long.timeoutIntervalForResource = 180
        long.requestCachePolicy = .reloadIgnoringLocalCacheData
        long.httpMaximumConnectionsPerHost = 2
        longSession = URLSession(configuration: long)
    }

    var hostLabel: String { base.host.map { h in base.port.map { "\(h):\($0)" } ?? h } ?? base.absoluteString }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
                         timeout: TimeInterval = 15) -> URLRequest {
        var url = base.appending(path: path)
        if !query.isEmpty { url = url.appending(queryItems: query) }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// The body and status of a request; transport failures become `APIError.offline`.
    private func perform(_ r: URLRequest, on session: URLSession? = nil) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (session ?? self.session).data(for: r)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw APIError.offline("timed out")
        } catch {
            throw APIError.offline(error.localizedDescription)
        }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func errorMessage(_ data: Data) -> String {
        (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["error"]?.string
            ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    private func send<T: Decodable>(_ r: URLRequest, as: T.Type) async throws -> T {
        let (data, code) = try await perform(r)
        switch code {
        case 200..<300:
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw APIError.decoding(String(describing: error).prefix(200).description) }
        case 401, 403: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default:
            throw APIError.http(code, Self.errorMessage(data))
        }
    }

    // MARK: AI logging (SPEC "AI logging"): every failure is an AgentFailure with friendly copy.

    /// Sends an agent request. A 401 or 403 that names the provider's key is the key's problem; otherwise
    /// it's this phone's token (`APIError.unauthorized`, as everywhere else).
    private func sendAgent<T: Decodable>(_ r: URLRequest, as: T.Type, long: Bool = false) async throws -> T {
        let data: Data, code: Int
        do {
            (data, code) = try await perform(r, on: long ? longSession : session)
        } catch APIError.offline(let message) {
            throw message == "timed out" ? AgentFailure(.timeout, detail: nil) : AgentFailure(.offline, detail: message)
        }
        if (200..<300).contains(code) {
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw AgentFailure(.server, detail: "Unexpected response from the server") }
        }
        let message = Self.errorMessage(data)
        if code == 401 || code == 403 {
            let m = message.lowercased()
            if !(m.contains("key") || m.contains("provider") || m.contains("credit")) { throw APIError.unauthorized }
        }
        if code == 404 && message.lowercased().contains("job") { throw AgentFailure(.server, detail: message) }
        throw AgentFailure.classify(status: code, message: message)
    }

    func agentConfig() async throws -> AgentConfig {
        try await sendAgent(request("v1/agent/config", timeout: 15), as: AgentConfig.self)
    }

    /// The key, if any, is only in this request's body.
    func updateAgentConfig(_ change: AgentConfigChange) async throws -> AgentConfig {
        try await sendAgent(request("v1/agent/config", method: "PUT", body: try change.body(), timeout: 20), as: AgentConfig.self)
    }

    func agentModels(query: String) async throws -> [AgentModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return try await sendAgent(request("v1/agent/models", query: q.isEmpty ? [] : [URLQueryItem(name: "q", value: q)],
                                           timeout: 30), as: AgentModelList.self).models
    }

    func agentTest() async throws -> AgentTestResult {
        try await sendAgent(request("v1/agent/test", method: "POST", body: Data("{}".utf8), timeout: 60), as: AgentTestResult.self, long: true)
    }

    /// 202 with the job's id. The photo upload gets 90 s.
    func createAgentJob(_ input: AgentJobInput) async throws -> String {
        try await sendAgent(request("v1/agent/jobs", method: "POST", body: try input.body(), timeout: 90),
                            as: AgentJobCreated.self, long: true).job
    }

    /// Long-polls up to `wait` seconds for the job to move on.
    func agentJob(_ id: String, wait: Int = 25) async throws -> AgentJob {
        try await sendAgent(request("v1/agent/jobs/\(id)", query: [URLQueryItem(name: "wait", value: String(wait))],
                                    timeout: TimeInterval(wait) + 20), as: AgentJob.self, long: true)
    }

    /// Logs the draft, or `items` when the person edited it.
    func confirmAgentJob(_ id: String, items: [JSONValue]?) async throws -> AgentConfirmed {
        var body: [String: JSONValue] = [:]
        if let items { body["items"] = .array(items) }
        return try await sendAgent(request("v1/agent/jobs/\(id)/confirm", method: "POST",
                                           body: try JSONEncoder().encode(JSONValue.object(body)), timeout: 30),
                                   as: AgentConfirmed.self, long: true)
    }

    func cancelAgentJob(_ id: String) async {
        _ = try? await perform(request("v1/agent/jobs/\(id)", method: "DELETE", timeout: 10))
    }

    struct Ping: Decodable { var ok: Bool; var version: Int? }

    func ping() async throws -> Ping { try await send(request("v1/ping"), as: Ping.self) }

    /// Rows past `since`. With `wait > 0` the server holds the request up to 25 s until something changes.
    func sync(since: Int, wait: Int, timeout: TimeInterval? = nil) async throws -> SyncPayload {
        let q = [URLQueryItem(name: "since", value: String(since)), URLQueryItem(name: "wait", value: String(wait))]
        return try await send(request("v1/sync", query: q, timeout: timeout ?? TimeInterval(wait) + 15), as: SyncPayload.self)
    }

    func mutations(_ list: [Mutation]) async throws -> MutationsResult {
        let body = try JSONEncoder().encode(["mutations": list])
        return try await send(request("v1/mutations", method: "POST", body: body, timeout: 20), as: MutationsResult.self)
    }

    func search(_ q: String, limit: Int = 25) async throws -> [Food] {
        struct R: Decodable { var results: [Food] }
        let query = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: String(limit))]
        return try await send(request("v1/search", query: query, timeout: 10), as: R.self).results
    }

    /// nil when the barcode isn't known anywhere (404).
    func barcode(_ code: String) async throws -> Food? {
        struct R: Decodable { var food: Food }
        do { return try await send(request("v1/barcode/\(code)", timeout: 12), as: R.self).food }
        catch APIError.notFound { return nil }
    }

    /// GET /v1/meta: only the server's time zone is used (the nutrient catalog is built in).
    struct Meta: Decodable { var timezone: String? }

    func meta() async throws -> Meta { try await send(request("v1/meta", timeout: 10), as: Meta.self) }

    /// POST /v1/health_days (SPEC "Server notes"): Apple Health daily totals, when there's no health server.
    struct HealthDaysResult: Decodable, Sendable {
        var written: Int
        var skipped: Int
        init(from decoder: Decoder) throws {
            let r = try RowReader(decoder)
            written = r.int("days_written") ?? 0
            skipped = r.int("days_skipped") ?? 0
        }
    }

    func healthDays(_ body: [String: Any]) async throws -> HealthDaysResult {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(request("v1/health_days", method: "POST", body: data, timeout: 30), as: HealthDaysResult.self)
    }

    func suggest(meal: Meal, day: String) async throws -> Suggestions {
        let q = [URLQueryItem(name: "meal", value: meal.rawValue), URLQueryItem(name: "day", value: day)]
        return try await send(request("v1/suggest", query: q, timeout: 10), as: Suggestions.self)
    }
}
