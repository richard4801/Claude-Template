import Foundation

// Blender relay (plans/api.md "MCP & camera sessions", 2026-11-05): the server hands Blender tool calls to the owner's Mac,
// which runs each as a fixed MUSE script (or a native add-on command) against the MCP for Blender add-on on 127.0.0.1:9876
// and posts the result back. Renders go straight to storage as camera-session assets. Owner only.

/// The Blender tools the relay will run. Anything else is refused without touching Blender.
public enum BlenderTool: String, CaseIterable, Codable, Sendable {
    case status = "blender_status"
    case sceneInfo = "blender_scene_info"
    case screenshot = "blender_screenshot"
    case setupScene = "blender_setup_scene"
    case placeCharacter = "blender_place_character"
    case animateCharacter = "blender_animate_character"
    case addProp = "blender_add_prop"
    case setCamera = "blender_set_camera"
    case renderGuides = "blender_render_guides"
}

/// One relayed call (`blender` live event `{op: "call", call}`, the heartbeat's `pending`, GET /v1/blender/calls).
public struct BlenderCall: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sessionId: String
    /// Kept as a string: an unknown tool must still decode so it can be answered with an error.
    public var tool: String
    public var args: JSONValue
    public var outDir: String?
    /// Epoch ms.
    public var createdAt: Int64
    /// Epoch ms; 0 = no expiry given.
    public var expiresAt: Int64

    public init(id: String, sessionId: String, tool: String, args: JSONValue = .object([:]), outDir: String? = nil, createdAt: Int64 = 0, expiresAt: Int64 = 0) {
        self.id = id
        self.sessionId = sessionId
        self.tool = tool
        self.args = args
        self.outDir = outDir
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case id, sessionId, tool, args, outDir, createdAt, expiresAt }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        tool = try c.decode(String.self, forKey: .tool)
        args = try c.decodeIfPresent(JSONValue.self, forKey: .args) ?? .object([:])
        outDir = try c.decodeIfPresent(String.self, forKey: .outDir)
        createdAt = BlenderCall.millis(c, .createdAt)
        expiresAt = BlenderCall.millis(c, .expiresAt)
    }

    /// Epoch ms, or an ISO-8601 date string.
    static func millis(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Int64 {
        if let n = try? c.decode(Double.self, forKey: k), n.isFinite { return Int64(n) }
        guard let s = try? c.decode(String.self, forKey: k) else { return 0 }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
    }

    public var knownTool: BlenderTool? { BlenderTool(rawValue: tool) }

    public func isExpired(now: Date = Date()) -> Bool {
        expiresAt > 0 && Int64(now.timeIntervalSince1970 * 1000) >= expiresAt
    }
}

/// What the Mac knows about the add-on (heartbeat body's `blender`).
public struct BlenderLink: Codable, Sendable, Equatable {
    public var connected: Bool
    public var addonVersion: String?
    public var `protocol`: Int?

    public init(connected: Bool, addonVersion: String? = nil, protocol: Int? = nil) {
        self.connected = connected
        self.addonVersion = addonVersion
        self.protocol = `protocol`
    }
}

/// POST /v1/blender/relay body (and the `blender` `{op: "relay"}` event).
public struct BlenderRelayStatus: Codable, Sendable, Equatable {
    public var online: Bool
    public var blender: BlenderLink

    public init(online: Bool, blender: BlenderLink) {
        self.online = online
        self.blender = blender
    }
}

/// POST /v1/blender/relay reply.
public struct BlenderHeartbeatReply: Codable, Sendable {
    public var ok: Bool
    public var pending: [BlenderCall]

    public init(ok: Bool = true, pending: [BlenderCall] = []) {
        self.ok = ok
        self.pending = pending
    }

    enum CodingKeys: String, CodingKey { case ok, pending }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        pending = try c.decodeIfPresent([BlenderCall].self, forKey: .pending) ?? []
    }
}

/// POST /v1/blender/calls/{id}/result body.
public struct BlenderCallResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var result: JSONValue?
    public var error: String?
    public var assetIds: [String]?

    public init(ok: Bool, result: JSONValue? = nil, error: String? = nil, assetIds: [String]? = nil) {
        self.ok = ok
        self.result = result
        self.error = error
        self.assetIds = assetIds
    }

    public static func failure(_ message: String, assetIds: [String]? = nil) -> BlenderCallResult {
        BlenderCallResult(ok: false, error: message, assetIds: assetIds?.isEmpty == false ? assetIds : nil)
    }
}

/// A camera session asset (only the fields the relay needs).
public struct CameraAsset: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: String
    public var label: String?
    public var state: String
    public var contentType: String?
    public var bytes: Int64?
    // Workstream 2: camera sessions UI (Guides, History): who made it ("app"|"mcp"|"relay"|"chat"), its presigned GET (ready only), when (ms).
    public var source: String?
    public var url: String?
    public var createdAt: Double?

    public init(id: String, kind: String, label: String? = nil, state: String = "pending", contentType: String? = nil, bytes: Int64? = nil,
                source: String? = nil, url: String? = nil, createdAt: Double? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.state = state
        self.contentType = contentType
        self.bytes = bytes
        self.source = source
        self.url = url
        self.createdAt = createdAt
    }
}

/// POST /v1/camera-sessions/{id}/assets body.
public struct CameraAssetRequest: Codable, Sendable, Equatable {
    public var kind: String
    public var contentType: String
    public var bytes: Int64?
    public var label: String?

    public init(kind: String, contentType: String, bytes: Int64?, label: String?) {
        self.kind = kind
        self.contentType = contentType
        self.bytes = bytes
        self.label = label
    }
}

/// The presigned PUT for a new asset.
public struct CameraUploadTicket: Codable, Sendable, Equatable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var expiresAt: JSONValue?

    public init(method: String = "PUT", url: String, headers: [String: String] = [:], expiresAt: JSONValue? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case method, url, headers, expiresAt }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "PUT"
        url = try c.decode(String.self, forKey: .url)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        expiresAt = try c.decodeIfPresent(JSONValue.self, forKey: .expiresAt)
    }
}

/// POST /v1/camera-sessions/{id}/assets reply.
public struct CameraAssetUpload: Codable, Sendable, Equatable {
    public var asset: CameraAsset
    public var upload: CameraUploadTicket

    public init(asset: CameraAsset, upload: CameraUploadTicket) {
        self.asset = asset
        self.upload = upload
    }
}

/// `blender` live events.
public enum BlenderLiveEvent: Sendable, Equatable {
    case call(BlenderCall)
    case cancel(String)
    case relay(BlenderRelayStatus)
}

/// Asset kinds and content types for the files MUSE writes into a session's `out` folder.
public enum BlenderAssetKinds {
    /// The asset kind for a finished file in `out/` (relay renders, or files Claude Desktop / Code dropped there); nil = not uploaded.
    public static func kind(forFile name: String) -> String? {
        switch name.lowercased() {
        case "greybox.mp4": return "greybox"
        case "depth.mp4": return "depth"
        case "pose.mp4": return "pose"
        case "tracks.mp4": return "tracks"
        case "keyframe_start.png": return "keyframe_start"
        case "keyframe_mid.png": return "keyframe_mid"
        case "keyframe_end.png": return "keyframe_end"
        case "camera.json": return "camera_json"
        case "characters.json": return "characters_json"
        case "set.json": return "set_json"
        default:
            let n = name.lowercased()
            return n.hasSuffix(".blend") && !n.hasPrefix(".") ? "blend" : nil
        }
    }

    public static func contentType(forFile name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4": return "video/mp4"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
}
