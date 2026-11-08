import Foundation

/// The built edit rendered on the server (workstream 1, plans/api.md "The built edit, rendered"): Compare's "Your edit".
/// `GET|POST /v1/edit-sessions/{id}/preview` → this. Decoded leniently; `url` is authenticated (load with the session token).
public struct EditPreviewRender: Codable, Hashable, Sendable {
    public var sessionId: String
    public var revision: Int?
    /// none | rendering | ready | failed
    public var state: String
    public var url: String?
    public var durationSec: Double?
    public var width: Int?
    public var height: Int?
    /// What the server render doesn't draw (rotation, masks, captions…): non-empty = "Preview of the cut".
    public var unsupported: [String]
    public var error: String?

    public var isReady: Bool { state == "ready" && url != nil }
    public var isRendering: Bool { state == "rendering" }
    public var isFailed: Bool { state == "failed" }
    /// The server's picture leaves something out: the player says "Preview of the cut".
    public var isCutOnly: Bool { !unsupported.isEmpty }

    public init(sessionId: String, revision: Int? = nil, state: String, url: String? = nil, durationSec: Double? = nil, width: Int? = nil,
                height: Int? = nil, unsupported: [String] = [], error: String? = nil) {
        self.sessionId = sessionId; self.revision = revision; self.state = state; self.url = url; self.durationSec = durationSec
        self.width = width; self.height = height; self.unsupported = unsupported; self.error = error
    }

    enum CodingKeys: String, CodingKey { case sessionId, revision, state, url, durationSec, width, height, unsupported, error }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sessionId = c.o(.sessionId) ?? ""
        revision = c.o(.revision)
        state = c.o(.state) ?? "none"
        url = c.o(.url)
        durationSec = c.o(.durationSec)
        width = c.o(.width)
        height = c.o(.height)
        unsupported = c.o(.unsupported) ?? []
        error = c.o(.error)
    }
}

/// "Post with the original sound": the platform's own steps, shown next to the export.
public struct UseThisSound: Codable, Hashable, Sendable {
    /// tiktok | instagram | youtube | nil (a file reference: general steps)
    public var platform: String?
    public var sourceUrl: String?
    public var startAtSec: Double?
    public var durationSec: Double?
    public var title: String
    public var steps: [String]
    public var note: String?

    public init(platform: String? = nil, sourceUrl: String? = nil, startAtSec: Double? = 0, durationSec: Double? = nil, title: String, steps: [String], note: String? = nil) {
        self.platform = platform; self.sourceUrl = sourceUrl; self.startAtSec = startAtSec; self.durationSec = durationSec
        self.title = title; self.steps = steps; self.note = note
    }

    enum CodingKeys: String, CodingKey { case platform, sourceUrl, startAtSec, durationSec, title, steps, note }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        platform = c.o(.platform)
        sourceUrl = c.o(.sourceUrl)
        startAtSec = c.o(.startAtSec)
        durationSec = c.o(.durationSec)
        title = c.o(.title) ?? "Post with the original sound"
        steps = c.o(.steps) ?? []
        note = c.o(.note)
    }
}

/// `POST|GET /v1/recreate/references/{id}/export` → this: the built edit, as long as the reference, with its sound as a
/// guide track or silent. `url` (authenticated) is the file once `ready`.
public struct RecreateServerExport: Codable, Hashable, Sendable {
    public var referenceId: String
    public var sessionId: String
    public var revision: Int?
    /// guide | silent
    public var sound: String
    /// none | rendering | ready | failed
    public var state: String
    public var url: String?
    public var durationSec: Double?
    public var width: Int?
    public var height: Int?
    public var unsupported: [String]
    public var error: String?
    public var useThisSound: UseThisSound?

    public var isReady: Bool { state == "ready" && url != nil }
    public var isRendering: Bool { state == "rendering" }
    public var isFailed: Bool { state == "failed" }

    public init(referenceId: String, sessionId: String, revision: Int? = nil, sound: String, state: String, url: String? = nil, durationSec: Double? = nil,
                unsupported: [String] = [], error: String? = nil, useThisSound: UseThisSound? = nil) {
        self.referenceId = referenceId; self.sessionId = sessionId; self.revision = revision; self.sound = sound; self.state = state
        self.url = url; self.durationSec = durationSec; self.unsupported = unsupported; self.error = error; self.useThisSound = useThisSound
    }

    enum CodingKeys: String, CodingKey { case referenceId, sessionId, revision, sound, state, url, durationSec, width, height, unsupported, error, useThisSound }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        referenceId = c.o(.referenceId) ?? ""
        sessionId = c.o(.sessionId) ?? ""
        revision = c.o(.revision)
        sound = c.o(.sound) ?? "guide"
        state = c.o(.state) ?? "none"
        url = c.o(.url)
        durationSec = c.o(.durationSec)
        width = c.o(.width)
        height = c.o(.height)
        unsupported = c.o(.unsupported) ?? []
        error = c.o(.error)
        useThisSound = c.o(.useThisSound)
    }
}

extension RecreateExport {
    /// The reminder lines next to the export: the server's `useThisSound` (title, steps, note) when it sent one, else the
    /// reference's reminder, else the plain one.
    public static func reminderLines(_ use: UseThisSound?, reference: RecreateReference?) -> (title: String, steps: [String], note: String?) {
        if let use, !use.steps.isEmpty || !(use.note ?? "").isEmpty {
            return (use.title.isEmpty ? "Post with the original sound" : use.title, use.steps, use.note)
        }
        return ("Post with the original sound", [reminder(reference)], nil)
    }

    /// The server can't render (an older server: 404, or the route isn't there): the Mac renders it itself.
    public static func serverLacksRender(_ error: Error) -> Bool {
        guard let e = error as? ApiError else { return false }
        return ["http_404", "not_found", "http_405", "http_501"].contains(e.code) && !e.message.lowercased().contains("session")
    }
}

/// Edit session ids are checked before they reach a URL.
public enum EditSessionIds {
    public static func check(_ id: String) throws -> String {
        guard id.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil else { throw ApiError("bad_id", "That isn't an edit session") }
        return id
    }
}
