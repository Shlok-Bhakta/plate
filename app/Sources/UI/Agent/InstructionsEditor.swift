// Settings → AI logging → Instructions: the agent's system prompt, editable. It opens on what the agent
// uses now (your own text, or the server's default), with a Default/Custom badge, Save (PUT
// system_prompt), Reset to default (with a confirm), a 32 KB cap with a counter near it, and a guard
// against leaving with unsaved changes. Presented full screen from Settings → AI logging.
import SwiftUI

struct InstructionsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var service = AgentService.shared
    @State private var text = ""
    /// What the editor opened with (or last saved), to tell whether there are changes.
    @State private var baseline = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var failure: AgentFailure?
    @State private var aboutExpanded = true
    @State private var confirmReset = false
    @State private var confirmLeave = false
    @FocusState private var focused: Bool

    private var limit: Int { AgentConfig.promptLimit }
    private var bytes: Int { text.utf8.count }
    private var dirty: Bool { loaded && text != baseline }
    private var defaultText: String { service.config?.defaultSystemPrompt ?? "" }
    /// What would be stored if saved now: matching the default text means "use the default".
    private var isDefault: Bool {
        dirty ? text == defaultText : (service.config?.usesDefaultPrompt ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            about
            Divider()
            editor
        }
        .background(Palette.background)
        .navigationTitle("Instructions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { if dirty { confirmLeave = true } else { dismiss() } } label: { Image(systemName: "xmark") }
                    .tint(.primary)
                    .accessibilityLabel("Close")
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Instructions").font(.headline)
                    badge
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { confirmReset = true } label: {
                        Label("Reset to default", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(service.config?.usesDefaultPrompt == true && text == defaultText)
                } label: { Image(systemName: "ellipsis") }
                .tint(.primary)
                .accessibilityLabel("More")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                }
                .disabled(!dirty || saving || bytes > limit || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .interactiveDismissDisabled(dirty)

        .confirmationDialog("Reset to the default instructions?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to default", role: .destructive, action: reset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your own instructions are replaced by the built-in ones, which follow Plate's updates.")
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure?.detail ?? failure?.message ?? "")
        }
        .task {
            if service.config?.defaultSystemPrompt == nil { await service.refresh() }
            open()
        }
    }

    private var badge: some View {
        Text(isDefault ? "Using default" : "Custom")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isDefault ? Color.secondary : Palette.accentInk)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .background(isDefault ? Palette.chip : Palette.accent.opacity(0.15), in: Capsule())
            .contentTransition(.opacity)
            .animation(.snappy, value: isDefault)
    }

    private var about: some View {
        DisclosureGroup(isExpanded: $aboutExpanded) {
            Text("Plate always adds today's date, the meal, what's left today and your note, and gives the agent only food tools: search, barcode, your usual foods, today, goals, and a draft it can't log without you.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label("What the agent gets", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .tint(.secondary)
        .padding(.horizontal, Space.l + 4)
        .padding(.vertical, 12)
        .background(Palette.card)
    }

    private var editor: some View {
        ZStack(alignment: .bottomTrailing) {
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, Space.l - 4)
                .padding(.top, 6)
                .focused($focused)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .disabled(!loaded)
                .overlay {
                    if !loaded { ProgressView() }
                }
            if bytes > limit * 8 / 10 {
                Text("\(AgentFormat.bytes(bytes)) of \(AgentFormat.bytes(limit))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(bytes > limit ? Palette.overInk : .secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .background(Palette.card)
        .animation(.smooth, value: bytes > limit * 8 / 10)
    }

    private func open() {
        guard let c = service.config else { return }
        text = c.effectivePrompt
        baseline = text
        loaded = true
        if UserDefaults.standard.bool(forKey: "PlateInstructionsCollapsed") { aboutExpanded = false }
    }

    private func save() {
        guard bytes <= limit else { return }
        // Saving the default text unchanged keeps "using default", so later server updates still apply.
        let value: String? = text == defaultText ? nil : text
        put(value)
    }

    private func reset() { put(nil) }

    private func put(_ value: String?) {
        saving = true
        focused = false
        Task {
            do {
                let c = try await service.update(AgentConfigChange(systemPrompt: .some(value)))
                text = c.effectivePrompt.isEmpty ? (value ?? defaultText) : c.effectivePrompt
                baseline = text
                Haptics.success()
                Toasts.shared.message(value == nil ? "Using the default instructions" : "Instructions saved")
            } catch let f as AgentFailure {
                failure = f
                Haptics.warning()
            } catch {
                failure = AgentFailure(.offline, detail: error.localizedDescription)
            }
            saving = false
        }
    }
}
