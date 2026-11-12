import MuseCore
import SwiftUI

/// What Claude sees, live (owner, 2026-11-12): the page's name as a small leading label, then a row of 30 pt thumbnails
/// with tiny labels (the clip, her, the outfit, the background, references, the guide, the model), from the same screen
/// Claude reads (ClaudeContext). Calm: no chrome; it scrolls sideways when narrow; items change with a short cross-fade.
struct ClaudeContextStrip: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var service: ClaudeCodeService = .shared
    let page: String
    let items: [ClaudeContextItem]

    static let side: CGFloat = 30

    var body: some View {
        let r = t.roles
        HStack(alignment: .top, spacing: Space.s2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sees").scaled(t.scale.micro, r.ink2)
                Text(page).scaled(t.scale.micro, r.ink).lineLimit(2).frame(maxWidth: items.isEmpty ? .infinity : 72, alignment: .leading)
            }
            .padding(.top, 2)
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Space.s2) {
                        ForEach(items) { item in tile(item).transition(.opacity) }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: items.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude sees \(page)" + (items.isEmpty ? "" : ": " + items.map { "\($0.label)\($0.detail.map { " \($0)" } ?? "")" }.joined(separator: ", ")))
    }

    private func tile(_ item: ClaudeContextItem) -> some View {
        let r = t.roles
        let shape = RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous)
        return VStack(spacing: 3) {
            ZStack {
                shape.fill(r.field)
                if let ref = item.image {
                    MuseImage(ref: ImageRef(url: service.resolve(ref.url)), symbol: nil)
                } else if item.words != nil {
                    Ph("text-aa", 13).foregroundStyle(r.ink2)
                } else {
                    Ph(Self.icon(item.kind), 13).foregroundStyle(r.ink2)
                }
                if item.isVideo && item.image != nil {
                    Ph("play", 9).foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 2)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(shape)
            Text(item.label).scaled(t.scale.micro, r.ink2).lineLimit(1).fixedSize()
        }
        .help(item.detail.map { "\(item.label): \($0)" } ?? item.label)
    }

    static func icon(_ k: ClaudeContextItem.Kind) -> String {
        switch k {
        case .clip, .guide: "video-camera"
        case .character, .face: "user"
        case .outfit, .product: "image"
        case .background: "image"
        case .frame, .reference: "images"
        case .audio: "speaker-high"
        case .model: "aperture"
        }
    }
}
