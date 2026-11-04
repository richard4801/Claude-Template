import Foundation

// Keep GPU warm (plans/backend.md → "Keep GPU warm", plans/api.md → "Keep GPU warm"): a dedicated H100 for the user who switches
// it on, billed by wall time from their credit, with auto-off on idle, a session cap, low credit and a low owner balance.

/// GET / POST /v1/gpu/warm, and the `gpu` field of a `gpu` event.
public struct WarmGpu: Codable, Hashable, Sendable {
    /// off | starting (the pod is booting, 3–6 min) | warm (ready) | stopping
    public var state: String
    /// When it was switched on (ms). The whole wall time from here is billed.
    public var startedAt: Int64?
    /// When the pod was ready (ms).
    public var readyAt: Int64?
    /// Whole minutes since `startedAt`.
    public var minutes: Double
    /// "Warm GPU" charged so far, in dollars (settled per minute).
    public var costUsd: Double
    /// The pod's dollars per hour (~3.99).
    public var ratePerHour: Double
    /// A render is running on it.
    public var busy: Bool
    /// The earliest idle or cap auto-off (ms), and which one: idle | cap.
    public var autoOffAt: Int64?
    public var autoOffReason: String?
    /// autoOffAt − 5 min: when the warning fires (ms).
    public var warningAt: Int64?
    /// The studio's warmIdleMinutes.
    public var idleMinutes: Int
    /// The session cap in minutes, including an extension.
    public var maxMinutes: Int
    /// "Keep warm" can still extend the cap (once per session).
    public var canExtend: Bool
    /// This user may switch it on (studio setting `warmGpuAllowed`).
    public var allowed: Bool
    /// While off: how the last session ended (within the last hour).
    public var lastOff: WarmGpuOff?

    public init(state: String = "off", startedAt: Int64? = nil, readyAt: Int64? = nil, minutes: Double = 0, costUsd: Double = 0,
                ratePerHour: Double = WarmGpu.defaultRate, busy: Bool = false, autoOffAt: Int64? = nil, autoOffReason: String? = nil, warningAt: Int64? = nil,
                idleMinutes: Int = 20, maxMinutes: Int = 120, canExtend: Bool = false, allowed: Bool = true, lastOff: WarmGpuOff? = nil) {
        self.state = state
        self.startedAt = startedAt
        self.readyAt = readyAt
        self.minutes = minutes
        self.costUsd = costUsd
        self.ratePerHour = ratePerHour
        self.busy = busy
        self.autoOffAt = autoOffAt
        self.autoOffReason = autoOffReason
        self.warningAt = warningAt
        self.idleMinutes = idleMinutes
        self.maxMinutes = maxMinutes
        self.canExtend = canExtend
        self.allowed = allowed
        self.lastOff = lastOff
    }

    public static let defaultRate = Pricing.gpuPerHour
    public static let off = WarmGpu()

    /// Starting or warm: the bar shows and the switch is on.
    public var isOn: Bool { state == "starting" || state == "warm" }
    public var isStarting: Bool { state == "starting" }

    /// The 5-minute warning this status implies (after a reload, when the `warning` event was missed).
    public func pendingWarning(now: Int64) -> WarmGpuWarning? {
        guard isOn, let at = autoOffAt, let w = warningAt, now >= w else { return nil }
        return WarmGpuWarning(reason: autoOffReason ?? "idle", autoOffAt: at)
    }

    /// Between `tick` events: minutes counted from `startedAt` on this clock, and the cost of the whole minutes billed by now
    /// (never less than the server's figures).
    public func live(now: Int64) -> WarmGpu {
        guard isOn, let s = startedAt, now > s else { return self }
        var g = self
        g.minutes = Swift.max(minutes, Double(now - s) / 60_000)
        let billed = ((g.minutes.rounded(.down) * ratePerHour / 60) * 100).rounded() / 100
        g.costUsd = Swift.max(costUsd, billed)
        return g
    }

    /// Whole minutes until the auto-off, or nil.
    public func minutesLeft(now: Int64) -> Int? {
        guard isOn, let at = autoOffAt else { return nil }
        return Swift.max(0, Int((Double(at - now) / 60_000).rounded(.up)))
    }

    enum CodingKeys: String, CodingKey {
        case state, startedAt, readyAt, minutes, costUsd, ratePerHour, busy, autoOffAt, autoOffReason, warningAt, idleMinutes, maxMinutes, canExtend, allowed, lastOff
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        state = c.v(.state, "off")
        startedAt = c.o(.startedAt)
        readyAt = c.o(.readyAt)
        minutes = c.v(.minutes, 0)
        costUsd = c.v(.costUsd, 0)
        ratePerHour = c.v(.ratePerHour, WarmGpu.defaultRate)
        busy = c.v(.busy, false)
        autoOffAt = c.o(.autoOffAt)
        autoOffReason = c.o(.autoOffReason)
        warningAt = c.o(.warningAt)
        idleMinutes = c.v(.idleMinutes, 20)
        maxMinutes = c.v(.maxMinutes, 120)
        canExtend = c.v(.canExtend, false)
        allowed = c.v(.allowed, true)
        lastOff = c.o(.lastOff)
    }
}

/// How the last warm session ended.
public struct WarmGpuOff: Codable, Hashable, Sendable {
    /// user | idle | cap | credit | owner_balance | gpu_lost
    public var reason: String
    public var at: Int64
    public var minutes: Double
    public var costUsd: Double
    public init(reason: String, at: Int64, minutes: Double, costUsd: Double) {
        self.reason = reason
        self.at = at
        self.minutes = minutes
        self.costUsd = costUsd
    }
}

/// The warning 5 minutes before an idle or cap auto-off (`warning` on a `gpu` event with `event: "warning"`).
public struct WarmGpuWarning: Codable, Hashable, Sendable {
    /// idle | cap
    public var reason: String
    /// When it will turn off (ms).
    public var autoOffAt: Int64
    /// The server's wording, e.g. "Warm GPU turns off in 5 min (no renders)".
    public var message: String?
    public init(reason: String, autoOffAt: Int64, message: String? = nil) {
        self.reason = reason
        self.autoOffAt = autoOffAt
        self.message = message
    }
}

/// POST /v1/gpu/warm: `{on: true}` from "Warm up", `{on: false}` from "Turn off", `{extend: true}` from "Keep warm".
public struct WarmGpuRequest: Codable, Hashable, Sendable {
    public var on: Bool?
    public var extend: Bool?
    public init(on: Bool? = nil, extend: Bool? = nil) {
        self.on = on
        self.extend = extend
    }
    public static let turnOn = WarmGpuRequest(on: true)
    public static let turnOff = WarmGpuRequest(on: false)
    public static let keepWarm = WarmGpuRequest(extend: true)
}

/// The words for Keep GPU warm, shared by every screen (and matching the Android app).
public enum WarmGpuText {
    public static let nudgeTitle = "Warm up a GPU?"
    /// The nudge and the switch-on confirmation (every time).
    public static func costWarning(rate: Double = WarmGpu.defaultRate, idleMinutes: Int = 20) -> String {
        "Warm up a GPU now so your render starts right away? About \(perHour(rate)) from your credit while it's on, and it turns off by itself after \(idleMinutes) min without renders."
    }
    public static let warmUp = "Warm up"
    public static let notNow = "Not now"
    public static let turnOff = "Turn off"
    public static let keepWarm = "Keep warm"
    public static let switchLabel = "Keep GPU warm"

    /// "$4/hour": the rate rounded to whole dollars.
    public static func perHour(_ rate: Double) -> String { "$\(Int(rate.rounded()))/hour" }

    /// Whole minutes for display ("42 min", "1 h 05 min").
    public static func duration(_ minutes: Double) -> String {
        let m = max(0, Int(minutes.rounded(.down)))
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h " + String(format: "%02d", m % 60) + " min"
    }

    /// The persistent bar (before " · Turn off"): "GPU warm · 42 min · $2.80 so far", or "GPU starting…" while the pod boots.
    public static func bar(_ g: WarmGpu) -> String {
        if g.isStarting { return "GPU starting…" }
        return "GPU warm · \(duration(g.minutes)) · \(Pricing.money(g.costUsd)) so far"
    }

    /// The short title-bar / menu-bar indicator: "Starting…" or "42 min · $2.80".
    public static func indicator(_ g: WarmGpu) -> String {
        g.isStarting ? "Starting…" : "\(duration(g.minutes)) · \(Pricing.money(g.costUsd))"
    }

    /// The 5-minute warning (banner and notification).
    public static func warningTitle(_ w: WarmGpuWarning) -> String {
        w.reason == "cap" ? "Warm GPU reaches its time limit in 5 min" : "Warm GPU turns off in 5 min"
    }

    public static func warningBody(_ w: WarmGpuWarning, canExtend: Bool = true) -> String {
        if w.reason == "cap" {
            return canExtend ? "Keep warm to extend the session once, or let it turn off." : "It has had its one extension and turns off then."
        }
        return "No renders lately. Keep warm to hold it, or let it turn off."
    }

    /// Said when it turns off (toast, and a notification for an auto-off).
    public static func offMessage(_ off: WarmGpuOff?) -> String {
        let total = off.map { " · \(duration($0.minutes)) · \(Pricing.money($0.costUsd)) in all" } ?? ""
        switch off?.reason {
        case "idle": return "Warm GPU turned off: no renders for a while" + total
        case "cap": return "Warm GPU turned off at its time limit" + total
        case "credit": return "Warm GPU turned off: your credit is running low" + total
        case "owner_balance": return "Warm GPU turned off: the studio's GPU credit is low" + total
        case "gpu_lost": return "Warm GPU turned off: the GPU stopped responding" + total
        default: return "Warm GPU off" + total
        }
    }
}

/// The warm GPU's rules on a clock you pass in, like `server/api/src/services/warm.ts`: boot, per-minute billing, the idle and cap
/// auto-off (idle only counts once ready and while no render runs), the 5-minute warnings, "Keep warm" and the credit floor.
/// The in-process fake runs it; tests drive it minute by minute.
public struct WarmGpuSim: Sendable {
    public struct Config: Sendable {
        public var idleMinutes: Int
        public var maxMinutes: Int
        public var warnMinutes: Int
        /// Credit must cover this many more minutes or it turns off (and can't be switched on).
        public var creditFloorMinutes: Int
        public var bootSeconds: Double
        public var ratePerHour: Double
        public init(idleMinutes: Int = 20, maxMinutes: Int = 120, warnMinutes: Int = 5, creditFloorMinutes: Int = 10, bootSeconds: Double = 240,
                    ratePerHour: Double = WarmGpu.defaultRate) {
            self.idleMinutes = idleMinutes
            self.maxMinutes = maxMinutes
            self.warnMinutes = warnMinutes
            self.creditFloorMinutes = creditFloorMinutes
            self.bootSeconds = bootSeconds
            self.ratePerHour = ratePerHour
        }
        public static let standard = Config()
    }

    /// What a tick produced, in order.
    public enum Output: Equatable, Sendable {
        /// Take this much from the user's credit (whole minutes, and the last part-minute at the end).
        case charge(Double)
        /// It finished booting.
        case ready
        case warning(WarmGpuWarning)
        /// It turned off by itself.
        case off(reason: String)
    }

    public let config: Config
    public private(set) var state = "off"
    public private(set) var startedAt: Int64?
    public private(set) var readyAt: Int64?
    public private(set) var lastActive: Int64?
    public private(set) var maxMinutes: Int
    public private(set) var extended = false
    public private(set) var settledUntil: Int64 = 0
    public private(set) var costUsd = 0.0
    public private(set) var busy = false
    public private(set) var lastOff: WarmGpuOff?
    private var warnedFor: String?

    public init(config: Config = .standard) {
        self.config = config
        maxMinutes = config.maxMinutes
    }

    public var isOn: Bool { state == "starting" || state == "warm" }
    var floorUsd: Double { config.ratePerHour * Double(config.creditFloorMinutes) / 60 }
    private static let min: Int64 = 60_000

    /// The next auto-off: idle once ready and not busy, else the cap.
    public func autoOff() -> (at: Int64, reason: String)? {
        guard isOn, let s = startedAt else { return nil }
        let capAt = s + Int64(maxMinutes) * Self.min
        if state == "warm", !busy, let a = lastActive {
            let idleAt = a + Int64(config.idleMinutes) * Self.min
            if idleAt < capAt { return (idleAt, "idle") }
        }
        return (capAt, "cap")
    }

    public func status(now: Int64) -> WarmGpu {
        guard isOn, let s = startedAt else {
            return WarmGpu(state: "off", ratePerHour: config.ratePerHour, idleMinutes: config.idleMinutes, maxMinutes: config.maxMinutes,
                           lastOff: lastOff.flatMap { now - $0.at < 60 * Self.min ? $0 : nil })
        }
        let off = autoOff()
        return WarmGpu(state: state, startedAt: s, readyAt: readyAt, minutes: Double(Swift.max(0, (now - s) / Self.min)), costUsd: (costUsd * 1e4).rounded() / 1e4,
                       ratePerHour: config.ratePerHour, busy: busy, autoOffAt: off?.at, autoOffReason: off?.reason,
                       warningAt: off.map { $0.at - Int64(config.warnMinutes) * Self.min }, idleMinutes: config.idleMinutes, maxMinutes: maxMinutes,
                       canExtend: !extended)
    }

    /// Switches it on (or does nothing if it's on). Throws when the credit can't cover the floor.
    public mutating func turnOn(now: Int64, creditUsd: Double) throws {
        if isOn { return }
        if creditUsd + 1e-9 < floorUsd {
            throw ApiError("insufficient_balance", "Not enough credit to keep a GPU warm · it needs at least \(Pricing.money(floorUsd)) (\(config.creditFloorMinutes) min)")
        }
        let ready = config.bootSeconds <= 0
        state = ready ? "warm" : "starting"
        startedAt = now
        readyAt = ready ? now : nil
        lastActive = ready ? now : nil
        maxMinutes = config.maxMinutes
        extended = false
        settledUntil = now
        costUsd = 0
        busy = false
        warnedFor = nil
    }

    /// Ends the session and returns the final charge (the part-minute since the last settle).
    @discardableResult
    public mutating func turnOff(now: Int64, reason: String = "user") -> Double {
        guard isOn, let s = startedAt else { return 0 }
        let usd = Double(Swift.max(0, now - settledUntil)) / 3_600_000 * config.ratePerHour
        settledUntil = Swift.max(settledUntil, now)
        costUsd += usd
        state = "off"
        lastOff = WarmGpuOff(reason: reason, at: now, minutes: Double(Swift.max(0, now - s) / Self.min), costUsd: (costUsd * 1e4).rounded() / 1e4)
        warnedFor = nil
        return usd
    }

    /// "Keep warm": restarts the idle clock; when the cap is the next auto-off, extends it once by the studio's cap.
    public mutating func keepWarm(now: Int64) throws {
        guard isOn else { throw ApiError("not_warm", "The GPU is not warm") }
        if autoOff()?.reason == "cap" && !extended {
            extended = true
            maxMinutes += config.maxMinutes
        }
        if state == "warm" { lastActive = now }
        warnedFor = nil
    }

    /// Advances to `now`: finishes booting, bills whole minutes, warns, and turns off when a limit is hit.
    /// `creditUsd` is the credit left before this tick's charges; `busy` is whether a render runs on it.
    public mutating func tick(now: Int64, creditUsd: Double, ownerBalanceLow: Bool = false, busy: Bool = false) -> [Output] {
        guard isOn, let s = startedAt else { return [] }
        var out: [Output] = []
        if state == "starting" && Double(now - s) >= config.bootSeconds * 1000 {
            state = "warm"
            readyAt = now
            lastActive = now
            out.append(.ready)
        }
        self.busy = busy
        if busy && state == "warm" { lastActive = now }
        if let off = autoOff(), now >= off.at {
            out.append(.charge(turnOff(now: off.at, reason: off.reason)))
            out.append(.off(reason: off.reason))
            return out
        }
        var credit = creditUsd
        let whole = (now - settledUntil) / Self.min
        if whole > 0 {
            let usd = Double(whole) / 60 * config.ratePerHour
            settledUntil += whole * Self.min
            costUsd += usd
            credit -= usd
            out.append(.charge(usd))
        }
        if ownerBalanceLow || credit + 1e-9 < floorUsd {
            let reason = ownerBalanceLow ? "owner_balance" : "credit"
            out.append(.charge(turnOff(now: now, reason: reason)))
            out.append(.off(reason: reason))
            return out
        }
        if let off = autoOff() {
            let key = "\(off.reason):\(off.at)"
            if now >= off.at - Int64(config.warnMinutes) * Self.min && warnedFor != key {
                warnedFor = key
                let left = Swift.max(1, Int((Double(off.at - now) / 60_000).rounded()))
                let msg = off.reason == "idle" ? "Warm GPU turns off in \(left) min (no renders)" : "Warm GPU reaches its time limit in \(left) min"
                out.append(.warning(WarmGpuWarning(reason: off.reason, autoOffAt: off.at, message: msg)))
            }
        }
        return out
    }
}
