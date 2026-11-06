import AppKit
import MuseCore
import SwiftUI

// AI suite (workstream 1): the Camera picker's steps (C2, C3). Setup: four drums side by side (Camera, Lens, Focal,
// Aperture; RigDrum.swift) under one selection band, on the always-dark camera bag. Angle: Height and Framing as tile
// grids. Movement: category chips + search over a 4-column grid; a move goes into the prompt as #move.

// MARK: Setup

/// Camera → Setup: the rig's four hardware drums. WS3's Photo tool reuses this view as is.
struct CameraSetupStep: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let c = store.suite.camera
        let s = store.suite.pickerSettings
        let cams = ComposerWheels.cameras(c), lenses = ComposerWheels.lenses(c), focals = ComposerWheels.focals(c), aps = ComposerWheels.apertures(c)
        HStack(alignment: .top, spacing: 0) {
            RigDrum(label: "Camera", items: cams, selected: Wheel.index(of: s.body, in: cams, options: c.bodies)) { item in
                store.suite.pickerSettings.body = item.value
            }
            RigDrum(label: "Lens", items: lenses, selected: Wheel.index(of: s.lens, in: lenses, options: c.lenses)) { item in
                store.suite.pickerSettings.lens = item.value
            }
            RigDrum(label: "Focal", items: focals, selected: ComposerWheels.focalIndex(s.focalMm, in: focals), face: .focal) { item in
                store.suite.pickerSettings.focalMm = item.value.flatMap { Double($0) }
            }
            RigDrum(label: "Aperture", items: aps, selected: Wheel.index(of: s.aperture, in: aps, options: c.apertures), face: .aperture) { item in
                store.suite.pickerSettings.aperture = item.value
            }
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 16).padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RigDrum.Bag.raised)
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
                OptionGrid(options: c.heights, selected: s.height, autoLine: "The scene decides", tileHeight: 84) {
                    store.suite.pickerSettings.height = $0
                }
                Text("Framing").font(t.body(16, .semibold)).padding(.top, 20)
                OptionGrid(options: c.shotSizes, selected: s.shotSize, autoLine: "The scene decides", tileHeight: 84) {
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
