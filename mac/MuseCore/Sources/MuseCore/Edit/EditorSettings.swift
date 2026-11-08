import Foundation

// The owner's controls for the paid AI editing helpers (captions, background removal, voice clean-up):
// GET/PATCH /v1/editor/settings (plans/api.md "Editor v2"). Owner only; members get 403. The server also refuses new
// paid jobs with 503 editor_paid_off while they are off and 402 editor_daily_cap past the day's limit; the apps show
// those messages as they come (ApiError.friendlyMessage passes them through).

public struct EditorSettings: Codable, Hashable, Sendable {
    /// "on" or "off".
    public var paidHelpers: String
    /// The studio's daily limit on paid helpers, in dollars (the server default, $5, when it wasn't set).
    public var capPerDayUsd: Double?
    /// What paid helpers have cost today (UTC), running jobs' estimates included.
    public var todayUsd: Double?
    /// Price = cost × markup (2). Shown prices already include it.
    public var markup: Double?

    public var isOn: Bool { paidHelpers == "on" }

    public init(paidHelpers: String, capPerDayUsd: Double? = nil, todayUsd: Double? = nil, markup: Double? = nil) {
        self.paidHelpers = paidHelpers; self.capPerDayUsd = capPerDayUsd; self.todayUsd = todayUsd; self.markup = markup
    }

    enum CodingKeys: String, CodingKey { case paidHelpers, capPerDayUsd, todayUsd, markup }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        paidHelpers = c.v(.paidHelpers, "off")
        capPerDayUsd = c.o(.capPerDayUsd)
        todayUsd = c.o(.todayUsd)
        markup = c.o(.markup)
    }

    /// "$0.40 of $5.00 today".
    public var todayLine: String {
        let cap = capPerDayUsd.map { " of " + EditorSettings.money($0) } ?? ""
        return EditorSettings.money(todayUsd ?? 0) + cap + " today"
    }

    public static func money(_ v: Double) -> String { "$" + String(format: "%.2f", v) }

    /// "5", "$5", " 7.50 " → the limit; nil for empty or not a positive number.
    public static func parseLimit(_ text: String) -> Double? {
        let s = text.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(s), v > 0, v.isFinite else { return nil }
        return (v * 100).rounded() / 100
    }
}

/// PATCH /v1/editor/settings. `resetCap` sends `capPerDayUsd: null` (back to the server default).
public struct EditorSettingsPatch: Encodable, Hashable, Sendable {
    public var paidHelpers: String?
    public var capPerDayUsd: Double?
    public var resetCap: Bool

    public init(paidHelpers: Bool? = nil, capPerDayUsd: Double? = nil, resetCap: Bool = false) {
        self.paidHelpers = paidHelpers.map { $0 ? "on" : "off" }; self.capPerDayUsd = capPerDayUsd; self.resetCap = resetCap
    }

    enum CodingKeys: String, CodingKey { case paidHelpers, capPerDayUsd }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(paidHelpers, forKey: .paidHelpers)
        if resetCap { try c.encodeNil(forKey: .capPerDayUsd) } else { try c.encodeIfPresent(capPerDayUsd, forKey: .capPerDayUsd) }
    }
}

public protocol EditorSettingsAPI: Sendable {
    func editorSettings() async throws -> EditorSettings
    func updateEditorSettings(_ patch: EditorSettingsPatch) async throws -> EditorSettings
}

extension HTTPMuseAPI: EditorSettingsAPI {
    public func editorSettings() async throws -> EditorSettings { try await suiteCall("GET", "v1/editor/settings") }
    public func updateEditorSettings(_ patch: EditorSettingsPatch) async throws -> EditorSettings {
        try await suiteCall("PATCH", "v1/editor/settings", body: try JSONEncoder().encode(patch))
    }
}

/// Demo mode: helpers off (as on a new server), a $5 limit, nothing spent. Nothing is charged.
public final class FakeEditorSettingsAPI: EditorSettingsAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var s = EditorSettings(paidHelpers: "off", capPerDayUsd: 5, todayUsd: 0, markup: 2)
    public init() {}
    public func editorSettings() async throws -> EditorSettings { lock.lock(); defer { lock.unlock() }; return s }
    public func updateEditorSettings(_ patch: EditorSettingsPatch) async throws -> EditorSettings {
        lock.lock(); defer { lock.unlock() }
        if let p = patch.paidHelpers { s.paidHelpers = p }
        if patch.resetCap { s.capPerDayUsd = 5 } else if let c = patch.capPerDayUsd { s.capPerDayUsd = c }
        return s
    }
}
