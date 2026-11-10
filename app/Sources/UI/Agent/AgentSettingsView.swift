// Settings → AI logging: provider (OpenRouter or any OpenAI-compatible server), the API key (sent to the
// server once, never kept here), the model, the agent's instructions, speed (`reasoning_effort` and
// `verify_matches`), a connection test, auto-log, and usage. Everything is stored on the Plate server; this phone only caches has_key and key_hint.
import SwiftUI

struct AgentSettingsView: View {
    /// Opened from the camera button before AI logging was set up: a one-line explanation on top, and Done.
    var intro = false
    var done: (() -> Void)?

    @State private var service = AgentService.shared
    @State private var keyText = ""
    @State private var replacingKey = false
    @State private var customURL = ""
    @State private var provider: AgentProvider = .openRouter
    @State private var saving: String?
    @State private var error: AgentFailure?
    @State private var test: TestState = .idle
    @State private var showModels = false
    @State private var showInstructions = false
    @State private var confirmRemove = false
    @FocusState private var keyFocused: Bool

    enum TestState: Equatable { case idle, running, ok(AgentTestResult), failed(AgentFailure) }

    private var config: AgentConfig? { service.config }

    var body: some View {
        ScrollViewReader { proxy in
            form
                .task {
                    guard UserDefaults.standard.string(forKey: "PlateScreen") == "agentspeed" else { return }
                    try? await Task.sleep(for: .milliseconds(700))
                    withAnimation { proxy.scrollTo("speed", anchor: .center) }
                }
        }
    }

    private var form: some View {
        Form {
            if intro {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 28)
                        Text("Snap a meal or describe it, and AI drafts the entries for you to check. It needs an API key and a model first.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
            if let config {
                status(config)
                providerSection(config)
                keySection(config)
                modelSection(config)
                speedSection(config)
                testSection(config)
                autoLogSection(config)
                usageSection(config)
            } else if service.loading {
                Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Can't load AI logging").font(.headline)
                        Text(service.loadError?.kind == .offline || service.loadError == nil
                             ? "Your server isn't reachable right now."
                             : "Your server may need an update to use AI logging.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button("Try again") { Task { await service.refresh() } }
                        .foregroundStyle(Palette.accentInk)
                }
            }
        }
        .navigationTitle("AI logging")
        .navigationBarTitleDisplayMode(intro ? .inline : .large)
        .toolbar {
            if let done {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: done) { Image(systemName: "checkmark") }.accessibilityLabel("Done")
                }
            }
        }
        .navigationDestination(isPresented: $showModels) { ModelPickerView() }
        .fullScreenCover(isPresented: $showInstructions) { NavigationStack { InstructionsEditor() } }
        .task {
            sync(config)
            await service.refresh()
            sync(service.config)
            if UserDefaults.standard.string(forKey: "PlateScreen") == "agentinstructions" { showInstructions = true }
            if UserDefaults.standard.string(forKey: "PlateScreen") == "agentmodels" { showModels = true }
        }
        .onChange(of: service.config) { _, c in sync(c) }
        .onDisappear { keyText = "" }
        .alert(error?.title ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text([error?.detail, error.map { $0.kind == .server ? nil : $0.message } ?? nil].compactMap { $0 }.joined(separator: "\n\n"))
        }
        .confirmationDialog("Remove the API key from your server?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove key", role: .destructive) { save("key", AgentConfigChange(apiKey: "")) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI logging stops until you add a key again.")
        }
    }

    private func sync(_ c: AgentConfig?) {
        guard let c else { return }
        provider = c.provider
        if c.provider == .custom && customURL.isEmpty { customURL = c.baseURL }
    }

    // MARK: Sections

    private func status(_ c: AgentConfig) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                StatusDot(color: c.isConfigured ? Palette.fiber : Color(uiColor: .systemGray), pulsing: false)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.isConfigured ? "Ready" : "Not set up").font(.headline)
                    Text(statusDetail(c)).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func statusDetail(_ c: AgentConfig) -> String {
        if c.isConfigured {
            return "Snap a meal from the camera button, or ask AI from search. You check the draft before anything is logged."
        }
        if !c.hasKey { return "Add an API key from your provider, then pick a model." }
        return "Pick a model to finish."
    }

    @ViewBuilder private func providerSection(_ c: AgentConfig) -> some View {
        Section {
            Picker("Provider", selection: Binding(get: { provider }, set: { setProvider($0, c) })) {
                Text("OpenRouter").tag(AgentProvider.openRouter)
                Text("Custom (OpenAI-compatible)").tag(AgentProvider.custom)
            }
            .tint(Palette.accentInk)
            if provider == .custom {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL").font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        TextField("https://api.example.com/v1", text: $customURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onSubmit { saveURL() }
                        if saving == "url" { ProgressView() } else if customURL != c.baseURL && !customURL.isEmpty {
                            Button("Save", action: saveURL).fontWeight(.semibold).foregroundStyle(Palette.accentInk)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } footer: {
            Text(provider == .openRouter
                 ? "OpenRouter reaches most vision models with one key and reports what each log costs."
                 : "Any server with the OpenAI Chat Completions API, image input and tool calls: OpenAI, a local server, and others.")
        }
    }

    @ViewBuilder private func keySection(_ c: AgentConfig) -> some View {
        Section {
            if c.hasKey && !replacingKey {
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(Palette.fiber.gradient, in: .rect(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Key saved").font(.body)
                        Text(c.keyDots).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if saving == "key" { ProgressView() }
                }
                Button("Replace key") {
                    replacingKey = true
                    keyFocused = true
                }
                .foregroundStyle(Palette.accentInk)
                Button("Remove key", role: .destructive) { confirmRemove = true }
                    .foregroundStyle(Palette.overInk)
            } else {
                HStack {
                    SecureField(provider == .openRouter ? "sk-or-…" : "API key", text: $keyText)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($keyFocused)
                        .submitLabel(.done)
                        .onSubmit(saveKey)
                    if saving == "key" {
                        ProgressView()
                    } else {
                        Button("Save", action: saveKey)
                            .fontWeight(.semibold)
                            .foregroundStyle(Palette.accentInk)
                            .buttonStyle(.borderless)
                            .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if replacingKey {
                    Button("Keep the saved key") { replacingKey = false; keyText = "" }
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("API key")
        } footer: {
            Text("Your key is stored on your server, encrypted. Plate never keeps it on this phone.")
        }
    }

    @ViewBuilder private func modelSection(_ c: AgentConfig) -> some View {
        Section {
            Button { showModels = true } label: {
                NavRow(title: "Model", symbol: "cpu", tint: Palette.protein,
                       value: c.model.isEmpty ? "Choose" : Self.shortName(c.model))
            }
            .tint(.primary)
            Button { showInstructions = true } label: {
                NavRow(title: "Instructions", symbol: "text.alignleft", tint: Palette.mineral,
                       value: c.usesDefaultPrompt ? "Default" : "Custom")
            }
            .tint(.primary)
        } footer: {
            Text(c.provider == .openRouter
                 ? "Only models that accept images and tools are shown. Cheaper models work well for most meals."
                 : "Use a model that accepts images and tool calls.")
        }
    }

    /// Speed: how hard the model thinks, and the optional second pass. An older server ignores both fields
    /// (its reply leaves them out), so the control shows the server's default and says why.
    @ViewBuilder private func speedSection(_ c: AgentConfig) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Speed", selection: Binding(get: { c.effort }, set: { e in
                    guard e != c.effort else { return }
                    Haptics.selection()
                    save("speed", AgentConfigChange(reasoningEffort: e))
                })) {
                    ForEach(AgentEffort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(alignment: .firstTextBaseline) {
                    Text("Faster is cheaper and usually accurate enough for meals.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if saving == "speed" { ProgressView().controlSize(.small) }
                }
            }
            .padding(.vertical, 4)
            .id("speed")
            Toggle(isOn: Binding(get: { c.verifyMatches ?? false }, set: { on in
                save("verify", AgentConfigChange(verifyMatches: on))
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Double-check matches")
                    Text("Adds a second pass, about 5–15 s slower").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Palette.accent)
        } header: {
            Text("Speed")
        } footer: {
            if !c.hasSpeedSettings {
                Text("Your server doesn't offer these yet; it uses its own speed until it's updated.")
            }
        }
    }

    /// "google/gemini-2.5-flash" → "gemini-2.5-flash".
    static func shortName(_ id: String) -> String { id.split(separator: "/").last.map(String.init) ?? id }

    @ViewBuilder private func testSection(_ c: AgentConfig) -> some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.circle")
                        .symbolEffect(.pulse, options: .repeating, isActive: test == .running)
                    Text(test == .running ? "Testing…" : "Test connection")
                }
                .fontWeight(.medium)
                .foregroundStyle(Palette.accentInk)
            }
            .disabled(test == .running || !c.hasKey || c.model.isEmpty)
            switch test {
            case .ok(let r):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected").font(.body.weight(.semibold))
                        Text([r.model.map(Self.shortName), r.latencyMs.map { "answered in \(Fmt.whole(Double($0))) ms" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.fiber)
                }
                .transition(.opacity)
            case .failed(let f):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).font(.body.weight(.semibold))
                        Text(f.detail ?? f.message).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.over)
                }
                .transition(.opacity)
            default:
                EmptyView()
            }
        } footer: {
            if !c.hasKey || c.model.isEmpty { Text("Add a key and a model to test them.") }
        }
        .animation(.smooth, value: test)
    }

    private func autoLogSection(_ c: AgentConfig) -> some View {
        Section {
            Toggle(isOn: Binding(get: { c.autoLog }, set: { on in save("auto", AgentConfigChange(autoLog: on)) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log automatically")
                    Text("Skip review").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Palette.accent)
        } footer: {
            Text("Meals are logged as soon as they're ready, and the usual Undo stays a tap away. Off, you check every draft first.")
        }
    }

    private func usageSection(_ c: AgentConfig) -> some View {
        Section {
            LabeledContent("Today") { Text(AgentFormat.usage(c.today)).monospacedDigit() }
            LabeledContent("This month") { Text(AgentFormat.usage(c.month)).monospacedDigit() }
        } header: {
            Text("Usage")
        } footer: {
            Text("Up to \(c.maxJobsPerDay) AI logs a day. " + (c.today.cost == nil && c.month.cost == nil
                 ? "Costs show when your provider reports them." : "Costs are as your provider reports them."))
        }
    }

    // MARK: Actions

    private func setProvider(_ p: AgentProvider, _ c: AgentConfig) {
        guard p != provider else { return }
        provider = p
        test = .idle
        Haptics.selection()
        if p == .openRouter {
            customURL = ""
            save("url", AgentConfigChange(baseURL: AgentProvider.openRouterURL))
        }
        // Custom: the field shows; the URL is saved with Save.
    }

    private func saveURL() {
        let url = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true, parsed.host != nil else {
            error = AgentFailure(.server, detail: "Enter the full URL, like https://api.openai.com/v1")
            return
        }
        save("url", AgentConfigChange(baseURL: url))
    }

    /// The key goes into one request body and is cleared from the field straight away.
    private func saveKey() {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyText = ""
        keyFocused = false
        test = .idle
        save("key", AgentConfigChange(apiKey: key)) { replacingKey = false }
    }

    private func save(_ what: String, _ change: AgentConfigChange, then: (() -> Void)? = nil) {
        saving = what
        Task {
            do {
                try await service.update(change)
                Haptics.light()
                then?()
            } catch let f as AgentFailure {
                error = f
                Haptics.warning()
            } catch {
                self.error = AgentFailure(.offline, detail: error.localizedDescription)
            }
            saving = nil
        }
    }

    private func runTest() {
        test = .running
        Task {
            do {
                let r = try await service.test()
                test = r.ok ? .ok(r) : .failed(AgentFailure.classify(message: r.error))
                if r.ok { Haptics.success() } else { Haptics.warning() }
            } catch let f as AgentFailure {
                test = .failed(f)
                Haptics.warning()
            } catch {
                test = .failed(AgentFailure(.offline, detail: error.localizedDescription))
            }
        }
    }
}

/// The Settings row that opens AI logging.
struct AgentSettingsRow: View {
    @State private var service = AgentService.shared
    var body: some View {
        NavRow(title: "AI logging", symbol: "sparkles", tint: Palette.accent,
               value: service.config.map { $0.isConfigured ? ($0.autoLog ? "Auto" : "On") : "Set up" } ?? nil)
    }
}
