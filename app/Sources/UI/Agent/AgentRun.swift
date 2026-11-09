// One AI log from start to finish: send the photo or text, long-poll the job's steps, then a draft to
// review (or, with auto-log, straight to the undo toast), confirm, or a friendly error. The photo stays in
// memory until the run ends, so a retry never needs another shot. A transient poll failure retries the
// same job quietly before saying anything.
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

    // MARK: Running

    func start() {
        task?.cancel()
        phase = .sending
        step = nil
        steps = []
        startedAt = Date()
        task = Task { [weak self] in await self?.run(resume: false) }
    }

    /// After an error: poll the same job again when one exists and the failure was in polling, otherwise
    /// send again (the photo is still here).
    func retry() {
        task?.cancel()
        let resume = jobID != nil
        phase = resume ? .running : .sending
        if !resume { steps = []; step = nil; startedAt = Date() }
        task = Task { [weak self] in await self?.run(resume: resume) }
    }

    /// Cancel (or swipe away): stops polling and deletes the job on the server.
    func cancel() {
        task?.cancel()
        task = nil
        if let id = jobID { Task { await AgentService.shared.cancel(id) } }
        jobID = nil
        if phase != .done { phase = .done }
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
                    Haptics.light()
                    withAnimation(Motion.smooth) { phase = .draft }
                    return
                case .logged:
                    jobID = nil
                    await finishAutoLog(job)
                    return
                case .failed:
                    jobID = nil
                    throw AgentFailure.classify(message: job.error)
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
        Haptics.warning()
        withAnimation(Motion.smooth) { phase = .failed(f) }
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
        Actions.agentLogged(entries)
        phase = .done
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
