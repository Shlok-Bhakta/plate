// The AI log sheet. While the job runs: the photo with a slow glowing ring and the live steps from the
// long-poll, and Cancel (which deletes the job). Then the draft: entry rows (as on Today) with kcal and
// protein, the total, the agent's summary, one big "Log meal". A row opens the amount editor (the Entry
// edit steppers) or removes the item. Errors say what to do, and keep the photo for Try again.
import SwiftUI

struct AgentJobSheet: View {
    var run: AgentRun
    var close: () -> Void
    @State private var detent: PresentationDetent = .medium
    @State private var editing: DraftRow?
    @State private var showSettings = false

    struct DraftRow: Identifiable { let id: Int }
    /// Errors carry up to three buttons; a little taller than medium.
    static let errorDetent = PresentationDetent.fraction(0.62)

    var body: some View {
        NavigationStack {
            Group {
                switch run.phase {
                case .sending, .running:
                    AgentProgressView(run: run, cancel: { run.cancel(); close() })
                case .draft, .logging:
                    AgentDraftView(run: run, editing: $editing, discard: { run.cancel(); close() })
                case .failed(let f):
                    AgentErrorView(run: run, failure: f, openSettings: { showSettings = true }, close: { run.cancel(); close() })
                case .done:
                    Color.clear
                }
            }
            .transition(.opacity)
            .navigationDestination(isPresented: $showSettings) { AgentSettingsView(intro: false) }
        }
        .animation(Motion.smooth, value: run.phase)
        .presentationDetents([.medium, Self.errorDetent, .large], selection: $detent)
        .presentationDragIndicator(run.phase == .draft ? .visible : .hidden)
        .interactiveDismissDisabled(run.phase == .sending || run.phase == .running || run.phase == .logging)
        .sheet(item: $editing) { row in
            DraftItemEditor(run: run, index: row.id)
        }
        .onChange(of: run.phase, initial: true) { _, phase in
            switch phase {
            case .draft: withAnimation(Motion.smooth) { detent = .large }
            case .done: close()
            case .failed: if !run.confirmFailed { withAnimation(Motion.smooth) { detent = Self.errorDetent } }
            default: break
            }
        }
    }
}

// MARK: - Progress

private struct AgentProgressView: View {
    var run: AgentRun
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            ThinkingThumbnail(image: run.thumbnail, text: run.input.trimmedText)
                .padding(.bottom, 26)
            TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(run.startedAt)
                VStack(spacing: 10) {
                    StepList(steps: shownSteps)
                    Text(hint(elapsed))
                        .font(.footnote).foregroundStyle(.tertiary)
                        .contentTransition(.opacity)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            Button(action: cancel) {
                Text("Cancel").font(.body.weight(.semibold)).frame(maxWidth: 220, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.secondary)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, Space.xl)
        .frame(maxWidth: .infinity)
        .background(Palette.background)
        .accessibilityElement(children: .contain)
    }

    /// The last three steps; before the first one arrives, "Sending your photo".
    private var shownSteps: [String] {
        var all = run.steps
        if all.isEmpty || run.phase == .sending { all = [run.isText ? "Sending your note" : "Sending your photo"] }
        return Array(all.suffix(3))
    }

    private func hint(_ elapsed: TimeInterval) -> String {
        switch elapsed {
        case ..<25: "Usually 10 to 20 seconds"
        case ..<60: "Still working. Busy models can take a minute."
        default: "Taking a while. You can cancel and try again."
        }
    }
}

/// The photo (or the note) with a slowly turning accent ring: calm, not a spinner.
private struct ThinkingThumbnail: View {
    var image: UIImage?
    var text: String?
    @State private var spin = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        ZStack {
            shape
                .fill(AngularGradient(colors: [Palette.accent, Palette.fat.opacity(0.9), Palette.accent.opacity(0.15),
                                               Palette.accent], center: .center))
                .frame(width: 136, height: 136)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .mask(shape.frame(width: 136, height: 136))
                .blur(radius: breathe ? 14 : 9)
                .opacity(0.55)
            shape
                .strokeBorder(AngularGradient(colors: [Palette.accent, Palette.accent.opacity(0.1), Palette.fat, Palette.accent],
                                              center: .center, angle: .degrees(spin ? 360 : 0)), lineWidth: 3)
                .frame(width: 132, height: 132)
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Palette.card
                        VStack(spacing: 8) {
                            Image(systemName: "text.bubble.fill").font(.system(size: 22)).foregroundStyle(Palette.accent)
                            if let text {
                                Text(text).font(.footnote.weight(.medium)).multilineTextAlignment(.center)
                                    .lineLimit(3).padding(.horizontal, 10)
                            }
                        }
                    }
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityHidden(true)
    }
}

/// Finished steps get a quiet check; the current one a small spinner.
private struct StepList: View {
    var steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element) { i, step in
                let current = i == steps.count - 1
                HStack(spacing: 10) {
                    ZStack {
                        if current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Palette.fiber.opacity(0.85))
                        }
                    }
                    .frame(width: 18)
                    Text(step)
                        .font(current ? .body.weight(.semibold) : .subheadline)
                        .foregroundStyle(current ? .primary : .secondary)
                        .lineLimit(1)
                }
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .animation(.smooth(duration: 0.5), value: steps)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(steps.last ?? "Working")
    }
}

// MARK: - Draft

private struct AgentDraftView: View {
    var run: AgentRun
    @Binding var editing: AgentJobSheet.DraftRow?
    var discard: () -> Void
    @Environment(Store.self) private var store

    var body: some View {
        let draft = run.draft ?? AgentDraft(items: [], preview: [], summary: "")
        List {
            Section {
                header(draft)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 14, trailing: 4))
                    .listRowBackground(Color.clear)
                PreviewCard(nutrients: draft.totals)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            .listSectionSeparator(.hidden)
            if draft.isEmpty {
                Section {
                    Text("Nothing left to log. Close this, or snap the meal again.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(Array(draft.preview.enumerated()), id: \.element.id) { i, entry in
                        Button { if draft.isEditable { editing = .init(id: i) } } label: {
                            EntryRowLabel(entry: entry, showsProtein: true)
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 20 }
                        .listRowInsets(EdgeInsets(top: 0, leading: Space.l - 4, bottom: 0, trailing: Space.l))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if draft.isEditable {
                                Button(role: .destructive) { run.remove(at: i) } label: { Label("Remove", systemImage: "trash") }
                            }
                        }
                        .accessibilityHint(draft.isEditable ? "Change the amount or remove it" : "")
                    }
                } header: {
                    Text("\(draft.preview.count) item\(draft.preview.count == 1 ? "" : "s")")
                } footer: {
                    Text(draft.isEditable ? "Tap an item to change its amount. Nothing is logged until you tap Log meal." :
                            "Nothing is logged until you tap Log meal.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: discard) { Image(systemName: "xmark") }
                    .tint(.primary)
                    .accessibilityLabel("Discard")
            }
            ToolbarItem(placement: .principal) {
                MealMenu(meal: Binding(get: { run.meal }, set: { run.move(to: $0) }))
            }
        }
        .safeAreaInset(edge: .bottom) { logButton(draft) }
    }

    private func header(_ draft: AgentDraft) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if let image = run.thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 24)).foregroundStyle(Palette.accent)
                    .frame(width: 64, height: 64)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Draft from AI", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.accentInk)
                    .labelStyle(.titleAndIcon)
                Text(draft.summary.isEmpty ? (run.input.trimmedText ?? "Your meal") : draft.summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if run.isEdited {
                    Text("Edited").font(.caption).foregroundStyle(.secondary)
                }
                if let reason = run.autoLogError {
                    Text("Couldn't log this automatically (\(reason)). Check it and tap Log meal.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func logButton(_ draft: AgentDraft) -> some View {
        Button { run.confirm() } label: {
            HStack(spacing: 8) {
                if run.phase == .logging { ProgressView().tint(.white) }
                Text(run.phase == .logging ? "Logging…" : "Log meal · \(Fmt.kcal(draft.kcal)) kcal")
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: draft.kcal))
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .tint(Palette.accent)
        .controlSize(.large)
        .padding(.horizontal, Space.l)
        .padding(.bottom, 8)
        .disabled(draft.isEmpty || run.phase == .logging)
        .animation(.snappy, value: draft.kcal)
    }
}

/// One draft item: the live preview, the Entry edit steppers (servings, and weight when known), Remove.
private struct DraftItemEditor: View {
    var run: AgentRun
    var index: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units

    var body: some View {
        NavigationStack {
            if let entry = run.draft?.preview[safe: index] {
                Form {
                    Section {
                        PreviewCard(nutrients: entry.nutrients)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } header: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name).font(.title3.weight(.bold)).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            let detail = entry.detailLine(units)
                            if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        .textCase(nil)
                        .padding(.bottom, 8)
                    }
                    Section {
                        HStack {
                            Text("Servings")
                            Spacer()
                            ServingStepper(value: entry.servings) { run.setServings($0, at: index) }
                        }
                        if let g = entry.grams, g > 0 {
                            HStack {
                                Text("Weight")
                                Spacer()
                                WeightStepper(grams: g, unit: units.food) { run.setGrams($0, at: index) }
                            }
                        }
                    } footer: {
                        Text("Changes go into the draft. Your meal is logged when you tap Log meal.")
                    }
                    Section {
                        Button(role: .destructive) {
                            dismiss()
                            run.remove(at: index)
                        } label: {
                            Text("Remove from meal").frame(maxWidth: .infinity)
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: { Image(systemName: "checkmark") }
                            .accessibilityLabel("Done")
                    }
                }
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Errors

private struct AgentErrorView: View {
    var run: AgentRun
    var failure: AgentFailure
    var openSettings: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = run.thumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Palette.card
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .saturation(0.6)
                Image(systemName: failure.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color(uiColor: .systemGray), in: Circle())
                    .overlay(Circle().strokeBorder(Palette.background, lineWidth: 3))
                    .offset(x: 10, y: 10)
            }
            .padding(.bottom, 22)
            .accessibilityHidden(true)
            Text(run.confirmFailed ? "Couldn't log your meal" : failure.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(run.confirmFailed ? "Your draft is still here, edits and all. Try again in a moment." : failure.message)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            if let detail = failure.detail, detail.lowercased() != failure.title.lowercased() {
                Text(detail.capitalizedFirst)
                    .font(.footnote).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.top, 8)
            }
            Spacer(minLength: 16)
            VStack(spacing: 10) {
                if failure.needsSettings && !run.confirmFailed {
                    primary("Open AI settings", openSettings)
                    if failure.kind != .noKey { secondary("Try again") { run.retry() } }
                } else if failure.kind != .dailyLimit {
                    primary("Try again") { run.confirmFailed ? run.confirm() : run.retry() }
                }
                if run.confirmFailed {
                    secondary("Back to draft") { run.backToDraft() }
                } else {
                    secondary("Close", close)
                }
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, Space.xl)
        .frame(maxWidth: .infinity)
        .background(Palette.background)
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .tint(Palette.accent)
        .controlSize(.large)
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.secondary)
    }
}
