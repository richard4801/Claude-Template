import MuseCore
import SwiftUI

// AI suite (workstream 1): the one picker shell (plans/video-composer.md "The picker shell"), C2–C4. A centred ~840×540
// modal over a dimmed page with a title, Reset all and ×; sub-steps in a left rail with a dot on any step that has a
// value. Choices apply instantly (no OK). Always dark (Theme B Camera Body), whatever the app theme.

/// The chips that open a picker.
enum ComposerPicker: String, Identifiable {
    case style, camera, look, lighting
    var id: String { rawValue }

    var chip: ComposerChip {
        switch self {
        case .style: return .style
        case .camera: return .camera
        case .look: return .look
        case .lighting: return .lighting
        }
    }

    init?(chip: ComposerChip) {
        switch chip {
        case .style: self = .style
        case .camera: self = .camera
        case .look: self = .look
        case .lighting: self = .lighting
        case .references: return nil
        }
    }

    /// Sentence case ("Camera"), per the design direction: no caps tracking.
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var subtitle: String {
        switch self {
        case .camera: return "Choices apply instantly"
        case .style: return "Genre, era and tempo, applied instantly"
        case .look, .lighting: return "Applies instantly"
        }
    }

    /// The left rail's sub-steps. Directed is the owner's (and only for the composer); a storyboard's look lock has no moves.
    /// `photo`: the Photo tool (workstream 3) has no Movement or Directed step, and no Tempo.
    func steps(owner: Bool, target: PickerTarget, ugc: Bool = false, photo: Bool = false) -> [PickerStep] {
        switch self {
        case .camera:
            var s = [PickerStep(id: "setup", title: "Setup", icon: "slider.horizontal.3"), PickerStep(id: "angle", title: "Angle", icon: "eye")]
            if target == .composer && !photo { s.append(PickerStep(id: "movement", title: "Movement", icon: "arrow.up.and.down.and.arrow.left.and.right")) }
            if owner && target == .composer && !photo { s.append(PickerStep(id: "directed", title: "Directed", icon: "cube", owner: true)) }
            return s
        case .style:
            // UGC ad: the format wheel comes first, above genre, era and tempo.
            let format = ugc ? [PickerStep(id: "format", title: "Format", icon: "shippingbox")] : []
            let tempo = photo ? [] : [PickerStep(id: "tempo", title: "Tempo", icon: "metronome")]
            return format + [PickerStep(id: "genre", title: "Genre", icon: "theatermasks"), PickerStep(id: "era", title: "Era", icon: "clock")] + tempo
        case .look: return [PickerStep(id: "look", title: "Look", icon: "camera.filters")]
        case .lighting: return [PickerStep(id: "lighting", title: "Lighting", icon: "lightbulb")]
        }
    }
}

struct PickerStep: Identifiable, Hashable {
    var id: String
    var title: String
    var icon: String
    var owner = false
}

/// The dark theme every picker uses.
enum PickerTheme {
    static let dark = Theme.get(.b)
}

/// The open picker over the page (dim + modal), or nothing.
struct ComposerPickerHost: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let p = store.suite.picker {
            ZStack {
                Color(hex: 0x100E0C, alpha: 0.52)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { store.closePicker() }
                    .accessibilityHidden(true)
                PickerShell(picker: p)
                    .frame(width: 840, height: 540)
            }
            .transition(.opacity)
            .environment(\.theme, PickerTheme.dark)
            .environment(\.colorScheme, .dark)
        }
    }
}

struct PickerShell: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var picker: ComposerPicker
    @State private var moveQuery = ""

    private var steps: [PickerStep] {
        picker.steps(owner: store.isOwner, target: store.suite.pickerTarget, ugc: store.suite.pickerTarget == .composer && store.suite.composer.tool == .ugc,
                     photo: store.suite.pickerTarget == .composer && store.suite.composer.tool == .photo)
    }
    private var step: String { steps.contains { $0.id == store.suite.pickerStep } ? store.suite.pickerStep : (steps.first?.id ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(t.line).frame(height: 1)
            HStack(spacing: 0) {
                if steps.count > 1 {
                    rail
                    Rectangle().fill(t.line).frame(width: 1)
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(t.ink)
        .background(t.bg)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(t.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 60, y: 40)
        .onExitCommand { store.closePicker() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(picker.title) picker")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(picker.title).font(t.scale.title.font).foregroundStyle(Roles.bag.ink)
            if !(picker == .camera && step == "movement") {
                Text(picker.subtitle).font(t.body(13)).foregroundStyle(t.muted)
            }
            Spacer(minLength: 8)
            if picker == .camera && step == "movement" {
                HStack(spacing: 8) {
                    Ph("magnifyingglass", 12)
                    TextField("Search \(store.suite.camera.moves.count) moves", text: $moveQuery).textFieldStyle(.plain).font(t.body(13))
                }
                .foregroundStyle(t.muted)
                .padding(.horizontal, 12).frame(width: 210, height: 34)
                .background(Capsule().fill(t.surface2))
            }
            Button { reset() } label: {
                Text("Reset all").font(t.scale.label.font).foregroundStyle(Roles.bag.ink2)
                    .padding(.horizontal, 8).frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reset")
            Button { store.closePicker() } label: {
                Ph("xmark", 18).foregroundStyle(Roles.bag.ink).frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.leading, 24).padding(.trailing, 14)
        .frame(height: 62)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps) { s in
                let on = s.id == step
                Button { store.suite.pickerStep = s.id } label: {
                    HStack(spacing: 11) {
                        Ph(s.icon, 15).frame(width: 18)
                        Text(s.title).font(t.body(15, .semibold))
                        Spacer(minLength: 4)
                        if s.owner {
                            Text("Owner").font(t.scale.micro.font).foregroundStyle(t.muted)
                        } else if hasValue(s.id) {
                            Circle().fill(t.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(on ? t.ink : t.muted)
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? t.surface2 : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(s.title)\(s.owner ? ", owner" : hasValue(s.id) ? ", set" : "")\(on ? ", selected" : "")")
            }
            Spacer(minLength: 0)
            if picker == .camera {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your camera").font(t.scale.label.font).foregroundStyle(t.muted)
                    Text(cameraLine).font(t.body(12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6).padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 14)
        .frame(width: 176)
    }

    private var cameraLine: String {
        if store.suite.pickerTarget == .composer, store.suite.composer.directed != nil { return "Directed camera" }
        let v = ComposerCatalog.summary(.camera, store.suite.pickerSettings, store.suite.camera).values
        let moves = store.suite.pickerTarget == .composer ? store.suite.composer.tokens.moves.compactMap { p -> String? in
            if case .move(_, let label, _, _, _) = p { return label }
            return nil
        } : []
        let all = v + moves
        return all.isEmpty ? "Auto · the camera follows the scene" : all.joined(separator: " · ")
    }

    private func hasValue(_ id: String) -> Bool {
        let s = store.suite.pickerSettings
        switch id {
        case "setup": return s.body != nil || s.lens != nil || s.focalMm != nil || s.aperture != nil
        case "angle": return s.height != nil || s.shotSize != nil
        case "movement": return !store.suite.composer.tokens.moves.isEmpty
        case "directed": return store.suite.composer.directed != nil
        case "format": return s.format != nil
        case "genre": return s.genre != nil
        case "era": return s.era != nil
        case "tempo": return s.tempo != nil
        default: return s.isSet(picker.chip)
        }
    }

    @ViewBuilder private var content: some View {
        switch picker {
        case .camera:
            switch step {
            case "angle": CameraAngleStep()
            case "movement": CameraMovementStep(query: $moveQuery)
            case "directed":
                DirectedModePanel(shotTitle: store.suite.composer.title) { store.applyDirected($0) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default: CameraSetupStep()
            }
        case .style: StyleStep(step: step)
        case .look: LookStep()
        case .lighting: LightingStep()
        }
    }

    private func reset() {
        store.suite.pickerSettings = store.suite.pickerSettings.reset(picker.chip)
        if picker == .camera && store.suite.pickerTarget == .composer {
            var tk = store.suite.composer.tokens
            for k in tk.moves.compactMap(\.key) { tk = tk.remove(key: k) }
            store.suite.composer.tokens = tk
            store.suite.composer.directed = nil
        }
    }
}

/// A picker grid's tile: the preview (still, or a muted loop on hover), the name and a line; outlined when picked (the
/// outline alone: a check badge on top of it was a second mark for the same thing).
/// The first tile of every grid is Auto.
struct PickerOptionTile: View {
    @Environment(\.theme) private var t
    var name: String
    var line: String
    var preview: PickerPreview?
    var auto = false
    var swatches: [String] = []
    var selected: Bool
    var height: CGFloat = 96
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if auto, let p = preview, p.hasRender {
                            // The Auto tile's own still (Lighting).
                            PreviewView(preview: p, fallback: name)
                        } else if auto {
                            LinearGradient(colors: [Color(hex: 0x1B1D20), Color(hex: 0x141518)], startPoint: .top, endPoint: .bottom)
                                .overlay(Ph("aperture", 22).foregroundStyle(t.muted)) // Auto: the aperture mark, as on the drums
                        } else if let p = preview, p.still != nil || p.hasRender {
                            PreviewView(preview: p, fallback: name)
                        } else {
                            // Style cards: big type until their stills exist.
                            LinearGradient(colors: [Color(hex: 0x23262A), Color(hex: 0x141518)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .overlay(alignment: .bottomLeading) {
                                    Text(name).font(Fonts.font("Instrument Serif", 26, .regular)).foregroundStyle(t.ink).lineLimit(1).minimumScaleFactor(0.6).padding(10)
                                }
                        }
                    }
                    .frame(height: height)
                    .clipped()
                    if !swatches.isEmpty || auto {
                        SwatchStrip(colors: auto ? Self.autoStrip : swatches).frame(height: 10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? t.accent : .clear, lineWidth: 2).padding(-4))
                Text(name).font(t.body(14, .semibold)).lineLimit(1).padding(.top, 9)
                Text(line).font(t.body(12)).foregroundStyle(t.muted).lineLimit(2).padding(.top, 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name)\(selected ? ", selected" : "")")
    }

    static let autoStrip = ["#1E2023", "#26292C", "#2F3236", "#383C40", "#42464A", "#4D5155", "#585C60", "#64686C", "#707478", "#7D8185"]
}

/// Was the amber check on a picked tile. One selection mark per control (the outline), so it draws nothing now;
/// the call site goes in the next restyle pass.
struct PickCheck: View {
    var body: some View { EmptyView() }
}

/// A palette's colour strip, darkest first.
struct SwatchStrip: View {
    var colors: [String]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                Rectangle().fill(Color(hexString: c) ?? .gray)
            }
        }
    }
}

extension Color {
    /// "#RRGGBB" → a colour.
    init?(hexString: String) {
        let s = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}
