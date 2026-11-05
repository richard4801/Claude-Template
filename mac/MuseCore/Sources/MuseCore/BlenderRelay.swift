import Foundation

/// The server side of the relay, as the Mac sees it (plans/api.md "MCP & camera sessions"). HTTPBlenderRelayAPI is the real one.
public protocol BlenderRelayAPI: Sendable {
    func heartbeat(_ status: BlenderRelayStatus) async throws -> BlenderHeartbeatReply
    func pendingCalls() async throws -> [BlenderCall]
    func claim(callId: String) async throws -> BlenderCall
    func postResult(callId: String, _ result: BlenderCallResult) async throws
    func createAsset(sessionId: String, kind: String, contentType: String, bytes: Int64?, label: String?) async throws -> CameraAssetUpload
    /// PUT the file to the presigned URL (no MUSE credentials go to storage).
    func putUpload(url: String, headers: [String: String], contentType: String, file: URL) async throws
    func confirmAsset(sessionId: String, assetId: String) async throws -> CameraAsset
}

/// Runs relayed Blender calls: claim → validate → fixed script or native add-on command → upload outputs → post the result.
/// Nothing outside the nine tools is ever sent to Blender, and arguments only ever travel as data.
public actor BlenderRelay {
    public enum Outcome: Equatable, Sendable {
        /// Not run here (duplicate, cancelled, expired, or another Mac claimed it).
        case skipped(String)
        case posted(BlenderCallResult)
        /// Ran, but the result couldn't be posted.
        case unposted(BlenderCallResult, String)
    }

    let transport: BlenderTransport
    let api: BlenderRelayAPI
    /// `~/MUSE`; a session's files live in `CameraSessions/<sessionId>/out`.
    public let root: URL
    let timeout: TimeInterval
    let renderTimeout: TimeInterval
    let now: @Sendable () -> Date

    private var seen: [String] = []
    private var seenSet: Set<String> = []
    private var cancelled: Set<String> = []
    /// The session whose files a call is writing right now (the folder watcher leaves it alone meanwhile).
    public private(set) var busySessionId: String?
    public private(set) var lastCall: String?
    public private(set) var lastError: String?

    public init(transport: BlenderTransport, api: BlenderRelayAPI, root: URL, timeout: TimeInterval = 20, renderTimeout: TimeInterval = 120,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.api = api
        self.root = root
        self.timeout = timeout
        self.renderTimeout = renderTimeout
        self.now = now
    }

    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MUSE", isDirectory: true) }

    public func cancel(_ callId: String) { cancelled.insert(callId) }

    /// `~/MUSE/CameraSessions`.
    public nonisolated var sessionsDir: URL { root.appendingPathComponent("CameraSessions", isDirectory: true) }

    /// `CameraSessions/<sessionId>/out` under the root; nil for an id that isn't `cs_` + 6–64 letters/digits.
    public nonisolated func outDir(sessionId: String) -> URL? {
        guard BlenderArgs.isSessionId(sessionId) else { return nil }
        return sessionsDir.appendingPathComponent(sessionId, isDirectory: true).appendingPathComponent("out", isDirectory: true)
    }

    // MARK: Heartbeat

    /// Is the add-on there, and which version (for POST /v1/blender/relay).
    public func link() async -> BlenderLink {
        do {
            _ = try await transport.send("ping", [:], timeout: 5)
        } catch {
            return BlenderLink(connected: false)
        }
        guard let info = try? await transport.send("get_addon_info", [:], timeout: 5) else { return BlenderLink(connected: true) }
        return BlenderRelay.link(fromAddonInfo: info)
    }

    static func link(fromAddonInfo info: JSONValue) -> BlenderLink {
        guard case .object(let o) = info else { return BlenderLink(connected: true) }
        var version: String?
        for k in ["version", "addon_version", "addonVersion"] {
            switch o[k] {
            case .string(let s)?: version = s
            case .number(let n)?: version = JSONValue.number(n).description
            case .array(let a)?: version = a.map(\.description).joined(separator: ".")
            default: continue
            }
            break
        }
        var proto: Int?
        for k in ["protocol", "protocol_version", "protocolVersion"] {
            if case .number(let n)? = o[k], n.isFinite { proto = Int(n); break }
        }
        return BlenderLink(connected: true, addonVersion: version, protocol: proto)
    }

    // MARK: Calls

    public func handle(_ call: BlenderCall) async -> Outcome {
        if seenSet.contains(call.id) { return .skipped("duplicate") }
        if cancelled.contains(call.id) { return .skipped("cancelled") }
        remember(call.id)
        if call.isExpired(now: now()) { return .skipped("expired") }
        do {
            _ = try await api.claim(callId: call.id)
        } catch let e as ApiError where ["already_claimed", "call_expired", "http_409", "http_410"].contains(e.code) {
            return .skipped(e.code)
        } catch {
            // Offline or a server hiccup: forget it so the next catch-up tries again.
            forget(call.id)
            lastError = "Couldn't claim \(call.tool): \(BlenderRelay.message(error))"
            return .skipped("claim_failed")
        }
        lastCall = call.tool
        let result = await run(call)
        if !result.ok { lastError = result.error }
        do {
            try await api.postResult(callId: call.id, result)
            return .posted(result)
        } catch {
            let m = BlenderRelay.message(error)
            lastError = "Couldn't send the \(call.tool) result: \(m)"
            return .unposted(result, m)
        }
    }

    private func remember(_ id: String) {
        guard seenSet.insert(id).inserted else { return }
        seen.append(id)
        if seen.count > 500 { seenSet.remove(seen.removeFirst()) }
    }

    private func forget(_ id: String) {
        seenSet.remove(id)
        seen.removeAll { $0 == id }
    }

    /// Validate, run and upload. Never throws: every failure becomes `{ok: false, error}`.
    func run(_ call: BlenderCall) async -> BlenderCallResult {
        guard let tool = call.knownTool else { return .failure("Unknown Blender tool “\(call.tool.prefix(64))”; not run") }
        guard let out = outDir(sessionId: call.sessionId) else { return .failure("Bad camera session id") }
        let prepared: BlenderArgs.Prepared
        do {
            prepared = try BlenderArgs.prepare(tool, call.args, outDir: out.path)
        } catch {
            return .failure("Invalid arguments for \(tool.rawValue): \(BlenderRelay.message(error))")
        }
        do {
            switch prepared {
            case .status:
                let link = await self.link()
                var o: [String: JSONValue] = ["connected": .bool(link.connected)]
                if let v = link.addonVersion { o["addonVersion"] = .string(v) }
                if let p = link.protocol { o["protocol"] = .number(Double(p)) }
                if link.connected { o["scene"] = try await transport.send("get_scene_info", [:], timeout: timeout) }
                return BlenderCallResult(ok: true, result: BlenderRelay.capped(.object(o)))
            case .sceneInfo:
                return BlenderCallResult(ok: true, result: BlenderRelay.capped(try await transport.send("get_scene_info", [:], timeout: timeout)))
            case .screenshot(let maxSize):
                return try await screenshot(call, out: out, maxSize: maxSize)
            case .script(let code):
                let render = tool == .renderGuides
                if render {
                    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                    busySessionId = call.sessionId
                }
                defer { if render { busySessionId = nil } }
                let reply = try await transport.send("execute_code", ["code": .string(code)], timeout: render ? renderTimeout : timeout)
                guard case .object(let r) = reply, case .string(let stdout)? = r["result"] else { return .failure("Blender gave no script output") }
                guard case .object(var res)? = BlenderScripts.parseResult(stdout) else { return .failure("The MUSE script gave no result") }
                if case .bool(false)? = res["ok"] {
                    if case .string(let e)? = res["error"] { return .failure(String(e.prefix(300))) }
                    return .failure("The MUSE script failed")
                }
                res["ok"] = nil
                guard render else { return BlenderCallResult(ok: true, result: BlenderRelay.capped(.object(res))) }
                return try await uploadOutputs(call, out: out, result: res)
            }
        } catch {
            return .failure(BlenderRelay.message(error))
        }
    }

    private func screenshot(_ call: BlenderCall, out: URL, maxSize: Int) async throws -> BlenderCallResult {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let name = "preview_\(BlenderArgs.isId(call.id) ? call.id : "call").png"
        let file = out.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reply = try await transport.send("get_viewport_screenshot", ["max_size": .number(Double(maxSize)), "filepath": .string(file.path), "format": .string("png")],
                                             timeout: timeout)
        if case .object(let o) = reply, case .string(let e)? = o["error"] { return .failure("Blender: \(e.prefix(300))") }
        guard FileManager.default.fileExists(atPath: file.path) else { return .failure("Blender didn't write the screenshot") }
        let id = try await upload(sessionId: call.sessionId, file: file, kind: "preview", label: "Blender viewport")
        var res: [String: JSONValue] = [:]
        if case .object(let o) = reply {
            for k in ["width", "height"] { if let v = o[k] { res[k] = v } }
        }
        res["assetIds"] = .array([.string(id)])
        return BlenderCallResult(ok: true, result: .object(res), assetIds: [id])
    }

    private func uploadOutputs(_ call: BlenderCall, out: URL, result: [String: JSONValue]) async throws -> BlenderCallResult {
        var names: [String] = []
        if case .array(let a)? = result["files"] {
            for case .string(let n) in a where BlenderAssetKinds.kind(forFile: n) != nil && !n.contains("/") && !names.contains(n) { names.append(n) }
        }
        var ids: [String] = []
        var manifest = BlenderUploadManifest.load(out)
        for n in names {
            let file = out.appendingPathComponent(n)
            guard let kind = BlenderAssetKinds.kind(forFile: n), FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                let id = try await upload(sessionId: call.sessionId, file: file, kind: kind, label: n)
                ids.append(id)
                manifest.mark(n, in: out, assetId: id)
            } catch {
                manifest.save(out)
                return .failure("Rendered, but couldn't upload \(n): \(BlenderRelay.message(error))", assetIds: ids)
            }
        }
        manifest.save(out)
        var res = result
        res["assetIds"] = .array(ids.map { .string($0) })
        return BlenderCallResult(ok: true, result: BlenderRelay.capped(.object(res)), assetIds: ids)
    }

    /// presign → PUT → confirm. The asset id.
    public func upload(sessionId: String, file: URL, kind: String, label: String?) async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value
        let type = BlenderAssetKinds.contentType(forFile: file.lastPathComponent)
        let ticket = try await api.createAsset(sessionId: sessionId, kind: kind, contentType: type, bytes: (size ?? 0) > 0 ? size : nil, label: label)
        try await api.putUpload(url: ticket.upload.url, headers: ticket.upload.headers, contentType: type, file: file)
        return try await api.confirmAsset(sessionId: sessionId, assetId: ticket.asset.id).id
    }

    /// Results are ≤ 256 KB on the server.
    static func capped(_ v: JSONValue) -> JSONValue {
        guard let d = try? JSONEncoder().encode(v), d.count > 250_000 else { return v }
        return .object(["truncated": .bool(true), "note": .string("Result too large to send (\(d.count / 1024) KB)")])
    }

    static func message(_ error: Error) -> String {
        if let e = error as? ApiError { return e.message }
        if let e = error as? BlenderError { return e.errorDescription ?? "Blender error" }
        if let e = error as? BlenderArgs.Invalid { return e.message }
        return error.localizedDescription
    }
}

// MARK: - Arguments

/// Strict argument checks (ranges from plans/api.md) and the data each script gets. Unknown keys are refused.
public enum BlenderArgs {
    public struct Invalid: Error, Equatable, LocalizedError {
        public var message: String
        init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public enum Prepared: Equatable {
        case status, sceneInfo
        case screenshot(maxSize: Int)
        case script(String)
    }

    static let aspects: [String: (Int, Int)] = ["9:16": (9, 16), "16:9": (16, 9), "1:1": (1, 1), "4:5": (4, 5), "21:9": (21, 9)]
    static let passes: Set<String> = ["greybox", "keyframes", "camera_json", "characters_json"]
    static let eases: Set<String> = ["linear", "in", "out", "in_out"]
    static let shapes: Set<String> = ["box", "cylinder", "sphere", "plane"]
    /// Blender object names are ≤ 63 bytes; "MUSE_char_" / "MUSE_prop_" take 10.
    static let maxNameId = 53

    public static func isId(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-" }
    }

    public static func isSessionId(_ s: String) -> Bool {
        guard s.hasPrefix("cs_") else { return false }
        let rest = s.dropFirst(3)
        return (6...64).contains(rest.count) && rest.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    public static func prepare(_ tool: BlenderTool, _ args: JSONValue, outDir: String) throws -> Prepared {
        switch tool {
        case .status:
            _ = try object(args, allowed: [])
            return .status
        case .sceneInfo:
            _ = try object(args, allowed: [])
            return .sceneInfo
        case .screenshot:
            let o = try object(args, allowed: ["maxSize"])
            return .screenshot(maxSize: try int(o, "maxSize", 256...1600, default: 800))
        default:
            return .script(BlenderScripts.code(tool, data: try data(tool, args, outDir: outDir)) ?? "")
        }
    }

    /// The validated data a script gets as `A`.
    public static func data(_ tool: BlenderTool, _ args: JSONValue, outDir: String) throws -> [String: JSONValue] {
        switch tool {
        case .setupScene:
            let o = try object(args, allowed: ["fps", "durationSec", "aspect", "resolutionShort", "clear"])
            let fps = try int(o, "fps", 12...60, default: 24)
            let dur = try number(o, "durationSec", 1...30, default: 6)
            let aspectValue = o["aspect"] ?? .string("9:16")
            guard case .string(let aspect) = aspectValue, let ratio = aspects[aspect] else { throw Invalid("aspect must be one of 9:16, 16:9, 1:1, 4:5, 21:9") }
            let short = try int(o, "resolutionShort", 480...1080, default: 720)
            let (w, h) = size(ratio, short: short)
            return ["fps": .number(Double(fps)), "frameEnd": .number(Double(max(1, Int((dur * Double(fps)).rounded())))),
                    "width": .number(Double(w)), "height": .number(Double(h)), "clear": .bool(try bool(o, "clear", default: false))]
        case .placeCharacter:
            let o = try object(args, allowed: ["modelId", "label", "heightM", "position", "facingDeg"])
            return ["modelId": .string(try nameId(o, "modelId")), "label": .string(try text(o, "label", max: 80, default: "")),
                    "heightM": .number(try number(o, "heightM", 1.2...2.2, default: 1.68)), "position": vec(try vec3(o, "position", 1000)),
                    "facingDeg": .number(normalized(try number(o, "facingDeg", -3600...3600, default: 0)))]
        case .animateCharacter:
            let o = try object(args, allowed: ["modelId", "keyframes"])
            let keys = try array(o, "keyframes", 1...64)
            var out: [JSONValue] = []
            var last = -1.0
            for (i, k) in keys.enumerated() {
                let ko = try object(k, allowed: ["t", "position", "facingDeg", "action"], what: "keyframes[\(i)]")
                let t = try number(ko, "t", 0...30, required: true)
                guard t >= last else { throw Invalid("keyframes must be in time order") }
                last = t
                var e: [String: JSONValue] = ["t": .number(t), "position": vec(try vec3(ko, "position", 1000))]
                if ko["facingDeg"] != nil, ko["facingDeg"] != .null { e["facingDeg"] = .number(normalized(try number(ko, "facingDeg", -3600...3600, required: true))) }
                if let a = try optionalText(ko, "action", max: 80) { e["action"] = .string(a) }
                out.append(.object(e))
            }
            return ["modelId": .string(try nameId(o, "modelId")), "keyframes": .array(out)]
        case .addProp:
            let o = try object(args, allowed: ["id", "shape", "size", "position", "rotationDeg"])
            guard case .string(let shape)? = o["shape"], shapes.contains(shape) else { throw Invalid("shape must be box, cylinder, sphere or plane") }
            let size = try vec3(o, "size", 100)
            for (i, s) in size.enumerated() where s < 0 || (s < 0.001 && !(shape == "plane" && i == 2)) {
                throw Invalid("size must be 0.001–100 m on each axis")
            }
            let rot = o["rotationDeg"] == nil || o["rotationDeg"] == .null ? [0, 0, 0] : try vec3(o, "rotationDeg", 3600)
            return ["id": .string(try nameId(o, "id")), "shape": .string(shape), "size": vec(size), "position": vec(try vec3(o, "position", 1000)),
                    "rotationDeg": vec(rot)]
        case .setCamera:
            return try cameraPath(args)
        case .renderGuides:
            let o = try object(args, allowed: ["passes", "resolutionShort"])
            let list = try array(o, "passes", 1...4)
            var ps: [String] = []
            for p in list {
                guard case .string(let s) = p, passes.contains(s) else { throw Invalid("passes are greybox, keyframes, camera_json, characters_json") }
                if !ps.contains(s) { ps.append(s) }
            }
            return ["passes": .array(ps.map { .string($0) }), "resolutionShort": .number(Double(try int(o, "resolutionShort", 480...1080, default: 0))),
                    "outDir": .string(outDir)]
        case .status, .sceneInfo, .screenshot:
            return [:]
        }
    }

    /// CameraPath → fully resolved keys: a missing target is the previous key's (else the next one's, else [0, 0, 1.4]);
    /// focal length likewise (else 35 mm); roll carries over (else 0); ease defaults to in_out; the key before each cut
    /// (a `cuts` time, or a second key at the same t) holds.
    static func cameraPath(_ args: JSONValue) throws -> [String: JSONValue] {
        let o = try object(args, allowed: ["keyframes", "cuts", "sensorMm"])
        let keys = try array(o, "keyframes", 1...64)
        struct K { var t: Double; var pos: [Double]; var target: [Double]?; var focal: Double?; var roll: Double?; var ease: String? }
        var ks: [K] = []
        var last = -1.0
        for (i, k) in keys.enumerated() {
            let ko = try object(k, allowed: ["t", "position", "target", "focalMm", "rollDeg", "ease"], what: "keyframes[\(i)]")
            let t = try number(ko, "t", 0...30, required: true)
            guard t >= last else { throw Invalid("keyframes must be in time order") }
            last = t
            let target = ko["target"] == nil || ko["target"] == .null ? nil : try vec3(ko, "target", 1000)
            let focal = ko["focalMm"] == nil || ko["focalMm"] == .null ? nil : try number(ko, "focalMm", 8...300, required: true)
            let roll = ko["rollDeg"] == nil || ko["rollDeg"] == .null ? nil : try number(ko, "rollDeg", -180...180, required: true)
            var ease: String?
            if let e = ko["ease"], e != .null {
                guard case .string(let s) = e, eases.contains(s) else { throw Invalid("ease must be linear, in, out or in_out") }
                ease = s
            }
            ks.append(K(t: t, pos: try vec3(ko, "position", 1000), target: target, focal: focal, roll: roll, ease: ease))
        }
        var cuts: [Double] = []
        if let c = o["cuts"], c != .null {
            for v in try array(o, "cuts", 0...64) {
                guard case .number(let n) = v, n.isFinite, (0...30).contains(n) else { throw Invalid("cuts must be times 0–30 s") }
                cuts.append(n)
            }
        }
        let sensor = try number(o, "sensorMm", 1...100, default: 36)
        var eases = ks.map { $0.ease ?? "in_out" }
        for c in cuts { if let i = ks.lastIndex(where: { $0.t < c }) { eases[i] = "cut" } }
        // Two keys at the same time are a hard cut (the script puts the second one frame later).
        for i in ks.indices.dropFirst() where ks[i].t == ks[i - 1].t { eases[i - 1] = "cut" }
        var out: [JSONValue] = []
        var roll = 0.0
        for (i, k) in ks.enumerated() {
            let target = k.target ?? ks[..<i].last(where: { $0.target != nil })?.target ?? ks[i...].first(where: { $0.target != nil })?.target ?? [0, 0, 1.4]
            let focal = k.focal ?? ks[..<i].last(where: { $0.focal != nil })?.focal ?? ks[i...].first(where: { $0.focal != nil })?.focal ?? 35
            roll = k.roll ?? roll
            out.append(.object(["t": .number(k.t), "position": vec(k.pos), "target": vec(target), "focalMm": .number(focal), "rollDeg": .number(roll),
                                "ease": .string(eases[i])]))
        }
        return ["keyframes": .array(out), "cuts": .array(cuts.map { .number($0) }), "sensorMm": .number(sensor)]
    }

    /// Width × height for an aspect with the short side `short`, both even (H.264).
    static func size(_ r: (Int, Int), short: Int) -> (Int, Int) {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        if r.0 == r.1 { return (even(Double(short)), even(Double(short))) }
        if r.0 < r.1 { return (even(Double(short)), even(Double(short) * Double(r.1) / Double(r.0))) }
        return (even(Double(short) * Double(r.0) / Double(r.1)), even(Double(short)))
    }

    static func normalized(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    // MARK: Readers

    static func object(_ v: JSONValue, allowed: Set<String>, what: String = "arguments") throws -> [String: JSONValue] {
        let o: [String: JSONValue]
        switch v {
        case .null: o = [:]
        case .object(let x): o = x
        default: throw Invalid("\(what) must be an object")
        }
        if let k = o.keys.sorted().first(where: { !allowed.contains($0) }) { throw Invalid("unknown field “\(k.prefix(40))” in \(what)") }
        return o
    }

    static func number(_ o: [String: JSONValue], _ k: String, _ range: ClosedRange<Double>, default def: Double? = nil, required: Bool = false) throws -> Double {
        switch o[k] {
        case .number(let n)?:
            guard n.isFinite, range.contains(n) else { throw Invalid("\(k) must be \(fmt(range.lowerBound))–\(fmt(range.upperBound))") }
            return n
        case nil, .null?:
            if let def, !required { return def }
            throw Invalid("\(k) is required")
        default:
            throw Invalid("\(k) must be a number")
        }
    }

    static func int(_ o: [String: JSONValue], _ k: String, _ range: ClosedRange<Int>, default def: Int) throws -> Int {
        if o[k] == nil || o[k] == .null { return def }
        let n = try number(o, k, Double(range.lowerBound)...Double(range.upperBound), required: true)
        guard n == n.rounded() else { throw Invalid("\(k) must be a whole number") }
        return Int(n)
    }

    static func bool(_ o: [String: JSONValue], _ k: String, default def: Bool) throws -> Bool {
        switch o[k] {
        case .bool(let b)?: return b
        case nil, .null?: return def
        default: throw Invalid("\(k) must be true or false")
        }
    }

    static func vec3(_ o: [String: JSONValue], _ k: String, _ limit: Double) throws -> [Double] {
        guard case .array(let a)? = o[k], a.count == 3 else { throw Invalid("\(k) must be [x, y, z]") }
        return try a.map {
            guard case .number(let n) = $0, n.isFinite, abs(n) <= limit else { throw Invalid("\(k) values must be numbers within ±\(fmt(limit))") }
            return n
        }
    }

    static func array(_ o: [String: JSONValue], _ k: String, _ count: ClosedRange<Int>) throws -> [JSONValue] {
        guard case .array(let a)? = o[k] else { throw Invalid("\(k) must be a list") }
        guard count.contains(a.count) else { throw Invalid("\(k) must have \(count.lowerBound)–\(count.upperBound) items") }
        return a
    }

    static func nameId(_ o: [String: JSONValue], _ k: String) throws -> String {
        guard case .string(let s)? = o[k], isId(s), s.count <= maxNameId else { throw Invalid("\(k) must be 1–\(maxNameId) letters, digits, _ or -") }
        return s
    }

    static func text(_ o: [String: JSONValue], _ k: String, max: Int, default def: String) throws -> String {
        try optionalText(o, k, max: max) ?? def
    }

    /// Free text is only ever data (base64 in the script); control characters are dropped.
    static func optionalText(_ o: [String: JSONValue], _ k: String, max: Int) throws -> String? {
        switch o[k] {
        case nil, .null?: return nil
        case .string(let s)?:
            guard s.count <= max else { throw Invalid("\(k) must be at most \(max) characters") }
            return String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        default: throw Invalid("\(k) must be text")
        }
    }

    static func vec(_ v: [Double]) -> JSONValue { .array(v.map { .number($0) }) }

    static func fmt(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e9 ? String(Int(d)) : String(d) }
}

// MARK: - Live events

/// Picks the `blender` events out of the GET /v1/events stream. Feed it SSE lines (without line endings).
public struct BlenderLiveEventFilter: Sendable {
    private var parser = SSEParser()

    public init() {}

    public mutating func feed(_ line: String) -> BlenderLiveEvent? {
        guard let payload = parser.feed(line) else { return nil }
        return BlenderLiveEventFilter.parse(Data(payload.utf8))
    }

    private struct Envelope: Decodable {
        var type: String
        var op: String?
        var id: String?
        var call: BlenderCall?
        var online: Bool?
        /// The server sends `blender: boolean` (+ `addonVersion`); a link object is accepted too.
        var blender: JSONValue?
        var addonVersion: String?
    }

    /// One event's JSON (`{type: "blender", op: "call", call}` / `{op: "cancel", id}` / `{op: "relay", online, blender}`).
    public static func parse(_ json: Data) -> BlenderLiveEvent? {
        guard let e = try? JSONDecoder().decode(Envelope.self, from: json), e.type == "blender" else { return nil }
        switch e.op {
        case "call": return e.call.map { .call($0) }
        case "cancel": return e.id.map { .cancel($0) }
        case "relay":
            var link = BlenderLink(connected: false, addonVersion: e.addonVersion)
            switch e.blender {
            case .bool(let b)?: link.connected = b
            case .object(let o)?:
                if case .bool(let b)? = o["connected"] { link.connected = b }
                if case .string(let v)? = o["addonVersion"] { link.addonVersion = v }
                if case .number(let n)? = o["protocol"], n.isFinite { link.protocol = Int(n) }
            default: break
            }
            return .relay(BlenderRelayStatus(online: e.online ?? false, blender: link))
        default: return nil
        }
    }
}

// MARK: - Upload manifest

/// `.muse-uploaded.json` in a session's `out` folder: which files are already session assets (by size and modification time),
/// so the folder watcher doesn't upload a relay render again, and re-uploads a file that changed.
public struct BlenderUploadManifest: Codable, Sendable, Equatable {
    public static let fileName = ".muse-uploaded.json"

    public struct Entry: Codable, Sendable, Equatable {
        public var size: Int64
        public var mtime: Double
        public var assetId: String
    }

    public var files: [String: Entry] = [:]

    public init() {}

    public static func load(_ dir: URL) -> BlenderUploadManifest {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(fileName)), let m = try? JSONDecoder().decode(BlenderUploadManifest.self, from: d) else {
            return BlenderUploadManifest()
        }
        return m
    }

    public func save(_ dir: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let d = try? enc.encode(self) else { return }
        try? d.write(to: dir.appendingPathComponent(BlenderUploadManifest.fileName), options: .atomic)
    }

    /// Size and modification time of a file, if it exists.
    public static func stamp(_ file: URL) -> (size: Int64, mtime: Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: file.path), let size = (a[.size] as? NSNumber)?.int64Value else { return nil }
        return (size, (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }

    public func isUploaded(_ name: String, in dir: URL) -> Bool {
        guard let e = files[name], let s = BlenderUploadManifest.stamp(dir.appendingPathComponent(name)) else { return false }
        return e.size == s.size && abs(e.mtime - s.mtime) < 0.001
    }

    public mutating func mark(_ name: String, in dir: URL, assetId: String) {
        guard let s = BlenderUploadManifest.stamp(dir.appendingPathComponent(name)) else { return }
        files[name] = Entry(size: s.size, mtime: s.mtime, assetId: assetId)
    }
}
