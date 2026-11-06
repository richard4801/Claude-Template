import Foundation

/// Renders run this much faster than real time in the demo (same as the prototype, the Android app and server/mock).
public let demoSpeed = 24.0

/// Seed data, matching the desktop prototype's state `S` (and the Android app's SampleData).
public enum SampleData {
    public static let demo = "m_demo"
    public static let demoB = "m_demo_b"
    public static let green = "o_green"
    public static let crystal = "o_crystal"
    public static let sampleClip = "clip_sample"
    public static let badClip = "clip_bad"
    /// A neutral look for the demo model (no real person).
    public static let demoLook = "young woman, shoulder-length dark brown hair, brown eyes, warm olive skin"

    /// Neutral demo names (no real person). The stills are drawn as silhouette placeholders.
    public static let demoName = "Demo model"
    public static let demoBName = "Demo model B"

    /// Slot key → the sample image key used for that angle (the app draws silhouette placeholders for these keys).
    public static let slotSample: [(String, String)] = [("face", "face"), ("profile", "profile"), ("front", "g_front"), ("tq", "g_tq"), ("side", "g_side"), ("back", "g_back")]
    public static func sample(for slot: String) -> String { slotSample.first { $0.0 == slot }?.1 ?? (slot == SheetAngle.faceTq.rawValue ? "face_tq" : "face") }

    public static func models() -> [MuseModel] {
        [
            MuseModel(id: demo, name: demoName, age: 24, niche: "Beauty · lifestyle", look: demoLook, neverAdd: ["tattoos", "rings"],
                      slots: slotSample.map { SheetSlot(key: $0.0, image: .asset($0.1)) } + [SheetSlot(key: SheetAngle.faceTq.rawValue)], outfitIds: [green, crystal],
                      personality: "Warm, a little dry, morning-routine energy.",
                      notes: "Demo data: the stills are placeholder silhouettes."),
            MuseModel(id: demoB, name: demoBName, age: 27, niche: "Beauty", slots: SheetAngle.allCases.map { SheetSlot(key: $0.rawValue) }),
        ]
    }

    public static func outfits() -> [Outfit] {
        [
            Outfit(id: green, modelId: demo, name: "Green set", mode: "own", description: "Dark green cropped tee and drawstring shorts",
                   angles: ["g_front", "g_tq", "g_side", "g_back"].map { ImageRef.asset($0) }),
            Outfit(id: crystal, modelId: demo, name: "Crystal dress", mode: "describe", description: "Silver crystal cowl-neck mini dress",
                   angles: ["c_front", "c_tq", "c_face", "c_front"].map { ImageRef.asset($0) }),
        ]
    }

    static func req(_ title: String, _ engine: Engine, _ steps: Int, outfit: String = green) -> JobRequest {
        JobRequest(title: title, modelId: demo, outfitId: outfit, clipId: sampleClip, engine: engine.rawValue, steps: steps, use: ClipUse.full.rawValue)
    }

    public static func jobs(now: Int64) -> [Job] {
        let living = JobRequest.replicate(title: "Living room dance", modelId: demo, outfitId: green, clipId: sampleClip, quality: .standard, clipSeconds: 9.4)
        return [
            Job(id: "j3", title: "Living room dance", modelId: demo, modelName: demoName, outfitId: green, request: living, state: "queued",
                totalSteps: 1, phase: "Queued", secondsLeft: Pricing.totalSeconds(living.spec), totalSeconds: Pricing.totalSeconds(living.spec),
                cost: Pricing.totalCost(living.spec), createdAt: now - 60_000, seed: 48213, thumb: .asset("vid_living")),
            Job(id: "j1", title: "Kick test", modelId: demo, modelName: demoName, outfitId: green, request: req("Kick test", .viggle, 4), state: "done",
                progress: 100, step: 4, totalSteps: 4, phase: "Done", totalSeconds: 95, cost: 0.13, createdAt: now - 7_200_000, finishedAt: now - 7_000_000,
                seed: 7, thumb: .asset("vid_kick")),
            Job(id: "j2", title: "Bathroom trend", modelId: demo, modelName: demoName, outfitId: crystal, request: req("Bathroom trend", .h3, 30, outfit: crystal),
                state: "done", progress: 100, step: 30, totalSteps: 30, phase: "Done", totalSeconds: 2760, cost: 3.05, createdAt: now - 86_400_000,
                finishedAt: now - 83_640_000, seed: 42, thumb: .asset("vid_bath")),
            Job(id: "j0", title: "Mirror selfie", modelId: demo, modelName: demoName, outfitId: green, request: req("Mirror selfie", .h3, 10), state: "failed",
                progress: 18, step: 3, totalSteps: 10, phase: "Failed", totalSeconds: 608, cost: 0.19, refunded: 0.19,
                error: MemberText.wentWrong, createdAt: now - 3_600_000, finishedAt: now - 3_500_000, thumb: .asset("vid_living2")),
        ]
    }

    public static func takes(now: Int64) -> [Take] {
        [
            Take(id: "t_j1", jobId: "j1", title: "Kick test", label: "Fast · beta", engineLabel: "Fast · beta", cost: 0.13, seed: 7, thumb: .asset("vid_kick"), createdAt: now - 7_000_000),
            Take(id: "t_j2", jobId: "j2", title: "Bathroom", label: "Edit", engineLabel: "Edit", cost: 3.05, seed: 42, thumb: .asset("vid_bath"), createdAt: now - 83_640_000),
            Take(id: "t_g1", title: "Living room", label: "Standard", engineLabel: "Standard · 768P", cost: 0.66, seed: 48213, status: "final", thumb: .asset("vid_living"), createdAt: now - 90_000_000),
            Take(id: "t_g4", kind: "shot", title: "Photo · crystal", label: "Photo", cost: 0.02, seed: 48213, thumb: .asset("c_front"), createdAt: now - 96_000_000),
            Take(id: "t_g5", title: "Living room", label: "Edit", engineLabel: "Edit", cost: 0.98, seed: 48213, thumb: .asset("vid_living2"), createdAt: now - 95_000_000),
            Take(id: "t_g6", kind: "shot", title: "Photo · crystal ¾", label: "Photo", cost: 0.02, seed: 48213, thumb: .asset("c_tq"), createdAt: now - 97_000_000),
            Take(id: "t_g7", kind: "shot", title: "Photo · green set", label: "Photo", cost: 0.02, seed: 48213, thumb: .asset("g_front"), createdAt: now - 98_000_000),
        ]
    }

    public static func balance() -> Balance { Balance(balance: 6.07, month: 18.93, videos: 9, today: 0.66) }

    /// The good sample clip and the failing-clip example. Third-party footage is never bundled; the app draws placeholders.
    public static let sampleMeta = ClipMeta(name: "Living-room dance", durationSec: 9.4, width: 1080, height: 1920, fps: 30)
    public static let badMeta = ClipMeta(name: "Mirror trend (download)", durationSec: 22, width: 1080, height: 1920, fps: 30, people: 2, watermark: "TikTok logo")
}

/// Source clip checks. Same rules as the Android app and server/mock. People and watermark detection are server-side (mocked).
public enum ClipRules {
    public static func checks(_ m: ClipMeta) -> [ClipCheck] {
        var out: [ClipCheck] = []
        out.append(m.people == 1 ? ClipCheck(label: "One person in frame", value: "Yes", status: "good")
            : ClipCheck(label: "People in frame", value: "\(m.people) found", status: "bad", fix: "Crop it, or pick a clip with one person"))
        if let w = m.watermark {
            out.append(ClipCheck(label: "Watermark", value: w, status: "bad", fix: "Use the original file, not a download"))
        } else {
            out.append(ClipCheck(label: "Watermark", value: "None", status: "good"))
        }
        let res = "\(m.width)×\(m.height) · \(m.fps)fps"
        if m.height < m.width {
            out.append(ClipCheck(label: res, value: "Landscape", status: "bad", fix: "Use a vertical 9:16 clip"))
        } else if min(m.width, m.height) < 720 {
            out.append(ClipCheck(label: res, value: "Low res", status: "bad", fix: "Use a clip at least 720 wide"))
        } else {
            out.append(ClipCheck(label: res, value: "OK", status: "good"))
        }
        let len = Pricing.trimNum(m.durationSec)
        out.append(m.durationSec <= Pricing.maxClipSec ? ClipCheck(label: "Length \(len)s", value: "Max 15s", status: "good")
            : ClipCheck(label: "Length \(len)s", value: "Over 15s", status: "bad", fix: "Trim to 15s or less"))
        out.append(ClipCheck(label: "Performer talking", value: m.talking ? "Yes" : "No", status: "info"))
        return out
    }
}

/// Where a job is after `elapsed` seconds of (simulated) render time. Edit, each take: getting ready (30 s), rendering, then lip sync
/// (4 min) if on. Fast · beta has no getting-ready part. Phases are member-safe (plans/api.md "App clean-up" §1); `step` is only for
/// progress maths and never shown.
public struct JobProgress: Equatable, Sendable {
    public var progress: Double
    public var take: Int
    public var step: Int
    public var totalSteps: Int
    public var phase: String
    public var secondsLeft: Double
}

public enum JobClock {
    public static func progress(_ req: JobRequest, elapsed: Double) -> JobProgress {
        let spec = req.spec
        if spec.isReplicate { return replicateProgress(spec, elapsed: elapsed) }
        let takes = max(1, spec.takes)
        let total = Pricing.totalSeconds(spec)
        let perTake = total / Double(takes)
        let viggle = spec.engine == .viggle
        let totalSteps = viggle ? 4 : spec.steps
        let startup = viggle ? 0 : Pricing.gpuStartupMin * 60
        let lip = !viggle && spec.lipSync ? Pricing.lipSyncMin * 60 : 0
        let stepsTime = perTake - startup - lip
        let e = min(max(elapsed, 0), total)
        let take = min(takes, Int(floor(e / perTake)) + 1)
        let inTake = e - Double(take - 1) * perTake
        let left = total - e
        let prefix = takes > 1 ? "take \(take)/\(takes) · " : ""
        var step = 0
        var phase = ""
        if e >= total {
            step = totalSteps
            phase = "Done"
        } else if inTake < startup {
            phase = "\(prefix)Getting ready · \(leftText(left))"
        } else if inTake < startup + stepsTime {
            step = min(totalSteps, Int(floor((inTake - startup) / stepsTime * Double(totalSteps))) + 1)
            phase = "\(prefix)Rendering · \(leftText(left))"
        } else {
            step = totalSteps
            phase = "\(prefix)Lip sync · \(leftText(left))"
        }
        return JobProgress(progress: min(100, max(0, e / total * 100)), take: take, step: step, totalSteps: totalSteps, phase: phase, secondsLeft: left)
    }

    /// Replicate (plans/api.md "How a replicate job runs"): totalSteps = takes, step = takes finished;
    /// "Preparing the clip", "Rendering · ~2 min left" ("take 2/3 · …"), "Finishing".
    static func replicateProgress(_ spec: RenderSpec, elapsed: Double) -> JobProgress {
        let takes = max(1, spec.takes)
        let total = Pricing.totalSeconds(spec)
        let perTake = total / Double(takes)
        let e = min(max(elapsed, 0), total)
        let take = min(takes, Int(floor(e / perTake)) + 1)
        let inTake = e - Double(take - 1) * perTake
        let left = total - e
        let prefix = takes > 1 ? "take \(take)/\(takes) · " : ""
        let phase: String
        if e >= total {
            phase = "Done"
        } else if take == 1 && inTake < perTake * 0.1 {
            phase = "Preparing the clip"
        } else if inTake > perTake * 0.9 {
            phase = "\(prefix)Finishing"
        } else {
            phase = "\(prefix)Rendering · \(leftText(left))"
        }
        let step = e >= total ? takes : take - 1
        return JobProgress(progress: min(100, max(0, e / total * 100)), take: take, step: step, totalSteps: takes, phase: phase, secondsLeft: left)
    }

    /// "~6 min left" / "~40s left".
    public static func leftText(_ sec: Double) -> String {
        sec >= 60 ? "~\(Int(ceil(sec / 60))) min left" : "~\(Int(ceil(sec)))s left"
    }

    /// The elapsed (simulated) seconds at which a failing job breaks: step 3 of take 1.
    public static func failAt(_ req: JobRequest) -> Double {
        let spec = req.spec
        let perTake = Pricing.totalSeconds(spec) / Double(max(1, spec.takes))
        if spec.isReplicate { return perTake * 0.5 }
        let viggle = spec.engine == .viggle
        let totalSteps = viggle ? 4 : spec.steps
        let startup = viggle ? 0 : Pricing.gpuStartupMin * 60
        let lip = !viggle && spec.lipSync ? Pricing.lipSyncMin * 60 : 0
        return startup + (perTake - startup - lip) * 2.5 / Double(totalSteps)
    }
}
