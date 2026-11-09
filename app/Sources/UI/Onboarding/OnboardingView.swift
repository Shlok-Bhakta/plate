// First launch without a server: what Plate is, then the server's URL and token (typed, from a pasted
// plate://setup link, or from its QR code). ServerCheck tests them; on success, builds without a health
// server offer Apple Health once, then the Store connects and the tabs appear. Settings → Server →
// Change server reuses the same form (ServerConnectView). Builds with Secrets.swift never get here.
import SwiftUI
import UIKit

extension SetupLink: Identifiable {
    var id: String { url + "\n" + token }
}

/// The URL and token fields, the paste and scan options, and the check's progress and errors.
@MainActor
@Observable
final class ServerFormModel {
    var url = ""
    var token = ""
    private(set) var step: ServerCheck.Step?
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    var busy: Bool { step != nil }
    var canConnect: Bool { !busy && !url.trimmingCharacters(in: .whitespaces).isEmpty && !token.trimmingCharacters(in: .whitespaces).isEmpty }

    var stepText: String {
        switch step {
        case .reaching?: "Reaching your server…"
        case .signingIn?: "Checking the token…"
        case .loading?: "Loading your log…"
        case nil: "Connect"
        }
    }

    func fill(_ link: SetupLink) {
        url = link.url
        token = link.token
        error = nil
    }

    /// Pasted text: a setup link fills both fields, a bare https URL fills the URL.
    /// Returns whether it was a complete setup link.
    func paste(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else {
            error = "The clipboard is empty. Copy the setup link first."
            return false
        }
        if let link = SetupLink.parse(text) {
            fill(link)
            return true
        }
        if case .success(let u) = ServerAddress.normalize(text), text.lowercased().hasPrefix("https://") {
            url = u
            error = nil
            return false
        }
        error = "The clipboard doesn't have a setup link. It starts with plate://setup."
        return false
    }

    func check(then done: @escaping @MainActor (ServerCheckResult) -> Void) {
        guard !busy else { return }
        error = nil
        step = .reaching
        let url = url, token = token
        task = Task {
            do {
                let result = try await ServerCheck.run(url: url, token: token) { [weak self] s in self?.step = s }
                step = nil
                Haptics.success()
                done(result)
            } catch is CancellationError {
                step = nil
            } catch {
                step = nil
                self.error = error.localizedDescription
                Haptics.warning()
            }
        }
    }

    func cancel() {
        task?.cancel()
        step = nil
    }
}

struct ServerForm: View {
    @Bindable var model: ServerFormModel
    var title: String
    var connect: () -> Void
    @State private var reveal = false
    @State private var scanning = false
    @FocusState private var focus: Field?
    private enum Field { case url, token }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text("Enter your server's address and a token from `food token new`, or use a setup link.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Server URL") {
                TextField("Server URL", text: $model.url, prompt: Text(verbatim: "https://plate.example.com"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .url)
                    .onSubmit { focus = .token }
            }

            field("Token") {
                HStack(spacing: 8) {
                    Group {
                        if reveal {
                            TextField("Token", text: $model.token)
                        } else {
                            SecureField("Token", text: $model.token)
                        }
                    }
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .submitLabel(.go)
                    .focused($focus, equals: .token)
                    .onSubmit { if model.canConnect { connect() } }
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reveal ? "Hide token" : "Show token")
                }
            }

            HStack(spacing: 8) {
                Button {
                    if model.paste(UIPasteboard.general.string) { connect() }
                } label: {
                    Label("Paste setup link", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.glass)
                Button { scanning = true } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.glass)
            }
            .tint(Palette.accentInk)
            .disabled(model.busy)

            if let error = model.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.over)
                    Text(error).font(.subheadline).foregroundStyle(Palette.overInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                focus = nil
                connect()
            } label: {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().tint(.white) }
                    Text(model.stepText).fontWeight(.semibold).contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .disabled(!model.canConnect)
        }
        .animation(Motion.smooth, value: model.error)
        .animation(Motion.smooth, value: model.busy)
        .card(padding: Space.xl - 4)
        .sheet(isPresented: $scanning) {
            SetupScannerView { link in
                scanning = false
                if let link {
                    model.fill(link)
                    connect()
                }
            }
        }
    }

    private func field<F: View>(_ label: String, @ViewBuilder content: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).sectionCaps()
            content()
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @State private var model = ServerFormModel()
    /// A checked server, waiting for the Apple Health step.
    @State private var pending: ServerCheckResult?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Space.xl) {
                    if let pending {
                        HealthStep(host: ServerAddress.label(pending.config.url)) { finish(pending) }
                            .padding(.top, 60)
                            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity).combined(with: .opacity))
                    } else {
                        hero
                        features
                        ServerForm(model: model, title: "Connect your server", connect: connect).id("form")
                        Text("No server yet? Plate's server is one small program you run on a computer you own. See server/README.md in the Plate repository.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Space.l)
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { TodayBackground() }
            .animation(Motion.smooth, value: pending == nil)
            .onChange(of: router.setupLink, initial: true) { _, link in
                guard let link else { return }
                router.setupLink = nil
                model.fill(link)
                proxy.scrollTo("form", anchor: .center)
                connect()
            }
            .task {
                // Screenshots and QA: -PlateOnboarding <url or setup link> fills the form (a plain URL gets a
                // sample token); -PlateOnboardingScroll form scrolls to it; -PlateOnboardingConnect YES taps Connect
                // (-PlateOnboardingHealth skip then skips the Apple Health step).
                let defaults = UserDefaults.standard
                if let text = defaults.string(forKey: "PlateOnboarding"), model.url.isEmpty {
                    if let link = SetupLink.parse(text) { model.fill(link) } else {
                        model.url = text
                        model.token = "0123456789abcdef0123456789abcdef"
                    }
                }
                if defaults.string(forKey: "PlateOnboardingScroll") == "form" {
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation { proxy.scrollTo("form", anchor: .bottom) }
                }
                if defaults.bool(forKey: "PlateOnboardingConnect") { connect() }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: Space.m) {
            AppIconImage(icon: AppIconStore.shared.current, size: 92)
                .shadow(color: Palette.accent.opacity(0.25), radius: 18, y: 8)
            Text("Plate")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("A quick, private food log that lives on your own server.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 48)
        .accessibilityElement(children: .combine)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: Space.l + 2) {
            feature("fork.knife", Palette.accent, "Log in seconds",
                    "Search, scan a barcode or tap a favorite. Calories, macros and micronutrients add up as you go.")
            feature("sparkles", Palette.protein, "Your agent logs too",
                    "Anything that can run the `food` command on your server, from a script to an AI agent reading a photo of your plate, logs to the same place. It shows up here within a second.")
            feature("lock.fill", Palette.fiber, "Yours alone",
                    "Your log lives in an encrypted database on your server, and Plate talks only to it.")
        }
        .card(padding: Space.xl - 4)
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint.gradient, in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func connect() {
        guard model.canConnect else { return }
        model.check { result in
            // -PlateOnboardingHealth skip (QA) goes straight to the app.
            if HealthDaysPush.isEnabled && HealthDaysPush.isAvailable && !HealthDaysPush.shared.requested
                && UserDefaults.standard.string(forKey: "PlateOnboardingHealth") != "skip" {
                pending = result
            } else {
                finish(result)
            }
        }
    }

    private func finish(_ result: ServerCheckResult) {
        store.connect(result)
    }
}

/// After connecting, in builds without a health server: one optional ask for Apple Health.
private struct HealthStep: View {
    var host: String
    var done: () -> Void
    @State private var asking = false

    var body: some View {
        VStack(spacing: Space.xl) {
            VStack(spacing: Space.m) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.fiber)
                    .padding(.bottom, 4)
                Text("Connected to \(host)")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: Space.l) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(Palette.over.gradient, in: .rect(cornerRadius: 18, style: .continuous))
                Text("Apple Health").font(.title2.weight(.bold))
                Text("Plate can send daily totals from Apple Health to your server: weight, active and resting energy, steps and exercise minutes, plus your height, birth date and sex. Your calorie goal then adapts to what you actually burn.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Only daily totals, and only to your server. You can change this later in Settings.")
                    .font(.footnote).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .card(padding: Space.xl)
            VStack(spacing: Space.s) {
                Button {
                    asking = true
                    Task {
                        await HealthDaysPush.shared.requestAccess()
                        done()
                    }
                } label: {
                    Text("Allow Apple Health").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .disabled(asking)
                Button("Not now", action: done)
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.accentInk)
                    .frame(height: 44)
                    .disabled(asking)
            }
        }
    }
}

// MARK: - Change server (Settings)

/// Settings → Server → Change server, and a setup link opened while connected.
struct ServerConnectView: View {
    enum Mode { case change }
    var mode: Mode = .change
    var link: SetupLink?
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model = ServerFormModel()
    @State private var confirm: ServerCheckResult?

    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                ServerForm(model: model, title: link == nil ? "Change server" : "Use this server?", connect: connect)
                Text("Connecting to a different server replaces this phone's copy of the log with that server's. A new token for the same server keeps it.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, Space.l)
            }
            .padding(Space.l)
        }
        .background(Palette.background)
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") {
                    model.cancel()
                    dismiss()
                }
            }
        }
        .onAppear {
            if let link { model.fill(link) } else if let url = store.serverURL, model.url.isEmpty { model.url = url }
        }
        .confirmationDialog("Switch servers?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { result in
            Button("Switch to \(ServerAddress.label(result.config.url))", role: .destructive) { finish(result) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("\(store.pendingCount) change\(store.pendingCount == 1 ? " hasn't" : "s haven't") reached \(store.serverLabel) yet and will be lost. This phone's copy of the log is replaced by the new server's.")
        }
    }

    private func connect() {
        guard model.canConnect else { return }
        model.check { result in
            let different = store.serverURL != result.config.url
            if different && store.pendingCount > 0 { confirm = result } else { finish(result) }
        }
    }

    private func finish(_ result: ServerCheckResult) {
        store.connect(result)
        Toasts.shared.message("Connected to \(ServerAddress.label(result.config.url))", symbol: "checkmark.circle.fill")
        dismiss()
    }
}
