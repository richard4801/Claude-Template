import MuseCore
import SwiftUI

// AI suite (workstream 1): the Extend tool's VIDEO slot and prompt area, and Upscale on a finished take (a small dark
// popover with the three sizes, each with its price for this take or greyed "Soon"). Pickers are always dark.

/// The VIDEO slot: one of your takes or an uploaded video.
struct ExtendVideoSlot: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var card: ComposerSlotCard
    var size: CGFloat
    @State private var open = false
    @Environment(\.slotThumbs) private var thumbs

    var body: some View {
        let source = store.suite.composer.extend.source
        Group {
            if let p = store.suite.extendUpload {
                VStack(spacing: 8) {
                    ProgressView(value: p).progressViewStyle(.linear).frame(width: size - 28)
                    Text("Uploading · \(Int((p * 100).rounded()))%").font(t.body(10.5)).foregroundStyle(t.muted)
                }
                .frame(width: size, height: size)
                .background(t.bg)
                .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
                .accessibilityLabel("Video, uploading")
            } else if let s = source {
                filled(s)
            } else {
                EmptySlotCard(card: card) { open = true }
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ExtendVideoPicker { open = false }
                .environment(store)
                .environment(\.theme, PickerTheme.dark)
                .environment(\.colorScheme, .dark)
        }
    }

    private func filled(_ s: ExtendSource) -> some View {
        ZStack(alignment: .bottomLeading) {
            Button { open = true } label: {
                Group {
                    if let thumb = s.thumb {
                        MuseImage(ref: thumb)
                    } else {
                        Rectangle().fill(Color(hex: 0x1A1714)).overlay(Image(systemName: "film").font(.system(size: 20)).foregroundStyle(Color(hex: 0xA39C90)))
                    }
                }
                .frame(width: size, height: size).clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(s.name), change")
            if !thumbs {
                LinearGradient(colors: [.clear, Color(hex: 0x0E0C0A, alpha: 0.78)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 1) {
                    Text("VIDEO").font(t.mono(9.5, .medium)).tracking(1).foregroundStyle(Color(hex: 0xF8F5EF))
                    Text("\(s.caption) · change").font(t.body(10.5)).foregroundStyle(Color(hex: 0xE7E1D6)).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.bottom, 7)
                .allowsHitTesting(false)
            }
            Button { store.setExtendSource(nil) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: 0xF8F5EF))
                    .frame(width: 20, height: 20).background(Circle().fill(Color(hex: 0x0E0C0A, alpha: 0.55)))
            }
            .buttonStyle(.plain)
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .accessibilityLabel("Remove the video")
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: thumbs ? t.radii.control : 0))
        .accessibilityLabel("Video, \(s.name), \(s.caption)")
    }
}

/// The VIDEO slot's picker: your finished takes, or upload a video.
struct ExtendVideoPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var onDone: () -> Void

    var body: some View {
        let list = store.extendableTakes
        let current = store.suite.composer.extend.source?.key
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VIDEO TO EXTEND").font(t.mono(10.5, .medium)).tracking(1.2)
                Spacer()
                Text("A take or an upload").font(t.body(11.5)).foregroundStyle(t.muted)
            }
            if list.isEmpty {
                Text("No finished takes yet. Upload a video, or render a take first.").font(t.body(12)).foregroundStyle(t.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 8), count: 4), alignment: .leading, spacing: 10) {
                        ForEach(list) { item in
                            let on = item.source.key == current
                            Button {
                                store.setExtendSource(item.source)
                                onDone()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    MuseImage(ref: item.take.thumb).frame(width: 88, height: 110).clipped()
                                        .overlay(Rectangle().strokeBorder(on ? t.accent : t.line, lineWidth: on ? 2 : 1))
                                    Text(item.take.caption).font(t.body(10.5)).lineLimit(1).frame(width: 88, alignment: .leading)
                                    Text(item.source.seconds.map { Take.clock($0) } ?? "—").font(t.mono(9.5)).foregroundStyle(t.muted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(item.take.caption)\(on ? ", selected" : "")")
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 320)
            }
            Divider()
            Button {
                onDone()
                store.uploadExtendVideo()
            } label: {
                Label("Upload a video…", systemImage: "square.and.arrow.up").font(t.body(13, .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("MP4 or MOV, up to \(Int(ExtendSource.maxUploadSeconds)) s. The new part joins on, so the take is the whole longer clip.")
                .font(t.body(11)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 410, alignment: .leading)
        .foregroundStyle(t.ink)
        .background(t.surface)
    }
}

/// Extend's After / Before switch and the new part's length (the composer's Setup rail).
struct ExtendDirectionControl: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let d = store.suite.composer.extend
        let range = ComposerBar.lengthRange(store.suite.catalog?.tier(store.suite.composer.quality))
        VStack(alignment: .leading, spacing: Space.s2) {
            SuiteSeg(options: ExtendDirection.allCases.map { ($0, $0.label) }, selection: d.direction) { store.suite.composer.extend.direction = $0 }
                .accessibilityLabel("Extend after or before")
            HStack {
                Text("Added length").font(t.scale.label.font).foregroundStyle(t.roles.ink2)
                Spacer(minLength: Space.s2)
                Text("+\(store.suite.composer.duration) s").font(t.scale.label.font).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(store.suite.composer.duration) }, set: { store.suite.composer.duration = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1)), step: 1) { Text("Added length") }
                .labelsHidden()
            Text(d.direction == .after ? "The take carries on from its last moment. You get the whole longer clip." :
                    "New footage leads into the take's first moment. You get the whole longer clip.")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Extend's prompt (the composer's prompt bar): what happens in the new part.
struct ExtendPromptField: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let d = store.suite.composer.extend
        TextField(d.direction.placeholder, text: Binding(get: { store.suite.composer.extend.prompt }, set: { store.suite.composer.extend.prompt = $0 }),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(t.body(16))
            .lineLimit(2...3)
            .padding(.vertical, Space.s1)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
            .accessibilityLabel(d.direction.promptTitle)
    }
}

// MARK: Upscale

/// The Upscale picker: 1080p / 2K / 4K, each with its price for this take, greyed "Soon" while it isn't offered.
struct UpscalePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var take: Take
    var onDone: () -> Void

    var body: some View {
        let choices = store.upscaleChoices(take)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("UPSCALE").font(t.mono(10.5, .medium)).tracking(1.2)
                OwnerModelPill(purpose: .upscale, compact: true) // the owner's upscale model (WS6)
                Spacer()
                Text(take.durationSec.map { "for this \(Take.clock($0)) take" } ?? "sharper, from this take").font(t.body(11.5)).foregroundStyle(t.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            ForEach(choices) { c in
                Button {
                    guard c.canPick else { return }
                    onDone()
                    store.upscale(take, size: c.size)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.size.label).font(t.body(13, .semibold))
                            Text(c.size.sizeLine).font(t.mono(10)).foregroundStyle(t.muted)
                        }
                        Spacer(minLength: 12)
                        if c.available {
                            Text(c.priceText).font(t.mono(13, .medium))
                        } else {
                            SuiteTag(text: c.priceText)
                        }
                    }
                    .padding(.horizontal, 14).frame(height: 46)
                    .opacity(c.canPick ? 1 : 0.45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!c.canPick || store.upscaling)
                .accessibilityLabel("\(c.size.label), \(c.priceText)")
            }
            Text("A new take, sharper and bigger. The original is kept.").font(t.body(11)).foregroundStyle(t.muted)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 280, alignment: .leading)
        .foregroundStyle(t.ink)
        .background(t.surface)
    }
}

/// "Upscale" on a finished render take: opens the picker.
struct UpscaleButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var take: Take
    var size: ButtonSize = .regular
    var fill = false
    @State private var open = false

    var body: some View {
        MButton(store.upscaleLive ? "Upscale" : "Upscale · soon", icon: "arrow.up.left.and.arrow.down.right", size: size, off: store.upscaling, fill: fill) { open = true }
            .help("Sharper 1080p, 2K or 4K from this take")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                UpscalePicker(take: take) { open = false }
                    .environment(store)
                    .environment(\.theme, PickerTheme.dark)
                    .environment(\.colorScheme, .dark)
            }
    }
}
