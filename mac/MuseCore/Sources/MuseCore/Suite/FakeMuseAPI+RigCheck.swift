import Foundation

// AI suite · the rig check (workstream 3, plans/video-composer.md "Rig check"): demo mode's port of
// server/api/src/suite/rigcheck.ts. The same rules, wording and merge-patch fixes, read against the bundled catalog.
// Pure: the prompt is read with the same keyword map. FakeMuseAPI+Suite.swift puts it on the estimate and on rig-check.

enum FakeRigCheck {
    private static var cat: CameraCatalog { SuiteDemoCatalog.catalog.camera }
    /// Small sensors or fixed-focus optics: everything is in focus whatever the aperture says.
    private static let deepFocusBodies = ["camcorder", "phone", "webcam", "security_cam"]
    private static let shallowApertures = ["f1.2", "f1.4", "f2", "f2.8"]
    private static let closeSizes = ["cu", "ecu"]
    private static let wormCloseSizes = ["mcu", "cu", "ecu"]

    /// Colour character of each look and palette, for the clash rule.
    private enum Tone { case mono, warm, cold, saturated, muted }
    private static let lookTones: [String: [Tone]] = [
        "phone_hdr": [.saturated], "portrait_negative": [.warm], "tungsten_stock": [.cold], "slide_film": [.saturated], "bw_film": [.mono],
        "bleach_bypass": [.muted], "cross_process": [.saturated], "reversal_16": [.saturated], "faded_print": [.muted],
    ]
    private static let paletteTones: [String: [Tone]] = [
        "bleached_warm": [.warm, .muted], "hyper_neon": [.saturated], "teal_orange": [.saturated], "sodium_decay": [.warm], "cold_steel": [.cold, .muted],
        "bleach_bypass": [.muted], "classic_bw": [.mono], "muted_earth": [.muted], "golden_warmth": [.warm], "moody_blue": [.cold], "vintage_fade": [.muted],
        "cyber_magenta": [.saturated], "desert_sand": [.warm], "retro_80s": [.saturated], "nineties_mall": [.saturated, .warm], "y2k_gloss": [.cold],
        "candy_pop": [.saturated], "autumn": [.warm], "winter_frost": [.cold], "sepia": [.mono], "kodachrome_like": [.saturated], "matte_film": [.muted],
    ]
    private static let opposite: [(Tone, Tone)] = [(.mono, .saturated), (.mono, .warm), (.mono, .cold), (.warm, .cold), (.saturated, .muted)]

    /// What a prompt says about the camera: the words, and the ids that do what they describe (the first is the fix).
    /// Order matters: more specific phrases first ("crash zoom" before "zoom in").
    private static let moveWords: [(String, [String])] = [
        (#"\bwhip[- ]?pans?\b"#, ["whip_pan"]),
        (#"\bcrash[- ]?zooms?\b"#, ["crash_zoom"]),
        (#"\b(dolly[- ]?zoom|vertigo (shot|effect))\b"#, ["dolly_zoom"]),
        (#"\b(rack(s|ing)? focus|focus (pull|rack)s?|pulls? focus)\b"#, ["rack_focus"]),
        (#"\b(360|full circle|all the way around)\b"#, ["orbit_360", "bullet_time"]),
        (#"\b(orbit(s|ing)?|circles? (around|round)|arcs? (around|round))\b"#, ["orbit_right", "orbit_left", "orbit_360", "top_down_spin", "bullet_time"]),
        (#"\bfpv\b"#, ["fpv"]),
        (#"\b(drone|aerial|fly ?over|flies over)\b"#, ["drone_reveal", "flyover", "fpv"]),
        (#"\b(pull(s|ing)? back|dolly(ing)? out|dollies out|backs? away)\b"#, ["dolly_out", "drone_reveal", "zoom_out"]),
        (#"\b(push(es|ing)? in|dolly(ing)? in|dollies in|moves? in (on|toward|towards))\b"#, ["dolly_in", "micro_push", "dutch_push", "zoom_in"]),
        (#"\bzoom(s|ing)? in\b"#, ["zoom_in", "crash_zoom", "dolly_zoom"]),
        (#"\bzoom(s|ing)? out\b"#, ["zoom_out", "dolly_zoom"]),
        (#"\bpan(s|ning)? (to the )?left\b"#, ["pan_left", "whip_pan"]),
        (#"\bpan(s|ning)? (to the )?right\b"#, ["pan_right", "whip_pan"]),
        (#"\btilt(s|ing)? up\b"#, ["tilt_up", "crane_up"]),
        (#"\btilt(s|ing)? down\b"#, ["tilt_down", "crane_up"]),
        (#"\b(crane(s|ing)? (up|over)|jib(s|bing)? up|camera rises)\b"#, ["crane_up", "pedestal_up", "crane_overhead", "drone_reveal"]),
        (#"\b(crane(s|ing)? down|jib(s|bing)? down|camera (descends|lowers))\b"#, ["crane_down", "pedestal_down"]),
        (#"\b(follow(s|ing)? (her|him|them|the|behind)|tracking shot|track(s|ing)? (with|alongside|behind))\b"#,
         ["follow", "track_side", "lead", "steadicam", "handheld", "handheld_run", "selfie", "fpv"]),
        (#"\bselfie\b"#, ["selfie", "handheld"]),
        (#"\b(handheld|hand-held|shaky cam)\b"#, ["handheld", "handheld_run", "selfie"]),
        (#"\b(static|locked[- ]off|on a tripod|still camera|camera (stays|is) still)\b"#, ["static", "rack_focus", "micro_push"]),
    ]
    private static let angleWords: [(String, [String])] = [
        (#"\bworm[’']?s[- ]eye\b"#, ["worm", "ground"]),
        (#"\b(bird[’']?s[- ]eye|top[- ]down|overhead (shot|view))\b"#, ["overhead"]),
        (#"\b(low[- ]angle|from below|looking up at)\b"#, ["low", "worm", "ground", "hip"]),
        (#"\b(high[- ]angle|from above|looking down (at|on))\b"#, ["high", "overhead"]),
        (#"\beye[- ]level\b"#, ["eye", "shoulder"]),
    ]
    private static let sizeWords: [(String, [String])] = [
        (#"\bextreme close[- ]?ups?\b"#, ["ecu", "insert", "cu"]),
        (#"\b(close[- ]?ups?|closeups?)\b"#, ["cu", "ecu", "mcu", "insert"]),
        (#"\b(extreme wide|establishing shot)\b"#, ["els", "ls"]),
        (#"\bwide shot\b"#, ["ls", "els", "full"]),
    ]
    /// "Open on the street, then find her" / "reveal": the camera has to start somewhere else and discover the subject.
    private static let revealWords = #"\b(open(s|ing)? on|start(s|ing)? on|begin(s|ning)? on|reveal(s|ed|ing)?|comes? into view|to find (her|him|them))\b"#
    /// Moves that start on the subject (or never leave it), so they can't open elsewhere and reveal.
    private static let noReveal = ["static", "micro_push", "dolly_in", "dutch_push", "zoom_in", "crash_zoom", "crane_up", "crane_overhead", "snorricam", "selfie",
                                   "top_down_spin", "bullet_time"]

    private static func match(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }

    private static func firstHit(_ words: String, _ table: [(String, [String])]) -> (quote: String, ids: [String])? {
        for (p, ids) in table { if let q = match(p, words) { return (q, ids) } }
        return nil
    }

    /// Prompt words, lower-cased, with the composer's own #tokens (option labels) and any negated phrase taken out.
    static func promptWords(_ prompt: String) -> String {
        var p = " " + prompt.lowercased().replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"") + " "
        let labels = (cat.moves.map(\.label) + cat.heights.map(\.label) + cat.shotSizes.map(\.label)).map { $0.lowercased() }.sorted { $0.count > $1.count }
        for l in labels { p = p.replacingOccurrences(of: "#" + l, with: " ") }
        // "no zoom", "without a pan", "don't tilt up" say what NOT to do.
        return p.replacingOccurrences(of: #"\b(no|not|never|without|don[’']?t|doesn[’']?t|avoid)\b( (a|an|any|the))? [a-z’'-]+( [a-z’'-]+)?"#, with: " ",
                                      options: .regularExpression)
    }

    private static func label(_ list: [SuiteOption], _ id: String?) -> String { list.first { $0.id == id }?.label ?? id ?? "" }
    private static func move(_ id: String?) -> SuiteMoveOption? { id.flatMap { cat.move($0) } }
    private static func cam(_ c: [String: JSONValue]) -> JSONValue { .object(["camera": .object(c)]) }
    private static func setMove(_ id: String) -> JSONValue { cam(["move": .object(["id": .string(id)])]) }
    private static func str(_ v: String) -> JSONValue { .string(v) }

    /// The camera as it compiles: its preset underneath (the choices win), merged ids as their survivors.
    static func resolved(_ spec: CameraSpec) -> CameraSpec {
        var c = spec
        if let id = spec.preset, let p = cat.presets.first(where: { $0.id == id })?.spec {
            let a = p.rig ?? CameraRig(), b = spec.rig ?? CameraRig()
            let rig = CameraRig(body: b.body ?? a.body, lens: b.lens ?? a.lens, focalMm: b.focalMm ?? a.focalMm, aperture: b.aperture ?? a.aperture,
                                look: b.look ?? a.look, fps: b.fps ?? a.fps, shutter: b.shutter ?? a.shutter)
            c.rig = rig.isEmpty ? nil : rig
            if spec.lighting == nil { c.lighting = p.lighting }
            if spec.palette == nil { c.palette = p.palette }
            if c.move == nil { c.move = p.move }
            if p.angle != nil || spec.angle != nil {
                c.angle = CameraAngle(height: spec.angle?.height ?? p.angle?.height, shotSize: spec.angle?.shotSize ?? p.angle?.shotSize,
                                      dutchDeg: spec.angle?.dutchDeg ?? p.angle?.dutchDeg)
            }
        }
        if var r = c.rig {
            r.body = ComposerCatalog.survivor(cat.bodies, r.body)
            r.lens = ComposerCatalog.survivor(cat.lenses, r.lens)
            r.aperture = ComposerCatalog.survivor(cat.apertures, r.aperture)
            r.look = ComposerCatalog.survivor(cat.looks, r.look)
            c.rig = r
        }
        if var pal = c.palette {
            pal.preset = ComposerCatalog.survivor(cat.palettes, pal.preset)
            c.palette = pal
        }
        return c
    }

    /// The clashes in a shot, most serious first (the server's rule order).
    static func check(prompt: String?, camera: CameraSpec?, speaking: Bool) -> [RigWarning] {
        var out: [RigWarning] = []
        let c = camera.map(resolved)
        let body = c?.rig?.body, aperture = c?.rig?.aperture, focal = c?.rig?.focalMm
        let height = c?.angle?.height, size = c?.angle?.shotSize
        let mv = move(c?.move?.id), mix = move(c?.mix?.id)
        let moves = [mv, mix].compactMap { $0 }
        let words = prompt.map { $0.isEmpty ? "" : promptWords($0) } ?? ""

        // 1 · Deep-focus cameras can't show shallow focus or a focus pull.
        if let c, let body, deepFocusBodies.contains(body) {
            let rack = moves.contains { $0.id == "rack_focus" }
            let shallow = aperture.map { shallowApertures.contains($0) } ?? false
            if rack || shallow {
                let what = rack ? "the rack focus won’t show" : "\(label(cat.apertures, aperture)) won’t blur the background"
                out.append(RigWarning(id: "deep_focus", severity: "warn", reason: "\(label(cat.bodies, body)) keeps everything in focus, so \(what)",
                                      fix: RigFix(label: "Use Cinema camera", patch: cam(["rig": .object(["body": str("cinema_digital")])])),
                                      alt: rack ? RigFix(label: "Drop the rack focus", patch: dropMove("rack_focus", c))
                                          : RigFix(label: "Use f/11", patch: cam(["rig": .object(["aperture": str("f11")])]))))
            }
        }
        // 2 · A wide lens this close distorts the face.
        if let focal, focal <= 24, let size, closeSizes.contains(size), c?.rig?.lens != "fisheye" {
            out.append(RigWarning(id: "wide_close", severity: "warn", reason: "A \(ComposerWheels.focalText(focal))mm lens this close stretches the face",
                                  fix: RigFix(label: "Use 85mm", patch: cam(["rig": .object(["focalMm": .number(85)])])),
                                  alt: RigFix(label: "Medium shot", patch: cam(["angle": .object(["shotSize": str("ms")])]))))
        }
        // 3 · From the ground you can't frame chest-up.
        if height == "worm", let size, wormCloseSizes.contains(size) {
            out.append(RigWarning(id: "worm_close", severity: "warn", reason: "Worm’s-eye from the ground can’t frame a \(label(cat.shotSizes, size).lowercased())",
                                  fix: RigFix(label: "Low angle", patch: cam(["angle": .object(["height": str("low")])])),
                                  alt: RigFix(label: "Full body", patch: cam(["angle": .object(["shotSize": str("full")])]))))
        }
        // 4 · Looks that pull the colour opposite ways.
        if let look = c?.rig?.look, let palette = c?.palette?.preset, look != palette {
            let a = lookTones[look] ?? [], b = paletteTones[palette] ?? []
            if let hit = opposite.first(where: { x, y in (a.contains(x) && b.contains(y)) || (a.contains(y) && b.contains(x)) }) {
                let L = label(cat.looks, look), P = label(cat.palettes, palette)
                let reason = hit.0 == .mono ? (a.contains(.mono) ? "\(L) is black and white, so \(P) won’t show" : "\(P) is black and white, so \(L) won’t show")
                    : "\(L) and \(P) pull the colour opposite ways"
                out.append(RigWarning(id: "look_clash", severity: "tip", reason: reason,
                                      fix: RigFix(label: "Keep \(L)", patch: cam(["palette": .object(["preset": str("naturalistic")])])),
                                      alt: RigFix(label: "Keep \(P)", patch: cam(["rig": .object(["look": str("digital_clean")])]))))
            }
        }
        if !words.isEmpty {
            // 5 · The prompt describes a different move, angle or size from the chips.
            if let hit = firstHit(words, moveWords), let mv, !moves.contains(where: { hit.ids.contains($0.id) }), let to = move(hit.ids[0]) {
                out.append(RigWarning(id: "prompt_move", severity: "warn", reason: "The prompt says “\(hit.quote)” but the move is \(mv.label)",
                                      fix: RigFix(label: "Use \(to.label)", patch: setMove(to.id))))
            }
            if let hit = firstHit(words, angleWords), let height, !hit.ids.contains(height) {
                out.append(RigWarning(id: "prompt_angle", severity: "warn", reason: "The prompt says “\(hit.quote)” but the angle is \(label(cat.heights, height))",
                                      fix: RigFix(label: "Use \(label(cat.heights, hit.ids[0]))", patch: cam(["angle": .object(["height": str(hit.ids[0])])]))))
            }
            if let hit = firstHit(words, sizeWords), let size, !hit.ids.contains(size) {
                out.append(RigWarning(id: "prompt_size", severity: "tip", reason: "The prompt says “\(hit.quote)” but the framing is \(label(cat.shotSizes, size))",
                                      fix: RigFix(label: "Use \(label(cat.shotSizes, hit.ids[0]))", patch: cam(["angle": .object(["shotSize": str(hit.ids[0])])]))))
            }
            // 6 · "Open on X / reveal" needs a move that starts away from the subject.
            let mixReveals = mix.map { !noReveal.contains($0.id) } ?? false
            if let mv, match(revealWords, words) != nil, noReveal.contains(mv.id), !mixReveals, let to = revealFor(mv.id) {
                let rise = mv.id == "crane_up" || mv.id == "crane_overhead"
                out.append(RigWarning(id: "no_reveal", severity: "warn",
                                      reason: "The prompt opens on something else, but \(mv.label) \(rise ? "starts at the subject" : "can’t reveal")",
                                      fix: RigFix(label: "Use \(to.label)", patch: setMove(to.id))))
            }
        }
        // 7 · Speaking shots need a move that won't fight lip sync.
        if speaking, let bad = moves.first(where: { !$0.talkSafe }) {
            let isMix = bad.id != mv?.id
            out.append(RigWarning(id: "talk_move", severity: "warn", reason: "\(bad.label) can fight lip sync on a speaking shot",
                                  fix: isMix ? RigFix(label: "Drop \(bad.label)", patch: cam(["mix": .null])) : RigFix(label: "Lock it off", patch: setMove("static")),
                                  alt: isMix ? nil : RigFix(label: "Handheld UGC", patch: setMove("handheld"))))
        }
        // A reveal clash already names the move to use, so a second "use this move" line would only compete with it.
        return out.contains { $0.id == "no_reveal" } ? out.filter { $0.id != "prompt_move" } : out
    }

    /// Take one move out without letting a preset put another back: the mix goes, or the main move becomes the mix / static.
    private static func dropMove(_ id: String, _ c: CameraSpec) -> JSONValue {
        if c.mix?.id == id { return cam(["mix": .null]) }
        if let m = c.mix {
            // The whole mix as the server's schema reads it (its defaults filled in).
            var o: [String: JSONValue] = ["id": .string(m.id), "intensity": .number(m.intensity ?? 0.5), "speed": .string(m.speed ?? "normal"),
                                          "ease": .string(m.ease ?? "in_out")]
            if let v = m.startS { o["startS"] = .number(v) }
            if let v = m.endS { o["endS"] = .number(v) }
            return cam(["move": .object(o), "mix": .null])
        }
        return setMove("static")
    }

    /// The reveal that fits: a rise after a rise ("Rise to reveal" once the catalog has it, else Tilt up), else a pull back.
    private static func revealFor(_ id: String) -> SuiteMoveOption? {
        if id == "crane_up" || id == "crane_overhead" {
            return cat.moves.first { $0.id.range(of: #"^rise.*reveal|reveal.*rise"#, options: .regularExpression) != nil } ?? move("tilt_up")
        }
        return move("dolly_out")
    }
}
