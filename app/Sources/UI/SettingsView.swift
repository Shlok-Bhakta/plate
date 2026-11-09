// DESIGN 4.10 Settings, pushed from the gear in Today: the server and sync status card (with Change server
// and Sign out), Apple Health
// (Settings/HealthSection.swift), App Icon (Settings/AppIconSection.swift), Units, Reminders
// (Settings/RemindersSection.swift), Goals (mode,
// plan, kcal and macro targets with auto/override badges and inline editors, water, micronutrients,
// meal split, limits), "How your goal is set" from `goals.basis`, and About. Goal writes go through
// Store.updateGoals; the server recomputes targets and the app shows "Recalculating…" until they sync.
import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.units) private var units
    @State private var expanded: String?
    @State private var showMicros = false
    @State private var showSplit = false
    @State private var showLimits = false
    @State private var showHealthActivity = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ServerSection()
                HealthSection(showActivity: $showHealthActivity).id("health")
                AppIconSection().id("appicon")
                UnitsSection().id("units")
                RemindersSection().id("reminders")
                if let g = store.goals {
                    goalsSection(g)
                    BasisSection(goals: g).id("basis")
                } else {
                    Section("Goals") {
                        Text("Your goals arrive with the first sync from your server.").foregroundStyle(.secondary)
                    }
                }
                AboutSection().id("about")
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $showMicros) { MicronutrientTargetsView() }
            .navigationDestination(isPresented: $showSplit) { MealSplitView() }
            .navigationDestination(isPresented: $showLimits) { LimitsView() }
            .navigationDestination(isPresented: $showHealthActivity) { HealthActivityView() }
            .onChange(of: store.goals?.version) { _, v in GoalsRecalc.shared.observe(v) }
            .task {
                // Debug: -PlateScreen goals | basis | appicon | units | reminders | about | health | micros | mealsplit | limits | healthlog
                switch UserDefaults.standard.string(forKey: "PlateScreen") {
                case "micros": showMicros = true
                case "mealsplit": showSplit = true
                case "limits": showLimits = true
                case "healthlog": showHealthActivity = true
                case let target? where ["goals", "basis", "appicon", "units", "reminders", "about", "health"].contains(target):
                    try? await Task.sleep(for: .milliseconds(500))
                    proxy.scrollTo(target, anchor: ["health", "units", "appicon"].contains(target) ? .center : .top)
                default: break
                }
                if let key = UserDefaults.standard.string(forKey: "PlateGoalEdit") { expanded = key }
            }
        }
    }

    @ViewBuilder private func goalsSection(_ g: Goals) -> some View {
        Section {
            LabeledContent("Mode") {
                Picker("Mode", selection: Binding(get: { g.mode }, set: { setMode($0) })) {
                    Text("Auto").tag("auto")
                    Text("Manual").tag("manual")
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Plan") {
                    Picker("Plan", selection: Binding(get: { g.plan }, set: { setPlan($0) })) {
                        Text("Cut").tag("cut")
                        Text("Maintain").tag("maintain")
                        Text("Bulk").tag("bulk")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Text(planCaption(g)).font(.footnote).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .disabled(g.mode == "manual")
            .opacity(g.mode == "manual" ? 0.5 : 1)
        } header: {
            Text("Goals")
        } footer: {
            Text(g.mode == "auto"
                 ? "Auto recalculates your targets from Apple Health every 30 minutes. Overrides always win."
                 : "Manual keeps your targets exactly as you set them.")
        }
        .id("goals")

        Section {
            ForEach(["kcal", "protein", "carbs", "fat", "fiber", "water"], id: \.self) { key in
                GoalTargetRow(key: key, expanded: $expanded)
            }
        } header: {
            Text("Daily targets")
        } footer: {
            Text("Tap a target to change it.")
        }

        Section {
            Button { showMicros = true } label: {
                NavRow(title: "Micronutrients", symbol: "leaf.fill", tint: Palette.vitamin,
                       value: "\(microCount(g)) targets")
            }
            Button { showSplit = true } label: {
                NavRow(title: "Meal split", symbol: "chart.pie.fill", tint: Palette.accent,
                       value: Meal.allCases.map { Fmt.whole((g.mealSplit[$0.rawValue] ?? 0) * 100) }.joined(separator: " · "))
            }
            Button { showLimits = true } label: {
                NavRow(title: "Limits", symbol: "gauge.with.dots.needle.67percent", tint: Palette.mineral,
                       value: "\(g.limits.count)")
            }
        }
    }

    private func microCount(_ g: Goals) -> Int {
        Nutrients.all.filter { !["kcal", "protein", "carbs", "fat", "fiber", "water"].contains($0.key) && g.target($0.key) != nil }.count
    }

    private func planCaption(_ g: Goals) -> String {
        switch g.plan {
        case "cut": "TDEE − 20% · protein \(Fmt.perBodyWeight(2.0, units))"
        case "bulk": "TDEE + 10% · protein \(Fmt.perBodyWeight(1.8, units))"
        default: "Eat what you burn · protein \(Fmt.perBodyWeight(1.8, units))"
        }
    }

    private func setMode(_ mode: String) {
        guard mode != store.goals?.mode else { return }
        store.updateGoals { g in
            if mode == "manual" { g.targets = g.effectiveTargets }
            g.mode = mode
        }
        GoalsRecalc.shared.begin(store)
        Haptics.selection()
    }

    private func setPlan(_ plan: String) {
        guard plan != store.goals?.plan else { return }
        store.updateGoals { $0.plan = plan }
        GoalsRecalc.shared.begin(store)
        Haptics.selection()
    }
}

/// A Settings-style navigation row: a 29 pt rounded icon tile, the title, a trailing value and a chevron.
struct NavRow: View {
    var title: String
    var symbol: String
    var tint: Color
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint.gradient, in: .rect(cornerRadius: 7, style: .continuous))
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let value {
                Text(value).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Server

private struct ServerSection: View {
    @Environment(Store.self) private var store
    @State private var syncing = false
    @State private var changing = false
    @State private var confirmSignOut = false

    private var host: String { store.serverLabel }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                StatusDot(color: dotColor, pulsing: syncing || isSyncingState)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.headline)
                        Spacer(minLength: 8)
                        LastSyncText(date: store.lastSyncAt, demo: store.isDemo)
                    }
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            LabeledContent("Server") {
                Text(host).font(.footnote.monospaced()).lineLimit(1).minimumScaleFactor(0.8)
            }
            LabeledContent("Sync version") {
                Text(store.version.formatted()).font(.body.monospacedDigit())
            }
            LabeledContent("Pending changes") {
                Text("\(store.pendingCount)").monospacedDigit()
                    .contentTransition(.numericText(value: Double(store.pendingCount)))
            }
            Button {
                syncing = true
                Task {
                    await store.syncNow()
                    withAnimation(.smooth) { syncing = false }
                    Haptics.light()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeating, isActive: syncing)
                    Text(syncing ? "Syncing…" : "Sync now")
                }
                .fontWeight(.medium)
                .foregroundStyle(Palette.accentInk)
            }
            .disabled(syncing)
            Button { changing = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                    Text("Change server")
                }
                .fontWeight(.medium)
                .foregroundStyle(Palette.accentInk)
            }
            Button(role: .destructive) { confirmSignOut = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Sign out")
                }
                .fontWeight(.medium)
                .foregroundStyle(Palette.overInk)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Your log lives on your server. Signing out removes the token and this phone's copy; the log stays on the server.")
        }
        .sheet(isPresented: $changing) {
            NavigationStack { ServerConnectView(mode: .change) }
        }
        .confirmationDialog("Sign out of \(host)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                store.signOut()
                Haptics.light()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(signOutMessage)
        }
    }

    private var signOutMessage: String {
        let pending = store.pendingCount
        let lost = pending == 0 ? "" : " \(pending) change\(pending == 1 ? " that hasn't" : "s that haven't") synced will be lost."
        return "This removes the token and this phone's copy of your log.\(lost) Everything on the server stays."
    }

    private var isSyncingState: Bool {
        if case .syncing = store.connection { return true }
        return false
    }

    private var title: String {
        switch store.connection {
        case .synced: "Connected"
        case .syncing: "Syncing"
        case .offline: "Offline"
        case .authFailed: "Sign-in failed"
        case .demo: "Demo data"
        }
    }

    private var detail: String {
        switch store.connection {
        case .synced: "Live: the agent's logs appear here within a second."
        case .syncing(let n): n > 0 ? "Sending \(n) change\(n == 1 ? "" : "s") to your server." : "Catching up with your server."
        case .offline: "Changes are saved on this phone and will sync when your server is reachable."
        case .authFailed: "The server didn't accept this phone's token. Make a new one with food token new on the server, then use Change server."
        case .demo: "Sample meals, foods and goals on this phone. Nothing is sent to the server."
        }
    }

    private var dotColor: Color {
        switch store.connection {
        case .synced: Palette.fiber
        case .demo: Palette.accent
        case .syncing, .offline: Color(uiColor: .systemGray)
        case .authFailed: Palette.over
        }
    }
}

/// A 10 pt status dot with a soft halo; the halo breathes while syncing.
struct StatusDot: View {
    var color: Color
    var pulsing: Bool
    @State private var breathe = false

    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .background {
                Circle().fill(color.opacity(0.25))
                    .frame(width: 20, height: 20)
                    .scaleEffect(pulsing && breathe ? 1.25 : 1)
                    .opacity(pulsing && breathe ? 0.3 : 1)
            }
            .frame(width: 20, height: 20)
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { breathe = true }
            }
            .accessibilityHidden(true)
    }
}

/// "synced 3 s ago", ticking each second.
struct LastSyncText: View {
    var date: Date?
    var demo: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(now: context.date))
                .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func label(now: Date) -> String {
        guard let date else { return demo ? "local only" : "not yet synced" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<5: return "synced just now"
        case ..<60: return "synced \(s) s ago"
        case ..<3600: return "synced \(s / 60) min ago"
        default: return "synced \(date.formatted(date: .omitted, time: .shortened))"
        }
    }
}

// MARK: - Basis

/// "How your goal is set": the auto basis in plain language and as a small aligned equation.
private struct BasisSection: View {
    var goals: Goals
    @Environment(\.units) private var units

    var body: some View {
        if let b = goals.basis, b.bmr != nil || b.tdee != nil || b.note != nil {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(summary(b)).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if b.bmr != nil || b.tdee != nil { equation(b) }
                }
                .padding(.vertical, 6)
            } header: {
                Text("How your goal is set")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let line = updatedLine(b) { Text(line) }
                    if let note = b.note { Text(note.capitalizedFirst + (note.hasSuffix(".") ? "" : ".")) }
                }
            }
        }
    }

    private func summary(_ b: GoalBasis) -> String {
        if goals.mode == "manual" {
            return "Manual mode keeps your own targets. This is the estimate auto mode would start from."
        }
        if b.tdee == nil { return "Plate needs your weight, height and age from Apple Health to estimate what you burn." }
        let active = b.activeKcalAvg14 != nil ? "plus what your Watch measured you burning on the move" : "times 1.35 for a typical day's movement"
        return "Your calories adapt to you: what your body burns at rest, \(active), then your plan."
    }

    private func equation(_ b: GoalBasis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let bmr = b.bmr {
                line("", "Resting (BMR)", bmr, detail: bmrDetail(b))
            }
            if let active = b.activeKcalAvg14 {
                let days = b.extra["active_days"]?.double.map { " over \(Fmt.whole($0)) days" } ?? ""
                line("+", "Active energy", active, detail: "Daily average from Apple Watch\(days)")
            } else if b.bmr != nil, b.tdee != nil {
                line("×", "Typical movement", nil, detail: "Until there are 5 days of Watch data", raw: "1.35")
            }
            if let tdee = b.tdee {
                Divider()
                line("=", "You burn (TDEE)", tdee, detail: nil, bold: true)
                if let kcal = goals.kcal {
                    line(planSymbol, planTitle, kcal, detail: goalDetail, bold: true, accent: true)
                }
            }
        }
    }

    private var planSymbol: String { goals.plan == "maintain" ? "→" : goals.plan == "cut" ? "−" : "+" }
    private var planTitle: String {
        switch goals.plan {
        case "cut": "Cut, 20% less"
        case "bulk": "Bulk, 10% more"
        default: "Maintain"
        }
    }
    private var goalDetail: String? {
        if goals.overrides["kcal"] != nil { return "Your override replaces the estimate" }
        return "Your daily calorie goal, rounded to 10"
    }

    private func bmrDetail(_ b: GoalBasis) -> String {
        var parts = ["Mifflin–St Jeor"]
        if let w = b.weightKg { parts.append(Fmt.bodyWeightShort(w, units)) }
        if let h = b.heightCm { parts.append(Fmt.height(h, units)) }
        if let a = b.age { parts.append("\(Fmt.whole(a)) y") }
        if let s = b.sex { parts.append(s) }
        return parts.joined(separator: " · ")
    }

    private func line(_ op: String, _ title: String, _ value: Double?, detail: String?, raw: String? = nil,
                      bold: Bool = false, accent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(op).numberFont(17, .semibold, relativeTo: .body).foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(bold ? .body.weight(.semibold) : .body)
                    Spacer(minLength: 8)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(raw ?? Fmt.kcal(value))
                            .numberFont(17, bold ? .semibold : .regular, relativeTo: .body)
                            .foregroundStyle(accent ? Palette.accentInk : .primary)
                        if raw == nil { Text("kcal").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func updatedLine(_ b: GoalBasis) -> String? {
        var parts: [String] = []
        if let at = b.computedAt, at > 0 {
            let date = Date(timeIntervalSince1970: Double(at) / 1000)
            parts.append("Updated \(date.formatted(.relative(presentation: .named)))")
        }
        if let day = b.extra["weight_day"]?.string { parts.append("weight from \(Days.title(day).replacingOccurrences(of: "Today", with: "today").replacingOccurrences(of: "Yesterday", with: "yesterday"))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - About

private struct AboutSection: View {
    @Environment(Store.self) private var store
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }
    private var tokenSet: Bool { store.isDemo || store.api != nil }
    private var zoneSource: String {
        _ = store.zoneChanges
        if store.isDemo { return "This phone's (demo data)" }
        return Days.hasServerZone() ? "From your server" : "This phone's, until the first sync"
    }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                AppIconImage(icon: AppIconStore.shared.current, size: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plate").font(.title3.weight(.semibold))
                    Text(version).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    Text("Your food log, on your own server").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            LabeledContent("Token") {
                Label(tokenSet ? "Token set" : "Missing", systemImage: tokenSet ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .labelStyle(TrailingIconLabelStyle(tint: tokenSet ? Palette.fiber : Palette.over))
            }
            LabeledContent {
                Text(Days.zone.identifier)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time zone")
                    Text(zoneSource).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("About")
        } footer: {
            Text("Days follow your server's time zone, so this app, the server and its command line agree on what \"today\" is. Anything that can run the food command on your server, from you to an AI agent, logs to the same place; this app is the fast place to look, and to log by hand.")
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.foregroundStyle(tint).imageScale(.small)
        }
    }
}
