import Foundation
import XCTest
@testable import MuseCore

/// The Blender relay (plans/api.md "MCP & camera sessions"): allowlist, strict args, args as data in the fixed scripts,
/// MUSE_RESULT parsing, claim/expiry skips, presign → PUT → confirm → result, Blender errors, live-event filtering.
final class BlenderRelayTests: XCTestCase {
    private let sid = "cs_abc123XYZ"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-blender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fakes

    final class FakeTransport: BlenderTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [(String, [String: JSONValue])] = []
        var reply: @Sendable (String, [String: JSONValue]) throws -> JSONValue

        init(reply: @escaping @Sendable (String, [String: JSONValue]) throws -> JSONValue = { _, _ in .object([:]) }) { self.reply = reply }

        var sent: [(String, [String: JSONValue])] { lock.lock(); defer { lock.unlock() }; return _sent }
        var types: [String] { sent.map(\.0) }

        private func record(_ type: String, _ params: [String: JSONValue]) {
            lock.lock()
            _sent.append((type, params))
            lock.unlock()
        }

        func send(_ type: String, _ params: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue {
            record(type, params)
            return try reply(type, params)
        }

        /// `execute_code` output for a script that printed `json`.
        static func stdout(_ json: String) -> JSONValue { .object(["executed": .bool(true), "result": .string("Blender says hi\nMUSE_RESULT:\(json)\n")]) }
    }

    final class FakeAPI: BlenderRelayAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var _log: [String] = []
        private var _results: [String: BlenderCallResult] = [:]
        var claimError: Error?
        var putError: Error?
        private var n = 0

        var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
        var results: [String: BlenderCallResult] { lock.lock(); defer { lock.unlock() }; return _results }
        private func add(_ s: String) { lock.lock(); _log.append(s); lock.unlock() }

        func heartbeat(_ status: BlenderRelayStatus) async throws -> BlenderHeartbeatReply { add("heartbeat"); return BlenderHeartbeatReply() }
        func pendingCalls() async throws -> [BlenderCall] { [] }
        func claim(callId: String) async throws -> BlenderCall {
            add("claim \(callId)")
            if let claimError { throw claimError }
            return BlenderCall(id: callId, sessionId: "cs_abc123XYZ", tool: "blender_status")
        }
        func postResult(callId: String, _ result: BlenderCallResult) async throws {
            add("result \(callId) ok=\(result.ok)")
            store(callId, result)
        }
        private func store(_ id: String, _ r: BlenderCallResult) { lock.lock(); _results[id] = r; lock.unlock() }
        private func nextId() -> String { lock.lock(); defer { lock.unlock() }; n += 1; return "ca_\(n)" }
        func createAsset(sessionId: String, kind: String, contentType: String, bytes: Int64?, label: String?) async throws -> CameraAssetUpload {
            let id = nextId()
            add("create \(kind) \(contentType) \(bytes ?? -1)")
            return CameraAssetUpload(asset: CameraAsset(id: id, kind: kind), upload: CameraUploadTicket(url: "https://r2.example/\(id)?sig=x", headers: ["Content-Type": contentType]))
        }
        func putUpload(url: String, headers: [String: String], contentType: String, file: URL) async throws {
            add("put \(url)")
            if let putError { throw putError }
        }
        func confirmAsset(sessionId: String, assetId: String) async throws -> CameraAsset {
            add("confirm \(assetId)")
            return CameraAsset(id: assetId, kind: "x", state: "ready")
        }
    }

    private func relay(_ t: FakeTransport, _ api: FakeAPI) -> BlenderRelay { BlenderRelay(transport: t, api: api, root: root) }

    private func call(_ tool: String, _ args: JSONValue = .object([:]), id: String = "bc_1", expiresAt: Int64 = 0) -> BlenderCall {
        BlenderCall(id: id, sessionId: sid, tool: tool, args: args, outDir: "CameraSessions/\(sid)", createdAt: 1, expiresAt: expiresAt)
    }

    private func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    private func posted(_ o: BlenderRelay.Outcome) -> BlenderCallResult? {
        if case .posted(let r) = o { return r }
        return nil
    }

    // MARK: Allowlist and args

    func testUnknownToolIsAnsweredWithAnErrorAndNeverRun() async {
        let t = FakeTransport()
        let api = FakeAPI()
        let r = posted(await relay(t, api).handle(call("blender_execute_python", json(#"{"code":"import os"}"#))))
        XCTAssertEqual(r?.ok, false)
        XCTAssertTrue(r?.error?.contains("Unknown Blender tool") ?? false)
        XCTAssertTrue(t.sent.isEmpty)
        XCTAssertEqual(api.log, ["claim bc_1", "result bc_1 ok=false"])
    }

    func testAllowlistIsTheNineTools() {
        XCTAssertEqual(Set(BlenderTool.allCases.map(\.rawValue)), [
            "blender_status", "blender_scene_info", "blender_screenshot", "blender_setup_scene", "blender_place_character",
            "blender_animate_character", "blender_add_prop", "blender_set_camera", "blender_render_guides",
        ])
    }

    func testBadArgumentsAreRefusedBeforeBlender() async {
        let bad: [(String, String)] = [
            ("blender_setup_scene", #"{"fps":100,"durationSec":6,"aspect":"9:16"}"#),
            ("blender_setup_scene", #"{"fps":24,"durationSec":6,"aspect":"3:2"}"#),
            ("blender_setup_scene", #"{"fps":24.5,"durationSec":6,"aspect":"9:16"}"#),
            ("blender_setup_scene", #"{"fps":24,"durationSec":6,"aspect":"9:16","script":"x"}"#),
            ("blender_place_character", #"{"modelId":"../etc","label":"a","heightM":1.7,"position":[0,0,0]}"#),
            ("blender_place_character", #"{"modelId":"m_1","label":"a","heightM":3,"position":[0,0,0]}"#),
            ("blender_place_character", #"{"modelId":"m_1","label":"a","heightM":1.7,"position":[0,0]}"#),
            ("blender_place_character", #"{"modelId":"m_1","label":"a","heightM":1.7,"position":[0,"0",0]}"#),
            ("blender_place_character", #"{"modelId":"m_1","label":"a","heightM":1.7,"position":[0,0,1e9]}"#),
            ("blender_animate_character", #"{"modelId":"m_1","keyframes":[]}"#),
            ("blender_animate_character", #"{"modelId":"m_1","keyframes":[{"t":2,"position":[0,0,0]},{"t":1,"position":[0,0,0]}]}"#),
            ("blender_add_prop", #"{"id":"p1","shape":"torus","size":[1,1,1],"position":[0,0,0]}"#),
            ("blender_add_prop", #"{"id":"p1","shape":"box","size":[1,0,1],"position":[0,0,0]}"#),
            ("blender_set_camera", #"{"keyframes":[{"t":0,"position":[0,-4,1.6],"focalMm":2}]}"#),
            ("blender_set_camera", #"{"keyframes":[{"t":0,"position":[0,-4,1.6],"ease":"bounce"}]}"#),
            ("blender_render_guides", #"{"passes":["greybox","exec"]}"#),
            ("blender_render_guides", #"{"passes":[]}"#),
            ("blender_screenshot", #"{"maxSize":5000}"#),
            ("blender_status", #"{"x":1}"#),
        ]
        let many = (0..<65).map { #"{"t":\#($0 / 3),"position":[0,0,0]}"# }.joined(separator: ",")
        for (i, (tool, args)) in (bad + [("blender_animate_character", #"{"modelId":"m_1","keyframes":[\#(many)]}"#)]).enumerated() {
            let t = FakeTransport()
            let r = posted(await relay(t, FakeAPI()).handle(call(tool, json(args), id: "bc_\(i)")))
            XCTAssertEqual(r?.ok, false, "\(tool) \(args)")
            XCTAssertTrue(r?.error?.hasPrefix("Invalid arguments for \(tool)") ?? false, r?.error ?? "")
            XCTAssertTrue(t.sent.isEmpty, "\(tool) \(args) reached Blender")
        }
    }

    func testBadSessionIdIsRefused() async {
        let t = FakeTransport()
        var c = call("blender_scene_info")
        c.sessionId = "../../etc"
        let r = posted(await relay(t, FakeAPI()).handle(c))
        XCTAssertEqual(r?.ok, false)
        XCTAssertTrue(t.sent.isEmpty)
    }

    func testScriptArgumentsTravelAsBase64Data() async throws {
        let evil = #""); import os; os.system("rm -rf ~") #"#
        let t = FakeTransport { _, _ in FakeTransport.stdout(#"{"ok":true,"object":"MUSE_char_m_1"}"#) }
        let api = FakeAPI()
        let args = JSONValue.object(["modelId": .string("m_1"), "label": .string(evil), "heightM": .number(1.7), "position": .array([.number(1), .number(2), .number(0)]),
                                     "facingDeg": .number(370)])
        let r = posted(await relay(t, api).handle(call("blender_place_character", args)))
        XCTAssertEqual(r?.ok, true)
        XCTAssertEqual(r?.result, .object(["object": .string("MUSE_char_m_1")]))
        XCTAssertEqual(t.types, ["execute_code"])
        guard case .string(let code)? = t.sent.first?.1["code"] else { return XCTFail("no code") }
        XCTAssertFalse(code.contains(evil))
        XCTAssertFalse(code.contains("rm -rf"))
        XCTAssertFalse(code.contains("os.system"))
        // The data line decodes back to exactly the validated args.
        let line = try XCTUnwrap(code.split(separator: "\n").first { $0.hasPrefix("A = json.loads(base64.b64decode(\"") })
        let b64 = line.dropFirst("A = json.loads(base64.b64decode(\"".count).prefix { $0 != "\"" }
        XCTAssertTrue(b64.allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) })
        let decoded = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(Data(base64Encoded: String(b64))))
        XCTAssertEqual(decoded, .object(["modelId": .string("m_1"), "label": .string(evil), "heightM": .number(1.7),
                                         "position": .array([.number(1), .number(2), .number(0)]), "facingDeg": .number(10)]))
    }

    func testScriptsStayInsideTheRules() throws {
        let data: [BlenderTool: [String: JSONValue]] = [
            .setupScene: try BlenderArgs.data(.setupScene, json(#"{"fps":24,"durationSec":6,"aspect":"9:16","clear":true}"#), outDir: "/x"),
            .placeCharacter: try BlenderArgs.data(.placeCharacter, json(#"{"modelId":"m_1","label":"Mia","heightM":1.7,"position":[0,0,0]}"#), outDir: "/x"),
            .animateCharacter: try BlenderArgs.data(.animateCharacter, json(#"{"modelId":"m_1","keyframes":[{"t":0,"position":[0,0,0],"action":"walk"}]}"#), outDir: "/x"),
            .addProp: try BlenderArgs.data(.addProp, json(#"{"id":"table","shape":"box","size":[1,0.6,0.75],"position":[0,1,0]}"#), outDir: "/x"),
            .setCamera: try BlenderArgs.data(.setCamera, json(#"{"keyframes":[{"t":0,"position":[0,-4,1.6]}]}"#), outDir: "/x"),
            .renderGuides: try BlenderArgs.data(.renderGuides, json(#"{"passes":["greybox","keyframes","camera_json","characters_json"]}"#), outDir: "/Users/a/MUSE/CameraSessions/cs_abc123/out"),
        ]
        var scripts: [String] = []
        for (tool, d) in data {
            let code = try XCTUnwrap(BlenderScripts.code(tool, data: d))
            for banned in ["os.system", "subprocess", "socket", "urllib", "requests", "eval(", "exec(", "__import__", "shutil"] {
                XCTAssertFalse(code.contains(banned), "\(tool): \(banned)")
            }
            XCTAssertEqual(code.components(separatedBy: "print(").count - 1, 1, "\(tool) prints once")
            scripts.append(code)
        }
        XCTAssertNil(BlenderScripts.code(.status, data: [:]))
        try assertPythonParses(scripts)
    }

    /// The scripts are valid Python (when python3 is around).
    private func assertPythonParses(_ scripts: [String]) throws {
        let python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { return }
        for (i, s) in scripts.enumerated() {
            let f = root.appendingPathComponent("script\(i).py")
            try s.write(to: f, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = ["-I", "-c", "import ast, sys; ast.parse(open(sys.argv[1]).read())", f.path]
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) + "\n" + s)
        }
    }

    func testSetupSceneSizesAndCameraPathResolution() throws {
        let s = try BlenderArgs.data(.setupScene, json(#"{"fps":30,"durationSec":5,"aspect":"9:16"}"#), outDir: "")
        XCTAssertEqual(s["width"], .number(720))
        XCTAssertEqual(s["height"], .number(1280))
        XCTAssertEqual(s["frameEnd"], .number(150))
        XCTAssertEqual(s["clear"], .bool(false))
        let w = try BlenderArgs.data(.setupScene, json(#"{"fps":24,"durationSec":6,"aspect":"21:9","resolutionShort":1080}"#), outDir: "")
        XCTAssertEqual(w["width"], .number(2520))
        XCTAssertEqual(w["height"], .number(1080))

        let c = try BlenderArgs.data(.setCamera, json(#"""
            {"keyframes":[{"t":0,"position":[0,-4,1.6]},{"t":2,"position":[1,-3,1.6],"target":[0,0,1.5],"focalMm":50,"rollDeg":5},
             {"t":4,"position":[2,-3,1.6],"ease":"linear"}],"cuts":[3]}
            """#), outDir: "")
        guard case .array(let keys)? = c["keyframes"] else { return XCTFail() }
        XCTAssertEqual(keys[0], json(#"{"t":0,"position":[0,-4,1.6],"target":[0,0,1.5],"focalMm":50,"rollDeg":0,"ease":"in_out"}"#))
        XCTAssertEqual(keys[1], json(#"{"t":2,"position":[1,-3,1.6],"target":[0,0,1.5],"focalMm":50,"rollDeg":5,"ease":"cut"}"#))
        XCTAssertEqual(keys[2], json(#"{"t":4,"position":[2,-3,1.6],"target":[0,0,1.5],"focalMm":50,"rollDeg":5,"ease":"linear"}"#))
        XCTAssertEqual(c["sensorMm"], .number(36))
        // A second key at the same time is a hard cut.
        let cut = try BlenderArgs.data(.setCamera, json(#"{"keyframes":[{"t":0,"position":[0,-4,1.6]},{"t":2,"position":[0,-4,1.6]},{"t":2,"position":[3,0,1.6]}]}"#), outDir: "")
        guard case .array(let ck)? = cut["keyframes"], case .object(let k1) = ck[1], case .object(let k2) = ck[2] else { return XCTFail() }
        XCTAssertEqual(k1["ease"], .string("cut"))
        XCTAssertEqual(k2["ease"], .string("in_out"))
        let lone = try BlenderArgs.data(.setCamera, json(#"{"keyframes":[{"t":0,"position":[0,-4,1.6]}]}"#), outDir: "")
        guard case .array(let k1)? = lone["keyframes"], case .object(let o)? = k1.first else { return XCTFail() }
        XCTAssertEqual(o["target"], json("[0,0,1.4]"))
        XCTAssertEqual(o["focalMm"], .number(35))
    }

    // MARK: Results

    func testMuseResultParsing() {
        XCTAssertEqual(BlenderScripts.parseResult("noise\nMUSE_RESULT:{\"a\":1}\nmore"), .object(["a": .number(1)]))
        XCTAssertEqual(BlenderScripts.parseResult("MUSE_RESULT:{\"a\":1}\r\nMUSE_RESULT:{\"a\":2}"), .object(["a": .number(2)]))
        XCTAssertNil(BlenderScripts.parseResult("no result here"))
        XCTAssertNil(BlenderScripts.parseResult("MUSE_RESULT:{broken"))
    }

    func testScriptFailureAndMissingResultBecomeErrors() async {
        let failing = FakeTransport { _, _ in FakeTransport.stdout(#"{"ok":false,"error":"No MUSE_char_m_1 in the scene: place the character first"}"#) }
        let r = posted(await relay(failing, FakeAPI()).handle(call("blender_animate_character", json(#"{"modelId":"m_1","keyframes":[{"t":0,"position":[0,0,0]}]}"#))))
        XCTAssertEqual(r, .failure("No MUSE_char_m_1 in the scene: place the character first"))
        let silent = FakeTransport { _, _ in .object(["executed": .bool(true), "result": .string("")]) }
        let r2 = posted(await relay(silent, FakeAPI()).handle(call("blender_setup_scene", json(#"{"fps":24,"durationSec":6,"aspect":"9:16"}"#))))
        XCTAssertEqual(r2?.ok, false)
        XCTAssertEqual(r2?.error, "The MUSE script gave no result")
    }

    func testBlenderNotRunningPostsAFailure() async {
        let t = FakeTransport { _, _ in throw BlenderError.notConnected }
        let api = FakeAPI()
        let r = posted(await relay(t, api).handle(call("blender_scene_info")))
        XCTAssertEqual(r?.ok, false)
        XCTAssertTrue(r?.error?.contains("Blender isn't connected") ?? false, r?.error ?? "")
        XCTAssertEqual(api.results["bc_1"]?.ok, false)
        // The add-on's Python exception JSON is shortened to type: message.
        XCTAssertEqual(BlenderError.shortMessage(#"{"exception_type":"KeyError","message":"'x'","traceback":"…long…"}"#), "KeyError: 'x'")
    }

    func testStatusPingsAndReadsTheScene() async {
        let t = FakeTransport { type, _ in
            switch type {
            case "ping": return .object(["pong": .bool(true)])
            case "get_addon_info": return .object(["name": .string("MCP for Blender"), "addon_version": .array([.number(1), .number(8)]), "protocol_version": .number(15)])
            default: return .object(["name": .string("Scene"), "object_count": .number(3)])
            }
        }
        let r = posted(await relay(t, FakeAPI()).handle(call("blender_status")))
        XCTAssertEqual(t.types, ["ping", "get_addon_info", "get_scene_info"])
        XCTAssertEqual(r?.result, json(#"{"connected":true,"addonVersion":"1.8","protocol":15,"scene":{"name":"Scene","object_count":3}}"#))
    }

    // MARK: Claim and expiry

    func testClaimedElsewhereIsSkipped() async {
        let t = FakeTransport()
        let api = FakeAPI()
        api.claimError = ApiError("already_claimed", "Taken")
        let o = await relay(t, api).handle(call("blender_scene_info"))
        XCTAssertEqual(o, .skipped("already_claimed"))
        XCTAssertEqual(api.log, ["claim bc_1"])
        XCTAssertTrue(t.sent.isEmpty)
    }

    func testExpiredCallIsSkippedWithoutClaiming() async {
        let t = FakeTransport()
        let api = FakeAPI()
        let past = Int64(Date().timeIntervalSince1970 * 1000) - 1000
        let o = await relay(t, api).handle(call("blender_scene_info", expiresAt: past))
        XCTAssertEqual(o, .skipped("expired"))
        XCTAssertTrue(api.log.isEmpty)
        XCTAssertTrue(t.sent.isEmpty)
    }

    func testDuplicateAndCancelledCallsAreSkipped() async {
        let api = FakeAPI()
        let r = relay(FakeTransport { _, _ in .object([:]) }, api)
        _ = await r.handle(call("blender_scene_info"))
        let again = await r.handle(call("blender_scene_info"))
        XCTAssertEqual(again, .skipped("duplicate"))
        await r.cancel("bc_2")
        let cancelled = await r.handle(call("blender_scene_info", id: "bc_2"))
        XCTAssertEqual(cancelled, .skipped("cancelled"))
        XCTAssertEqual(api.log, ["claim bc_1", "result bc_1 ok=true"])
    }

    // MARK: Uploads

    func testRenderGuidesUploadsEachFileThenPostsAssetIds() async throws {
        let out = root.appendingPathComponent("CameraSessions/\(sid)/out")
        let t = FakeTransport { [out] type, params in
            XCTAssertEqual(type, "execute_code")
            // Blender writes the files, then prints the names.
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data([0, 0, 0, 24]).write(to: out.appendingPathComponent("greybox.mp4"))
            try Data("{\"frames\":[]}".utf8).write(to: out.appendingPathComponent("camera.json"))
            return FakeTransport.stdout(#"{"ok":true,"files":["greybox.mp4","camera.json","../../etc/passwd","notes.txt"],"width":720,"height":1280}"#)
        }
        let api = FakeAPI()
        let r = posted(await relay(t, api).handle(call("blender_render_guides", json(#"{"passes":["greybox","camera_json"]}"#))))
        XCTAssertEqual(r?.ok, true)
        XCTAssertEqual(r?.assetIds, ["ca_1", "ca_2"])
        XCTAssertEqual(api.log, [
            "claim bc_1",
            "create greybox video/mp4 4", "put https://r2.example/ca_1?sig=x", "confirm ca_1",
            "create camera_json application/json 13", "put https://r2.example/ca_2?sig=x", "confirm ca_2",
            "result bc_1 ok=true",
        ])
        guard case .object(let res)? = r?.result else { return XCTFail() }
        XCTAssertEqual(res["assetIds"], json(#"["ca_1","ca_2"]"#))
        XCTAssertNil(res["ok"])
        // The script got the session's out folder as data, and the folder watcher won't upload these again.
        guard case .string(let code)? = t.sent.first?.1["code"] else { return XCTFail() }
        XCTAssertFalse(code.contains(out.path))
        let m = BlenderUploadManifest.load(out)
        XCTAssertTrue(m.isUploaded("greybox.mp4", in: out))
        XCTAssertTrue(m.isUploaded("camera.json", in: out))
        XCTAssertEqual(m.files["camera.json"]?.assetId, "ca_2")
        try Data("{\"frames\":[1]}".utf8).write(to: out.appendingPathComponent("camera.json"))
        XCTAssertFalse(BlenderUploadManifest.load(out).isUploaded("camera.json", in: out)) // changed since
    }

    func testFailedUploadPostsAFailure() async throws {
        let out = root.appendingPathComponent("CameraSessions/\(sid)/out")
        let t = FakeTransport { [out] _, _ in
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data([1]).write(to: out.appendingPathComponent("keyframe_start.png"))
            return FakeTransport.stdout(#"{"ok":true,"files":["keyframe_start.png"]}"#)
        }
        let api = FakeAPI()
        api.putError = ApiError("http_403", "Upload refused (403)")
        let r = posted(await relay(t, api).handle(call("blender_render_guides", json(#"{"passes":["keyframes"]}"#))))
        XCTAssertEqual(r?.ok, false)
        XCTAssertEqual(r?.error, "Rendered, but couldn't upload keyframe_start.png: Upload refused (403)")
        XCTAssertEqual(api.log.last, "result bc_1 ok=false")
    }

    func testScreenshotIsUploadedAsAPreview() async throws {
        let t = FakeTransport { type, params in
            XCTAssertEqual(type, "get_viewport_screenshot")
            XCTAssertEqual(params["max_size"], .number(1024))
            XCTAssertEqual(params["format"], .string("png"))
            guard case .string(let path)? = params["filepath"] else { throw BlenderError.badReply("no path") }
            try Data([0x89, 0x50]).write(to: URL(fileURLWithPath: path))
            return .object(["success": .bool(true), "width": .number(1024), "height": .number(576), "filepath": .string(path)])
        }
        let api = FakeAPI()
        let r = posted(await relay(t, api).handle(call("blender_screenshot", json(#"{"maxSize":1024}"#))))
        XCTAssertEqual(r?.ok, true)
        XCTAssertEqual(r?.assetIds, ["ca_1"])
        XCTAssertEqual(r?.result, json(#"{"width":1024,"height":576,"assetIds":["ca_1"]}"#))
        XCTAssertEqual(api.log, ["claim bc_1", "create preview image/png 2", "put https://r2.example/ca_1?sig=x", "confirm ca_1", "result bc_1 ok=true"])
        let left = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("CameraSessions/\(sid)/out").path)
        XCTAssertFalse(left.contains { $0.hasPrefix("preview_") })
    }

    func testAssetKindsFromFileNames() {
        XCTAssertEqual(BlenderAssetKinds.kind(forFile: "greybox.mp4"), "greybox")
        XCTAssertEqual(BlenderAssetKinds.kind(forFile: "keyframe_mid.png"), "keyframe_mid")
        XCTAssertEqual(BlenderAssetKinds.kind(forFile: "characters.json"), "characters_json")
        XCTAssertEqual(BlenderAssetKinds.kind(forFile: "shot.blend"), "blend")
        XCTAssertNil(BlenderAssetKinds.kind(forFile: "shot.blend1"))
        XCTAssertNil(BlenderAssetKinds.kind(forFile: "preview_bc_1.png"))
        XCTAssertNil(BlenderAssetKinds.kind(forFile: BlenderUploadManifest.fileName))
        XCTAssertEqual(BlenderAssetKinds.contentType(forFile: "camera.json"), "application/json")
    }

    // MARK: Live events and wire format

    func testLiveEventFilter() {
        var f = BlenderLiveEventFilter()
        let lines = [
            ": keep-alive", "",
            #"data: {"type":"job","job":{"id":"j1"}}"#, "",
            #"data: {"type":"blender","op":"call","call":{"id":"bc_9","sessionId":"cs_abc123XYZ","tool":"blender_status","args":{},"#,
            #"data: "outDir":"CameraSessions/cs_abc123XYZ","createdAt":1762300000000,"expiresAt":"2026-11-05T12:00:00.000Z"}}"#, "",
            #"data: {"type":"blender","op":"cancel","id":"bc_9"}"#, "",
            #"data: {"type":"blender","op":"relay","online":true,"blender":{"connected":true,"addonVersion":"1.8","protocol":15}}"#, "",
            #"data: {"type":"blender","op":"relay","online":true,"blender":true,"addonVersion":"1.8"}"#, "",
        ]
        let events = lines.compactMap { f.feed($0) }
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[3], .relay(BlenderRelayStatus(online: true, blender: BlenderLink(connected: true, addonVersion: "1.8"))))
        guard case .call(let c) = events[0] else { return XCTFail() }
        XCTAssertEqual(c.id, "bc_9")
        XCTAssertEqual(c.knownTool, .status)
        XCTAssertEqual(c.createdAt, 1_762_300_000_000)
        XCTAssertEqual(c.expiresAt, 1_793_880_000_000)
        XCTAssertEqual(events[1], .cancel("bc_9"))
        XCTAssertEqual(events[2], .relay(BlenderRelayStatus(online: true, blender: BlenderLink(connected: true, addonVersion: "1.8", protocol: 15))))
    }

    func testWireFormat() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let status = String(decoding: try enc.encode(BlenderRelayStatus(online: true, blender: BlenderLink(connected: false))), as: UTF8.self)
        XCTAssertEqual(status, #"{"blender":{"connected":false},"online":true}"#)
        let result = String(decoding: try enc.encode(BlenderCallResult.failure("Nope")), as: UTF8.self)
        XCTAssertEqual(result, #"{"error":"Nope","ok":false}"#)
        let reply = try JSONDecoder().decode(CameraAssetUpload.self, from: Data(#"""
            {"asset":{"id":"ca_1","kind":"greybox","state":"pending","contentType":"video/mp4","source":"relay","createdAt":1},
             "upload":{"method":"PUT","url":"https://r2/x","headers":{"Content-Type":"video/mp4"},"expiresAt":1762300000000}}
            """#.utf8))
        XCTAssertEqual(reply.asset.id, "ca_1")
        XCTAssertEqual(reply.upload.headers["Content-Type"], "video/mp4")
        let hb = try JSONDecoder().decode(BlenderHeartbeatReply.self, from: Data(#"{"ok":true,"pending":[{"id":"bc_1","sessionId":"cs_abc123XYZ","tool":"blender_status","args":{},"outDir":"x","createdAt":1,"expiresAt":2}]}"#.utf8))
        XCTAssertEqual(hb.pending.first?.expiresAt, 2)
    }

    // MARK: Socket

    func testSocketIsLocalhostOnly() {
        XCTAssertThrowsError(try BlenderSocket(host: "192.168.1.5"))
        XCTAssertThrowsError(try BlenderSocket(host: "example.com"))
        XCTAssertNoThrow(try BlenderSocket(host: "localhost"))
    }

    func testSocketReplyFraming() throws {
        XCTAssertFalse(BlenderSocket.isComplete(Data(#"{"status":"success","result":{"a":"#.utf8)))
        XCTAssertTrue(BlenderSocket.isComplete(Data("{\"status\":\"success\",\"result\":{\"name\":\"Caf\u{e9}\"}}\n".utf8)))
        // A reply cut inside a multi-byte character isn't complete yet.
        var cut = Data("{\"status\":\"success\",\"result\":\"\u{e9}\"}".utf8)
        let tail = cut.suffix(4)
        cut.removeLast(4)
        XCTAssertFalse(BlenderSocket.isComplete(cut))
        cut.append(tail)
        XCTAssertTrue(BlenderSocket.isComplete(cut))
        XCTAssertEqual(try BlenderSocket.unwrap(Data(#"{"status":"success","result":{"pong":true}}"#.utf8)), .object(["pong": .bool(true)]))
        XCTAssertThrowsError(try BlenderSocket.unwrap(Data(#"{"status":"error","message":"Unknown command type: nope"}"#.utf8))) {
            XCTAssertEqual($0 as? BlenderError, .command("Unknown command type: nope"))
        }
    }

    // MARK: Reply reader (the add-on sends one JSON object with no framing)

    private func feedAll(_ chunks: [Data], max: Int = 32 * 1024 * 1024) throws -> Data? {
        var r = ReplyReader(maxReply: max)
        for c in chunks { if case .done(let d) = try r.feed(c) { return d } }
        return nil
    }

    private func chunks(_ d: Data, size: Int) -> [Data] {
        stride(from: 0, to: d.count, by: size).map { d.subdata(in: $0..<min($0 + size, d.count)) }
    }

    func testReaderWaitsForTheWholeObjectAcrossChunks() throws {
        // Braces and quotes inside strings don't close the object; a split "é" doesn't either.
        let reply = Data(#"{"status":"success","result":{"name":"Caf\#u{e9} {x} \"}\" ]","list":[1,{"a":[]}]}}"#.utf8)
        for size in [1, 2, 3, 7, 64] {
            XCTAssertEqual(try feedAll(chunks(reply, size: size)), reply, "chunk size \(size)")
        }
        XCTAssertNil(try feedAll([reply.prefix(reply.count - 1)]))
    }

    func testReaderHandlesALargeReply() throws {
        let items = (0..<40_000).map { #"{"name":"MUSE_obj_\#($0)","location":[1.25,-2.5,0.0]}"# }.joined(separator: ",")
        let reply = Data(#"{"status":"success","result":{"objects":["#.utf8) + Data(items.utf8) + Data("]}}".utf8)
        XCTAssertGreaterThan(reply.count, 1_500_000)
        XCTAssertEqual(try feedAll(chunks(reply, size: 64 * 1024)), reply)
        XCTAssertThrowsError(try feedAll(chunks(reply, size: 64 * 1024), max: 1_048_576)) {
            guard case .badReply? = $0 as? BlenderError else { return XCTFail("\($0)") }
        }
    }

    func testReaderRecognisesBlenderLabsServer() throws {
        // Blender's official MCP add-on (same port) answers a foreign request after 10 s with a NUL-terminated object.
        let lab = Data("{\"status\": \"error\", \"message\": \"Client timed out\"}\0".utf8)
        XCTAssertThrowsError(try feedAll([lab])) { XCTAssertEqual($0 as? BlenderError, .otherServer) }
        XCTAssertThrowsError(try feedAll(chunks(lab, size: 7))) { XCTAssertEqual($0 as? BlenderError, .otherServer) }
        // NUL in a later packet: the object is read, and its words give it away.
        let first = try XCTUnwrap(try feedAll(chunks(lab, size: 5)))
        XCTAssertThrowsError(try BlenderSocket.unwrap(first)) { XCTAssertEqual($0 as? BlenderError, .otherServer) }
        XCTAssertThrowsError(try BlenderSocket.unwrap(Data(#"{"status":"error","message":"Unknown request type: 'ping'"}"#.utf8))) {
            XCTAssertEqual($0 as? BlenderError, .otherServer)
        }
    }

    func testReaderEndOfStream() {
        XCTAssertThrowsError(try ReplyReader(maxReply: 100).finish()) { XCTAssertEqual($0 as? BlenderError, .notConnected) }
        var r = ReplyReader(maxReply: 100)
        XCTAssertEqual(try r.feed(Data(#"{"status":"succ"#.utf8)), .needMore)
        XCTAssertThrowsError(try r.finish()) { XCTAssertEqual($0 as? BlenderError, .badReply("connection closed mid-reply after 15 bytes")) }
        var http = ReplyReader(maxReply: 100)
        XCTAssertThrowsError(try http.feed(Data("HTTP/1.1 400 Bad Request\r\n".utf8))) {
            guard case .badReply(let m)? = $0 as? BlenderError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.hasPrefix("not a JSON object"))
        }
    }

    func testStatusExplainsAnotherServerOnThePort() async {
        let t = FakeTransport { _, _ in throw BlenderError.otherServer }
        let r = posted(await relay(t, FakeAPI()).handle(call("blender_status")))
        XCTAssertEqual(r?.result, .object(["connected": .bool(false), "problem": .string(BlenderError.otherServerText)]))
    }

    /// Against a closed port: notConnected, quickly.
    func testSocketWithNoBlender() async throws {
        let s = try BlenderSocket(port: 1)
        do {
            _ = try await s.send("ping", [:], timeout: 2)
            XCTFail("connected to port 1?")
        } catch {
            XCTAssertEqual(error as? BlenderError, .notConnected)
        }
    }
}
