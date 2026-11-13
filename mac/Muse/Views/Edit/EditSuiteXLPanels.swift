import AppKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

// The owner-approved helpers on the selected item (WS8 contracts, WS16 jobs): the effects library, the cross-dissolve
// between overlays, split voice and music, and cut out a picture.

/// Effects (WS8 f7226f2): one effect per clip or picture, with its amount, speed for the moving ones, and two colours
/// for duotone.
struct EffectsPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    private static let names: [String: String] = [
        "glitch": "Glitch", "vhs": "VHS", "film": "Film", "blur": "Blur", "zoomBlur": "Zoom blur", "mirror": "Mirror",
        "pixelate": "Pixelate", "posterize": "Posterize", "duotone": "Duotone", "shake": "Shake", "flash": "Flash", "rain": "Rain",
    ]

    var body: some View {
        let e = session.state.selectedEffect
        EditPanel(title: "Effects") {
            FlowLayout(spacing: 6) {
                Chip("None", on: e == nil) { session.edit { $0.setEffect(nil) } }
                ForEach(EditV2.effectIds, id: \.self) { id in
                    Chip(Self.names[id] ?? id, on: e?.id == id) {
                        session.edit { $0.setEffect(EditV2.Effect(id: id, amount: e?.amount ?? 0.6, speed: nil, colors: id == "duotone" ? e?.colors : nil)) }
                    }
                    .accessibilityLabel("Effect \(Self.names[id] ?? id)")
                }
            }
            if let e {
                SuiteSlider("Amount", value: e.amount, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in
                    var n = e; n.amount = (v * 100).rounded() / 100
                    session.edit { $0.setEffect(n) }
                }
                if EditV2.effectSpeedIds.contains(e.id) {
                    SuiteSlider("Speed", value: e.speed ?? 1, range: 0.1...4, format: { String(format: "%.1f×", $0) }) { v in
                        var n = e; n.speed = abs(v - 1) < 0.05 ? nil : (v * 10).rounded() / 10
                        session.edit { $0.setEffect(n) }
                    }
                }
                if e.id == "duotone" {
                    let cs = e.colors ?? EditV2.duotoneDefault
                    HStack(spacing: Space.s2) {
                        Text("Colours").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                        Spacer(minLength: 0)
                        SuiteSwatch(hex: cs[0], label: "Shadow colour") { c in var n = e; n.colors = [c, cs[1]]; session.edit { $0.setEffect(n) } }
                        SuiteSwatch(hex: cs[1], label: "Highlight colour") { c in var n = e; n.colors = [cs[0], c]; session.edit { $0.setEffect(n) } }
                    }
                }
            }
        }
    }
}

/// "Dissolve from previous" on an overlay clip or picture that touches the one before it (WS8 3d62419): it moves earlier
/// by the dissolve's length, or back when switched off.
struct OverlayDissolvePanel: View {
    @Bindable var session: EditSuiteSession
    @State private var length = 0.5

    var body: some View {
        let d = session.state.selectedDissolve
        EditPanel(title: "Transition") {
            SuiteToggleRow(title: "Dissolve from previous", hint: "Overlaps the item before it and fades across", isOn: d != nil) { on in
                session.edit { $0.setOverlayDissolve(on ? length : nil) }
            }
            if let d {
                SuiteSlider("Length", value: d.durationSec, range: 0.1...2, format: { String(format: "%.1f s", $0) }) { v in
                    length = (v * 10).rounded() / 10
                    session.edit { $0.setOverlayDissolve(nil) }
                    session.edit { $0.setOverlayDissolve(length) }
                }
            }
        }
    }
}

/// Split voice and music on the selected clip (paid; the price shows before it runs).
struct SeparateRow: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        if session.features?.isAvailable(.separate) == false {
            HelperUnavailableRow(title: "Split voice and music", note: session.helperNote(.separate))
        } else {
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Text("Split voice and music").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                    if session.isRunning(.separate) { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }
                HStack(spacing: Space.s2) {
                    SuiteToolButton(title: "Keep both", disabled: session.isRunning(.separate)) { Task { await session.separateSelected(keep: .both) } }
                    SuiteToolButton(title: "Voice only", disabled: session.isRunning(.separate), plain: true) { Task { await session.separateSelected(keep: .vocals) } }
                    SuiteToolButton(title: "Music only", disabled: session.isRunning(.separate), plain: true) { Task { await session.separateSelected(keep: .instrumental) } }
                }
                Text("Mutes the clip and puts each part on its own row, in time with it.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Cut out the selected picture (paid): the person; it stays where it was.
struct CutoutRow: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        if session.features?.isAvailable(.cutout) == false {
            HelperUnavailableRow(title: "Cut out", note: session.helperNote(.cutout))
        } else {
            HStack(spacing: Space.s2) {
                SuiteToolButton(title: session.isRunning(.cutout) ? "Cutting out…" : "Cut out the person", icon: "scissors", disabled: session.isRunning(.cutout)) {
                    Task { await session.cutoutSelected() }
                }
                if session.isRunning(.cutout) { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
        }
    }
}
