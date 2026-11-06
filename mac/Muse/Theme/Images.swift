import AppKit
import CoreGraphics
import ImageIO
import MuseCore
import SwiftUI

/// Loads images for `ImageRef`s (performance pass, plans/perf-audit.md "Mac"):
/// - decoded **at display size** with ImageIO (`CGImageSourceCreateThumbnailAtIndex`) on a background thread, so a 190 pt
///   gallery tile holds a 768 px image instead of the 2–4K original, and nothing decodes on the main thread;
/// - kept in an `NSCache` with a byte-cost limit (it was an unbounded dictionary of full-size images);
/// - downloaded once per URL however many views ask at once, over a disk URLCache (`ImageDataLoader`).
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    /// Decoded bytes kept in memory at most (the system also trims it under memory pressure).
    static let memoryLimit = 192 << 20
    /// The size `load(_:)` and `image(for:)` decode at when the caller doesn't say (full-frame uses like a poster grab).
    static let largeSide = 2048

    private let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = ImageCache.memoryLimit
        c.countLimit = 800
        c.delegate = ImageCacheStats.shared
        return c
    }()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    /// Which sizes of a URL are in memory, so a smaller tile can reuse a bigger decode (bounded by `memory`'s own evictions).
    private var sizes: [String: Set<Int>] = [:]

    private static func key(_ url: String, _ px: Int) -> NSString { "\(short(url))#\(px)" as NSString }

    /// Cache keys for data URLs (Claude chat images, inline thumbs) are a few bytes, not the whole base64 image.
    nonisolated static func short(_ url: String) -> String {
        guard url.utf8.count > 512 else { return url }
        return "h\(url.utf8.count)-\(url.hashValue)-\(url.suffix(24))"
    }

    /// A decode of `url` good for `px` (that size or bigger), else the biggest smaller one as a stand-in. Memory only, cheap.
    func cached(_ url: String, px: Int) -> (image: NSImage, exact: Bool)? {
        guard let known = sizes[Self.short(url)] else { return nil }
        var best: (NSImage, Bool)?
        var gone: [Int] = []
        for s in known.sorted() {
            guard let i = memory.object(forKey: Self.key(url, s)) else { gone.append(s); continue }
            if s >= px || s == 0 {
                best = (i, true)
                break
            }
            best = (i, false) // a smaller decode stands in until the right size arrives
        }
        if !gone.isEmpty { // evicted: forget them so the bookkeeping stays as small as the cache
            let left = known.subtracting(gone)
            sizes[Self.short(url)] = left.isEmpty ? nil : left
        }
        return best.map { (image: $0.0, exact: $0.1) }
    }

    /// Decodes `url` at `px` (longest side, pixels) off the main thread; one decode per URL and size at a time.
    func load(_ url: String, px: Int) async -> NSImage? {
        if let c = cached(url, px: px), c.exact { return c.image }
        let k = Self.key(url, px) as String
        if let t = inflight[k] { return await t.value }
        let t = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = await ImageCache.decode(url, maxPixel: px) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        inflight[k] = t
        let img = await t.value
        inflight[k] = nil
        if let img { store(url, px, img) }
        return img
    }

    private func store(_ url: String, _ px: Int, _ img: NSImage) {
        memory.setObject(img, forKey: Self.key(url, px), cost: Self.cost(img))
        sizes[Self.short(url), default: []].insert(px)
        ImageCacheStats.shared.added(Self.cost(img))
    }

    /// Bytes a decoded image holds (4 bytes a pixel).
    nonisolated static func cost(_ img: NSImage) -> Int {
        if let rep = img.representations.first { return max(1, rep.pixelsWide * rep.pixelsHigh * 4) }
        return max(1, Int(img.size.width * img.size.height * 4))
    }

    /// Reads and downsamples off the main thread: local files straight from disk, data URLs inline, http(s) through the cache.
    nonisolated static func decode(_ url: String, maxPixel: Int) async -> CGImage? {
        let source: CGImageSource?
        if url.hasPrefix("file:"), let u = URL(string: url) {
            source = CGImageSourceCreateWithURL(u as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else if url.hasPrefix("data:"), let comma = url.firstIndex(of: ","), let d = Data(base64Encoded: String(url[url.index(after: comma)...])) {
            source = CGImageSourceCreateWithData(d as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else if let u = URL(string: url), let d = try? await ImageDataLoader.shared.data(for: u) {
            source = CGImageSourceCreateWithData(d as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else {
            source = nil
        }
        guard let source else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, // decode now, here, not on the main thread at first draw
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    // MARK: The older entry points (kept for their callers)

    /// Local files and data URLs, synchronously (cached). Prefer `MuseImage`, which decodes off the main thread.
    func image(for url: String) -> NSImage? {
        if let c = cached(url, px: Self.largeSide) { return c.image }
        guard url.hasPrefix("file:") || url.hasPrefix("data:") else { return nil }
        let src: CGImageSource?
        if url.hasPrefix("file:"), let u = URL(string: url) {
            src = CGImageSourceCreateWithURL(u as CFURL, nil)
        } else if let comma = url.firstIndex(of: ","), let d = Data(base64Encoded: String(url[url.index(after: comma)...])) {
            src = CGImageSourceCreateWithData(d as CFData, nil)
        } else {
            src = nil
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: Self.largeSide]
        guard let src, let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        store(url, Self.largeSide, img)
        return img
    }

    /// An http(s) image at up to 2048 px.
    func load(_ url: String) async -> NSImage? { await load(url, px: Self.largeSide) }

    /// An image this Mac already has (a just-uploaded file), so it shows at once under its new address.
    func put(_ url: String, _ img: NSImage) {
        memory.setObject(img, forKey: Self.key(url, 0), cost: Self.cost(img))
        sizes[Self.short(url), default: []].insert(0)
        ImageCacheStats.shared.added(Self.cost(img))
    }
}

/// Roughly how many decoded bytes `ImageCache` holds (Settings → Developer → Performance).
final class ImageCacheStats: NSObject, NSCacheDelegate, @unchecked Sendable {
    static let shared = ImageCacheStats()
    private let lock = NSLock()
    private var bytes = 0
    private var count = 0

    func added(_ cost: Int) { lock.lock(); bytes += cost; count += 1; lock.unlock() }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let img = obj as? NSImage else { return }
        let c = ImageCache.cost(img)
        lock.lock(); bytes = max(0, bytes - c); count = max(0, count - 1); lock.unlock()
    }

    var snapshot: (bytes: Int, count: Int) { lock.lock(); defer { lock.unlock() }; return (bytes, count) }
}

/// An `ImageRef` drawn to fill its frame. No photos are bundled: demo asset keys ("face", "g_front", …) are drawn as neutral
/// silhouette placeholders, and anything that can't load falls back to the same art.
/// Performance pass: decoded at the frame's pixel size, off the main thread (see `ImageCache`).
struct MuseImage: View {
    var ref: ImageRef?
    var symbol: String?
    @Environment(\.displayScale) private var scale
    @State private var loaded: NSImage?
    @State private var loadedKey: String?

    var body: some View {
        GeometryReader { g in
            let px = ImageDataLoader.pixelBucket(width: g.size.width, height: g.size.height, scale: scale)
            content(px).frame(width: g.size.width, height: g.size.height).clipped()
                .task(id: "\(ImageCache.short(ref?.url ?? ""))#\(px)") { await fetch(px) }
        }
    }

    private func fetch(_ px: Int) async {
        guard let u = ref?.url, px > 0 else { return }
        if let c = ImageCache.shared.cached(u, px: px), c.exact { return }
        if let img = await ImageCache.shared.load(u, px: px), !Task.isCancelled {
            loaded = img
            loadedKey = "\(ImageCache.short(u))#\(px)"
        }
    }

    @ViewBuilder private func content(_ px: Int) -> some View {
        if let u = ref?.url, let img = (loadedKey == "\(ImageCache.short(u))#\(px)" ? loaded : nil) ?? ImageCache.shared.cached(u, px: px)?.image {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            Placeholder(key: ref?.asset ?? ref?.url ?? "empty", symbol: symbol)
        }
    }
}

/// Generated art standing in for demo stills: a tonal gradient keyed to the asset family with a generic silhouette (never a real person).
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
        case "face", "profile", "face_tq": return (Color(hex: 0xC9C3D6), Color(hex: 0x6E6884), "person.crop.circle")
        case "hero": return (Color(hex: 0xC9C3D6), Color(hex: 0x6E6884), "person.fill")
        case let k where k.hasPrefix("enh_") || k.hasPrefix("dressa_") || k.hasPrefix("dressb_"):
            let face = k.contains("face") || k.contains("profile")
            let tint: (Color, Color) = k.hasPrefix("dressb_") ? (Color(hex: 0xC8B6D9), Color(hex: 0x5B4A72)) : k.hasPrefix("dressa_") ? (Color(hex: 0xB9CDD9), Color(hex: 0x3F5A6E)) : (Color(hex: 0xD6D0C4), Color(hex: 0x6F6658))
            return (tint.0, tint.1, face ? "person.crop.circle" : "figure.stand")
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
