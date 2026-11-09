// Settings → Apple Health. In builds with HealthSecrets.swift: the state of the HealthKit sync to the
// separate health server (Sources/HealthSync), a Sync now button, and an Activity screen with this run's
// notes and the breadcrumbs of this run and the last. Those views only read HealthSync; they never change
// how or when it syncs. Other builds show the daily totals sent to the food server instead
// (HealthDaysSection). In demo mode they show a fixture.
import HealthKit
import SwiftUI

/// What the Apple Health views show, read from HealthSync or from the demo fixture.
struct HealthSyncState {
    enum Permission { case notAsked, answered, newTypes, unknown }

    var requested: Bool
    var busy: Bool
    var finished: Bool
    var status: String
    var lastSync: Date?
    var lastDailySync: Date?
    var sent: Int
    var runSent: Int
    var typesDone: Int
    var typeCount: Int
    var currentType: String?
    var log: [String]

    @MainActor static func live(_ sync: HealthSync) -> HealthSyncState {
        HealthSyncState(requested: sync.requested, busy: sync.busy, finished: sync.finished, status: sync.status,
                        lastSync: sync.lastSync, lastDailySync: sync.lastDailySync, sent: sync.sent,
                        runSent: sync.runSent, typesDone: sync.typesDone.count, typeCount: HealthSync.sampleTypes.count,
                        currentType: sync.currentType, log: sync.log)
    }

    /// The demo fixture. `-PlateHealth syncing | retry | none` shows the other states.
    @MainActor static var demo: HealthSyncState {
        let now = Days.now()
        let morning = Calendar.current.date(bySettingHour: 7, minute: 42, second: 0, of: now) ?? now
        var state = HealthSyncState(
            requested: true, busy: false, finished: true, status: "Up to date",
            lastSync: now.addingTimeInterval(-4 * 60), lastDailySync: min(morning, now), sent: 3_104_233, runSent: 1_204,
            typesDone: HealthSync.sampleTypes.count, typeCount: HealthSync.sampleTypes.count, currentType: nil,
            log: ["7:42 AM  Watching \(HealthSync.sampleTypes.count) types for new data",
                  "7:42 AM  Previous run ended after: 7:41:58 AM observer fired HKQuantityTypeIdentifierHeartRate error=false"])
        switch UserDefaults.standard.string(forKey: "PlateHealth") {
        case "syncing":
            state.busy = true; state.finished = false; state.status = "Sent 20,000 Heart Rate"
            state.typesDone = 41; state.currentType = "Heart Rate"; state.runSent = 86_400
        case "retry":
            state.status = "2 types will retry"
            state.log.append("7:43 AM  RespiratoryRate: The request timed out., will retry")
            state.log.append("7:43 AM  SleepAnalysis: The request timed out., will retry")
        case "none":
            state = HealthSyncState(requested: false, busy: false, finished: false, status: "Idle", lastSync: nil,
                                    lastDailySync: nil, sent: 0, runSent: 0, typesDone: 0,
                                    typeCount: HealthSync.sampleTypes.count, currentType: nil, log: [])
        default: break
        }
        return state
    }

    static let demoBreadcrumbs = """
        7:42:01 AM launch
        7:42:02 AM registering observers
        7:42:02 AM observers registered
        7:42:02 AM full sync
        7:42:02 AM sync HKQuantityTypeIdentifierStepCount
        7:42:03 AM query HKQuantityTypeIdentifierStepCount: 214 samples
        7:42:03 AM encoded 61873 bytes, sending 6912
        7:42:04 AM query HKQuantityTypeIdentifierStepCount: 0 samples
        """
}

/// Asks HealthKit, without any UI, whether a request for every type would still show the sheet.
/// Apps can't see which read types were allowed, only whether each one was answered.
@MainActor func healthPermission(requested: Bool) async -> HealthSyncState.Permission {
    guard requested else { return .notAsked }
    guard HKHealthStore.isHealthDataAvailable(),
          let status = try? await HKHealthStore().statusForAuthorizationRequest(toShare: [], read: HealthSync.readTypes)
    else { return .unknown }
    switch status {
    case .unnecessary: return .answered
    case .shouldRequest: return .newTypes
    default: return .unknown
    }
}

// MARK: - Section

struct HealthSection: View {
    @Environment(Store.self) private var store
    @Binding var showActivity: Bool

    var body: some View {
        if !BuildFeatures.healthServer {
            HealthDaysSection()
        } else if store.isDemo {
            let state = HealthSyncState.demo
            HealthSectionBody(state: state, permission: state.requested ? .answered : .notAsked,
                              showActivity: $showActivity, syncNow: { Haptics.light() }, allow: { Haptics.light() })
        } else {
            LiveHealthSection(showActivity: $showActivity)
        }
    }
}

private struct LiveHealthSection: View {
    @ObservedObject private var sync = HealthSync.shared
    @Binding var showActivity: Bool
    @State private var permission: HealthSyncState.Permission = .unknown

    var body: some View {
        HealthSectionBody(state: .live(sync), permission: permission, showActivity: $showActivity,
                          syncNow: {
                              sync.syncEverything()
                              Haptics.light()
                          },
                          allow: { Task { await sync.requestAccess() } })
            .task(id: sync.requested) { permission = await healthPermission(requested: sync.requested) }
    }
}

private struct HealthSectionBody: View {
    var state: HealthSyncState
    var permission: HealthSyncState.Permission
    @Binding var showActivity: Bool
    var syncNow: () -> Void
    var allow: () -> Void

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                StatusDot(color: dotColor, pulsing: state.busy)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.headline)
                        Spacer(minLength: 8)
                        if state.requested { LastSyncText(date: state.lastSync, demo: false) }
                    }
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(state.runSent)))
                        .fixedSize(horizontal: false, vertical: true)
                    if state.busy {
                        ProgressView(value: Double(state.typesDone), total: Double(max(state.typeCount, 1)))
                            .tint(Palette.accent)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(.vertical, 4)
            .animation(Motion.smooth, value: state.busy)
            LabeledContent("Permission") {
                Text(permissionText).monospacedDigit()
            }
            LabeledContent("Daily sync") {
                Text(dailyText).monospacedDigit()
            }
            if state.requested {
                Button(action: syncNow) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, options: .repeating, isActive: state.busy)
                        Text(state.busy ? "Syncing…" : "Sync now")
                    }
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.accentInk)
                }
                .disabled(state.busy)
            } else {
                Button(action: allow) {
                    HStack(spacing: 8) {
                        Image(systemName: "heart.text.square")
                        Text("Allow Health access")
                    }
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.accentInk)
                }
            }
            Button { showActivity = true } label: {
                NavRow(title: "Activity", symbol: "list.bullet.rectangle.portrait.fill", tint: Palette.mineral,
                       value: retries > 0 ? "\(retries) to retry" : nil)
            }
            .tint(Color(uiColor: .label))
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Every Health type goes to your health server the first time you unlock after 3 AM, and whenever you open Plate. Health can't be read while the phone is locked.")
        }
    }

    private var retries: Int {
        guard let n = state.status.split(separator: " ").first.flatMap({ Int($0) }), state.status.hasSuffix("will retry") else { return 0 }
        return n
    }

    private var title: String {
        if !state.requested { return "Health access needed" }
        if state.busy { return "Syncing" }
        if state.status == "Up to date" { return "Up to date" }
        if state.finished || state.status != "Idle" { return state.status }
        return "Waiting to sync"
    }

    private var detail: String {
        let all = state.sent.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        if !state.requested { return "Plate sends your Health data to your own health server. Allow access once to start." }
        if state.busy {
            let type = state.currentType.map { " · \($0)" } ?? ""
            return "Type \(min(state.typesDone + 1, state.typeCount)) of \(state.typeCount)\(type)\n\(state.runSent.formatted()) samples this run"
        }
        if state.finished {
            return state.runSent > 0
                ? "Sent \(state.runSent.formatted()) samples this run · \(all) all time"
                : "Nothing new this run, all \(state.typeCount) types checked · \(all) all time"
        }
        return "\(all) samples sent all time"
    }

    private var dotColor: Color {
        if !state.requested { return Color(uiColor: .systemGray) }
        if state.busy { return Color(uiColor: .systemGray) }
        if state.status == "Up to date" { return Palette.fiber }
        if state.status.hasSuffix("will retry") || state.status.hasPrefix("Paused") || state.status.hasPrefix("Phone locked") {
            return Palette.fat
        }
        return Color(uiColor: .systemGray)
    }

    private var permissionText: String {
        switch permission {
        case .notAsked: "Not asked yet"
        case .answered: "Answered for all \(state.typeCount) types"
        case .newTypes: "New types to allow"
        case .unknown: state.requested ? "Asked" : "Not asked yet"
        }
    }

    private var dailyText: String {
        guard let d = state.lastDailySync else { return "Not yet" }
        let time = d.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(d) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday \(time)" }
        return d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

// MARK: - Activity

/// This run's notes (errors and status), then the breadcrumbs of this run and the previous one. The
/// previous run's breadcrumbs are also what launch posts to the health service as `kind = 'diag'`.
struct HealthActivityView: View {
    @Environment(Store.self) private var store

    var body: some View {
        if store.isDemo {
            HealthActivityBody(state: .demo, current: HealthSyncState.demoBreadcrumbs,
                               previous: "7:41:58 AM observer fired HKQuantityTypeIdentifierHeartRate error=false",
                               reload: {}, askAgain: { Haptics.light() })
        } else {
            LiveHealthActivity()
        }
    }
}

private struct LiveHealthActivity: View {
    @ObservedObject private var sync = HealthSync.shared
    @State private var current = ""

    var body: some View {
        HealthActivityBody(state: .live(sync), current: current, previous: AppDelegate.previousRun ?? "",
                           reload: { current = Self.readBreadcrumbs() },
                           askAgain: { Task { await sync.requestAccess() } })
            .task(id: sync.status) { current = Self.readBreadcrumbs() }
    }

    static func readBreadcrumbs() -> String {
        (try? String(contentsOf: Breadcrumbs.url, encoding: .utf8)) ?? ""
    }
}

private struct HealthActivityBody: View {
    var state: HealthSyncState
    var current: String
    var previous: String
    var reload: () -> Void
    var askAgain: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: state.requested ? state.status : "Health access needed")
                LabeledContent("Last upload") {
                    Text(state.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Never").monospacedDigit()
                }
                LabeledContent("Samples sent, all time") {
                    Text(state.sent.formatted()).monospacedDigit()
                }
            }
            Section {
                if state.log.isEmpty {
                    Text("Nothing yet this run.").foregroundStyle(.secondary)
                } else {
                    mono(state.log.reversed().joined(separator: "\n"))
                }
            } header: {
                Text("This run")
            } footer: {
                Text("Newest first. A type that fails is retried on the next sync, from its last confirmed upload.")
            }
            Section {
                mono(tail(current))
            } header: {
                Text("Breadcrumbs")
            } footer: {
                Text("The last 40 steps of this run.")
            }
            if !previous.isEmpty {
                Section {
                    mono(tail(previous))
                } header: {
                    Text("Previous run")
                } footer: {
                    Text("Sent to the health server at launch as a diag row, so a crash leaves a trace.")
                }
            }
            if state.requested {
                Section {
                    Button("Ask for Health access again", action: askAgain)
                        .foregroundStyle(Palette.accentInk)
                } footer: {
                    Text("Health only shows the sheet for types you haven't answered yet.")
                }
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
    }

    private func tail(_ text: String) -> String {
        let lines = text.split(separator: "\n").suffix(40)
        return lines.isEmpty ? "None" : lines.joined(separator: "\n")
    }

    private func mono(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
