import AppKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

/// The export sheet (E4): shape, resolution, frame rate, format (MP4 · H.264 / HEVC), captions (burn in / .SRT file), the
/// Disclosure switches (both OFF by default, per export), the summary with a size estimate, Save to Gallery and EXPORT.
struct EditSuiteExportSheet: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: EditSuiteSession
    var onSaved: (Take) -> Void
    @State private var settings = EditSuite.ExportSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Export").font(t.display(30, .regular)).foregroundStyle(t.ink)
                Spacer()
                SuiteIconButton(systemName: "xmark", label: "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            SuiteRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SuiteLabel("Shape")
                    HStack(spacing: 10) {
                        ForEach(EditSuite.Ratio.allCases) { r in shapeTile(r) }
                    }
                    Text("Changing shape re-frames each clip to keep faces in view. Captions move with the safe area.")
                        .font(t.body(12)).foregroundStyle(t.muted)
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            SuiteLabel("Resolution")
                            EditSeg(options: EditSuite.Resolution.allCases.map { ($0, $0.label) }, selection: settings.resolution, height: 32) { settings.resolution = $0 }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            SuiteLabel("Frame rate")
                            EditSeg(options: EditSuite.ExportSettings.frameRates.map { ($0, "\($0)") }, selection: settings.fps, height: 32) { settings.fps = $0 }
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            SuiteLabel("Format")
                            EditSeg(options: EditSuite.Codec.allCases.map { ($0, $0.label) }, selection: settings.codec, height: 32) { settings.codec = $0 }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            SuiteLabel("Captions")
                            EditSeg(options: EditSuite.CaptionsOut.allCases.map { ($0, $0.label) }, selection: settings.captions, height: 32) { settings.captions = $0 }
                                .disabled(session.project.captionTrack == nil)
                                .opacity(session.project.captionTrack == nil ? 0.5 : 1)
                        }
                    }
                    disclosure
                    HStack {
                        Text(settings.summary(durationSec: session.duration)).font(t.body(13)).foregroundStyle(t.ink)
                        Spacer()
                        Text(settings.sizeLabel(durationSec: session.duration)).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.ink)
                    }
                    if let p = session.exportProblem { Note(warn: true, p) }
                    HStack(spacing: 12) {
                        Button { start(saveFile: false) } label: {
                            Text("Save to Library").font(t.body(13.5, .semibold)).foregroundStyle(t.ink)
                                .padding(.horizontal, 14).frame(height: 40)
                                .overlay(Rectangle().strokeBorder(t.line))
                        }
                        .buttonStyle(.plain)
                        .disabled(session.exportProblem != nil)
                        Button { start(saveFile: true) } label: {
                            Text("Export").font(t.body(14, .semibold)).foregroundStyle(t.bg)
                                .padding(.horizontal, 24).frame(height: 50)
                                .background(Rectangle().fill(t.ink))
                        }
                        .buttonStyle(.plain)
                        .disabled(session.exportProblem != nil)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 600, height: 700)
        .background(t.surface)
        .onAppear {
            // Claude's export request opens the sheet with its preset (Edit sessions, workstream 3).
            settings = session.exportAsk ?? session.state.export
            // Disclosure is chosen per export and starts off every time (owner rule).
            settings.labelAI = false
            settings.c2pa = false
            if session.project.captionTrack == nil { settings.captions = .burnIn }
        }
    }

    private func shapeTile(_ r: EditSuite.Ratio) -> some View {
        let on = settings.ratio == r
        let (a, b) = r.aspect
        let box: CGFloat = 46
        let w = a >= b ? box : box * CGFloat(a) / CGFloat(b), h = a >= b ? box * CGFloat(b) / CGFloat(a) : box
        return Button {
            settings.ratio = r
            if r != session.state.export.ratio { Task { await session.setRatio(r) } }
        } label: {
            VStack(spacing: 8) {
                Rectangle().fill(on ? t.ink : .clear).overlay(Rectangle().strokeBorder(t.ink, lineWidth: 2)).frame(width: w, height: h)
                Text(r.label).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.ink)
            }
            .frame(width: 92, height: 88)
            .background(on ? t.surface2 : t.bg)
            .overlay(Rectangle().strokeBorder(on ? t.ink : t.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shape \(r.label)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Ph("checkmark.shield").foregroundStyle(t.ink).accessibilityHidden(true)
                Text("Disclosure").font(t.body(14, .semibold)).foregroundStyle(t.ink)
                Spacer()
                Text("Your choice, per export").font(t.body(12)).foregroundStyle(t.muted)
            }
            SuiteToggleRow(title: "Label as AI-generated", hint: "Adds the platform’s AI label when you post from MUSE", isOn: settings.labelAI) { settings.labelAI = $0 }
            SuiteToggleRow(title: "Content Credentials (C2PA)", hint: settings.c2pa ? "Coming soon · signing isn't available yet, the file is exported without it"
                                                                                    : "Signed provenance inside the file",
                           isOn: settings.c2pa) { settings.c2pa = $0 }
            Text("Ads with realistic AI people may need a label in some places (EU, New York). We remind you when posting an ad.")
                .font(t.body(12)).foregroundStyle(t.muted)
        }
        .padding(14)
        .overlay(Rectangle().strokeBorder(t.line))
    }

    private func start(saveFile: Bool) {
        var dest: URL?
        if saveFile {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = (session.title.isEmpty ? "Edit" : session.title) + ".mp4"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            dest = url
        }
        session.view { $0.export = settings }
        // A Claude export request is answered when this export ends (Edit sessions, workstream 3).
        let request = session.exportAskRequest
        session.exportAskRequest = nil
        session.export(settings, saveFileTo: dest, request: request, onSaved: onSaved)
        dismiss()
    }
}

/// Export → upload progress with Cancel, over the editor.
struct EditSuiteExportProgress: View {
    @Environment(\.theme) private var t
    var session: EditSuiteSession

    var body: some View {
        let (title, value): (String, Double) = {
            switch session.exportPhase {
            case .rendering(let p): return ("Making the video on this Mac", p)
            case .uploading(let p): return ("Saving to Library", p)
            case .idle: return ("", 0)
            }
        }()
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(t.body(15, .bold))
                ProgressLine(value: value)
                HStack {
                    Text("\(Int((value * 100).rounded())) %").font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.muted)
                    Spacer()
                    MButton("Cancel", size: .small) { session.cancelExport() }.keyboardShortcut(.cancelAction)
                }
            }
            .frame(width: 340)
            .card(18)
        }
    }
}
