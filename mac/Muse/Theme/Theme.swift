import AppKit
import CoreText
import SwiftUI

/// The four looks from the prototype (prototype/screens/gen.py `THEMES` + the theme blocks in desktop.css).
/// Each one changes layout details, not just colours: corner shapes, borders, shadows, the steps control, stickers, viewfinder corners.
enum ThemeID: String, CaseIterable, Identifiable, Codable {
    case a, b, c, d
    var id: String { rawValue }
    var name: String {
        switch self {
        case .a: return "Editorial"
        case .b: return "Camera Body"
        case .c: return "Soft Tactile"
        case .d: return "Creator Pop"
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

struct Theme {
    let id: ThemeID
    let bg, surface, surface2, ink, muted, line, accent, accentInk, cta, ctaInk, good, warn: Color
    let warnBg, warnInk: Color
    let rec: Color
    /// Creator Pop extras.
    let blue = Color(hex: 0x1F4BFF), yellow = Color(hex: 0xFFE14D), mint = Color(hex: 0x39D98A), pink = Color(hex: 0xFF7EB6)
    let r: CGFloat
    let rLg: CGFloat
    let stroke: CGFloat
    let displayFamily, bodyFamily, monoFamily: String
    let isDark: Bool

    var isA: Bool { id == .a }
    var isB: Bool { id == .b }
    var isC: Bool { id == .c }
    var isD: Bool { id == .d }

    /// Sidebar / inspector / title bar background.
    var chrome: Color { isA || isC ? bg : surface }
    var sidebarBg: Color { isD ? blue : chrome }
    var sidebarInk: Color { isD ? .white : muted }
    /// Rounded corners for a "card"-level surface.
    var cardRadius: CGFloat { isA ? 0 : rLg }
    var controlRadius: CGFloat { isA ? 0 : r }
    var imageRadius: CGFloat { isA ? 0 : r }
    var lineWidth: CGFloat { isD ? 2.5 : 1 }
    var strongLine: Color { isD ? Color(hex: 0x111111) : line }

    // Text colours that pass WCAG AA (4.5:1) on bg, surface and surface2; checked in MuseCoreTests/UxPolishTests.
    /// Text links (`.link`): the accent, except where it's too light for text (Soft Tactile: its darker green; Creator Pop: blue).
    var link: Color { isD ? blue : isC ? good : accent }
    /// Text on the `.good` pill's `good.opacity(0.18)` tint.
    var goodInk: Color {
        switch id {
        case .a: return Color(hex: 0x22552B)
        case .b: return good
        case .c: return Color(hex: 0x3E5737)
        case .d: return Color(hex: 0x0A6B3D)
        }
    }
    /// The fill behind `accentInk` text (the `.acc` pill, a chip that's on). Soft Tactile's accent is too light for white text.
    var accentFill: Color { isC ? cta : accent }

    static func get(_ id: ThemeID) -> Theme {
        switch id {
        case .a:
            return Theme(id: .a, bg: Color(hex: 0xEFEBE3), surface: Color(hex: 0xF8F5EF), surface2: Color(hex: 0xE7E1D6), ink: Color(hex: 0x141210), muted: Color(hex: 0x67605A),
                         line: Color(hex: 0xCFC7BA), accent: Color(hex: 0xB5121B), accentInk: .white, cta: Color(hex: 0x141210), ctaInk: Color(hex: 0xF8F5EF),
                         good: Color(hex: 0x2F6B3A), warn: Color(hex: 0x9A5B00), warnBg: Color(hex: 0xF6E2C0), warnInk: Color(hex: 0x5B3600), rec: Color(hex: 0xB5121B),
                         r: 0, rLg: 0, stroke: 1, displayFamily: "Instrument Serif", bodyFamily: "Archivo", monoFamily: "IBM Plex Mono", isDark: false)
        case .b:
            return Theme(id: .b, bg: Color(hex: 0x0D0E0F), surface: Color(hex: 0x17191B), surface2: Color(hex: 0x212427), ink: Color(hex: 0xECEAE5), muted: Color(hex: 0xA9A6A0),
                         line: Color(hex: 0x2C3033), accent: Color(hex: 0xF2A93B), accentInk: Color(hex: 0x1A1205), cta: Color(hex: 0xF2A93B), ctaInk: Color(hex: 0x1A1205),
                         good: Color(hex: 0x7BD88F), warn: Color(hex: 0xF2A93B), warnBg: Color(hex: 0x3A2B14), warnInk: Color(hex: 0xF2B45A), rec: Color(hex: 0xE5483B),
                         r: 10, rLg: 14, stroke: 1, displayFamily: "Barlow Condensed", bodyFamily: "Barlow", monoFamily: "JetBrains Mono", isDark: true)
        case .c:
            return Theme(id: .c, bg: Color(hex: 0xE7E2D9), surface: Color(hex: 0xF3F0EA), surface2: Color(hex: 0xEAE5DC), ink: Color(hex: 0x23262A), muted: Color(hex: 0x5E5C57),
                         line: Color(hex: 0xD9D3C8), accent: Color(hex: 0x6E8465), accentInk: .white, cta: Color(hex: 0x5A6E52), ctaInk: .white,
                         good: Color(hex: 0x4E6B45), warn: Color(hex: 0x9A6B2A), warnBg: Color(hex: 0xF6E2C0), warnInk: Color(hex: 0x5B3600), rec: Color(hex: 0xC2362B),
                         r: 18, rLg: 28, stroke: 1, displayFamily: "Outfit", bodyFamily: "Outfit", monoFamily: "DM Mono", isDark: false)
        case .d:
            return Theme(id: .d, bg: Color(hex: 0xFFF6EC), surface: .white, surface2: Color(hex: 0xFFEBD8), ink: Color(hex: 0x111111), muted: Color(hex: 0x55504A),
                         line: Color(hex: 0x111111), accent: Color(hex: 0xFF7EB6), accentInk: Color(hex: 0x111111), cta: Color(hex: 0xFF7EB6), ctaInk: Color(hex: 0x111111),
                         good: Color(hex: 0x0E8A4F), warn: Color(hex: 0xB45A00), warnBg: Color(hex: 0xF6E2C0), warnInk: Color(hex: 0x5B3600), rec: Color(hex: 0xC2362B),
                         r: 14, rLg: 20, stroke: 2.5, displayFamily: "Bricolage Grotesque", bodyFamily: "Figtree", monoFamily: "Figtree", isDark: false)
        }
    }

    // MARK: Typography

    func body(_ size: CGFloat = 14, _ weight: Font.Weight = .regular) -> Font { Fonts.font(bodyFamily, size, weight) }
    func mono(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font { Fonts.font(monoFamily, size, weight) }
    func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { Fonts.font(displayFamily, size, weight) }

    /// `.h1` per theme.
    var h1: Font {
        switch id {
        case .a: return Fonts.font("Instrument Serif", 64, .regular)
        case .b: return Fonts.font("Barlow Condensed", 46, .bold)
        case .c: return Fonts.font("Outfit", 42, .medium)
        case .d: return Fonts.font("Bricolage Grotesque", 48, .heavy)
        }
    }

    var h2: Font {
        switch id {
        case .a: return Fonts.font("Instrument Serif", 30, .regular)
        case .b: return Fonts.font("Barlow Condensed", 24, .bold)
        case .c: return Fonts.font("Outfit", 22, .medium)
        case .d: return Fonts.font("Bricolage Grotesque", 22, .heavy)
        }
    }

    var headingsUppercase: Bool { isA || isB }

    /// Big numbers (KPIs, balance).
    func figure(_ size: CGFloat) -> Font { isA ? Fonts.font("Instrument Serif", size * 1.6, .regular) : mono(size, .medium) }

    var label: Font { isD ? Fonts.font("Figtree", 11, .heavy) : mono(11) }
    var navFont: Font {
        switch id {
        case .a: return mono(12, .medium)
        case .b: return Fonts.font("Barlow Condensed", 15, .semibold)
        case .c: return body(14, .medium)
        case .d: return body(14, .bold)
        }
    }

    var navUppercase: Bool { isA || isB }
}

/// Font lookup by family + weight (works for the bundled variable fonts), with a system fallback.
enum Fonts {
    private static var cache: [String: Font] = [:]

    static func registerBundled() {
        var urls: [URL] = []
        for sub in ["Fonts", nil] as [String?] {
            urls += Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: sub) ?? []
        }
        for u in urls { CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil) }
    }

    static func font(_ family: String, _ size: CGFloat, _ weight: Font.Weight) -> Font {
        let key = "\(family)|\(size)|\(weight)"
        if let f = cache[key] { return f }
        let f: Font
        if let ns = nsFont(family, size, weight) { f = Font(ns as CTFont) } else { f = .system(size: size, weight: weight) }
        cache[key] = f
        return f
    }

    static func nsFont(_ family: String, _ size: CGFloat, _ weight: Font.Weight) -> NSFont? {
        let w: NSFont.Weight
        switch weight {
        case .ultraLight: w = .ultraLight
        case .thin: w = .thin
        case .light: w = .light
        case .medium: w = .medium
        case .semibold: w = .semibold
        case .bold: w = .bold
        case .heavy: w = .heavy
        case .black: w = .black
        default: w = .regular
        }
        let d = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: w.rawValue]])
        guard let font = NSFont(descriptor: d, size: size), font.familyName == family else { return nil }
        return font
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.get(.a)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
