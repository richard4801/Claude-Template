import Foundation

/// Demo mode's learning editor data: the demo studio's playbook, lessons, corrections, library and gaps. The numbers are
/// illustrative; "Summer cut" is Recreate's demo reference (workstream 1's fixture), so "Use in Recreate" opens it.
struct LearnDemo {
    let rules: [LearnRule]
    let lessons: [LearnLesson]
    let corrections: [LearnCorrection]
    let recipes: [LearnRecipe]
    let gaps: [LearnGap]

    static let hour: Int64 = 3_600_000
    static let day: Int64 = 24 * hour

    init(now: Int64) {
        func ago(_ ms: Int64) -> Int64 { now - ms }
        let D = Self.day, H = Self.hour
        func corrections(_ n: Int, from: Int, _ note: String, every: Int64) -> [LearnEvidence] {
            (0..<n).map { LearnEvidence(kind: "correction", id: String(from + $0), note: note, at: ago(Int64($0 + 1) * every)) }
        }
        rules = [
            LearnRule(id: "rule_1", text: "Keep captions in the middle third of the frame, never over her face or the product.", area: "captions", source: "owner",
                      pinned: true, createdAt: ago(9 * D), updatedAt: ago(9 * D)),
            LearnRule(id: "rule_2", text: "On the hook line, make the first caption bigger and hold it half a beat longer than the rest, then drop to the normal size. "
                      + "Posts that did this kept people watching past the first two seconds; the ones that opened on small captions lost most viewers before the first cut.",
                      area: "captions", source: "learned",
                      evidence: [LearnEvidence(kind: "post", id: "p1", note: "1.2k views, 42% completion", at: ago(6 * D)),
                                 LearnEvidence(kind: "post", id: "p2", note: "860 views, 38% completion", at: ago(3 * D))],
                      createdAt: ago(6 * D), updatedAt: ago(6 * D)),
            LearnRule(id: "rule_3", text: "Use word pop captions on talking clips, two or three words at a time.", area: "captions", source: "claude",
                      evidence: corrections(3, from: 11, "Moved Claude's captions", every: D), createdAt: ago(4 * D), updatedAt: ago(4 * D)),
            LearnRule(id: "rule_4", text: "The first cut lands within 1.5 s. No opening shot runs longer than that.", area: "pacing", source: "owner",
                      pinned: true, createdAt: ago(8 * D), updatedAt: ago(8 * D)),
            LearnRule(id: "rule_5", text: "On calm songs, cut once per bar, not on every beat.", area: "pacing", source: "claude",
                      evidence: corrections(4, from: 41, "Lengthened Claude's cuts on a calm song", every: 2 * D), createdAt: ago(2 * D), updatedAt: ago(2 * D)),
            LearnRule(id: "rule_6", text: "No glitch transitions.", area: "transition", source: "owner", pinned: true, createdAt: ago(12 * D), updatedAt: ago(12 * D)),
            LearnRule(id: "rule_7", text: "Whip pans only on a strong beat.", area: "transition", source: "claude",
                      evidence: corrections(2, from: 21, "Undid Claude's whip", every: D), createdAt: ago(3 * D), updatedAt: ago(3 * D)),
            LearnRule(id: "rule_8", text: "Leave the look as I set it on the take. Only match colour between shots.", area: "look", source: "owner",
                      pinned: true, createdAt: ago(10 * D), updatedAt: ago(10 * D)),
            LearnRule(id: "rule_9", text: "Golden warmth at 70% or less when skin fills the frame.", area: "look", source: "claude",
                      evidence: corrections(4, from: 31, "Changed the look after Claude's “Look Film”", every: 2 * D), createdAt: ago(D), updatedAt: ago(D)),
            LearnRule(id: "rule_10", text: "Keep the trend audio at full length; trim the video to it, not the other way round.", area: "audio", source: "owner",
                      pinned: true, createdAt: ago(14 * D), updatedAt: ago(14 * D)),
            LearnRule(id: "rule_11", text: "Duck the music 3 dB under any voice-over.", area: "audio", source: "learned",
                      evidence: corrections(2, from: 47, "Turned the music down under the voice-over", every: 3 * D), createdAt: ago(5 * D), updatedAt: ago(5 * D)),
        ]
        lessons = [
            LearnLesson(area: "look", claudeChange: "Look", count: 4, undos: 1, last: ago(2 * D),
                        examples: ["Changed the look after Claude's “Look Film” in Living room dance", "Lowered Golden warmth to 70% in Kitchen walk"], ids: [31, 32, 33, 34]),
            LearnLesson(area: "captions", claudeChange: "Captions", count: 3, undos: 0, last: ago(D),
                        examples: ["Moved the captions from lower third to top in Café counter", "Moved the captions up in Rooftop turn"], ids: [11, 12, 13]),
            LearnLesson(area: "pacing", claudeChange: "Trim", count: 5, undos: 2, last: ago(3 * H),
                        examples: ["Trimmed the first shot from 1.4 s to 0.8 s in Summer cut", "Shortened the opening shot in Kitchen walk"], ids: [41, 42, 43, 44, 45]),
            LearnLesson(area: "transition", claudeChange: "Add transition", count: 2, undos: 2, last: ago(4 * D),
                        examples: ["Undid Claude's glitch transition at 0:04 in Mirror outfit swap"], ids: [21, 22]),
            LearnLesson(area: "audio", claudeChange: "Music", count: 2, undos: 0, last: ago(5 * D),
                        examples: ["Turned the music down 3 dB under the voice-over in Living room dance"], ids: [47, 48]),
        ]
        self.corrections = [
            LearnCorrection(id: 51, sessionId: "es_demo", takeId: "t_demo_dance", kind: "change", area: "look", what: "Changed the look from Film to Golden warmth", createdAt: ago(2 * H)),
            LearnCorrection(id: 50, sessionId: "es_demo", takeId: "t_demo_cafe", kind: "change", area: "captions", what: "Moved the captions from lower third to top", createdAt: ago(26 * H)),
            LearnCorrection(id: 49, sessionId: "es_demo", takeId: "t_demo_mirror", kind: "undo", area: "transition", what: "Undid Claude's glitch transition at 0:04", createdAt: ago(30 * H)),
            LearnCorrection(id: 48, sessionId: "es_demo", takeId: "t_demo_kitchen", kind: "change", area: "pacing", what: "Trimmed the first shot from 1.4 s to 0.8 s", createdAt: ago(3 * D)),
            LearnCorrection(id: 47, sessionId: "es_demo", takeId: "t_demo_dance", kind: "change", area: "audio", what: "Turned the music down 3 dB under the voice-over", createdAt: ago(5 * D)),
            LearnCorrection(id: 46, sessionId: "es_demo", takeId: "t_demo_rooftop", kind: "change", area: "text", what: "Changed the hook text Claude added", createdAt: ago(6 * D)),
        ]
        var list: [LearnRecipe] = []
        func add(_ json: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: json), let r = try? JSONDecoder().decode(LearnRecipe.self, from: data) { list.append(r) }
        }
        // Recreate's demo reference, as the library keeps it.
        if let ref = try? JSONDecoder().decode(RecreateReference.self, from: Data(RecreateDemo.referenceJSON.utf8)), let rec = ref.recipe,
           let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(rec)) {
            add(["id": "rcp_summer", "origin": "reference", "referenceId": ref.id, "name": ref.name ?? "Summer cut", "summary": "Walk-in, hair flip, hold",
                 "tags": ["reference", "fast-cuts", "short", "tempo-mid", "transition-crossfade", "transition-flash", "text", "dance"],
                 "features": ["durationSec": rec.durationSec, "shots": Double(rec.slots.count), "cutsPerMin": rec.pacing?.cutsPerMin ?? 27, "bpm": rec.sound?.bpm ?? 120],
                 "performance": NSNull(), "createdAt": ago(5 * H), "updatedAt": ago(5 * H), "recipe": body])
        }
        func edit(_ id: String, _ take: String, _ name: String, _ summary: String, tags: [String], shots: [Double], cuts: [String], bpm: Double, texts: Int,
                  swatches: [String], look: (String, String)?, perf: [String: Any]?, age: Int64, origin: String = "edit", referenceId: String? = nil) {
            var t = 0.0
            var slots: [[String: Any]] = []
            for (i, d) in shots.enumerated() {
                slots.append(["id": "s\(i + 1)", "index": i, "startSec": t, "endSec": t + d, "durationSec": d])
                t += d
            }
            var transitions: [[String: Any]] = []
            var at = 0.0
            for i in 0..<max(0, shots.count - 1) {
                at += shots[i]
                transitions.append(["atSec": at, "kind": i < cuts.count ? cuts[i] : "cut", "durationSec": 0, "from": "s\(i + 1)", "to": "s\(i + 2)"])
            }
            let text: [[String: Any]] = (0..<texts).map { ["id": "x\($0 + 1)", "startSec": Double($0) * 2, "endSec": Double($0) * 2 + 1.5] }
            var grade: [String: Any] = ["swatches": swatches]
            if let look { grade["look"] = ["id": look.0, "kind": "palette", "label": look.1, "distance": 0] }
            let cpm = t > 0 ? Double(shots.count - 1) / t * 60 : 0
            let body: [String: Any] = ["schema": "muse.recipe/1", "summary": summary, "tags": [String](), "source": ["durationSec": t, "aspect": "9:16"],
                                       "sound": ["bpm": bpm, "beats": [Double](), "strong": [Double]()],
                                       "pacing": ["shots": shots.count, "avgShotSec": t / Double(max(1, shots.count)), "cutsPerMin": cpm],
                                       "slots": slots, "transitions": transitions, "text": text, "grade": grade, "gaps": [Any]()]
            var entry: [String: Any] = ["id": id, "origin": origin, "name": name, "summary": summary, "tags": tags,
                                        "features": ["durationSec": t, "shots": Double(shots.count), "cutsPerMin": cpm, "bpm": bpm],
                                        "createdAt": ago(age), "updatedAt": ago(age), "recipe": body]
            if origin == "edit" { entry["takeId"] = take } else { entry["referenceId"] = referenceId.map { $0 as Any } ?? NSNull() }
            entry["performance"] = perf.map { $0 as Any } ?? NSNull()
            add(entry)
        }
        let golden = ["#2E2622", "#6B4A33", "#A77D5A", "#D8B98F", "#7E8A92"]
        edit("rcp_dance", "t_demo_dance", "Living room dance", "Dance to the hook, quick cuts on the beat, one outfit.",
             tags: ["own-edit", "dance", "fast-cuts", "high-energy", "trend audio", "living room", "text"],
             shots: [1.2, 0.9, 1.6, 0.8, 1.4, 0.7, 2.1, 1.1, 2.0], cuts: ["cut", "whip", "cut", "cut", "crossfade", "cut", "whip", "cut"], bpm: 120, texts: 3,
             swatches: golden, look: ("golden_warmth", "Golden warmth"),
             perf: ["posts": 1, "views": 1200, "likes": 80, "comments": 6, "saves": 12, "avgWatchSec": 6.5, "completion": 0.42], age: 2 * D)
        edit("rcp_rooftop", "t_demo_rooftop", "Rooftop turn", "A slow turn at golden hour, two holds and a text hook.",
             tags: ["own-edit", "golden hour", "slow-cuts", "calm", "text"], shots: [2.2, 1.6, 2.2], cuts: ["crossfade", "cut"], bpm: 92, texts: 1,
             swatches: ["#30282A", "#7A5844", "#B98E68", "#E2C7A0", "#8D96A3"], look: ("golden_warmth", "Golden warmth"),
             perf: ["posts": 1, "views": 860, "likes": 51, "comments": 3, "completion": 0.51], age: 3 * D)
        edit("rcp_kitchen", "t_demo_kitchen", "Kitchen walk", "Fast cuts, text hook.",
             tags: ["own-edit", "fast-cuts", "walk-in", "text", "café"], shots: [1.0, 0.8, 1.2, 1.1, 1.3, 1.0, 1.0, 1.6], cuts: ["cut", "cut", "flash", "cut", "cut", "cut", "cut"],
             bpm: 124, texts: 2, swatches: ["#22252A", "#4B5560", "#8C8F8C", "#C9C2B2", "#E8E0D0"], look: nil, perf: nil, age: 4 * D)
        edit("rcp_day", "", "Day in my life", "Seven shots cut on the beat, a warm film look.",
             tags: ["reference", "calm", "vlog", "slow-mo", "text"], shots: [2.5, 2.0, 2.4, 1.8, 2.2, 2.0, 2.1], cuts: ["crossfade", "cut", "cut", "crossfade", "cut", "cut"],
             bpm: 96, texts: 2, swatches: ["#2B2421", "#5E4636", "#9A7A5E", "#CDB08C", "#E9DCC4"], look: ("film_warm", "Warm film"), perf: nil, age: 6 * D,
             origin: "reference", referenceId: "rx_daylife")
        edit("rcp_cafe", "t_demo_cafe", "Café counter", "Order, sip, turn to camera.",
             tags: ["own-edit", "café", "talking", "medium-cuts", "outfit change"], shots: [1.8, 1.5, 2.0, 1.4, 2.3], cuts: ["cut", "crossfade", "cut", "cut"],
             bpm: 104, texts: 2, swatches: golden, look: ("golden_warmth", "Golden warmth"),
             perf: ["posts": 2, "views": 2400, "likes": 190, "comments": 14, "saves": 31, "avgWatchSec": 5.8, "completion": 0.36], age: 8 * D)
        edit("rcp_mirror", "", "Mirror outfit swap", "Two outfits, one jump cut on the drop.",
             tags: ["reference", "outfit change", "fast-cuts", "trend audio", "transition-unknown"], shots: [1.4, 1.1, 0.9, 1.6], cuts: ["unknown", "cut", "cut"],
             bpm: 128, texts: 1, swatches: ["#1F2024", "#4A4550", "#8E8794", "#C7BFC4", "#E6E1DE"], look: nil, perf: nil, age: 11 * D,
             origin: "reference", referenceId: "rx_mirror")
        recipes = list.sorted { $0.createdAt > $1.createdAt }
        gaps = [
            LearnGap(key: "transition:unknown", kind: "transition", what: "Unknown transition", count: 4,
                     examples: [LearnGap.Example(note: "A spin blur between two outfits in Mirror outfit swap", recipeId: "rcp_mirror", at: ago(D))], lastAt: ago(D)),
            LearnGap(key: "effect:speed-ramp-drop", kind: "effect", what: "Speed ramp on a drop", count: 2,
                     examples: [LearnGap.Example(note: "Slows to a stop on the drop in Kitchen walk", recipeId: "rcp_kitchen", at: ago(4 * D))], lastAt: ago(4 * D)),
            LearnGap(key: "effect:lens-flare", kind: "effect", what: "Lens flare", count: 1,
                     examples: [LearnGap.Example(note: "“Add a flare when she turns”, in Rooftop turn", recipeId: "ask_demo", at: ago(3 * D))], lastAt: ago(3 * D)),
        ]
    }
}
