// One AI log from start to finish: send the photo or text, long-poll the job's steps, then a draft to
// review (or, with auto-log, straight to the undo toast), confirm, or a friendly error. The photo stays in
// memory until the run ends, so a retry never needs another shot. A transient poll failure retries the
// same job quietly before saying anything.
//
// A run lives in AgentCenter, not in its sheet: swiping the sheet away (or Hide) keeps it polling, and
// AgentCenter decides what to show when it finishes (the sheet again, a notification, the undo toast).
// Only Cancel, Discard and Close end it; Cancel deletes the job on the server.
import Observation
import SwiftUI
import UIKit

@Observable
@MainActor
final class AgentRun: Identifiable {
    enum Phase: Equatable {
        case sending
        case running
        case draft
        case logging
        case failed(AgentFailure)
        case done
    }

    let id = UUID()
    /// What was sent: the prepared JPEG, the note, barcodes, meal and day.
    private(set) var input: AgentJobInput
    /// The photo as taken, for the thumbnail (the upload is the smaller re-encoded copy).
    let thumbnail: UIImage?
    private(set) var phase: Phase = .sending
    private(set) var step: String?
    /// Every step so far, oldest first (the sheet shows the last few).
    private(set) var steps: [String] = []
    private(set) var draft: AgentDraft?
    /// The draft as the agent proposed it; confirm sends items only when they differ.
    private(set) var original: AgentDraft?
    private(set) var startedAt = Date()
    /// The elapsed time the sheet and the pill show: from Send, corrected by the server's `elapsed_ms`.
    private(set) var clock = AgentClock()
    /// Swiped away or hidden: it keeps running and AgentCenter shows the result.
    var isHidden = false
    /// The server reported the job cancelled (from another device, or a DELETE that raced a poll).
    private(set) var cancelledRemotely = false
    /// Set when the run logged entries (the sheet closes and the toast shows).
    private(set) var logged: [Entry] = []
    /// Auto-log was on but its confirm failed: the draft is shown with this reason.
    private(set) var autoLogError: String?
    /// The draft is still here, but logging it failed (Try again confirms again).
    private(set) var confirmFailed = false

    @ObservationIgnored private var jobID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var service: AgentService { .shared }

    init(input: AgentJobInput, thumbnail: UIImage?) {
        self.input = input
        self.thumbnail = thumbnail
    }

    var isText: Bool { input.image == nil }
    var meal: Meal { draft?.preview.first?.meal ?? input.meal }
    var isEdited: Bool { draft != original }

    /// Where the run stands, for AgentCenter and the pill.
    var state: AgentRunState {
        switch phase {
        case .sending, .running: return .running
        case .draft, .logging: return .draft(kcal: draft?.kcal ?? 0)
        case .failed(let f): return confirmFailed ? .draft(kcal: draft?.kcal ?? 0) : .failed(f.title)
        case .done:
            if !logged.isEmpty { return .logged(kcal: logged.compactMap(\.kcal).reduce(0, +)) }
            return cancelledRemotely ? .cancelled : .done
        }
    }

    // MARK: Running

    func start() {
        task?.cancel()
        phase = .sending
        step = nil
        steps = []
        startedAt = Date()
        clock = AgentClock(start: startedAt)
        AgentCenter.shared.track(self)
        task = Task { [weak self] in await self?.run(resume: false) }
    }

    /// After an error: poll the same job again when one exists and the failure was in polling, otherwise
    /// send again (the photo is still here).
    func retry() {
        task?.cancel()
        let resume = jobID != nil
        phase = resume ? .running : .sending
        if !resume { steps = []; step = nil; startedAt = Date(); clock = AgentClock(start: startedAt) }
        AgentCenter.shared.track(self)
        task = Task { [weak self] in await self?.run(resume: resume) }
    }

    /// Cancel, Discard or Close: stops polling and deletes the job on the server (which stops it).
    func cancel() {
        task?.cancel()
        task = nil
        if let id = jobID { Task { await AgentService.shared.cancel(id) } }
        jobID = nil
        if phase != .done { phase = .done }
        AgentCenter.shared.ended(self)
    }

    private func run(resume: Bool) async {
        do {
            if !resume || jobID == nil {
                phase = .sending
                jobID = try await service.start(input)
            }
            guard let id = jobID else { return }
            phase = .running
            var transient = 0
            while !Task.isCancelled {
                let job: AgentJob
                do {
                    job = try await service.poll(id)
                    transient = 0
                } catch let f as AgentFailure where f.kind == .offline || f.kind == .timeout {
                    // A dropped long-poll: the job keeps running on the server; try again a few times.
                    transient += 1
                    if transient > 3 { throw f }
                    try await Task.sleep(for: .seconds(Double(transient) * 1.5))
                    continue
                }
                if Task.isCancelled { return }
                if let ms = job.elapsedMs { clock.correct(elapsedMs: ms, at: Date()) }
                if let s = job.step, s != step {
                    withAnimation(.smooth(duration: 0.5)) {
                        step = s
                        steps.append(s)
                    }
                }
                switch job.status {
                case .running:
                    continue
                case .draft:
                    guard let d = job.draft, !d.isEmpty else {
                        throw AgentFailure(.server, detail: job.error ?? "The model didn't find any food")
                    }
                    draft = d
                    original = d
                    autoLogError = job.error
                    if !isHidden { Haptics.light() }
                    withAnimation(Motion.smooth) { phase = .draft }
                    AgentCenter.shared.finished(self)
                    return
                case .logged:
                    jobID = nil
                    await finishAutoLog(job)
                    return
                case .failed:
                    jobID = nil
                    throw AgentFailure.classify(message: job.error)
                case .cancelled:
                    // Stopped on the server (another device, or our own DELETE racing this poll): end quietly.
                    jobID = nil
                    cancelledRemotely = true
                    withAnimation(Motion.smooth) { phase = .done }
                    AgentCenter.shared.finished(self)
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch let f as AgentFailure {
            if f.kind == .server, f.detail?.lowercased().contains("expire") == true { jobID = nil }
            fail(f)
        } catch {
            fail(AgentFailure(.offline, detail: error.localizedDescription))
        }
    }

    private func fail(_ f: AgentFailure) {
        guard !Task.isCancelled else { return }
        // A job that failed on the server can't be polled again; a retry sends it again.
        if !f.canRetry || f.kind == .server { jobID = nil }
        if !isHidden { Haptics.warning() }
        withAnimation(Motion.smooth) { phase = .failed(f) }
        AgentCenter.shared.finished(self)
    }

    private func finishAutoLog(_ job: AgentJob) async {
        let store = Store.shared
        var entries = store.ingestAgentEntries(job.entries)
        if entries.isEmpty {
            // The reply didn't list the entries: they arrive with the next sync.
            await store.syncNow()
            entries = store.agentEntries(day: input.day, since: Int(startedAt.timeIntervalSince1970 * 1000) - 60_000)
        }
        if entries.isEmpty, let d = job.draft { entries = d.preview }
        logged = entries
        // Hidden: AgentCenter shows the toast now, or a notification and the toast on the next open.
        if !isHidden { Actions.agentLogged(entries) }
        phase = .done
        AgentCenter.shared.finished(self)
    }

    // MARK: Draft

    func setServings(_ servings: Double, at index: Int) {
        guard let next = draft?.settingServings(servings, at: index) else { return }
        draft = next
    }

    func setGrams(_ grams: Double, at index: Int) {
        guard let next = draft?.settingGrams(grams, at: index) else { return }
        draft = next
    }

    func remove(at index: Int) {
        guard let d = draft else { return }
        withAnimation(.smooth) { draft = d.removing(index) }
        Haptics.light()
    }

    func move(to meal: Meal) {
        guard let d = draft else { return }
        draft = d.moving(to: meal)
        input.meal = meal
    }

    /// "Log meal": confirms with the edited items (or none, so the server logs its own draft).
    func confirm() {
        guard let d = draft, !d.isEmpty, let id = jobID else { return }
        phase = .logging
        confirmFailed = false
        let items = isEdited && d.isEditable ? d.confirmItems : nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await service.confirm(id, items: items, draft: d)
                jobID = nil
                let live = Store.shared.ingestAgentEntries(entries)
                logged = live.isEmpty ? entries : live
                Actions.agentLogged(logged)
                phase = .done
                AgentCenter.shared.ended(self)
            } catch is CancellationError {
                return
            } catch let f as AgentFailure {
                Haptics.warning()
                // The draft stays; logging can be tried again.
                confirmFailed = true
                withAnimation(Motion.smooth) { self.phase = .failed(f) }
            } catch {
                confirmFailed = true
                withAnimation(Motion.smooth) { self.phase = .failed(AgentFailure(.offline, detail: error.localizedDescription)) }
            }
        }
    }

    /// After a failed confirm, back to the draft that's still here.
    func backToDraft() {
        guard draft != nil else { return }
        confirmFailed = false
        withAnimation(Motion.smooth) { phase = .draft }
    }

    // MARK: Debug

    /// `-PlateScreen agentdraft`: a run that starts on its draft.
    static func debugDraft(meal: Meal, day: String, photo: UIImage?) -> AgentRun {
        let run = AgentRun(input: AgentJobInput(image: photo == nil ? nil : Data([0]), text: nil, meal: meal, day: day), thumbnail: photo)
        let d = DemoAgent.draft(text: nil, hasPhoto: photo != nil, meal: meal, day: day)
        run.draft = d
        run.original = d
        run.jobID = "debug"
        run.steps = DemoAgent.steps
        run.step = DemoAgent.steps.last
        run.phase = .draft
        return run
    }
}
