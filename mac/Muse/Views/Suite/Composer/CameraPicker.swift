import AppKit
import MuseCore
import SwiftUI

// AI suite (workstream 1): the Camera picker's steps (C2, C3). Setup: the live rig line and four drums side by side (Camera, Lens, Focal,
// Aperture; RigDrum.swift) under one selection band, on the always-dark camera bag. Angle: Height and Framing as tile
// grids. Movement: category chips + search over a 4-column grid; a move goes into the prompt as #move.

// MARK: Setup

/// Camera → Setup: the rig's four hardware drums, laid out as the prototype (design/drum-wheels-prototype.html): the live
/// rig line, then the camera bag with four equal columns under one band, centred (at most 980 wide) with no dead area.
/// WS3's Photo tool reuses this view as is.
struct CameraSetupStep: View {
    @Environment(AppStore.self) private var store

    /// The prototype's .wrap max width.
    static let maxWidth: CGFloat = 980

    var body: some View {
        let c = store.suite.camera
        let s = store.suite.pickerSettings
        let cams = ComposerWheels.cameras(c), lenses = ComposerWheels.lenses(c), focals = ComposerWheels.focals(c), aps = ComposerWheels.apertures(c)
        let ci = Wheel.index(of: s.body, in: cams, options: c.bodies)
        let li = Wheel.index(of: s.lens, in: lenses, options: c.lenses)
        let fi = ComposerWheels.focalIndex(s.focalMm, in: focals)
        let ai = Wheel.index(of: s.aperture, in: aps, options: c.apertures)
        let names = [Self.name(cams, ci), Self.name(lenses, li), Self.name(focals, fi), Self.name(aps, ai)]
        GeometryReader { g in
            let width = min(max(g.size.width - 32, 0), Self.maxWidth)
            // 112 pt rows once the drums area is 720 pt wide (the prototype's breakpoint), else 84.
            let row = RigDrum.row(wide: width >= RigDrum.wideWidth)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    RigLine(names: names)
                    RigDrums(rowHeight: row) {
                        RigDrum(label: "Camera", items: cams, selected: ci, rowHeight: row, band: false) { item in
                            store.suite.pickerSettings.body = item.value
                        }
                        RigDrum(label: "Lens", items: lenses, selected: li, rowHeight: row, band: false) { item in
                            store.suite.pickerSettings.lens = item.value
                        }
                        RigDrum(label: "Focal", items: focals, selected: fi, face: .focal, rowHeight: row, band: false) { item in
                            store.suite.pickerSettings.focalMm = item.value.flatMap { Double($0) }
                        }
                        RigDrum(label: "Aperture", items: aps, selected: ai, face: .aperture, rowHeight: row, band: false) { item in
                            store.suite.pickerSettings.aperture = item.value
                        }
                    }
                }
                .frame(width: width)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                // Centred both ways in the space the step has.
                .frame(maxWidth: .infinity, minHeight: g.size.height)
            }
        }
    }

    private static func name(_ items: [WheelItem], _ i: Int) -> String {
        items.indices.contains(i) ? items[i].name : "Auto"
    }
}

// MARK: Angle

/// Camera → Angle: not hardware, so tiles (the same grid as Lighting and Look).
struct CameraAngleStep: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let c = store.suite.camera
        let s = store.suite.pickerSettings
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Height").font(t.body(16, .semibold))
                OptionGrid(options: c.heights, selected: s.height) {
                    store.suite.pickerSettings.height = $0
                }
                Text("Framing").font(t.body(16, .semibold)).padding(.top, 20)
                OptionGrid(options: c.shotSizes, selected: s.shotSize) {
                    store.suite.pickerSettings.shotSize = $0
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
        }
    }
}

// MARK: Movement

struct CameraMovementStep: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Binding var query: String
    @State private var group = ComposerMoves.featured

    var body: some View {
        let c = store.suite.camera
        let moves = ComposerMoves.list(c, group: group, query: query)
        let talk = store.suite.composer.speaking == .on
        let inPrompt = Set(store.suite.composer.tokens.moves.compactMap { $0.move?.id })
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Click to add to your prompt").font(t.body(13))
                Text("·").foregroundStyle(t.muted)
                HStack(spacing: 4) {
                    Text("or type").foregroundStyle(t.muted)
                    Text("#").font(t.mono(11, .medium)).padding(.horizontal, 5).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(t.line, lineWidth: 1))
                }
                .font(t.body(13))
                Text("·").foregroundStyle(t.muted)
                Text("up to \(PromptTokens.maxMoves) moves").font(t.body(13)).foregroundStyle(t.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ComposerMoves.groups(c)) { g in
                        let on = g.id == group && query.isEmpty
                        Button {
                            group = g.id
                            query = ""
                        } label: {
                            Text(g.label).font(t.body(13, .semibold)).foregroundStyle(on ? t.bg : t.muted)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Capsule().fill(on ? t.ink : t.surface2))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(g.label)\(on ? ", selected" : "")")
                    }
                }
            }
            ScrollView {
                if moves.isEmpty {
                    Text("No move matches “\(query)”").font(t.body(13)).foregroundStyle(t.muted).padding(.top, 30).frame(maxWidth: .infinity)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 15), count: 4), alignment: .leading, spacing: 16) {
                    ForEach(moves) { m in
                        MoveTile(move: m, talkSafeBadge: talk && m.talkSafe, inPrompt: inPrompt.contains(m.id)) { store.insertMove(m) }
                    }
                }
                .padding(.bottom, 18)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 22).padding(.top, 16)
    }
}

/// A move's tile: the neutral still (or its loop, on hover) with the move's arrow, badges and the name.
struct MoveTile: View {
    @Environment(\.theme) private var t
    var move: SuiteMoveOption
    var talkSafeBadge: Bool
    var inPrompt: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topLeading) {
                    // The rendered loop plays while the tile is on screen; the drawn arrow only where there's no preview.
                    let pv = PickerPreview.move(move)
                    PreviewView(preview: pv, autoplay: true)
                        .overlay { if !pv.hasRender { MoveArrow(move: move) } }
                    VStack(alignment: .leading, spacing: 4) {
                        if talkSafeBadge { badge("Talk-safe", icon: "text.bubble") }
                        if move.editorBetter { badge("Better in Edit", icon: "scissors") }
                    }
                    .padding(8)
                }
                .frame(height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(inPrompt ? t.accent : .clear, lineWidth: 2).padding(-3))
                Text(move.label).font(t.body(14, .semibold)).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(move.description)
        .accessibilityLabel("\(move.label)\(talkSafeBadge ? ", talk-safe" : "")\(move.editorBetter ? ", better done in Edit" : "")\(inPrompt ? ", in the prompt" : "")")
    }

    private func badge(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Ph(icon, 9)
            Text(text).font(t.scale.micro.font)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(Color(hex: 0xECEAE5))
        .padding(.leading, 6).padding(.trailing, 8).frame(height: 20)
        .background(Capsule().fill(Color(hex: 0x0D0E0F, alpha: 0.74)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}
