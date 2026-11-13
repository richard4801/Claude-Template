import MuseCore
import SwiftUI

// Edit's platform preview (owner decision 2026-11-12, plans/edit-platform-preview.md): the generic chrome of each app drawn
// over the edit (our own drawing: grey bars for text, Phosphor glyphs for buttons; no logos, no brand colours, no
// platform type), and the red safe-area box. Moved here from the take viewer, which is now a clean player.
// The chrome fills the canvas exactly: the canvas is what gets posted, so nothing is cropped.

/// The chrome for a view: the phone layouts on portrait canvases, the landscape players on 16:9 ones; Clean draws nothing.
struct EditPlatformChrome: View {
    var view: PreviewSkin
    var landscape: Bool
    var width: Double
    var height: Double

    var body: some View {
        Group {
            if view == .clean {
                EmptyView()
            } else if landscape {
                LandscapeChrome(view: view, width: width, height: height)
            } else {
                PhoneChrome(skin: view, width: width, height: height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The red dashed box: where the app leaves the picture clear (approximate; the server's table can correct it).
struct EditSafeBoxGuide: View {
    var zone: SafeZone
    var name: String

    var body: some View {
        GeometryReader { g in
            let r = zone.safeRect
            Path { p in p.addRect(CGRect(x: g.size.width * r.x, y: g.size.height * r.y, width: g.size.width * r.w, height: g.size.height * r.h)) }
                .stroke(Color(hex: 0xFF5A5F).opacity(0.95), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Red box: \(name). Keep faces and words inside it.")
    }
}

/// A landscape player's chrome over the edit: the title row on top and the controls along the bottom (YouTube), or the
/// bottom controls and a small name row (Facebook).
struct LandscapeChrome: View {
    var view: PreviewSkin
    var width: Double
    var height: Double

    var body: some View {
        let k = width / 640
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: width, height: height * 0.16)
            HStack(spacing: 10 * k) {
                Circle().fill(.white.opacity(0.75)).frame(width: 26 * k, height: 26 * k)
                ChromeBar(w: (view == .youtube ? 180 : 120) * k, h: 10 * k)
                Spacer()
                if view == .youtube {
                    Ph("clock", 15 * k).foregroundStyle(.white)
                    Ph("share-fat", 15 * k).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16 * k).padding(.top, 14 * k)
            VStack(spacing: 8 * k) {
                Spacer()
                Capsule().fill(.white.opacity(0.35)).frame(height: 3 * k)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: width * 0.28, height: 3 * k) }
                HStack(spacing: 14 * k) {
                    Ph("play", 15 * k)
                    if view == .youtube { Ph("skip-forward", 15 * k) }
                    Ph("speaker-high", 15 * k)
                    ChromeBar(w: 70 * k, h: 7 * k, dim: true)
                    Spacer()
                    Ph("closed-captioning", 15 * k)
                    Ph("dots-three-vertical", 15 * k)
                    Ph("arrows-out-simple", 15 * k)
                }
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 14 * k).padding(.bottom, 10 * k)
            .frame(width: width, height: height)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).frame(height: height * 0.18)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .accessibilityLabel("\(view.label) layout")
    }
}

// MARK: Phone layouts

struct ChromeBar: View {
    var w: Double
    var h: Double
    var dim = false
    var body: some View { RoundedRectangle(cornerRadius: h / 2).fill(.white.opacity(dim ? 0.55 : 0.85)).frame(width: w, height: h) }
}

private struct ChromeGlyph: View {
    var name: String
    var size: Double
    var count = true
    var body: some View {
        VStack(spacing: size * 0.12) {
            Ph(name, size * 0.8).foregroundStyle(.white)
            if count { ChromeBar(w: size * 0.7, h: max(3, size * 0.2)) }
        }
    }
}

/// A phone app's layout over the edit: top bar, the right-hand rail, the caption block and the bottom navigation.
struct PhoneChrome: View {
    var skin: PreviewSkin
    var width: Double
    var height: Double

    var body: some View {
        let k = width / 300
        let nav = 56 * k
        let icon = 26 * k
        ZStack(alignment: .topLeading) {
            // status bar
            HStack { ChromeBar(w: 28 * k, h: 7 * k); Spacer(); ChromeBar(w: 40 * k, h: 7 * k) }
                .padding(.horizontal, 18 * k).padding(.top, 8 * k)
            top(k)
            rail(k, icon: icon)
                .padding(.trailing, 10 * k).padding(.bottom, nav + 16 * k)
                .frame(width: width, height: height, alignment: .bottomTrailing)
            caption(k)
                .padding(.leading, 12 * k).padding(.bottom, nav + 14 * k)
                .frame(width: width, height: height, alignment: .bottomLeading)
            HStack {
                ForEach(navIcons, id: \.self) { n in
                    Spacer(minLength: 0)
                    Ph(n, 18 * k).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
            }
            .padding(.bottom, 10 * k)
            .frame(width: width, height: nav)
            .background(Color.black.opacity(0.92))
            .frame(width: width, height: height, alignment: .bottom)
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var navIcons: [String] {
        switch skin {
        case .tiktok: return ["house", "users-three", "plus-square", "chat-circle", "user"]
        case .reels: return ["house", "magnifying-glass", "plus-square", "film-strip", "user-circle"]
        case .shorts: return ["house", "lightning", "plus-circle", "play-circle", "user-circle"]
        default: return ["house", "video", "users-three", "bag", "bell"]
        }
    }

    @ViewBuilder private func top(_ k: Double) -> some View {
        switch skin {
        case .tiktok:
            ZStack {
                HStack(spacing: 14 * k) { ChromeBar(w: 50 * k, h: 8 * k, dim: true); ChromeBar(w: 44 * k, h: 8 * k) }
                HStack { Spacer(); Ph("magnifying-glass", 18 * k).foregroundStyle(.white) }
            }
            .padding(.horizontal, 14 * k).padding(.top, 32 * k)
        case .reels:
            HStack { ChromeBar(w: 54 * k, h: 10 * k); Spacer(); Ph("camera", 18 * k).foregroundStyle(.white) }
                .padding(.horizontal, 14 * k).padding(.top, 32 * k)
        case .shorts:
            HStack(spacing: 16 * k) { Spacer(); Ph("magnifying-glass", 18 * k); Ph("dots-three-vertical", 18 * k) }
                .foregroundStyle(.white).padding(.horizontal, 14 * k).padding(.top, 30 * k)
        default:
            HStack(spacing: 14 * k) { Ph("caret-left", 18 * k); ChromeBar(w: 48 * k, h: 10 * k); Spacer(); Ph("magnifying-glass", 18 * k); Ph("user-circle", 18 * k) }
                .foregroundStyle(.white).padding(.horizontal, 14 * k).padding(.top, 30 * k)
        }
    }

    @ViewBuilder private func rail(_ k: Double, icon: Double) -> some View {
        switch skin {
        case .tiktok:
            VStack(spacing: 16 * k) {
                avatar(40 * k)
                ChromeGlyph(name: "heart", size: icon); ChromeGlyph(name: "chat-circle-dots", size: icon)
                ChromeGlyph(name: "bookmark-simple", size: icon); ChromeGlyph(name: "share-fat", size: icon)
                Circle().fill(Color(white: 0.2)).frame(width: 32 * k, height: 32 * k).overlay(Circle().strokeBorder(Color(white: 0.07), lineWidth: 5 * k))
            }
        case .reels:
            VStack(spacing: 18 * k) {
                ChromeGlyph(name: "heart", size: icon); ChromeGlyph(name: "chat-circle", size: icon); ChromeGlyph(name: "paper-plane-tilt", size: icon)
                ChromeGlyph(name: "dots-three-vertical", size: icon, count: false)
                RoundedRectangle(cornerRadius: 5 * k).fill(.white.opacity(0.6)).frame(width: 26 * k, height: 26 * k)
            }
        case .shorts:
            VStack(spacing: 16 * k) {
                ChromeGlyph(name: "thumbs-up", size: icon); ChromeGlyph(name: "thumbs-down", size: icon, count: false)
                ChromeGlyph(name: "chat-circle-dots", size: icon); ChromeGlyph(name: "share-fat", size: icon); ChromeGlyph(name: "arrows-clockwise", size: icon)
                RoundedRectangle(cornerRadius: 6 * k).fill(.white.opacity(0.6)).frame(width: 28 * k, height: 28 * k)
            }
        default:
            VStack(spacing: 18 * k) {
                ChromeGlyph(name: "thumbs-up", size: icon); ChromeGlyph(name: "chat-circle", size: icon); ChromeGlyph(name: "share-fat", size: icon)
                ChromeGlyph(name: "dots-three", size: icon, count: false)
            }
        }
    }

    private func caption(_ k: Double) -> some View {
        let w = width * 0.62
        return VStack(alignment: .leading, spacing: 6 * k) {
            switch skin {
            case .tiktok: ChromeBar(w: w * 0.4, h: 9 * k)
            case .reels:
                HStack(spacing: 8 * k) { avatar(26 * k); ChromeBar(w: w * 0.34, h: 9 * k)
                    RoundedRectangle(cornerRadius: 6 * k).strokeBorder(.white.opacity(0.8), lineWidth: 1.2 * k).frame(width: 46 * k, height: 20 * k) }
            case .shorts:
                HStack(spacing: 8 * k) { avatar(26 * k); ChromeBar(w: w * 0.3, h: 9 * k); Capsule().fill(.white.opacity(0.9)).frame(width: 60 * k, height: 22 * k) }
            default:
                HStack(spacing: 8 * k) { avatar(26 * k); ChromeBar(w: w * 0.3, h: 9 * k)
                    RoundedRectangle(cornerRadius: 6 * k).fill(.white.opacity(0.25)).frame(width: 44 * k, height: 20 * k) }
            }
            ChromeBar(w: w * 0.92, h: 7 * k, dim: true)
            ChromeBar(w: w * 0.64, h: 7 * k, dim: true)
            HStack(spacing: 6 * k) { Ph("music-note", 11 * k).foregroundStyle(.white); ChromeBar(w: w * 0.52, h: 6 * k, dim: true) }
        }
        .frame(width: w, alignment: .leading)
    }

    private func avatar(_ d: Double) -> some View {
        Circle().fill(.white.opacity(0.75)).frame(width: d, height: d).overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
    }
}

