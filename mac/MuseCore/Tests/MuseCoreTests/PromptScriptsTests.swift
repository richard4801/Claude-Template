import XCTest
@testable import MuseCore

/// Prompt scripts (workstream 4; plans/api.md "Prompt scripts"): decoding the server's real JSON
/// (Fixtures/prompt_scripts_fixture.json = GET /v1/prompt-scripts and a POST …/preview, printed by server/api's own code),
/// the rule sentences, tests by input type, the "Performer is speaking" pre-set, the request's `speaking`, and the demo
/// backend's save / reset / preview round trip.
final class PromptScriptsTests: XCTestCase {
    private struct Fixture: Decodable {
        var list: PromptScriptsList
        var preview: ScriptPreview
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "prompt_scripts_fixture", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func json<T: Encodable>(_ v: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(v)) as? [String: Any])
    }

    private var library: PromptLibrary { PromptLibrary(groups: PromptLibraryDefaults.groups, prompts: PromptLibraryDefaults.entries) }

    // MARK: Decoding the server's JSON

    func testDecodesTheServersScriptList() throws {
        let f = try loadFixture()
        let list = f.list
        XCTAssertEqual(list.ops.map(\.id), ["is", "isNot", "in", "notIn", "atLeast", "atMost", "has", "hasNot", "empty", "notEmpty"])
        XCTAssertEqual(list.ops, CondOpInfo.defaults, "the app's fallback matches the server's tests")
        XCTAssertTrue(list.scripts.count >= 11)
        XCTAssertEqual(list.sections.first?.group.id, "photoshoot")

        let video = try XCTUnwrap(list.script("video.replicate"))
        XCTAssertEqual(video.group, "video")
        XCTAssertEqual(video.format, "sections")
        XCTAssertEqual(video.inputs.first?.name, "speaking")
        XCTAssertEqual(video.inputs.first?.type, "bool")
        XCTAssertEqual(video.inputs.first?.sample, .bool(true))
        XCTAssertEqual(video.sections.first?.heading, "subject_definitions:")
        XCTAssertEqual(video.sections.last?.kind, "user")
        XCTAssertEqual(video.targets.map(\.id), video.sections.map(\.id))
        XCTAssertTrue(video.blocks.contains("video.replicate.summary.silent"))
        XCTAssertFalse(video.overridden)
        XCTAssertNil(video.updatedAt)
        XCTAssertEqual(video.rules, video.defaultRules)
        let subjects = try XCTUnwrap(video.rules.first { $0.id == "subjects" })
        XCTAssertTrue(subjects.isLocked)
        XCTAssertTrue(subjects.isOn)
        let silent = try XCTUnwrap(video.rules.first { $0.id == "summary.silent" })
        XCTAssertEqual(silent.when, [ScriptCond(input: "speaking", op: "is", value: .bool(false))])
        XCTAssertFalse(silent.isLocked)

        let shoot = try XCTUnwrap(list.script("photoshoot"))
        let refs = try XCTUnwrap(shoot.inputs.first { $0.name == "refs" })
        XCTAssertEqual(refs.type, "list")
        XCTAssertEqual(refs.fields?.map(\.name), ["refIndex", "guides"])
        XCTAssertEqual(refs.fields?.last?.options?.map(\.id), ["pose", "look", "scene"])
        guard case .array(let items) = refs.sample, case .object(let first)? = items.first else { return XCTFail("refs sample is a list of items") }
        XCTAssertEqual(first["refIndex"], .number(5)) // the shared sample set: her images 1–3, the outfit 4, the reference 5
        XCTAssertEqual(shoot.section("reference")?.each, "refs")
        XCTAssertEqual(shoot.values.map(\.name), ["lensNote"])
        XCTAssertEqual(shoot.targets.last?.id, "@lensNote")
        XCTAssertEqual(shoot.rules.first { $0.id == "lens.wide" }?.when.first?.value, .number(24))
        XCTAssertEqual(shoot.rules.first { $0.id == "never" }?.isOptional, true)
        XCTAssertEqual(shoot.input("item.guides", target: "reference")?.label, "Guides")
        XCTAssertNil(shoot.input("item.guides", target: "outfit"), "item fields only in a repeating section")
        XCTAssertEqual(shoot.conditionInputs(target: "reference").map { $0.key }.suffix(2), ["item.refIndex", "item.guides"])

        let p = f.preview
        XCTAssertEqual(p.id, "video.replicate")
        XCTAssertEqual(p.inputs["speaking"], .bool(false))
        XCTAssertTrue(p.fired.contains("summary.silent"))
        XCTAssertFalse(p.fired.contains("summary"))
        XCTAssertEqual(p.parts.last?.kind, "user")
        XCTAssertTrue(p.text.hasPrefix("subject_definitions:\n"))
    }

    func testRuleRoundTripKeepsTheServersKeys() throws {
        let f = try loadFixture()
        let shoot = try XCTUnwrap(f.list.script("photoshoot"))
        let never = try XCTUnwrap(shoot.rules.first { $0.id == "never" })
        let o = try json(never)
        XCTAssertEqual(o["optional"] as? Bool, true)
        XCTAssertEqual(o["locked"] as? Bool, true)
        XCTAssertNil(o["enabled"])
        XCTAssertNil(o["isOptional"])
        var off = try XCTUnwrap(shoot.rules.first { $0.id == "seed.new" })
        off.isOn = false
        XCTAssertEqual(try json(off)["enabled"] as? Bool, false)
        off.isOn = true
        XCTAssertNil(try json(off)["enabled"], "on is the default, so it is left out")
        let body = try JSONEncoder().encode(SaveScriptRequest(rules: shoot.rules))
        XCTAssertEqual(try JSONDecoder().decode(SaveScriptRequest.self, from: body).rules, shoot.rules)
        let preview = try json(ScriptPreviewRequest(id: "photoshoot", inputs: ["lens": .number(85), "presets": .bool(false)]))
        XCTAssertEqual((preview["inputs"] as? [String: Any])?["lens"] as? Int, 85)
        XCTAssertNil(preview["rules"])
        XCTAssertNil(preview["direction"])
    }

    func testPromptScriptEventUpdatesTheList() throws {
        let f = try loadFixture()
        var list: PromptScriptsList? = f.list
        var v = try XCTUnwrap(f.list.script("video.replicate"))
        v.overridden = true
        v.rules[1].isOn = false
        let data = try JSONEncoder().encode(ApiEvent(type: "promptScript", script: v))
        let e = try JSONDecoder().decode(ApiEvent.self, from: data)
        XCTAssertEqual(LiveEvents.applyPromptScript(&list, e)?.id, "video.replicate")
        XCTAssertEqual(list?.script("video.replicate")?.overridden, true)
        XCTAssertEqual(list?.script("video.replicate")?.rules[1].isOn, false)
        XCTAssertNil(LiveEvents.applyPromptScript(&list, ApiEvent(type: "prompts")))
    }

    // MARK: Clips and the "Performer is speaking" switch

    func testDecodesClipAudioAndPresetsTheSwitch() throws {
        let talking = try decode(Clip.self, #"{"id":"c1","name":"Talk","durationSec":6,"width":1080,"height":1920,"fps":30,"checks":[],"audio":{"kind":"speech","speaking":true,"detected":true}}"#)
        XCTAssertEqual(talking.audio, ClipAudio(kind: "speech", speaking: true, detected: true))
        XCTAssertTrue(PerformerSpeaking.preset(talking))
        let music = try decode(Clip.self, #"{"id":"c2","name":"Dance","audio":{"kind":"music","speaking":false,"detected":true}}"#)
        XCTAssertFalse(PerformerSpeaking.preset(music))
        let pending = try decode(Clip.self, #"{"id":"c3","name":"Running"}"#)
        XCTAssertNil(pending.audio)
        XCTAssertFalse(PerformerSpeaking.preset(pending), "off when unknown")
        XCTAssertFalse(PerformerSpeaking.preset(nil))

        // Another clip: its pre-set. The same clip's late detection: the pre-set, unless the user flipped the switch.
        XCTAssertTrue(PerformerSpeaking.after(music, talking, current: false, touched: true))
        XCTAssertFalse(PerformerSpeaking.after(talking, music, current: true, touched: true))
        var late = pending
        late.audio = ClipAudio(kind: "speech", speaking: true)
        XCTAssertTrue(PerformerSpeaking.after(pending, late, current: false, touched: false))
        XCTAssertFalse(PerformerSpeaking.after(pending, late, current: false, touched: true))
        XCTAssertTrue(PerformerSpeaking.after(talking, talking, current: true, touched: false))
        XCTAssertFalse(PerformerSpeaking.after(talking, talking, current: false, touched: true))

        XCTAssertEqual(PerformerSpeaking.hint(true), "She talks or sings: her lips follow the clip's sound")
        XCTAssertEqual(PerformerSpeaking.hint(false), "Her mouth follows the clip; she won't lip-sync to the music")

        let e = try decode(ApiEvent.self, #"{"type":"clip","clip":{"id":"c3","name":"Running","audio":{"kind":"silence","speaking":false,"detected":true}}}"#)
        XCTAssertEqual(e.clip?.audio?.kind, "silence")
    }

    func testRequestSendsSpeaking() throws {
        var r = JobRequest.replicate(title: "t", modelId: "m", outfitId: "o", clipId: "c", quality: .draft)
        XCTAssertNil(try json(r)["speaking"], "absent = the clip's detection")
        r.speaking = false
        XCTAssertEqual(try json(r)["speaking"] as? Bool, false)
        r.speaking = true
        XCTAssertEqual(try json(r)["speaking"] as? Bool, true)
        XCTAssertNil(try json(r)["speakingSource"])
        let back = try decode(JobRequest.self, #"{"title":"t","engine":"replicate","speaking":false,"speakingSource":"detected"}"#)
        XCTAssertEqual(back.speaking, false)
        XCTAssertEqual(back.speakingSource, "detected")
    }

    // MARK: Editor helpers

    func testRuleSentences() throws {
        let f = try loadFixture()
        let ops = f.list.ops
        let lib = library
        let title = { (k: String) in ScriptText.blockTitle(k, library: lib) }
        let video = try XCTUnwrap(f.list.script("video.replicate"))
        let silent = try XCTUnwrap(video.rules.first { $0.id == "summary.silent" })
        XCTAssertEqual(ScriptText.sentence(silent, script: video, ops: ops, blockTitle: title),
                       "When Performer is speaking is no → Summary: Draft/Standard/HD · summary (not speaking)")
        let subjects = try XCTUnwrap(video.rules.first { $0.id == "subjects" })
        XCTAssertEqual(ScriptText.sentence(subjects, script: video, ops: ops, blockTitle: title), "Always → Subjects: Draft/Standard/HD · subjects")

        let shoot = try XCTUnwrap(f.list.script("photoshoot"))
        func say(_ id: String) throws -> String {
            ScriptText.sentence(try XCTUnwrap(shoot.rules.first { $0.id == id }), script: shoot, ops: ops, blockTitle: title)
        }
        XCTAssertEqual(try say("lens.wide"), "When Lens (mm) is at most 24 → Lens note: Camera · wide lens note")
        XCTAssertEqual(try say("outfit.described"), "When Outfit is Described in words → Outfit: Outfit · described")
        XCTAssertEqual(try say("refs.pose"), "When Guides includes Pose & framing → Reference images: Pose & framing")
        XCTAssertEqual(try say("seed.locked"), "When Lock look is yes → Seed: Seed line · Lock look")

        var two = try XCTUnwrap(shoot.rules.first { $0.id == "seed.new" })
        two.when = [ScriptCond(input: "outfitSource", op: "in", value: .array([.string("set"), .string("product")])), ScriptCond(input: "presets", op: "isNot", value: .bool(true))]
        XCTAssertEqual(ScriptText.sentence(two, script: shoot, ops: ops) { $0 },
                       "When Outfit is one of Reference set (photos) or Product photo and Presets on is not yes → Seed: shoot.seed.new",
                       "the key stands in for a block the library doesn't have")
        XCTAssertEqual(ScriptText.condition(ScriptCond(input: "refs", op: "empty"), script: shoot, target: "seed", ops: ops), "Reference images is empty")
    }

    func testTestsByInputType() throws {
        let ops = try loadFixture().list.ops
        XCTAssertEqual(CondOpInfo.ops(for: "bool", in: ops).map(\.id), ["is", "isNot"])
        XCTAssertEqual(CondOpInfo.ops(for: "enum", in: ops).map(\.id), ["is", "isNot", "in", "notIn"])
        XCTAssertEqual(CondOpInfo.ops(for: "number", in: ops).map(\.id), ["is", "isNot", "atLeast", "atMost"])
        XCTAssertEqual(CondOpInfo.ops(for: "text", in: ops).map(\.id), ["is", "isNot", "empty", "notEmpty"])
        XCTAssertEqual(CondOpInfo.ops(for: "list", in: ops).map(\.id), ["has", "hasNot", "empty", "notEmpty"])
        XCTAssertEqual(CondOpInfo.ops(for: "list", in: []).map(\.id), ["has", "hasNot", "empty", "notEmpty"], "the defaults until loaded")
        XCTAssertFalse(CondOpInfo.needsValue("empty"))
        XCTAssertTrue(CondOpInfo.needsValue("in"))

        let shoot = PromptScriptDemo.photoshoot
        let lens = shoot.inputs.first { $0.name == "lens" }
        XCTAssertEqual(ScriptText.newCondition("lens", def: lens, ops: ops), ScriptCond(input: "lens", op: "is", value: .number(35)))
        let outfit = shoot.inputs.first { $0.name == "outfitSource" }
        XCTAssertEqual(ScriptText.defaultValue(op: "in", def: outfit), .array([.string("set")]))
        XCTAssertEqual(ScriptText.newCondition("presets", def: shoot.inputs.first, ops: ops).value, .bool(true))
        XCTAssertNil(ScriptText.defaultValue(op: "empty", def: outfit))
    }

    func testPlacesMoveAndNewRules() throws {
        let s = PromptScriptDemo.photoshoot
        let places = s.places(s.rules)
        XCTAssertEqual(places.first?.id, "identity")
        XCTAssertEqual(places.last?.id, "@lensNote")
        XCTAssertEqual(places.first { $0.id == "outfit" }?.rules.map(\.id), ["outfit.described", "outfit.product", "outfit.set"])

        var rules = s.rules
        XCTAssertTrue(ScriptText.move(&rules, id: "outfit.set", up: true))
        XCTAssertEqual(s.places(rules).first { $0.id == "outfit" }?.rules.map(\.id), ["outfit.described", "outfit.set", "outfit.product"])
        XCTAssertFalse(ScriptText.move(&rules, id: "outfit.described", up: true), "already first in its place")
        XCTAssertFalse(ScriptText.move(&rules, id: "identity", up: false), "alone in its place")
        XCTAssertEqual(rules.count, s.rules.count)

        let r = s.newRule(existing: rules)
        XCTAssertEqual(r.id, "rule.1")
        XCTAssertEqual(r.target, "identity")
        XCTAssertTrue(s.isAdded(r))
        XCTAssertFalse(s.isAdded(rules[0]))
        XCTAssertEqual(s.newRule(existing: rules + [r]).id, "rule.2")
    }

    func testValidationMatchesTheServersMessages() {
        let s = PromptScriptDemo.videoReplicate
        XCTAssertNil(ScriptEngine.validate(s, s.rules))
        var locked = s.rules
        locked[0].isOn = false
        XCTAssertEqual(ScriptEngine.validate(s, locked), "\"Who is who\" is locked: only its text can be changed (Settings → Prompts → its block)")
        XCTAssertEqual(ScriptEngine.validate(s, Array(s.rules.dropFirst())), "\"Who is who\" is required and can't be removed")
        var dup = s.rules
        dup.append(dup[1])
        XCTAssertEqual(ScriptEngine.validate(s, dup), "Two rules are called \"summary.silent\"")
        var badBlock = s.rules
        badBlock[1].block = "shoot.scene"
        XCTAssertEqual(ScriptEngine.validate(s, badBlock), "Rule \"Not speaking: no lip-sync\": this script can't use the block \"shoot.scene\"")
        var badValue = s.rules
        badValue[1].when = [ScriptCond(input: "speaking", op: "atLeast", value: .number(1))]
        XCTAssertEqual(ScriptEngine.validate(s, badValue), "Rule \"Not speaking: no lip-sync\": \"Performer is speaking\" can't use the test \"atLeast\"")
        var off = s.rules
        off[1].isOn = false
        XCTAssertNil(ScriptEngine.validate(s, off), "unlocked rules can be switched off")
    }

    // MARK: The demo runner reproduces the server's prompts

    private var texts: [String: String] {
        var out: [String: String] = [:]
        for e in PromptLibraryDefaults.entries { out[e.key] = e.defaultText }
        return out
    }

    func testDemoRunnerMatchesTheServersPreview() throws {
        let f = try loadFixture()
        let s = PromptScriptDemo.videoReplicate
        let p = ScriptEngine.run(s, inputs: ["speaking": .bool(false), "audioSent": .bool(true)], rules: s.rules, texts: texts,
                                 direction: "smiling, glancing at the camera")
        XCTAssertEqual(p.text, f.preview.text)
        XCTAssertEqual(p.fired, f.preview.fired)
        XCTAssertEqual(p.parts.map(\.section), f.preview.parts.map(\.section))

        let speaking = ScriptEngine.run(s, inputs: s.sampleInputs, rules: s.rules, texts: texts, direction: "smiling, glancing at the camera")
        XCTAssertEqual(speaking.fired, ["subjects", "summary", "retention", "detailed", "mouth.speaking", "user"])
        XCTAssertTrue(speaking.text.contains("and the words being mouthed. Sharp face matching <Image 1>, natural skin texture, no beauty filter. No text anywhere. <Subject 2>'s mouth follows <Video 1> and is in sync with <Audio 1>'s speech.\nDirection from the user: smiling, glancing at the camera\n"), speaking.text)
    }

    func testDemoRunnerPhotoshoot() {
        let s = PromptScriptDemo.photoshoot
        var inputs = s.sampleInputs
        inputs["lens"] = .number(85)
        inputs["lockSeed"] = .bool(true)
        let p = ScriptEngine.run(s, inputs: inputs, rules: s.rules, texts: texts, direction: "smiling, glancing at the camera")
        // server/api runScript on the same samples (the lens is not a placeholder value there either).
        XCTAssertEqual(p.text, """
        Demo model: young woman, shoulder-length dark brown hair. Identity from 7 locked reference images.
        Wearing: green set (outfit reference set).
        Scene: rooftop · golden hour.
        Camera: medium shot, mm lens, f/2.8, compressed background, creamy bokeh.
        Light: golden hour; grade: phone-natural.
        Direction: smiling, glancing at the camera
        Copy the pose and framing from image 8. Copy the light, colour grade and camera feel from image 8. Use the place and background from image 8. Do not take the face, body, hair or clothes from image 8.
        Style: realistic smartphone photo.
        Never add: tattoos, rings, logos.
        Seed: locked (variations keep the same look).
        """)
        XCTAssertEqual(p.fired, ["lens.tele", "identity", "outfit.set", "scene", "camera", "light", "direction", "refs.pose", "refs.look", "refs.scene", "refs.guard",
                                 "style", "never", "seed.locked"])
        inputs["presets"] = .bool(false)
        let off = ScriptEngine.run(s, inputs: inputs, rules: s.rules, texts: texts, direction: "")
        XCTAssertFalse(off.fired.contains("scene"), "Presets off drops the optional blocks")
        XCTAssertFalse(off.fired.contains("never"))
        XCTAssertFalse(off.fired.contains("direction"), "no direction, no user line")
        XCTAssertTrue(off.fired.contains("identity"))
    }

    // MARK: Demo backend

    func testDemoSaveResetAndPreviewRoundTrip() async throws {
        let api = FakeMuseAPI(speed: 100_000, genDelay: 0.02)
        let list = try await api.promptScripts()
        XCTAssertEqual(list.scripts.map(\.id), ["photoshoot", "video.replicate"])
        XCTAssertTrue(list.scripts.allSatisfy { !$0.overridden })

        var rules = try await api.promptScript(id: "video.replicate").rules
        let i = try XCTUnwrap(rules.firstIndex { $0.id == "summary.silent" })
        rules[i].isOn = false
        let saved = try await api.savePromptScript(id: "video.replicate", rules: rules)
        XCTAssertTrue(saved.overridden)
        XCTAssertNotNil(saved.updatedAt)
        XCTAssertEqual(saved.rules[i].enabled, false)
        let again = try await api.promptScript(id: "video.replicate")
        XCTAssertEqual(again.rules, saved.rules)

        // The saved rules run in the preview: not speaking now falls through to the speaking summary.
        let p = try await api.previewPromptScript(ScriptPreviewRequest(id: "video.replicate", inputs: ["speaking": .bool(false)]))
        XCTAssertFalse(p.fired.contains("summary.silent"))
        XCTAssertTrue(p.fired.contains("summary"))
        XCTAssertTrue(p.fired.contains("mouth.silent"))
        XCTAssertEqual(p.inputs["audioSent"], .bool(true), "inputs over the samples")
        // Unsaved rules preview without saving.
        let unsaved = try await api.previewPromptScript(ScriptPreviewRequest(id: "video.replicate", inputs: ["speaking": .bool(false)], rules: saved.defaultRules))
        XCTAssertTrue(unsaved.fired.contains("summary.silent"))

        // A locked rule can't be changed.
        var bad = saved.rules
        bad[0].label = "Who"
        bad[0].block = "video.replicate.summary"
        do {
            _ = try await api.savePromptScript(id: "video.replicate", rules: bad)
            XCTFail("expected script_invalid")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "script_invalid")
            XCTAssertEqual(e.message, "\"Who is who\" is locked: only its text can be changed (Settings → Prompts → its block)")
        }

        // Saving the defaults clears the override; so does Reset.
        let back = try await api.savePromptScript(id: "video.replicate", rules: saved.defaultRules)
        XCTAssertFalse(back.overridden)
        _ = try await api.savePromptScript(id: "video.replicate", rules: rules)
        let reset = try await api.resetPromptScript(id: "video.replicate")
        XCTAssertFalse(reset.overridden)
        XCTAssertEqual(reset.rules, reset.defaultRules)

        do {
            _ = try await api.promptScript(id: "nope")
            XCTFail("expected not_found")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "not_found")
        }
    }

    func testDemoUploadSetsAudioAndJobsResolveSpeaking() async throws {
        let api = FakeMuseAPI(speed: 0, genDelay: 0.02)
        let talking = try await api.uploadClip(ClipMeta(name: "Talk", durationSec: 6, width: 1080, height: 1920, fps: 30, talking: true), file: nil)
        XCTAssertEqual(talking.audio?.kind, "speech")
        XCTAssertEqual(talking.audio?.speaking, true)
        let dance = try await api.uploadClip(SampleData.sampleMeta, file: nil)
        XCTAssertEqual(dance.audio?.speaking, false)
        XCTAssertFalse(PerformerSpeaking.preset(dance))

        let outfit = SampleData.outfits().first { $0.modelId == SampleData.demo }?.id ?? ""
        let auto = try await api.createJob(JobRequest.replicate(title: "t", modelId: SampleData.demo, outfitId: outfit, clipId: talking.id, quality: .draft, clipSeconds: 6))
        XCTAssertEqual(auto.request.speaking, true)
        XCTAssertEqual(auto.request.speakingSource, "upload")
        var req = JobRequest.replicate(title: "t", modelId: SampleData.demo, outfitId: outfit, clipId: talking.id, quality: .draft, clipSeconds: 6)
        req.speaking = false
        let switched = try await api.createJob(req)
        XCTAssertEqual(switched.request.speaking, false)
        XCTAssertEqual(switched.request.speakingSource, "switch")
    }
}
