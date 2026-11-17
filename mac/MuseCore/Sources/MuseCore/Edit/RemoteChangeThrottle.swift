import Foundation

/// Performance (build 704, run 718: Claude's patches into a 66-clip edit cost ~90 % of a core, most of it SwiftUI re-diffing
/// the whole editor per patch). Changes from the live session show at once after a quiet moment; while they keep coming,
/// the ones arriving within `gap` (0.75 s) of the last shown are held and only the newest is shown at the end of that gap (each
/// carries the whole project, so nothing is lost).
public struct RemoteChangeThrottle: Sendable {
    public let gap: Double
    public private(set) var lastShown: Double = -.infinity

    public init(gap: Double = 0.75) { self.gap = gap }

    /// How long to wait before showing a change that arrived at `now` (0: show it now).
    public func delay(at now: Double) -> Double { max(0, lastShown + gap - now) }

    public mutating func shown(at now: Double) { lastShown = now }
}
