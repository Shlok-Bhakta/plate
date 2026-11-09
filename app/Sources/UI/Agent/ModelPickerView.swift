// The model picker: searchable, loaded from GET /v1/agent/models (name, id, and prices per 1M tokens for
// OpenRouter, which lists only models that take images and tools). A custom provider can also type any id.
import SwiftUI

struct ModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var service = AgentService.shared
    @State private var query = ""
    @State private var models: [AgentModel] = []
    @State private var loading = true
    @State private var failure: AgentFailure?
    @State private var typed = ""
    @State private var saving: String?

    private var current: String { service.config?.model ?? "" }
    private var isOpenRouter: Bool { service.config?.provider != .custom }
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var shown: [AgentModel] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return models }
        return models.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    var body: some View {
        List {
            if !isOpenRouter || (!trimmed.isEmpty && shown.isEmpty && !loading) {
                Section {
                    HStack {
                        TextField("Model id, like gpt-4.1-mini", text: $typed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onSubmit { choose(typed) }
                        Button("Use") { choose(typed) }
                            .fontWeight(.semibold)
                            .foregroundStyle(Palette.accentInk)
                            .buttonStyle(.borderless)
                            .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Model id")
                } footer: {
                    Text("Type the id your provider uses if it isn't listed.")
                }
            }
            Section {
                if loading && models.isEmpty {
                    HStack(spacing: 10) { ProgressView(); Text("Loading models…").foregroundStyle(.secondary) }
                } else if let failure, models.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(failure.title).font(.headline)
                        Text(failure.detail ?? failure.message).font(.subheadline).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }.foregroundStyle(Palette.accentInk)
                            .buttonStyle(.borderless).padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                } else if shown.isEmpty {
                    Text(trimmed.isEmpty ? "Your provider didn't list any models." : "No model matches ‘\(trimmed)’.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shown) { m in
                        Button { choose(m.id) } label: { ModelRow(model: m, selected: m.id == current, saving: saving == m.id) }
                            .buttonStyle(.plain)
                    }
                }
            } header: {
                if !models.isEmpty { Text(isOpenRouter ? "\(shown.count) models with images and tools" : "\(shown.count) models") }
            } footer: {
                if isOpenRouter && !models.isEmpty {
                    Text("Only models that accept images and tools are shown. Prices are per million tokens in and out; a photo log uses a few thousand.")
                }
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
        .task { typed = current; await load() }
        .task(id: trimmed) {
            // The server filters too; this refreshes its list for long queries without blocking typing.
            guard !trimmed.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, shown.isEmpty, !loading else { return }
            if let found = try? await service.models(query: trimmed), !found.isEmpty {
                let known = Set(models.map(\.id))
                models += found.filter { !known.contains($0.id) }
            }
        }
    }

    private func load() async {
        loading = true
        failure = nil
        do {
            models = try await service.models(query: "")
        } catch let f as AgentFailure {
            failure = f
        } catch {
            failure = AgentFailure(.offline, detail: error.localizedDescription)
        }
        loading = false
    }

    private func choose(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, saving == nil else { return }
        Haptics.selection()
        saving = id
        Task {
            do {
                try await service.update(AgentConfigChange(model: id))
                saving = nil
                dismiss()
            } catch {
                saving = nil
                failure = (error as? AgentFailure) ?? AgentFailure(.offline)
                Haptics.warning()
            }
        }
    }
}

private struct ModelRow: View {
    var model: AgentModel
    var selected: Bool
    var saving: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.body).foregroundStyle(.primary).lineLimit(1)
                Text(model.id).font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if let price = model.priceLine {
                    HStack(spacing: 6) {
                        Text(price).monospacedDigit()
                        if let ctx = model.contextLength { Text("· \(AgentFormat.tokens(ctx)) context") }
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if saving {
                ProgressView()
            } else if selected {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.accentInk)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
