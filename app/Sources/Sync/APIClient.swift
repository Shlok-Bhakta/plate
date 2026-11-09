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

    private func send<T: Decodable>(_ r: URLRequest, as: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: r)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.offline(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300:
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw APIError.decoding(String(describing: error).prefix(200).description) }
        case 401, 403: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw APIError.http(code, message)
        }
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
