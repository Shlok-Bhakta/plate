// Where the server connection lives: the URL in UserDefaults (`server.url`), the token in the Keychain.
// A build with Secrets.swift seeds both on first launch (and again whenever the compiled-in values change,
// say after a token rotation and rebuild), so it never shows onboarding. Keys are all `server.*`.
import CryptoKit
import Foundation
import Security

enum ServerSettings {
    private enum Key {
        static let url = "server.url"
        /// A hash of the compiled-in URL and token last seeded, so a sign-out or a changed server sticks
        /// until Secrets.swift itself changes.
        static let seeded = "server.seededFrom"
    }
    private static var defaults: UserDefaults { .standard }

    /// The configured server, seeding it from Secrets.swift first when that's compiled in and new.
    static func load() -> ServerConfig? {
        let compiled = BuildFeatures.compiledServer.flatMap(validCompiled)
        if let compiled {
            let stamp = fingerprint(compiled)
            if defaults.string(forKey: Key.seeded) != stamp {
                save(compiled)
                defaults.set(stamp, forKey: Key.seeded)
            }
        }
        guard let url = defaults.string(forKey: Key.url), !url.isEmpty else { return nil }
        // If the Keychain can't be read (it shouldn't happen), a compiled-in server still works.
        guard let token = Keychain.read() ?? (compiled?.url == url ? compiled?.token : nil), !token.isEmpty else { return nil }
        return ServerConfig(url: url, token: token)
    }

    /// Returns false when the Keychain refused the token (the connection then lasts until the app quits).
    @discardableResult
    static func save(_ config: ServerConfig) -> Bool {
        defaults.set(config.url, forKey: Key.url)
        guard Keychain.write(config.token) else {
            print("Plate: couldn't save the token in the Keychain")
            return false
        }
        return true
    }

    /// Sign out: forgets the URL and the token (the seeded stamp stays, so a compiled-in server doesn't
    /// come straight back).
    static func clear() {
        defaults.removeObject(forKey: Key.url)
        Keychain.delete()
    }

    private static func validCompiled(_ c: ServerConfig) -> ServerConfig? {
        guard case .success(let url) = ServerAddress.normalize(c.url), !c.token.isEmpty, c.token != "placeholder" else { return nil }
        return ServerConfig(url: url, token: c.token)
    }

    private static func fingerprint(_ c: ServerConfig) -> String {
        SHA256.hash(data: Data((c.url + "\n" + c.token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The token, as a generic password readable after the first unlock (background refreshes sync too).
enum Keychain {
    private static let service = "plate.server"
    private static let account = "token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add.merge(attributes) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
