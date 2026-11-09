import MuseCore
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Translate the captions (Mac Edit audit 2026-11-08: "Translate…" was a disabled placeholder). On this Mac with Apple's
/// on-device translation (macOS 15 and later; free, nothing leaves the Mac): each sentence is translated and keeps its time,
/// so the captions still follow the cuts. One undo step.
struct EditSuiteTranslateSheet: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: EditSuiteSession
    @State private var target = "es"
    @State private var running = false
    @State private var failure: String?
    @State private var request: AnyHashable?
    /// "device": Apple's translation on this Mac (free); "standard" / "best": the server's paid job (XL, WS16).
    @State private var how = EditSuiteTranslateSheet.available ? "device" : "standard"

    static let languages: [(String, String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
        ("nl", "Dutch"), ("pl", "Polish"), ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"), ("ar", "Arabic"),
        ("hi", "Hindi"), ("id", "Indonesian"), ("th", "Thai"), ("vi", "Vietnamese"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Translate captions").font(t.scale.heading.font).foregroundStyle(t.roles.ink)
                Spacer()
                SuiteIconButton(systemName: "xmark", label: "Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            let ways: [(String, String)] = (Self.available ? [("device", "On this Mac · free")] : []) + [("standard", "Standard"), ("best", "Best quality")]
            EditSeg(options: ways,
                    selection: how, small: true) { how = $0 }
            Text(how == "device"
                 ? "Each sentence is translated on this Mac and keeps its timing. The original words are kept; switch back any time."
                 : "Translated on the server, line by line with its timing. The price shows before it runs. The original words are kept.")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            Picker("Into", selection: $target) {
                ForEach(how == "device" ? Self.languages : session.translateLanguages.map { ($0.code, $0.name) }, id: \.0) { Text($0.1).tag($0.0) }
            }
            .frame(maxWidth: 280)
            if let failure { Note(warn: true, failure) }
            HStack {
                Spacer()
                if running { ProgressView().controlSize(.small) }
                SuiteToolButton(title: running || session.isRunning(.translate) ? "Translating…" : "Translate", icon: "chat-circle-text", accent: true,
                                disabled: running || session.isRunning(.translate) || (how != "device" && session.features?.isAvailable(.translate) == false)) { start() }
            }
            // On this Mac any script draws; the server's export only the languages it lists (WS16 0cfa277e).
            if how == "device", let server = session.features?.translate?.languages, server[target] == nil {
                Text("Exports made on this Mac show it; the server's export can't draw this script yet.")
                    .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if how != "device", let note = session.features?.note(.translate) {
                Text(note).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
            }
        }
        .padding(Space.s5)
        .frame(width: 420)
        .background(t.roles.canvas)
        .modifier(TranslateRunner(request: request, target: target, texts: session.state.captionChunks.map(\.text)) { result in
            running = false
            request = nil
            switch result {
            case .success(let out):
                if session.edit({ $0.translateCaptions(out, language: target) }) {
                    session.notice = "Captions translated · Show original switches back"
                    dismiss()
                } else { failure = "The translation didn't fit the captions · try again" }
            case .failure(let e):
                failure = "Couldn't translate: \(e.localizedDescription)"
            }
        })
    }

    static var available: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    private func start() {
        failure = nil
        if how != "device" {
            // The server's job: the price is asked first (the session's paid helper flow), then the timed words land.
            session.translateTarget = target
            session.translateQuality = how
            dismiss()
            Task { await session.translateCaptions() }
            return
        }
        running = true
        request = AnyHashable(UUID())
    }
}

/// Runs Apple's translation when `request` changes (macOS 15+); nothing on older systems.
private struct TranslateRunner: ViewModifier {
    var request: AnyHashable?
    var target: String
    var texts: [String]
    var done: (Result<[String], Error>) -> Void

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            content.modifier(TranslateRunner15(request: request, target: target, texts: texts, done: done))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct TranslateRunner15: ViewModifier {
    var request: AnyHashable?
    var target: String
    var texts: [String]
    var done: (Result<[String], Error>) -> Void
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, r in
                guard r != nil else { return }
                if config == nil || config?.target?.languageCode?.identifier != target {
                    config = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: target))
                } else {
                    config?.invalidate()
                }
            }
            .translationTask(config) { session in
                do {
                    let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)") }
                    let res = try await session.translations(from: reqs)
                    var out = texts
                    for r in res { if let i = r.clientIdentifier.flatMap(Int.init), out.indices.contains(i) { out[i] = r.targetText } }
                    await MainActor.run { done(.success(out)) }
                } catch {
                    await MainActor.run { done(.failure(error)) }
                }
            }
    }
}
#endif
