import AppKit
import MuseCore
import SwiftUI

/// Loads images for `ImageRef`s: local files and data URLs synchronously (cached), http(s) asynchronously.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var cache: [String: NSImage] = [:]
    private var inflight: Set<String> = []

    func image(for url: String) -> NSImage? {
        if let i = cache[url] { return i }
        var img: NSImage?
        if url.hasPrefix("file:"), let u = URL(string: url) {
            img = NSImage(contentsOf: u)
        } else if url.hasPrefix("data:"), let comma = url.firstIndex(of: ","), let d = Data(base64Encoded: String(url[url.index(after: comma)...])) {
            img = NSImage(data: d)
        }
        if let img { cache[url] = img }
        return img
    }

    func load(_ url: String) async -> NSImage? {
        if let i = cache[url] { return i }
        guard let u = URL(string: url), !inflight.contains(url) else { return nil }
        inflight.insert(url)
        defer { inflight.remove(url) }
        guard let res = try? await URLSession.shared.data(from: u), let img = NSImage(data: res.0) else { return nil }
        cache[url] = img
        return img
    }

    func put(_ url: String, _ img: NSImage) { cache[url] = img }

    /// Sienna's bundled reference photos (Resources/Samples/ref_<key>.jpg), the same set the Android app ships.
    /// Clip frames (`vid_*`, `src_clip`) come from third-party test footage and are deliberately not bundled.
    func sample(_ key: String) -> NSImage? {
        let k = "sample:" + key
        if let i = cache[k] { return i }
        guard let u = Bundle.main.url(forResource: "ref_" + key, withExtension: "jpg", subdirectory: "Samples"),
              let img = NSImage(contentsOf: u) else { return nil }
        cache[k] = img
        return img
    }
}

/// An `ImageRef` drawn to fill its frame. Bundled sample photos are used for asset keys; anything else falls back to placeholder art.
struct MuseImage: View {
    var ref: ImageRef?
    var symbol: String?
    @State private var remote: NSImage?

    var body: some View {
        GeometryReader { g in
            content.frame(width: g.size.width, height: g.size.height).clipped()
        }
        .task(id: ref?.url) {
            if let u = ref?.url, u.hasPrefix("http") { remote = await ImageCache.shared.load(u) }
        }
    }

    @ViewBuilder private var content: some View {
        if let u = ref?.url, let img = (u.hasPrefix("http") ? remote : ImageCache.shared.image(for: u)) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else if let a = ref?.asset, let img = ImageCache.shared.sample(a) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            Placeholder(key: ref?.asset ?? ref?.url ?? "empty", symbol: symbol)
        }
    }
}

/// Generated art standing in for the prototype's sample photos: a tonal gradient keyed to the asset family.
struct Placeholder: View {
    var key: String
    var symbol: String?

    var body: some View {
        let (top, bottom, sym) = Self.palette(key)
        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.white.opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 0.32), startRadius: 2, endRadius: 140)
            Image(systemName: symbol ?? sym)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.55))
                .padding(28)
                .frame(maxWidth: 120, maxHeight: 120)
        }
    }

    static func palette(_ key: String) -> (Color, Color, String) {
        switch key {
        case let k where k.hasPrefix("g_"): return (Color(hex: 0x6F8C7A), Color(hex: 0x1F4A35), "figure.stand")
        case let k where k.hasPrefix("c_"): return (Color(hex: 0xD9D4CC), Color(hex: 0x8C8378), k == "c_face" ? "person.crop.circle" : "figure.stand.dress")
        case "face", "profile": return (Color(hex: 0xE7C3A4), Color(hex: 0xA0705A), key == "profile" ? "person.crop.circle.badge" : "person.crop.circle")
        case "hero": return (Color(hex: 0xE2BE97), Color(hex: 0x8C5B44), "person.fill")
        case let k where k.hasPrefix("vid_bath"): return (Color(hex: 0xB8B2A6), Color(hex: 0x4E4A44), "figure.dance")
        case let k where k.hasPrefix("vid_kick"): return (Color(hex: 0x7C8FB8), Color(hex: 0x3A3550), "figure.kickboxing")
        case let k where k.hasPrefix("vid_"): return (Color(hex: 0x8C93C9), Color(hex: 0x4A3F3A), "figure.dance")
        case "src_clip", "clip": return (Color(hex: 0x6F78B8), Color(hex: 0x3B3431), "figure.dance")
        case "empty": return (Color(hex: 0xBDB6AA), Color(hex: 0x7E776C), "photo")
        default:
            var h: UInt32 = 2166136261
            for b in key.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
            let hue = Double(h % 360) / 360
            return (Color(hue: hue, saturation: 0.25, brightness: 0.8), Color(hue: hue, saturation: 0.4, brightness: 0.35), "photo")
        }
    }
}

/// Camera Body's viewfinder corners on 9:16 media.
struct ViewfinderCorners: View {
    var body: some View {
        GeometryReader { g in
            let s: CGFloat = 18
            Path { p in
                p.move(to: CGPoint(x: 10, y: 10 + s)); p.addLine(to: CGPoint(x: 10, y: 10)); p.addLine(to: CGPoint(x: 10 + s, y: 10))
                p.move(to: CGPoint(x: g.size.width - 10 - s, y: g.size.height - 10)); p.addLine(to: CGPoint(x: g.size.width - 10, y: g.size.height - 10))
                p.addLine(to: CGPoint(x: g.size.width - 10, y: g.size.height - 10 - s))
            }
            .stroke(.white.opacity(0.85), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

/// A framed piece of media: `.ph9` (9:16) or `.ph34` (3:4), with a caption, a corner tag and theme framing.
struct Media<Tag: View>: View {
    @Environment(\.theme) private var t
    var ref: ImageRef?
    var ratio: CGFloat = 9.0 / 16.0
    var caption: String?
    var captionIcon: String?
    var radius: CGFloat?
    var symbol: String?
    var selectedColor: Color?
    @ViewBuilder var tag: () -> Tag

    var body: some View {
        let rad = radius ?? (t.isA ? 0 : ratio < 0.7 ? t.r : t.r)
        let shape = RoundedRectangle(cornerRadius: rad, style: .continuous)
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay(MuseImage(ref: ref, symbol: symbol))
            .overlay(alignment: .bottomLeading) {
                if let caption {
                    HStack(spacing: 4) {
                        if let captionIcon { Image(systemName: captionIcon).font(.system(size: 9)) }
                        Text(caption).font(t.body(12, .semibold)).lineLimit(2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay(alignment: .topLeading) { tag().padding(8) }
            .overlay { if t.isB && ratio < 0.7 { ViewfinderCorners() } }
            .clipShape(shape)
            .overlay(shape.strokeBorder(t.isD ? Color(hex: 0x111111) : .clear, lineWidth: 2.5))
            .overlay(shape.strokeBorder(selectedColor ?? .clear, lineWidth: 3).padding(-3))
    }
}

extension Media where Tag == EmptyView {
    init(ref: ImageRef?, ratio: CGFloat = 9.0 / 16.0, caption: String? = nil, captionIcon: String? = nil, radius: CGFloat? = nil, symbol: String? = nil, selectedColor: Color? = nil) {
        self.init(ref: ref, ratio: ratio, caption: caption, captionIcon: captionIcon, radius: radius, symbol: symbol, selectedColor: selectedColor) { EmptyView() }
    }
}

/// Initial-letter tile for a model with no images (`.init`).
struct InitialTile: View {
    @Environment(\.theme) private var t
    var letter: String
    var size: CGFloat = 56
    var body: some View {
        Color.clear.aspectRatio(0.75, contentMode: .fit)
            .overlay(Text(letter).font(t.isA ? Fonts.font("Instrument Serif", size, .regular) : t.display(size)).foregroundStyle(t.muted))
    }
}

/// Shimmering placeholder while something generates.
struct Shimmer: View {
    @Environment(\.theme) private var t
    var ratio: CGFloat = 0.75
    @State private var phase: CGFloat = 0

    var body: some View {
        Color.clear.aspectRatio(ratio, contentMode: .fit)
            .background(
                GeometryReader { g in
                    LinearGradient(colors: [t.surface2, t.surface, t.surface2], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 3)
                        .offset(x: phase * g.size.width)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: t.imageRadius))
            .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = -2 } }
    }
}

/// Dashed "Add" tile (`.empty`, `.addtile`).
struct EmptyTile: View {
    @Environment(\.theme) private var t
    var ratio: CGFloat = 0.75
    var icon = "plus"
    var text: String
    var targeted = false

    var body: some View {
        Color.clear.aspectRatio(ratio, contentMode: .fit)
            .overlay(VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(text).font(t.body(12)).multilineTextAlignment(.center)
            }.foregroundStyle(targeted ? t.accent : t.muted))
            .background(RoundedRectangle(cornerRadius: t.imageRadius).fill(targeted ? t.accent.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: t.imageRadius).strokeBorder(targeted ? t.accent : t.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(Rectangle())
    }
}
