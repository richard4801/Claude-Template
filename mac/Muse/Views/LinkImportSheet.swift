import MuseCore
import SwiftUI

/// "Import a video from a link" (owner-approved 2026-11-08): a small sheet over the current screen. A link field
/// (filled from the clipboard when it holds a link), Import, then the fetch's progress with Stop; a refusal says why
/// in Recreate's words and offers the file instead. Escape closes it (and stops a fetch).
struct LinkImportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @FocusState private var focused: Bool

    var body: some View {
        let s = store.linkImport
        let strict = s.settings?.strictLinks ?? true
        let limits = s.settings.map { RecreateDeviceFetch.Limits($0) } ?? RecreateDeviceFetch.Limits()
        ZStack {
            Color.black.opacity(0.38).onTapGesture { if !s.fetching { store.closeLinkImport() } }
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import a video from a link").scaled(t.scale.title, t.roles.ink).accessibilityAddTraits(.isHeader)
                        Text(Self.purposeLine(s.purpose)).scaled(t.scale.caption, t.roles.ink2)
                    }
                    Spacer()
                    RIconButton(systemName: "xmark", help: "Close") { store.closeLinkImport() }
                        .keyboardShortcut(.cancelAction)
                }
                RField("Link", hint: LinkImport.hint(strict: strict, limits: limits)) {
                    TextField("https://www.tiktok.com/@…/video/…", text: Binding(get: { s.text }, set: { s.text = $0; s.problem = nil; s.error = nil }))
                        .focused($focused)
                        .onSubmit { store.startLinkImport() }
                        .roleField(focused: focused)
                        .disabled(s.fetching)
                        .accessibilityLabel("Video link")
                }
                if !s.fetching, s.purpose == .swap, !s.recent.isEmpty {
                    // Your earlier imports: pick one again, nothing downloaded (owner bug 2026-11-09: choose from the Library).
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Your imports").scaled(t.scale.label, t.roles.ink)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.s2) {
                                ForEach(Array(s.recent.enumerated()), id: \.offset) { _, r in
                                    if let c = r.clip {
                                        Button { store.useEarlierImport(r) } label: {
                                            VStack(alignment: .leading, spacing: Space.s1) {
                                                MuseImage(ref: c.thumb).frame(width: 72, height: 96)
                                                    .clipShape(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous))
                                                Text(c.name).scaled(t.scale.caption, t.roles.ink2).lineLimit(1).frame(width: 72, alignment: .leading)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .help("Use \(c.name)")
                                        .accessibilityLabel("Use import \(c.name)")
                                    }
                                }
                            }
                        }
                    }
                }
                if s.fetching {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        HStack {
                            Text(s.status ?? "Working…").monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
                            Spacer(minLength: Space.s3)
                            RButton("Stop", kind: .plain, small: true) { store.stopLinkImport() }
                        }
                        if let p = s.progress { RProgress(value: p) } else { ProgressView().controlSize(.small) }
                    }
                }
                if let p = s.problem {
                    InlineNotice(p.message, tone: .caution, actionTitle: p.offersFile ? "Choose a file instead" : nil) { chooseFile() }
                } else if let e = s.error {
                    InlineNotice(e, tone: .caution, actionTitle: "Choose a file instead") { chooseFile() }
                }
                HStack(spacing: Space.s3) {
                    Text("Only public videos. You need the right to use what you import.").scaled(t.scale.caption, t.roles.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.s4)
                    RButton("Cancel", kind: .plain) { store.closeLinkImport() }
                    RButton("Import", kind: .action, off: s.fetching || LinkImport.link(s.text, strict: strict) == nil) { store.startLinkImport() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Space.s6)
            .floatingPanel(width: 560)
        }
        .onAppear { focused = !s.fetching }
    }

    static func purposeLine(_ p: LinkImportPurpose) -> String {
        switch p {
        case .swap: return "It becomes the clip to swap a model into"
        case .library: return "It's added to your clips"
        case .edit: return "It's added to Uploads"
        }
    }

    /// The file instead: Swap's clip picker; elsewhere the same picker, then the clip is used where it was asked for.
    private func chooseFile() {
        let purpose = store.linkImport.purpose
        store.closeLinkImport()
        if purpose == .swap { store.openTool(.swap) }
        store.pickClip()
    }
}
