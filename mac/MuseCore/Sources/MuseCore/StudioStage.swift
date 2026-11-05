import Foundation

/// Where the video studio's stage is (its right pane, "<MODEL> · <outfit>"): idle shows the target, a render started from the
/// studio for the current clip, model and outfit shows its live state, a finished one plays its takes, a failed one says why.
public enum StagePhase: String, Sendable, Equatable {
    case idle, queued, rendering, ready, failed
}

/// The video studio's live stage (owner request 2026-11-05). Pure: built from the job and take lists the live events keep
/// up to date (`LiveEvents.applyJobs` / `applyTakes`), so it moves idle → queued → rendering → ready / failed by itself.
/// Member-safe wording only: results, time and price, never providers, models or GPUs.
public struct StudioStage: Equatable, Sendable {
    public var phase: StagePhase
    public var jobId: String?
    /// "Waiting to start", "#2 in line · about 9 min", "Rendering · about 2 min", "Ready", or what went wrong.
    public var headline: String
    /// 0…1.
    public var progress: Double
    /// "42%".
    public var percent: String
    /// The render's price ("$0.14").
    public var price: String
    /// Ready: the render's takes, take 1 first (edited versions are not takes of the render).
    public var takes: [Take]
    /// Failed: what went wrong, in member words.
    public var failure: String?

    public init(phase: StagePhase, jobId: String? = nil, headline: String = "", progress: Double = 0, percent: String = "", price: String = "",
                takes: [Take] = [], failure: String? = nil) {
        self.phase = phase
        self.jobId = jobId
        self.headline = headline
        self.progress = progress
        self.percent = percent
        self.price = price
        self.takes = takes
        self.failure = failure
    }

    public static let idle = StudioStage(phase: .idle)

    /// Waiting or rendering: the blurred, animated preview.
    public var isBusy: Bool { phase == .queued || phase == .rendering }

    /// The take to play: the one picked in the take switcher while it's still there, else take 1.
    public func take(_ id: String?) -> Take? { takes.first { $0.id == id } ?? takes.first }

    /// "Take 1 of 2" (nil for a single take).
    public func takeLabel(_ t: Take) -> String? {
        takes.count > 1 ? "Take \(t.index) of \(max(t.of, takes.count))" : nil
    }

    /// The stage for one render (nil = idle).
    public static func of(_ job: Job?, takes: [Take]) -> StudioStage {
        guard let j = job else { return .idle }
        let price = Pricing.money(j.cost)
        let p = min(1, max(0, j.progress / 100))
        if j.isFailed {
            let why = j.failureLine
            return StudioStage(phase: .failed, jobId: j.id, headline: why, progress: p, percent: percentText(p), price: price, failure: why)
        }
        if j.isDone {
            let mine = takes.filter { $0.jobId == j.id && $0.kind == "take" }.sorted { $0.index < $1.index }
            return StudioStage(phase: .ready, jobId: j.id, headline: "Ready", progress: 1, percent: "100%", price: price, takes: mine)
        }
        guard j.isActive else { return .idle }
        // Parked or waiting in line: nothing has rendered yet.
        if j.isQueued || j.isWaiting {
            let pos = j.queuePosition
            let line = (pos.map { $0 > 1 ? "#\($0) in line" : MemberText.waitingToStart } ?? MemberText.waitingToStart) + (pos != nil ? j.timeTail : "")
            return StudioStage(phase: .queued, jobId: j.id, headline: line, progress: 0, percent: "0%", price: price)
        }
        let phase = Job.memberPhase(j.phase)
        // Older servers say they're waiting in the phase only ("Waiting for a GPU" → "Waiting to start").
        if phase.hasSuffix(MemberText.waitingToStart) || phase.range(of: #"#\d+ in line$"#, options: .regularExpression) != nil {
            return StudioStage(phase: .queued, jobId: j.id, headline: phase, progress: p, percent: percentText(p), price: price)
        }
        return StudioStage(phase: .rendering, jobId: j.id, headline: phase + j.timeTail, progress: p, percent: percentText(p), price: price)
    }

    /// The render the stage follows: the newest one started from the studio (`started`, oldest first) that is still for
    /// this clip, model and outfit. Picking another clip, model or outfit puts the stage back to idle (the target);
    /// picking them again brings that render back.
    public static func job(in jobs: [Job], started: [String], clipId: String?, modelId: String?, outfitId: String?) -> Job? {
        for id in started.reversed() {
            guard let j = jobs.first(where: { $0.id == id }) else { continue }
            if let modelId, j.modelId != modelId { continue }
            if let outfitId, j.outfitId != outfitId && j.request.outfitId != outfitId { continue }
            if let clipId, !j.request.clipId.isEmpty, j.request.clipId != clipId { continue }
            return j
        }
        return nil
    }

    /// `job(in:…)` then `of(_:takes:)`.
    public static func resolve(jobs: [Job], takes: [Take], started: [String], clipId: String?, modelId: String?, outfitId: String?) -> StudioStage {
        of(job(in: jobs, started: started, clipId: clipId, modelId: modelId, outfitId: outfitId), takes: takes)
    }

    static func percentText(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }
}

/// Fixed studio wording.
public enum StudioText {
    /// The empty source area, before a clip is uploaded.
    public static let dropTitle = "Drop a clip or choose one"
    public static let dropHint = "Up to 15s works best · 9:16 · one person"

    /// "Never add: tattoos, rings. Removed automatically." under the outfit, or nil when the model has nothing on the list
    /// (the line is hidden then, never "Never add: .").
    public static func neverAdd(_ items: [String]) -> String? {
        let list = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return list.isEmpty ? nil : "Never add: \(list.joined(separator: ", ")). Removed automatically."
    }
}
