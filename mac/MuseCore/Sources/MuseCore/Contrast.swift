import Foundation

/// WCAG 2.x contrast for 0xRRGGBB colours (the app's theme tokens, Muse/Theme/Theme.swift), so text/background pairs can be
/// checked in tests (MuseCore has no SwiftUI). AA asks 4.5:1 for normal text and 3:1 for large text and UI parts.
public enum Contrast {
    public static let aaText = 4.5
    public static let aaLarge = 3.0

    /// Relative luminance (0 black … 1 white).
    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// The contrast ratio, 1…21, whichever colour is lighter.
    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `fg` at `alpha` over `bg` (a tinted fill such as `good.opacity(0.18)`), as one opaque colour.
    public static func mix(_ fg: UInt32, over bg: UInt32, alpha: Double) -> UInt32 {
        func c(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        func m(_ s: UInt32) -> UInt32 { UInt32((c(fg, s) * alpha + c(bg, s) * (1 - alpha)).rounded()) }
        return (m(16) << 16) | (m(8) << 8) | m(0)
    }
}
