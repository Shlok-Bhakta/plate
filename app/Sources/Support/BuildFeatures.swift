// What this build was compiled with. Both secrets files are optional and gitignored; build-env.sh passes
// one flag per file it finds:
//
//   -D PLATE_SECRETS        Secrets.swift (`enum Secrets { static let serverURL, token }`): seeds the server
//                           connection, so that build never shows onboarding (ServerSettings).
//   -D PLATE_HEALTH_SERVER  HealthSecrets.swift (`enum HealthSecrets { static let url: URL, token }`): the
//                           separate personal health server that HealthSync uploads every Health type to.
//
// Without them (the Xcode project, a fresh clone) the app asks for its server on first launch, and
// Apple Health's daily totals go to the food server through POST /v1/health_days (HealthDaysPush).
import Foundation

enum BuildFeatures {
    /// The server compiled in from Secrets.swift, if any.
    static var compiledServer: ServerConfig? {
        #if PLATE_SECRETS
        return ServerConfig(url: Secrets.serverURL, token: Secrets.token)
        #else
        return nil
        #endif
    }

    /// HealthSync (every Health type to a separate health server) runs only in builds with HealthSecrets.swift.
    /// Otherwise HealthDaysPush sends daily totals to the food server; the two never both run.
    static var healthServer: Bool {
        #if PLATE_HEALTH_SERVER
        return true
        #else
        return false
        #endif
    }
}

#if !PLATE_HEALTH_SERVER
/// Stands in for HealthSecrets.swift so HealthSync compiles. HealthSync never runs in these builds
/// (BuildFeatures.healthServer), and the address is unroutable on purpose.
enum HealthSecrets {
    static let url = URL(string: "https://127.0.0.1:9/ingest")!
    static let token = ""
}
#endif
