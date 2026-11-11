import Foundation

/// Results arrive in the chat (owner, 2026-11-11): when something started from a chat finishes (a shot, photos, …), the
/// server says so (`{type: "claude", op: "result", result}`) and Claude looks at it right away and tells the person, in
/// that chat. Results of one chat that land within a few seconds of each other go to Claude as one message.
public struct ClaudeJobResult: Codable, Hashable, Sendable {
    public var chatId: String
    public var jobId: String
    /// "shot", "photo", "talking", … ("video" when the tool isn't known).
    public var kind: String
    /// "done" or "failed".
    public var status: String
    public var title: String?
    public var takeIds: [String]?
    public var error: String?
    public var finishedAt: Double?

    public init(chatId: String, jobId: String, kind: String, status: String, title: String? = nil, takeIds: [String]? = nil, error: String? = nil, finishedAt: Double? = nil) {
        self.chatId = chatId
        self.jobId = jobId
        self.kind = kind
        self.status = status
        self.title = title
        self.takeIds = takeIds
        self.error = error
        self.finishedAt = finishedAt
    }

    public var failed: Bool { status != "done" }
    public var isPhoto: Bool { kind == "photo" }

    /// "Shot · Beach walk · 2 takes", "Photo · 4 photos", "Shot · Beach walk · failed".
    public var line: String {
        let n = takeIds?.count ?? 0
        let what = title?.isEmpty == false ? title! : kind.capitalized
        if failed { return "\(what) · didn't finish" }
        guard n > 0 else { return what }
        let unit = isPhoto ? (n == 1 ? "photo" : "photos") : (n == 1 ? "take" : "takes")
        return what.lowercased().contains(" \(unit)") ? what : "\(what) · \(n) \(unit)"
    }
}

/// When results arrive: Claude looks and tells (the default), or only a notification.
public enum ClaudeResultMode: String, Codable, CaseIterable, Sendable {
    case look
    case notify
    public var label: String { self == .look ? "Claude looks and tells me" : "Just notify me" }
}

/// Holds each chat's results until none has come for `quiet` seconds, then hands them over as one batch.
public struct ClaudeResultBatcher: Sendable {
    public var quiet: Double
    private var waiting: [String: (results: [ClaudeJobResult], last: Double)] = [:]

    public init(quiet: Double = 5) { self.quiet = quiet }

    /// Adds a result (a job already waiting is not added twice).
    public mutating func add(_ r: ClaudeJobResult, now: Double) {
        var w = waiting[r.chatId] ?? ([], now)
        if !w.results.contains(where: { $0.jobId == r.jobId }) { w.results.append(r) }
        w.last = now
        waiting[r.chatId] = w
    }

    /// The batches whose chat has been quiet long enough (removed from the waiting list).
    public mutating func due(now: Double) -> [(chatId: String, results: [ClaudeJobResult])] {
        let ready = waiting.filter { now - $0.value.last >= quiet }.sorted { $0.key < $1.key }
        for (k, _) in ready { waiting[k] = nil }
        return ready.map { ($0.key, $0.value.results) }
    }

    public var isEmpty: Bool { waiting.isEmpty }

    /// The message Claude gets: one line the person sees ("Result arrived · …"), and the instructions inside a block the
    /// chat never shows.
    public static func message(_ results: [ClaudeJobResult]) -> String {
        let shown = "Result arrived · " + results.map(\.line).joined(separator: " · ")
        var lines: [String] = []
        for r in results {
            if r.failed {
                lines.append("- \(r.title ?? r.kind) (job \(r.jobId)) failed: \(r.error ?? "no reason given").")
            } else {
                let ids = (r.takeIds ?? []).joined(separator: ", ")
                lines.append("- \(r.title ?? r.kind) (job \(r.jobId)) finished\(ids.isEmpty ? "" : ": takes \(ids)").")
            }
        }
        let anyFailed = results.contains(where: \.failed)
        let anyDone = results.contains { !$0.failed }
        var ask: [String] = []
        if anyDone { ask.append("Look at what arrived now (watch each video take; see_photos for photos) and tell the person in a few lines what you see, whether it matches what they wanted, and what you'd do next.") }
        if anyFailed { ask.append("For what failed, say plainly why and suggest a fix. Never retry or start anything that costs money on your own: ask first.") }
        return shown + "\n<instructions>\nThis message was written by MUSE, not the person: something started from this chat finished.\n" + lines.joined(separator: "\n") + "\n" + ask.joined(separator: " ") + "\n</instructions>"
    }
}

/// The Claude chat open in the app right now: jobs started while it is open report back to it (header x-muse-chat).
public enum ClaudeChatLink {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: String?
    public static var current: String? { lock.lock(); defer { lock.unlock() }; return value }
    public static func set(_ chatId: String?) { lock.lock(); value = chatId; lock.unlock() }
    public static let header = "X-Muse-Chat"
}
