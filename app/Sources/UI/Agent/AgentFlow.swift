// Where AI logging is presented from. Each place that can start it (the root for the Quick Log bar, the
// Add sheet, the Search tab) applies `.agentHost()`, which puts a launcher in the environment and owns the
// presentations: the camera cover, then the job sheet (progress, draft, errors), or, when AI logging isn't
// set up yet, Settings → AI logging in a sheet with a one-line explanation.
import SwiftUI

struct AgentCaptureRequest: Identifiable, Hashable {
    enum Mode: Hashable { case camera, text(String) }
    let id = UUID()
    var mode: Mode = .camera
    var meal: Meal
    var day: String
}

/// Starts AI logging from wherever the host is.
struct AgentLauncher {
    var launch: @MainActor (AgentCaptureRequest) -> Void
    @MainActor func callAsFunction(_ r: AgentCaptureRequest) { launch(r) }
}

private struct AgentLauncherKey: EnvironmentKey { static let defaultValue: AgentLauncher? = nil }
extension EnvironmentValues {
    var agentLauncher: AgentLauncher? {
        get { self[AgentLauncherKey.self] }
        set { self[AgentLauncherKey.self] = newValue }
    }
}

extension View {
    /// Presents AI logging from this view (see the file comment).
    func agentHost(debug: Bool = false) -> some View { modifier(AgentHost(debug: debug)) }
}

private struct AgentHost: ViewModifier {
    /// The root host also opens the debug screens (`-PlateScreen capture | agentprogress | agentdraft | agenterror`).
    var debug: Bool
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @State private var capture: AgentCaptureRequest?
    @State private var run: AgentRun?
    /// The run on screen, kept past dismissal (the sheet clears `run` before onDismiss).
    @State private var shownRun: AgentRun?
    /// Set by the camera's Send; becomes `run` once the cover is gone (one presentation at a time).
    @State private var nextRun: AgentRun?
    @State private var setup: AgentCaptureRequest?
    @State private var afterSetup: AgentCaptureRequest?

    func body(content: Content) -> some View {
        content
            .environment(\.agentLauncher, AgentLauncher { launch($0) })
            .fullScreenCover(item: $capture, onDismiss: {
                if let next = nextRun {
                    nextRun = nil
                    run = next
                    next.start()
                }
            }) { request in
                CaptureView(request: request) { newRun in
                    nextRun = newRun
                    capture = nil
                } onClose: { capture = nil }
            }
            .sheet(item: $run, onDismiss: {
                // Swiped away or closed: a job still running or a draft not logged is cancelled on the server.
                if let r = shownRun, r.phase != .done { r.cancel() }
                shownRun = nil
            }) { r in
                AgentJobSheet(run: r) { run = nil }
                    .onAppear { shownRun = r }
            }
            .sheet(item: $setup, onDismiss: {
                // Set up from here: carry on to the camera (or the text job) the person asked for.
                if let next = afterSetup, AgentService.shared.isConfigured {
                    afterSetup = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        launch(next)
                    }
                }
                afterSetup = nil
            }) { request in
                NavigationStack {
                    AgentSettingsView(intro: true) { setup = nil }
                }
                .onAppear { afterSetup = request }
            }
            .task {
                guard debug else { return }
                await openDebugScreen()
            }
    }

    @MainActor private func launch(_ request: AgentCaptureRequest) {
        let service = AgentService.shared
        if service.isConfigured {
            present(request)
            Task { await service.refresh() }
            return
        }
        Task {
            // Not known to be set up: ask the server once (the cache may predate a CLI setup).
            if service.config == nil || !service.isConfigured { await service.refresh() }
            if service.isConfigured { present(request) } else { setup = request }
        }
    }

    @MainActor private func present(_ request: AgentCaptureRequest) {
        switch request.mode {
        case .camera:
            capture = request
        case .text(let t) where !t.trimmingCharacters(in: .whitespaces).isEmpty:
            let r = AgentRun(input: AgentJobInput(text: t, meal: request.meal, day: request.day), thumbnail: nil)
            run = r
            r.start()
        case .text:
            capture = request
        }
    }

    @MainActor private func openDebugScreen() async {
        let screen = UserDefaults.standard.string(forKey: "PlateScreen")
        guard let screen, ["capture", "capturetext", "agentprogress", "agentdraft", "agenterror", "agenttext", "agentsetup"].contains(screen)
        else { return }
        try? await Task.sleep(for: .milliseconds(600))
        let meal = router.logMeal, day = router.day
        switch screen {
        case "capture": capture = AgentCaptureRequest(meal: meal, day: day)
        case "capturetext": capture = AgentCaptureRequest(mode: .text(""), meal: meal, day: day)
        case "agentsetup": setup = AgentCaptureRequest(meal: meal, day: day)
        case "agenttext":
            present(AgentCaptureRequest(mode: .text(UserDefaults.standard.string(forKey: "PlateQuery") ?? "2 eggs and toast"), meal: meal, day: day))
        case "agentdraft":
            run = AgentRun.debugDraft(meal: meal, day: day, photo: DemoPhoto.image)
        default:
            // agentprogress (add -PlateAgentHold YES to stay on it), agenterror (with -PlateAgentError <kind>).
            let photo = DemoPhoto.image
            guard let prepared = await PhotoPrep.prepare(PhotoPrep.data(from: photo) ?? Data()) else { return }
            let r = AgentRun(input: AgentJobInput(image: prepared.jpeg, text: nil, barcodes: prepared.barcodes, meal: meal, day: day),
                             thumbnail: photo)
            run = r
            r.start()
        }
    }
}
