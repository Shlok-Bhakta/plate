// Connecting to a Plate server: cleaning up the URL someone typed, and the setup link
// `plate://setup?url=<server URL>&token=<token>` (opened from anywhere, pasted, or scanned as a QR code).
import Foundation

/// A server the app talks to: its base URL and the bearer token from `food token new`.
struct ServerConfig: Equatable, Sendable {
    var url: String
    var token: String
}

enum ServerAddress {
    enum Problem: Error, Equatable {
        case empty
        /// `http://`: the token and the log would travel in the clear (and iOS refuses it anyway).
        case insecure
        case invalid
    }

    /// "plate.example.com:8445/" → "https://plate.example.com:8445". Adds https:// when there's no scheme,
    /// drops a trailing slash, a trailing "/v1" and any query or fragment.
    static func normalize(_ raw: String) -> Result<String, Problem> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") { return .failure(.insecure) }
        if !lower.hasPrefix("https://") {
            if text.contains("://") { return .failure(.invalid) }
            text = "https://" + text
        }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              !host.contains(" "), parts.user == nil else { return .failure(.invalid) }
        parts.scheme = "https"
        parts.query = nil
        parts.fragment = nil
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/v1") { path.removeLast(3) }
        parts.path = path
        guard let url = parts.string, URL(string: url) != nil else { return .failure(.invalid) }
        return .success(url)
    }

    /// "plate.example.com:8445" for display.
    static func label(_ url: String) -> String {
        guard let parts = URLComponents(string: url), let host = parts.host else { return url }
        let port = parts.port.map { ":\($0)" } ?? ""
        let path = parts.path.isEmpty || parts.path == "/" ? "" : parts.path
        return host + port + path
    }
}

/// `plate://setup?url=https%3A%2F%2Fplate.example.com&token=...`
struct SetupLink: Equatable, Sendable {
    var url: String
    var token: String

    static let scheme = "plate"

    /// A setup link, from a URL that was opened or from pasted or scanned text (surrounding whitespace is
    /// fine). The url is normalized; a link without a valid https URL or a token is nil.
    static func parse(_ text: String) -> SetupLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == scheme,
              (parts.host ?? parts.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "setup"
        else { return nil }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let raw = value("url"), case .success(let url) = ServerAddress.normalize(raw),
              let token = value("token"), !token.isEmpty else { return nil }
        return SetupLink(url: url, token: token)
    }

    /// The link for a server and token, for README examples and tests.
    static func make(url: String, token: String) -> String {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "setup"
        parts.queryItems = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "token", value: token)]
        // URLComponents leaves ":" and "/" alone in a query; encode them so any URL parser reads it back.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?&=+#")
        parts.percentEncodedQuery = parts.queryItems?.map {
            "\($0.name)=\($0.value?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return parts.string ?? ""
    }
}
