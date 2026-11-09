// Survives crashes: each step is appended to a file with a plain write(2), and fatal signals (which
// is what Swift runtime traps become) append a marker, so the next launch can report where the last
// run died.
import Darwin
import Foundation

enum Breadcrumbs {
    static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "breadcrumbs.txt")
    static var descriptor: Int32 = -1

    /// Returns the previous run's steps and starts a fresh file.
    static func start() -> String? {
        let previous = try? String(contentsOf: url, encoding: .utf8)
        try? FileManager.default.removeItem(at: url)
        descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        for number in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGFPE] {
            signal(number) { received in
                let marker: StaticString = "FATAL SIGNAL (see the step above)\n"
                _ = write(Breadcrumbs.descriptor, marker.utf8Start, marker.utf8CodeUnitCount)
                signal(received, SIG_DFL)
                raise(received)
            }
        }
        return previous
    }

    static func drop(_ step: String) {
        guard descriptor >= 0 else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(step)\n"
        line.withCString { _ = write(descriptor, $0, strlen($0)) }
    }
}
