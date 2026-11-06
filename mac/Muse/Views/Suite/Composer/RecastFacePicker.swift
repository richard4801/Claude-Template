import AppKit
import AVFoundation
import MuseCore
import SwiftUI

// AI suite (workstream 1): Recast's "tap a face" (plans/video-composer.md, Recast). The clip's first frame with a
// numbered marker on each face clicked; a click on a new face adds that person (up to the catalog's limit), then a
// studio character is picked to replace them. Where they stand comes from the third the face is in unless a position
// chip is picked, and a square crop around the face is sent as the person's faceCrop. Always dark, like every picker.

struct RecastFacePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var onDone: () -> Void
    @State private var frame: CGImage?
    @State private var loading = true
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(t.line).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    framePane
                    characterStrip
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(t.line).frame(width: 1)
                ScrollView { RecastCastList(selected: $selected).padding(16) }
                    .frame(width: 330)
            }
        }
        .frame(width: 940, height: 620)
        .foregroundStyle(t.ink)
        .background(t.bg)
        .task { await load() }
        .onAppear { if selected == nil { selected = store.suite.swap.people.first?.id } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("WHO BECOMES WHOM").font(Fonts.font("Barlow Condensed", 24, .bold)).tracking(2)
            Text("Click a face on the first frame, then pick who replaces them").font(t.body(13)).foregroundStyle(t.muted)
            Spacer(minLength: 8)
            Button(action: onDone) {
                Text("Done").font(t.body(13, .semibold)).padding(.horizontal, 16).frame(height: 32)
                    .background(Capsule().fill(t.surface2))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, 24).padding(.trailing, 14)
        .frame(height: 62)
    }

    // MARK: The first frame

    private var frameSize: CGSize {
        if let f = frame { return CGSize(width: f.width, height: f.height) }
        if let c = store.clip, c.width > 0, c.height > 0 { return CGSize(width: c.width, height: c.height) }
        return CGSize(width: 9, height: 16)
    }

    private func fitRect(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let s = min(box.width / size.width, box.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private var framePane: some View {
        GeometryReader { g in
            let fit = fitRect(frameSize, in: g.size)
            ZStack(alignment: .topLeading) {
                picture
                    .frame(width: fit.width, height: fit.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .offset(x: fit.minX, y: fit.minY)
                // The thirds the position chips follow.
                ForEach([1.0 / 3, 2.0 / 3], id: \.self) { x in
                    Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: fit.height)
                        .offset(x: fit.minX + fit.width * x, y: fit.minY)
                }
                ForEach(Array(store.suite.swap.people.enumerated()), id: \.element.id) { i, p in
                    if let f = p.face { marker(i, p, on: p.id == selected).position(x: fit.minX + f.x * fit.width, y: fit.minY + f.y * fit.height) }
                }
                if loading {
                    ProgressView().controlSize(.small).position(x: fit.midX, y: fit.midY)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in
                guard fit.width > 0, fit.contains(v.location) else { return }
                let p = FacePoint(x: (v.location.x - fit.minX) / fit.width, y: (v.location.y - fit.minY) / fit.height)
                selected = store.tapFace(p, frame: frame, selected: selected)
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The clip's first frame. Click a face to choose who to replace.")
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var picture: some View {
        if let frame {
            Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
            MuseImage(ref: store.clipPoster)
        }
    }

    private func marker(_ i: Int, _ p: RecastPerson, on: Bool) -> some View {
        ZStack {
            Circle().strokeBorder(on ? t.accent : Color.white, lineWidth: on ? 3 : 2)
                .background(Circle().fill(Color.black.opacity(0.18)))
                .frame(width: 44, height: 44)
            Text("\(i + 1)").font(t.mono(12, .semibold)).foregroundStyle(t.accentInk)
                .frame(width: 20, height: 20).background(Circle().fill(t.accent))
                .offset(x: 20, y: -20)
            if p.uploading { ProgressView().controlSize(.mini).offset(x: -20, y: 20) }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Person \(i + 1)")
    }

    // MARK: Who replaces the selected person

    @ViewBuilder private var characterStrip: some View {
        let people = store.suite.swap.people
        if let i = people.firstIndex(where: { $0.id == selected }) {
            let p = people[i]
            VStack(alignment: .leading, spacing: 8) {
                Text("PERSON \(i + 1) BECOMES").font(t.mono(10.5, .medium)).tracking(1.2).foregroundStyle(t.muted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.suiteCharacters) { m in
                            let on = m.id == p.member.characterId
                            Button {
                                store.setPerson(p.id) { q in
                                    q.member.characterId = m.id
                                    q.member.outfitId = nil
                                }
                            } label: {
                                VStack(spacing: 5) {
                                    MuseImage(ref: m.cover).frame(width: 52, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? t.accent : .clear, lineWidth: 2).padding(-3))
                                    Text(m.shortName).font(t.body(11.5, on ? .semibold : .regular)).lineLimit(1).frame(width: 60)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(m.name)\(on ? ", selected" : "")")
                        }
                    }
                    .padding(4)
                }
            }
        } else {
            Text(people.isEmpty ? "Click the first face to replace." : "Click a marker to change who replaces that person.")
                .font(t.body(12.5)).foregroundStyle(t.muted)
        }
    }

    // MARK: Loading the frame

    /// The clip's frame at 0 s; else its thumb; else the poster as the app draws it (so a crop always exists).
    private func load() async {
        defer { loading = false }
        if let url = store.clipFile {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            gen.maximumSize = CGSize(width: 1440, height: 1440)
            if let f = try? await gen.image(at: .zero).image {
                frame = f
                return
            }
        }
        if let u = store.clipPoster?.url {
            let img: NSImage? = u.hasPrefix("http") ? await ImageCache.shared.load(u) : ImageCache.shared.image(for: u)
            if let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                frame = cg
                return
            }
        }
        let size = frameSize
        let scale = 720 / max(size.width, size.height)
        let renderer = ImageRenderer(content: MuseImage(ref: store.clipPoster).frame(width: size.width * scale, height: size.height * scale))
        frame = renderer.cgImage
    }
}
