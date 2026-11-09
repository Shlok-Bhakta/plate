// Testing a server before saving it (onboarding, Settings → Change server): GET /v1/ping without the
// token, then an authenticated GET /v1/sync (whose rows become the first sync), then GET /v1/meta for the
// server's time zone. Every failure gets a message that says what to check.
import Foundation

struct ServerCheckResult: Sendable {
    var config: ServerConfig
    var payload: SyncPayload
    var timezone: String?
}

enum ServerCheckError: LocalizedError, Equatable {
    case emptyURL, insecure, invalidURL, emptyToken
    case hostNotFound(String)
    case noAnswer(String)
    case tls(String)
    case offline
    case notPlate(String)
    case unauthorized
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyURL: "Enter your server's URL."
        case .insecure: "Plate only connects over HTTPS, so the token and your log aren't sent in the clear. Put the server behind Tailscale Serve or a reverse proxy with TLS."
        case .invalidURL: "That doesn't look like a server URL. It should look like https://plate.example.com."
        case .emptyToken: "Enter the token. Run food token new on your server to make one."
        case .hostNotFound(let host): "Couldn't find \(host). Check the address, and that this phone is on the same network or tailnet as the server."
        case .noAnswer(let host): "\(host) didn't answer. Check that food serve is running and reachable at that address and port."
        case .tls(let host): "Couldn't make a secure connection to \(host). Check the server's HTTPS certificate."
        case .offline: "This phone is offline. Connect to the internet and try again."
        case .notPlate(let host): "\(host) answered, but it isn't a Plate server. Check the address and port."
        case .unauthorized: "The server didn't accept this token. Make a new one with food token new and try again."
        case .failed(let message): message
        }
    }
}

enum ServerCheck {
    enum Step: Sendable { case reaching, signingIn, loading }

    static func run(url rawURL: String, token rawToken: String,
                    progress: @MainActor @Sendable (Step) -> Void = { _ in }) async throws -> ServerCheckResult {
        let url: String
        switch ServerAddress.normalize(rawURL) {
        case .success(let u): url = u
        case .failure(.empty): throw ServerCheckError.emptyURL
        case .failure(.insecure): throw ServerCheckError.insecure
        case .failure(.invalid): throw ServerCheckError.invalidURL
        }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ServerCheckError.emptyToken }
        guard let base = URL(string: url), let api = APIClient(baseURL: url, token: token) else { throw ServerCheckError.invalidURL }
        let host = ServerAddress.label(url)

        await progress(.reaching)
        try await ping(base, host: host)

        await progress(.signingIn)
        let payload: SyncPayload
        do {
            // The whole log, which can take a while on a slow link.
            payload = try await api.sync(since: 0, wait: 0, timeout: 60)
        } catch APIError.unauthorized {
            throw ServerCheckError.unauthorized
        } catch APIError.notFound {
            throw ServerCheckError.notPlate(host)
        } catch APIError.decoding {
            throw ServerCheckError.notPlate(host)
        } catch APIError.http(let code, let message) {
            throw ServerCheckError.failed("The server answered \(code): \(message)")
        } catch APIError.offline(let message) {
            throw ServerCheckError.failed("The connection dropped while loading your log (\(message)). Try again.")
        }

        await progress(.loading)
        let timezone = try? await api.meta().timezone
        return ServerCheckResult(config: ServerConfig(url: url, token: token), payload: payload, timezone: timezone)
    }

    /// /v1/ping needs no token. Called directly, not through APIClient, to tell the network errors apart.
    private static func ping(_ base: URL, host: String) async throws {
        var request = URLRequest(url: base.appending(path: "v1/ping"), timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed: throw ServerCheckError.hostNotFound(host)
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: throw ServerCheckError.offline
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                throw ServerCheckError.tls(host)
            case .appTransportSecurityRequiresSecureConnection: throw ServerCheckError.insecure
            case .cancelled: throw CancellationError()
            default: throw ServerCheckError.noAnswer(host)
            }
        }
        struct Ping: Decodable { var ok: Bool? }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try? JSONDecoder().decode(Ping.self, from: data))?.ok == true else { throw ServerCheckError.notPlate(host) }
    }
}
