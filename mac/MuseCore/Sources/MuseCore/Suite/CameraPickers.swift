import Foundation

// AI suite (workstream 1): the camera as picker groups, independent of any screen. Each group is a chip that reads "Auto"
// until something is picked; its picker lists the catalog's options with name, caption and hardware render.

/// One option as any picker shows it: name, caption and its hardware render (a file in the app's `hardware/` folder).
public struct CameraPickerItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var caption: String
    public var render: String?
    public var description: String
    /// Library moves: ugc | cinematic | energy | subtle.
    public var tag: String?

    public init(id: String, name: String, caption: String = "", render: String? = nil, description: String = "", tag: String? = nil) {
        self.id = id
        self.name = name
        self.caption = caption
        self.render = render
        self.description = description
        self.tag = tag
    }
}

/// The groups of the camera.
public enum CameraGroup: String, CaseIterable, Sendable, Identifiable {
    case body, lens, look, lighting, palette, aperture, frameRate, shutter, move, height, framing, era, genre, tempo
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .body: return "Camera"
        case .lens: return "Lens"
        case .look: return "Film & sensor"
        case .lighting: return "Lighting"
        case .palette: return "Colour"
        case .aperture: return "Aperture"
        case .frameRate: return "Frame rate"
        case .shutter: return "Shutter"
        case .move: return "Move"
        case .height: return "Height"
        case .framing: return "Framing"
        case .era: return "Era"
        case .genre: return "Genre"
        case .tempo: return "Tempo"
        }
    }
}

extension CameraCatalog {
    private static func items(_ list: [SuiteOption]) -> [CameraPickerItem] {
        list.map { CameraPickerItem(id: $0.id, name: $0.title, caption: $0.caption ?? $0.description, render: $0.render, description: $0.description) }
    }

    /// A group's options, picker-ready. Moves are the 16-move library (UGC first), each with its grip render when there is one.
    public func items(_ g: CameraGroup) -> [CameraPickerItem] {
        switch g {
        case .body: return Self.items(bodies)
        case .lens: return Self.items(lenses)
        case .look: return Self.items(looks)
        case .lighting: return Self.items(lighting)
        case .palette: return Self.items(palettes)
        case .aperture:
            let r = optic("aperture")?.render
            return Self.items(apertures).map { var i = $0; i.render = r; return i }
        case .frameRate: return Self.items(frameRates)
        case .shutter:
            let r = optic("shutter")?.render
            return Self.items(shutters).map { var i = $0; i.render = r; return i }
        case .height: return Self.items(heights)
        case .framing: return Self.items(shotSizes)
        case .era: return Self.items(eras)
        case .genre: return Self.items(genres)
        case .tempo: return Self.items(tempos)
        case .move:
            return SuiteMoves.library(self, tag: nil).map {
                CameraPickerItem(id: $0.id, name: $0.label, caption: $0.description, render: grip(for: $0.id)?.render, description: $0.description, tag: $0.tag)
            }
        }
    }

    /// The groups that have something to pick on this server.
    public var groups: [CameraGroup] { CameraGroup.allCases.filter { !items($0).isEmpty } }
}

extension CameraSpec {
    /// The picked id in a group, or nil for Auto.
    public func selected(_ g: CameraGroup) -> String? {
        switch g {
        case .body: return rig?.body
        case .lens: return rig?.lens
        case .look: return rig?.look
        case .lighting: return lighting?.preset
        case .palette: return palette?.preset
        case .aperture: return rig?.aperture
        case .frameRate: return rig?.fps
        case .shutter: return rig?.shutter
        case .move: return move?.id
        case .height: return angle?.height
        case .framing: return angle?.shotSize
        case .era: return style?.era
        case .genre: return style?.genre
        case .tempo: return style?.tempo
        }
    }

    private mutating func editRig(_ f: (inout CameraRig) -> Void) {
        var x = rig ?? CameraRig()
        f(&x)
        rig = x.isEmpty ? nil : x
        preset = nil
    }

    private mutating func editAngle(_ f: (inout CameraAngle) -> Void) {
        var x = angle ?? CameraAngle()
        f(&x)
        angle = x == CameraAngle() ? nil : x
    }

    private mutating func editStyle(_ f: (inout CameraStyle) -> Void) {
        var x = style ?? CameraStyle()
        f(&x)
        style = x == CameraStyle() ? nil : x
    }

    /// Picks `id` in a group (nil = back to Auto). A rig, light or palette change makes it a custom camera (no preset).
    public mutating func set(_ g: CameraGroup, _ id: String?) {
        switch g {
        case .body: editRig { $0.body = id }
        case .lens: editRig { $0.lens = id }
        case .look: editRig { $0.look = id }
        case .aperture: editRig { $0.aperture = id }
        case .frameRate: editRig { $0.fps = id }
        case .shutter: editRig { $0.shutter = id }
        case .lighting:
            var x = lighting ?? CameraLighting()
            x.preset = id
            lighting = x == CameraLighting() ? nil : x
            preset = nil
        case .palette:
            palette = id.map { CameraPalette(preset: $0) }
            preset = nil
        case .move:
            let keep = move?.id == id ? move?.intensity : nil
            move = id.map { SuiteMove(id: $0, intensity: keep ?? 0.5, speed: move?.speed ?? "normal") }
            if id == nil || mix?.id == id { mix = nil }
        case .height: editAngle { $0.height = id }
        case .framing: editAngle { $0.shotSize = id }
        case .era: editStyle { $0.era = id }
        case .genre: editStyle { $0.genre = id }
        case .tempo: editStyle { $0.tempo = id }
        }
    }

    /// What a chip says: "Auto", or the picked option's name (moves: "Dolly in + Rack focus").
    public func chipLabel(_ g: CameraGroup, _ c: CameraCatalog) -> String {
        guard let id = selected(g) else { return "Auto" }
        let name = { (x: String) in c.items(g).first { $0.id == x }?.name ?? c.move(x)?.label ?? x }
        if g == .move, let m = mix { return "\(name(id)) + \(name(m.id))" }
        return name(id)
    }

    /// The picked option's render in a group, if any.
    public func render(_ g: CameraGroup, _ c: CameraCatalog) -> String? {
        selected(g).flatMap { id in c.items(g).first { $0.id == id }?.render }
    }
}
