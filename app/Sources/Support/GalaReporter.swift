// Drop this file into an app to send its console output, screenshots, and crash
// diagnostics to the Gala Mac over the tailnet. Gala writes GalaReportURL into
// Info.plist when it signs a delivered build; without that key every call is a no-op.
// Fetch the reports on the build client with `gala reports`.

import Foundation
import MetricKit
import UIKit

enum GalaReporter {
    static let endpoint = (Bundle.main.object(forInfoDictionaryKey: "GalaReportURL") as? String)
        .flatMap(URL.init(string:))

    /// Call once at launch. Forwards print() and NSLog output, sends crash diagnostics
    /// from the previous run, and optionally captures the screen after a delay.
    @MainActor
    static func start(captureOutput: Bool = true, screenshotAfter delay: TimeInterval? = nil) {
        guard endpoint != nil else { return }
        if captureOutput { OutputForwarder.shared.start() }
        MXMetricManager.shared.add(DiagnosticsSubscriber.shared)
        sendPendingException()
        NSSetUncaughtExceptionHandler { exception in
            let text = "\(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n")
            try? text.write(to: GalaReporter.pendingException, atomically: true, encoding: .utf8)
        }
        if let delay {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                screenshot()
            }
        }
    }

    static func log(_ message: String) {
        send(kind: "log", body: Data((message + "\n").utf8), type: "text/plain; charset=utf-8")
    }

    /// Render the key window as a PNG and send it.
    @MainActor
    static func screenshot() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard let window else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let png = image.pngData() { send(kind: "screenshot", body: png, type: "image/png") }
    }

    static func send(kind: String, body: Data, type: String) {
        guard let endpoint, !body.isEmpty else { return }
        var request = URLRequest(url: endpoint.appending(queryItems: [URLQueryItem(name: "kind", value: kind)]))
        request.httpMethod = "POST"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        URLSession.shared.uploadTask(with: request, from: body).resume()
    }

    fileprivate static let pendingException = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "gala-uncaught-exception.txt")

    private static func sendPendingException() {
        guard let data = try? Data(contentsOf: pendingException) else { return }
        try? FileManager.default.removeItem(at: pendingException)
        send(kind: "crash", body: data, type: "text/plain; charset=utf-8")
    }
}

/// MetricKit delivers crash and hang diagnostics, including Swift traps, on the next launch.
private final class DiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = DiagnosticsSubscriber()

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            GalaReporter.send(kind: "crash", body: payload.jsonRepresentation(), type: "application/json")
        }
    }
}

/// Copies stdout and stderr to the Mac in batches while still writing to the Xcode console.
private final class OutputForwarder: @unchecked Sendable {
    static let shared = OutputForwarder()
    private let lock = NSLock()
    private var buffer = Data()
    private var started = false

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        setvbuf(stdout, nil, _IOLBF, 0)
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            let original = dup(descriptor)
            let pipe = Pipe()
            dup2(pipe.fileHandleForWriting.fileDescriptor, descriptor)
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                _ = data.withUnsafeBytes { write(original, $0.baseAddress, data.count) }
                self?.append(data)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.flush() }
    }

    private func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let full = buffer.count > 256 * 1024
        lock.unlock()
        if full { flush() }
    }

    private func flush() {
        lock.lock()
        let batch = buffer
        buffer.removeAll()
        lock.unlock()
        GalaReporter.send(kind: "log", body: batch, type: "text/plain; charset=utf-8")
    }
}
