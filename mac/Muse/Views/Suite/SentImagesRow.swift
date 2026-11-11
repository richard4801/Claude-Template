import MuseCore
import SwiftUI

// Images sent (server images/sent.ts, owner 2026-11-11): the images the model gets for what's set up now, in the order
// sent ("Image 1, 2, …" in the prompt), each with its role; the reason MUSE (or Claude) picked it is in the tooltip. When
// Claude or the person changed the list: "Changed by Claude" and "Reset to automatic". Quiet when there's nothing to send.

struct SentImagesRow: View {
    @Environment(\.theme) private var t
    var sent: SentImages?
    /// Back to MUSE's own pick (nil: no reset offered).
    var reset: (() -> Void)?

    var body: some View {
        if let s = sent, !s.images.isEmpty || s.changed {
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Text(s.title).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                    if let tag = s.tag {
                        Text(tag).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    }
                    Spacer(minLength: Space.s2)
                    if s.changed, let reset {
                        Button("Reset to automatic", action: reset)
                            .buttonStyle(.plain)
                            .font(t.scale.label.font).foregroundStyle(t.roles.accent)
                            .help("Send the images MUSE picks by itself")
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Space.s2) {
                        ForEach(Array(s.images.enumerated()), id: \.offset) { i, img in
                            thumb(img, index: i + 1)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(s.title + (s.tag.map { ", \($0)" } ?? ""))
        }
    }

    private func thumb(_ x: SentImage, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            MuseImage(ref: x.image)
                .frame(width: 44, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
                .overlay(RoundedRectangle(cornerRadius: t.radii.chip).stroke(t.roles.hairline, lineWidth: 1))
            Text(x.caption).font(t.scale.micro.font).foregroundStyle(t.roles.ink2)
                .lineLimit(1).frame(width: 44, alignment: .leading)
        }
        .help("Image \(index): \(x.why.isEmpty ? x.caption : x.why)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Image \(index), \(x.caption)\(x.why.isEmpty ? "" : ", \(x.why)")")
    }
}

/// The composer's row: the estimate of the open tool; Reset clears the draft's choice (the server forgets it too).
struct ComposerSentImagesRow: View {
    @Environment(AppStore.self) private var store

    private var sent: SentImages? {
        switch store.suite.composer.tool {
        case .photo: return store.suite.photoEstimate?.sentImages
        case .swap, .recast: return store.suite.swapEstimate?.sentImages
        case .shot, .talking, .ugc: return store.suite.estimate?.sentImages
        default: return nil
        }
    }

    var body: some View {
        SentImagesRow(sent: sent) { store.suite.composer.sent = .null }
    }
}
