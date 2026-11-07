import Foundation

// AI suite (workstream 1): wire types for /v1/suite (plans/api.md "AI suite"). Decoding is lenient like the rest of MuseCore:
// a missing key falls back to a default. Owner-only fields (engine, models, tried) are optional; members never get them and
// the app only shows them in the owner's Engines view.

// MARK: Catalog

/// One camera option ({id, label, description}). Options with a hardware render also carry `render` (a file in the app's
/// bundled `hardware/` folder, without extension), `name` and `caption` ("Alexa 35 look · Super 35 · 4.6K").
public struct SuiteOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var description: String
    public var render: String?
    public var name: String?
    public var caption: String?
    /// Composer: false = not offered to members (owners and Directed mode keep it).
    public var visible: Bool
    /// A merged duplicate: pickers show the survivor with this id instead.
    public var mergedInto: String?
    /// Palettes and film stocks: 5 swatch colours (darkest first) and the LUT the take is graded with.
    public var swatches: [String]
    public var lut: String?
    /// Lighting and angles: the composer tile's still (a file in the bundled `previews/` folder).
    public var preview: SuitePreview?
    /// Other words a picker's search finds it by ("single shot" → One take).
    public var aliases: [String]

    public init(id: String, label: String, description: String = "", render: String? = nil, name: String? = nil, caption: String? = nil,
                visible: Bool = true, mergedInto: String? = nil, swatches: [String] = [], lut: String? = nil, preview: SuitePreview? = nil, aliases: [String] = []) {
        self.preview = preview
        self.aliases = aliases
        self.id = id
        self.label = label
        self.description = description
        self.render = render
        self.name = name
        self.caption = caption
        self.visible = visible
        self.mergedInto = mergedInto
        self.swatches = swatches
        self.lut = lut
    }

    enum CodingKeys: String, CodingKey { case id, label, description, render, name, caption, visible, mergedInto, swatches, lut, preview, aliases }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.v(.label, id)
        description = c.v(.description, "")
        render = c.o(.render)
        name = c.o(.name)
        caption = c.o(.caption)
        visible = c.v(.visible, true)
        mergedInto = c.o(.mergedInto)
        swatches = c.v(.swatches, [])
        lut = c.o(.lut)
        preview = c.o(.preview)
        aliases = c.v(.aliases, [])
    }

    /// The hardware name when there is one ("Super 35 Digital"), else the label.
    public var title: String { name ?? label }

    /// A picker search: the label, the hardware name, the id's words or an alias contains `query`.
    public func matches(_ query: String) -> Bool {
        suiteSearchMatches(query, [label, name ?? "", id.replacingOccurrences(of: "_", with: " ")] + aliases)
    }
}

/// A camera move from the full list.
public struct SuiteMoveOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var description: String
    public var category: String
    public var editorBetter: Bool
    public var talkSafe: Bool
    /// The composer's Movement chip it sits under (see `CameraCatalog.moveGroups`).
    public var group: String
    /// The Movement tile's loop and poster (files in the bundled `previews/` folder); nil = the drawn arrow.
    public var preview: SuitePreview?
    /// Other words the Movement search finds it by ("reveal" → Rise to reveal).
    public var aliases: [String]

    public init(id: String, label: String, description: String = "", category: String, editorBetter: Bool = false, talkSafe: Bool = false, group: String = "",
                preview: SuitePreview? = nil, aliases: [String] = []) {
        self.preview = preview
        self.aliases = aliases
        self.id = id
        self.label = label
        self.description = description
        self.category = category
        self.editorBetter = editorBetter
        self.talkSafe = talkSafe
        self.group = group
    }

    enum CodingKeys: String, CodingKey { case id, label, description, category, editorBetter, talkSafe, group, preview, aliases }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.v(.label, id)
        description = c.v(.description, "")
        category = c.v(.category, "")
        editorBetter = c.v(.editorBetter, false)
        talkSafe = c.v(.talkSafe, false)
        group = c.v(.group, "")
        preview = c.o(.preview)
        aliases = c.v(.aliases, [])
    }

    /// The Movement search: the label, the id's words or an alias contains `query`.
    public func matches(_ query: String) -> Bool {
        suiteSearchMatches(query, [label, id.replacingOccurrences(of: "_", with: " ")] + aliases)
    }
}

/// A picker search (AI suite, workstream 1): empty matches everything; otherwise any of `words` contains the query
/// (case-insensitive, "_" and "-" read as spaces).
public func suiteSearchMatches(_ query: String, _ words: [String]) -> Bool {
    let norm = { (s: String) in s.lowercased().replacingOccurrences(of: "[_-]", with: " ", options: .regularExpression) }
    let q = norm(query).trimmingCharacters(in: .whitespaces)
    return q.isEmpty || words.contains { norm($0).contains(q) }
}

/// A composer preview: a poster still and, for moves, a short muted loop. Paths are relative to the bundled `previews/`
/// folder ("moves/dolly_in.mp4", "lighting/window.webp").
public struct SuitePreview: Codable, Hashable, Sendable {
    public var video: String?
    public var poster: String
    public var seconds: Double?
    public init(video: String? = nil, poster: String, seconds: Double? = nil) {
        self.video = video
        self.poster = poster
        self.seconds = seconds
    }
    enum CodingKeys: String, CodingKey { case video, poster, seconds }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        video = c.o(.video)
        poster = c.v(.poster, "")
        seconds = c.o(.seconds)
    }
}

/// `camera.autoPreviews`: the Auto tile's preview per picker.
public struct SuiteAutoPreviews: Codable, Hashable, Sendable {
    public var lighting: SuitePreview?
    public init(lighting: SuitePreview? = nil) { self.lighting = lighting }
}

/// The composer's focal wheel step (`visible` = one of the six shown to members).
public struct SuiteFocal: Codable, Hashable, Sendable {
    public var mm: Double
    public var label: String
    public var description: String
    public var visible: Bool
    public init(mm: Double, label: String = "", description: String = "", visible: Bool = true) {
        self.mm = mm
        self.label = label
        self.description = description
        self.visible = visible
    }
    enum CodingKeys: String, CodingKey { case mm, label, description, visible }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mm = try c.decode(Double.self, forKey: .mm)
        label = c.v(.label, "")
        description = c.v(.description, "")
        visible = c.v(.visible, true)
    }
}

/// A Movement chip (Featured, UGC, Push…).
public struct SuiteMoveGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// The take's Look: a palette or film stock and its LUT (`pack:<id>` or `palette:<id>`), applied in the Edit suite.
public struct SuiteLook: Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    public var lut: String
    public init(id: String, kind: String = "palette", label: String = "", lut: String = "") {
        self.id = id
        self.kind = kind
        self.label = label
        self.lut = lut
    }
}

/// One of the 16 featured moves (UGC first), with its tag: ugc | cinematic | energy | subtle.
public struct SuiteLibraryMove: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var tag: String
    public var description: String
    public var category: String

    public init(id: String, label: String, tag: String, description: String = "", category: String = "") {
        self.id = id
        self.label = label
        self.tag = tag
        self.description = description
        self.category = category
    }

    enum CodingKeys: String, CodingKey { case id, label, tag, description, category }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.v(.label, id)
        tag = c.v(.tag, "")
        description = c.v(.description, "")
        category = c.v(.category, "")
    }
}

/// A hardware render that isn't an option: optics (`id` aperture | shutter) or a grip (`move`: the move it belongs to).
public struct SuiteHardware: Codable, Hashable, Sendable {
    public var id: String?
    public var move: String?
    public var render: String
    public var name: String
    public var caption: String

    enum CodingKeys: String, CodingKey { case id, move, render, name, caption }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.o(.id)
        move = c.o(.move)
        render = c.v(.render, "")
        name = c.v(.name, "")
        caption = c.v(.caption, "")
    }
}

/// A preset ("Phone UGC", "Cinematic") and the camera it stands for.
public struct SuitePreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var description: String
    public var spec: CameraSpec

    enum CodingKeys: String, CodingKey { case id, label, description, spec }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.v(.label, id)
        description = c.v(.description, "")
        spec = c.v(.spec, CameraSpec())
    }
}

public struct CameraLimits: Codable, Hashable, Sendable {
    public var intensity: [Double]
    public var dutchDeg: [Double]
    public var focalMm: [Double]
    public var paletteColors: Int
    public var mixPairs: String

    public init() {
        intensity = [0, 1]
        dutchDeg = [0, 30]
        focalMm = [8, 200]
        paletteColors = 5
        mixPairs = ""
    }

    enum CodingKeys: String, CodingKey { case intensity, dutchDeg, focalMm, paletteColors, mixPairs }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        intensity = c.v(.intensity, [0, 1])
        dutchDeg = c.v(.dutchDeg, [0, 30])
        focalMm = c.v(.focalMm, [8, 200])
        paletteColors = c.v(.paletteColors, 5)
        mixPairs = c.v(.mixPairs, "")
    }
}

/// GET /v1/suite/camera (also `catalog.camera`): every option the camera bag draws. The apps never hard-code these lists.
public struct CameraCatalog: Codable, Hashable, Sendable {
    public var presets: [SuitePreset]
    public var bodies: [SuiteOption]
    public var lenses: [SuiteOption]
    public var focalLengths: [Double]
    public var focals: [SuiteFocal]
    public var apertures: [SuiteOption]
    public var looks: [SuiteOption]
    public var frameRates: [SuiteOption]
    public var shutters: [SuiteOption]
    public var lighting: [SuiteOption]
    public var palettes: [SuiteOption]
    public var optics: [SuiteHardware]
    public var grips: [SuiteHardware]
    public var moves: [SuiteMoveOption]
    public var library: [SuiteLibraryMove]
    public var moveGroups: [SuiteMoveGroup]
    /// The Auto tiles' previews (Lighting today).
    public var autoPreviews: SuiteAutoPreviews
    public var heights: [SuiteOption]
    public var shotSizes: [SuiteOption]
    public var genres: [SuiteOption]
    public var eras: [SuiteOption]
    public var tempos: [SuiteOption]
    /// UGC ad's formats (Unboxing, Review, Try-on…), the Style picker's format wheel. Empty on older servers.
    public var ugcFormats: [SuiteOption]
    public var emotions: [String]
    public var limits: CameraLimits

    public init() {
        presets = []; bodies = []; lenses = []; focalLengths = []; focals = []; moveGroups = []; autoPreviews = SuiteAutoPreviews(); apertures = []; looks = []; frameRates = []; shutters = []
        lighting = []; palettes = []; optics = []; grips = []; moves = []; library = []; heights = []; shotSizes = []
        genres = []; eras = []; tempos = []; ugcFormats = []; emotions = []; limits = CameraLimits()
    }

    enum CodingKeys: String, CodingKey {
        case presets, bodies, lenses, focalLengths, focals, moveGroups, autoPreviews, apertures, looks, frameRates, shutters, lighting, palettes, optics, grips, moves, library
        case heights, shotSizes, genres, eras, tempos, ugcFormats, emotions, limits
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        presets = c.v(.presets, [])
        bodies = c.v(.bodies, [])
        lenses = c.v(.lenses, [])
        focalLengths = c.v(.focalLengths, [])
        focals = c.v(.focals, [])
        moveGroups = c.v(.moveGroups, [])
        autoPreviews = c.v(.autoPreviews, SuiteAutoPreviews())
        apertures = c.v(.apertures, [])
        looks = c.v(.looks, [])
        frameRates = c.v(.frameRates, [])
        shutters = c.v(.shutters, [])
        lighting = c.v(.lighting, [])
        palettes = c.v(.palettes, [])
        optics = c.v(.optics, [])
        grips = c.v(.grips, [])
        moves = c.v(.moves, [])
        library = c.v(.library, [])
        heights = c.v(.heights, [])
        shotSizes = c.v(.shotSizes, [])
        genres = c.v(.genres, [])
        eras = c.v(.eras, [])
        tempos = c.v(.tempos, [])
        ugcFormats = c.v(.ugcFormats, [])
        emotions = c.v(.emotions, [])
        limits = c.v(.limits, CameraLimits())
    }

    public func move(_ id: String) -> SuiteMoveOption? { moves.first { $0.id == id } }
    public func libraryMove(_ id: String) -> SuiteLibraryMove? { library.first { $0.id == id } }
    public func grip(for move: String) -> SuiteHardware? { grips.first { $0.move == move } }
    public func optic(_ id: String) -> SuiteHardware? { optics.first { $0.id == id } }
}

/// Owner only: a model on a tier's ladder.
public struct SuiteTierModel: Codable, Hashable, Sendable {
    public var model: String
    public var name: String
    public var resolution: String
    /// The input slots this engine takes (SuiteInputSlots.swift).
    public var inputs: SuiteInputs?
}

/// A quality tier: Draft / Standard / HD / Cinema. `models` is the owner's (what the tier runs today).
public struct SuiteTier: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String
    public var available: Bool
    public var resolution: String?
    public var fromPerSec: Double?
    /// The Length slider's range (seconds).
    public var minSeconds: Double?
    public var maxSeconds: Double?
    public var canKeyframes: Bool
    public var canReferences: Bool
    public var canGuide: Bool
    /// The input slots the tier takes; see `slots` (SuiteInputSlots.swift).
    public var inputs: SuiteInputs?
    public var models: [SuiteTierModel]?

    public init(id: String, label: String, detail: String, available: Bool = true, resolution: String? = nil, fromPerSec: Double? = nil, maxSeconds: Double? = nil,
                minSeconds: Double? = nil, canKeyframes: Bool = true, canReferences: Bool = true, canGuide: Bool = true, inputs: SuiteInputs? = nil, models: [SuiteTierModel]? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.available = available
        self.resolution = resolution
        self.fromPerSec = fromPerSec
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.canKeyframes = canKeyframes
        self.canReferences = canReferences
        self.canGuide = canGuide
        self.inputs = inputs
        self.models = models
    }

    enum CodingKeys: String, CodingKey { case id, label, detail, available, resolution, fromPerSec, minSeconds, maxSeconds, canKeyframes, canReferences, canGuide, inputs, models }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.v(.label, id)
        detail = c.v(.detail, "")
        available = c.v(.available, false)
        resolution = c.o(.resolution)
        fromPerSec = c.o(.fromPerSec)
        minSeconds = c.o(.minSeconds)
        maxSeconds = c.o(.maxSeconds)
        canKeyframes = c.v(.canKeyframes, false)
        canReferences = c.v(.canReferences, false)
        canGuide = c.v(.canGuide, false)
        inputs = c.o(.inputs)
        models = c.o(.models)
    }
}

/// GET /v1/suite/catalog. `enabled` false: the server runs with SUITE_MODE=off; `test` true: mock renders (free).
public struct SuiteCatalog: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var test: Bool
    public var defaultQuality: String
    public var tiers: [SuiteTier]
    public var modes: [String]
    public var recastMaxPeople: Int
    public var aspectRatios: [String]
    public var takesMax: Int
    public var camera: CameraCatalog
    /// Which composer tools are live (shot, swap, recast, storyboard, talking, ugc_ad, extend). Empty on older servers:
    /// the app's own "Coming soon" list then applies.
    public var tools: [SuiteToolStatus]

    public init(enabled: Bool, test: Bool, defaultQuality: String = "draft", tiers: [SuiteTier], modes: [String] = SuiteCatalog.allModes, recastMaxPeople: Int = 4,
                aspectRatios: [String] = ["9:16", "16:9", "1:1", "4:3", "3:4", "21:9"], takesMax: Int = 4, camera: CameraCatalog, tools: [SuiteToolStatus] = []) {
        self.tools = tools
        self.enabled = enabled
        self.test = test
        self.defaultQuality = defaultQuality
        self.tiers = tiers
        self.modes = modes
        self.recastMaxPeople = recastMaxPeople
        self.aspectRatios = aspectRatios
        self.takesMax = takesMax
        self.camera = camera
    }

    public static let allModes = ["text", "image", "reference", "swap", "recast"]

    enum CodingKeys: String, CodingKey { case enabled, test, defaultQuality, tiers, modes, recastMaxPeople, aspectRatios, takesMax, camera, tools }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        tools = c.v(.tools, [])
        enabled = c.v(.enabled, false)
        test = c.v(.test, false)
        defaultQuality = c.v(.defaultQuality, "draft")
        tiers = c.v(.tiers, [])
        modes = c.v(.modes, [])
        recastMaxPeople = c.v(.recastMaxPeople, 4)
        aspectRatios = c.v(.aspectRatios, ["9:16"])
        takesMax = c.v(.takesMax, 4)
        camera = c.v(.camera, CameraCatalog())
    }

    public func tier(_ id: String) -> SuiteTier? { tiers.first { $0.id == id } }
}

/// `catalog.tools[]`: one composer tool and whether the apps can offer it now.
public struct SuiteToolStatus: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var available: Bool
    public var comingSoon: Bool

    public init(id: String, available: Bool, comingSoon: Bool = false) {
        self.id = id
        self.available = available
        self.comingSoon = comingSoon
    }

    enum CodingKeys: String, CodingKey { case id, available, comingSoon }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        available = c.v(.available, false)
        comingSoon = c.v(.comingSoon, false)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(available, forKey: .available)
        if comingSoon { try c.encode(comingSoon, forKey: .comingSoon) }
    }
}

// MARK: Camera spec (what a shot sends)

public struct CameraRig: Codable, Hashable, Sendable {
    public var body: String?
    public var lens: String?
    public var focalMm: Double?
    public var aperture: String?
    public var look: String?
    public var fps: String?
    public var shutter: String?
    public init(body: String? = nil, lens: String? = nil, focalMm: Double? = nil, aperture: String? = nil, look: String? = nil, fps: String? = nil, shutter: String? = nil) {
        self.body = body
        self.lens = lens
        self.focalMm = focalMm
        self.aperture = aperture
        self.look = look
        self.fps = fps
        self.shutter = shutter
    }
    public var isEmpty: Bool { self == CameraRig() }
}

public struct CameraLighting: Codable, Hashable, Sendable {
    public var preset: String?
    public var direction: String?
    public var temperatureK: Double?
    public var intensity: String?
    public init(preset: String? = nil, direction: String? = nil, temperatureK: Double? = nil, intensity: String? = nil) {
        self.preset = preset
        self.direction = direction
        self.temperatureK = temperatureK
        self.intensity = intensity
    }
}

public struct CameraPalette: Codable, Hashable, Sendable {
    public var preset: String?
    public var colors: [String]?
    public init(preset: String? = nil, colors: [String]? = nil) {
        self.preset = preset
        self.colors = colors
    }
}

/// A camera move: intensity 0–1 (the UI shows 0–100 %), speed slow | normal | fast.
public struct SuiteMove: Codable, Hashable, Sendable {
    public var id: String
    public var intensity: Double?
    public var speed: String?
    public var ease: String?
    public var startS: Double?
    public var endS: Double?
    public init(id: String, intensity: Double? = nil, speed: String? = nil, ease: String? = nil, startS: Double? = nil, endS: Double? = nil) {
        self.id = id
        self.intensity = intensity
        self.speed = speed
        self.ease = ease
        self.startS = startS
        self.endS = endS
    }
}

public struct CameraAngle: Codable, Hashable, Sendable {
    public var height: String?
    public var shotSize: String?
    public var dutchDeg: Double?
    public init(height: String? = nil, shotSize: String? = nil, dutchDeg: Double? = nil) {
        self.height = height
        self.shotSize = shotSize
        self.dutchDeg = dutchDeg
    }
}

public struct CameraStyle: Codable, Hashable, Sendable {
    public var genre: String?
    public var era: String?
    public var tempo: String?
    /// UGC ad only: the format (`catalog.camera.ugcFormats` id: unboxing, review, try_on…).
    public var format: String?
    public init(genre: String? = nil, era: String? = nil, tempo: String? = nil, format: String? = nil) {
        self.genre = genre
        self.era = era
        self.tempo = tempo
        self.format = format
    }
}

/// CameraSpec: what the camera bag (Preset) or Directed mode hands to a shot. Unset parts are left out of the JSON.
public struct CameraSpec: Codable, Hashable, Sendable {
    public var mode: String?
    public var preset: String?
    public var rig: CameraRig?
    public var lighting: CameraLighting?
    public var palette: CameraPalette?
    public var move: SuiteMove?
    public var mix: SuiteMove?
    public var angle: CameraAngle?
    public var style: CameraStyle?
    /// Directed mode (workstream 2) fills these; the suite passes them through untouched.
    public var performance: JSONValue?
    public var guide: JSONValue?

    public init(mode: String? = nil, preset: String? = nil, rig: CameraRig? = nil, lighting: CameraLighting? = nil, palette: CameraPalette? = nil, move: SuiteMove? = nil,
                mix: SuiteMove? = nil, angle: CameraAngle? = nil, style: CameraStyle? = nil, performance: JSONValue? = nil, guide: JSONValue? = nil) {
        self.mode = mode
        self.preset = preset
        self.rig = rig
        self.lighting = lighting
        self.palette = palette
        self.move = move
        self.mix = mix
        self.angle = angle
        self.style = style
        self.performance = performance
        self.guide = guide
    }

    enum CodingKeys: String, CodingKey { case mode, preset, rig, lighting, palette, move, mix, angle, style, performance, guide }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = c.o(.mode)
        preset = c.o(.preset)
        rig = c.o(.rig)
        lighting = c.o(.lighting)
        palette = c.o(.palette)
        move = c.o(.move)
        mix = c.o(.mix)
        angle = c.o(.angle)
        style = c.o(.style)
        performance = c.o(.performance)
        guide = c.o(.guide)
    }

    /// A Directed mode panel's `onApply` JSON (a CameraSpec), or nil when it isn't one.
    public static func fromJSON(_ json: String) -> CameraSpec? {
        guard let d = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CameraSpec.self, from: d)
    }

    public var json: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: Shot request

public struct SuiteVideoRef: Codable, Hashable, Sendable {
    public var key: String?
    public var url: String?
    public var seconds: Double?
    public init(key: String? = nil, url: String? = nil, seconds: Double? = nil) {
        self.key = key
        self.url = url
        self.seconds = seconds
    }
}

/// `extend` on a shot request: `{video: {key} | {url}, direction: "after" | "before", join?}`. `join` nil = the server's
/// default (source + extension as one clip).
public struct SuiteExtend: Codable, Hashable, Sendable {
    public var video: SuiteVideoRef
    public var direction: String
    public var join: Bool?
    public init(video: SuiteVideoRef, direction: String = "after", join: Bool? = nil) {
        self.video = video
        self.direction = direction
        self.join = join
    }
}

public struct SuiteFrames: Codable, Hashable, Sendable {
    public var start: ImageRef?
    public var middle: [ImageRef]?
    public var end: ImageRef?
    public init(start: ImageRef? = nil, middle: [ImageRef]? = nil, end: ImageRef? = nil) {
        self.start = start
        self.middle = middle
        self.end = end
    }
}

/// An extra reference image: role product | location | style | prop | person.
public struct SuiteRefImage: Codable, Hashable, Sendable {
    public var image: ImageRef
    public var role: String
    public var label: String?
    public init(image: ImageRef, role: String, label: String? = nil) {
        self.image = image
        self.role = role
        self.label = label
    }
}

public struct SuiteRefVideo: Codable, Hashable, Sendable {
    public var video: SuiteVideoRef
    public var use: String
    public init(video: SuiteVideoRef, use: String = "motion") {
        self.video = video
        self.use = use
    }
}

public struct SuiteReferences: Codable, Hashable, Sendable {
    public var images: [SuiteRefImage]?
    public var videos: [SuiteRefVideo]?
    /// One audio track (an upload in this studio).
    public var audio: SuiteRefAudio?
    public init(images: [SuiteRefImage]? = nil, videos: [SuiteRefVideo]? = nil, audio: SuiteRefAudio? = nil) {
        self.images = images
        self.videos = videos
        self.audio = audio
    }
}

public struct SuiteRefAudio: Codable, Hashable, Sendable {
    public var audio: SuiteVideoRef
    public init(audio: SuiteVideoRef) { self.audio = audio }
}

/// Recast: one person in the source clip → a studio character.
public struct CastMember: Codable, Hashable, Sendable {
    public var characterId: String
    public var outfitId: String?
    public var personIndex: Int?
    public var personHint: String?
    public var personNote: String?
    /// The face tapped on the clip's first frame (an uploaded square crop): who to replace.
    public var faceCrop: ImageRef?
    public var speaking: Bool?
    public init(characterId: String, outfitId: String? = nil, personIndex: Int? = nil, personHint: String? = nil, personNote: String? = nil, faceCrop: ImageRef? = nil,
                speaking: Bool? = nil) {
        self.faceCrop = faceCrop
        self.characterId = characterId
        self.outfitId = outfitId
        self.personIndex = personIndex
        self.personHint = personHint
        self.personNote = personNote
        self.speaking = speaking
    }
}

/// POST /v1/suite/shots[/estimate]. Unset fields are left out (the server applies its defaults).
public struct ShotRequest: Codable, Hashable, Sendable {
    public var mode: String?
    public var cast: [CastMember]?
    public var title: String?
    public var modelId: String?
    public var outfitId: String?
    public var prompt: String
    public var direction: String?
    public var frames: SuiteFrames?
    public var references: SuiteReferences?
    public var duration: Int
    public var aspectRatio: String
    public var quality: String
    public var takes: Int
    public var audio: Bool
    public var speaking: Bool?
    public var seed: Int?
    public var camera: CameraSpec?
    public var dryRun: Bool?
    public var clipId: String?
    public var keepAudio: Bool?
    /// "Grade the take with this look" (nil = the server's default, on).
    public var gradeLook: Bool?
    /// Owner only (bypass the ladder). Members never send these.
    public var engineModel: String?
    public var resolution: String?
    /// Extend (`mode: "extend"`): the finished clip to continue and which way (suite/extend.ts).
    public var extend: SuiteExtend?
    /// The composer's full draft, stored with the job and its takes for "Reuse settings" (left out when nil; estimates ignore it).
    public var draft: SuiteDraft?

    public init(mode: String? = nil, cast: [CastMember]? = nil, title: String? = nil, modelId: String? = nil, outfitId: String? = nil, prompt: String = "",
                direction: String? = nil, frames: SuiteFrames? = nil, references: SuiteReferences? = nil, duration: Int = 5, aspectRatio: String = "9:16",
                quality: String = "draft", takes: Int = 1, audio: Bool = true, speaking: Bool? = nil, seed: Int? = nil, camera: CameraSpec? = nil,
                dryRun: Bool? = nil, clipId: String? = nil, keepAudio: Bool? = nil, engineModel: String? = nil, resolution: String? = nil) {
        self.mode = mode
        self.cast = cast
        self.title = title
        self.modelId = modelId
        self.outfitId = outfitId
        self.prompt = prompt
        self.direction = direction
        self.frames = frames
        self.references = references
        self.duration = duration
        self.aspectRatio = aspectRatio
        self.quality = quality
        self.takes = takes
        self.audio = audio
        self.speaking = speaking
        self.seed = seed
        self.camera = camera
        self.dryRun = dryRun
        self.clipId = clipId
        self.keepAudio = keepAudio
        self.engineModel = engineModel
        self.resolution = resolution
    }

    /// Extend: a longer take from a finished one (the new part is `duration` long; `prompt` is what happens next or before).
    public static func extendShot(_ video: SuiteVideoRef, direction: String = "after", duration: Int, quality: String, takes: Int = 1, prompt: String = "",
                              title: String? = nil) -> ShotRequest {
        var r = ShotRequest(mode: "extend", title: title, prompt: prompt, duration: duration, quality: quality, takes: takes)
        r.extend = SuiteExtend(video: video, direction: direction)
        return r
    }

    /// Recast ("same take, new cast"): 1–4 people of the clip → studio characters.
    public static func recast(clipId: String, cast: [CastMember], quality: String, keepAudio: Bool = true, takes: Int = 1, title: String? = nil, prompt: String = "") -> ShotRequest {
        ShotRequest(mode: "recast", cast: cast, title: title, prompt: prompt, quality: quality, takes: takes, clipId: clipId, keepAudio: keepAudio)
    }
}

// MARK: Estimate

public struct SuiteCaps: Codable, Hashable, Sendable {
    public var perJob: Double
    public var perDay: Double
    public var spentToday: Double
    public var leftToday: Double
    public var ok: Bool
    public var code: String?
    public var message: String?

    public init(perJob: Double, perDay: Double, spentToday: Double, leftToday: Double, ok: Bool = true, code: String? = nil, message: String? = nil) {
        self.perJob = perJob
        self.perDay = perDay
        self.spentToday = spentToday
        self.leftToday = leftToday
        self.ok = ok
        self.code = code
        self.message = message
    }

    enum CodingKeys: String, CodingKey { case perJob, perDay, spentToday, leftToday, ok, code, message }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        perJob = c.v(.perJob, 0)
        perDay = c.v(.perDay, 0)
        spentToday = c.v(.spentToday, 0)
        leftToday = c.v(.leftToday, 0)
        ok = c.v(.ok, true)
        code = c.o(.code)
        message = c.o(.message)
    }
}

public struct SuiteEstimateCamera: Codable, Hashable, Sendable {
    public var moves: [String]
    public var guideUsed: Bool
    public init(moves: [String] = [], guideUsed: Bool = false) {
        self.moves = moves
        self.guideUsed = guideUsed
    }
    enum CodingKeys: String, CodingKey { case moves, guideUsed }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        moves = c.v(.moves, [])
        guideUsed = c.v(.guideUsed, false)
    }
}

public struct SuiteSpeaking: Codable, Hashable, Sendable {
    public var speaking: Bool
    public var source: String
    public init(speaking: Bool, source: String) {
        self.speaking = speaking
        self.source = source
    }
}

/// Recast: who becomes whom ("the person on the left").
public struct SuiteCastLine: Codable, Hashable, Sendable {
    public var characterId: String
    public var outfitId: String?
    public var who: String
    public var speaking: String
    public init(characterId: String, outfitId: String? = nil, who: String, speaking: String = "unknown") {
        self.characterId = characterId
        self.outfitId = outfitId
        self.who = who
        self.speaking = speaking
    }
}

public struct SuiteLicence: Codable, Hashable, Sendable {
    public var kind: String
    public var name: String
    public var notice: String?
}

/// Owner only: the model a shot runs on, and its price.
public struct SuiteEngine: Codable, Hashable, Sendable {
    public var model: String
    public var name: String
    public var provider: String
    public var ref: String?
    public var resolution: String
    public var perSec: Double
    public var billedPerTake: Double?
    public var test: Bool?
    public var licence: SuiteLicence?
    public var notice: String?

    public init(model: String, name: String, provider: String, ref: String? = nil, resolution: String, perSec: Double, billedPerTake: Double? = nil, test: Bool? = nil) {
        self.model = model
        self.name = name
        self.provider = provider
        self.ref = ref
        self.resolution = resolution
        self.perSec = perSec
        self.billedPerTake = billedPerTake
        self.test = test
    }

    enum CodingKeys: String, CodingKey { case model, name, provider, ref, resolution, perSec, billedPerTake, test, licence, notice }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        model = c.v(.model, "")
        name = c.v(.name, "")
        provider = c.v(.provider, "")
        ref = c.o(.ref)
        resolution = c.v(.resolution, "")
        perSec = c.v(.perSec, 0)
        billedPerTake = c.o(.billedPerTake)
        test = c.o(.test)
        licence = c.o(.licence)
        notice = c.o(.notice)
    }
}

/// Owner only: a ladder step that was tried, and why it couldn't make the shot.
public struct SuiteTried: Codable, Hashable, Sendable {
    public var model: String
    public var resolution: String
    public var why: String?
}

/// POST /v1/suite/shots/estimate. Every Generate shows `buttonLabel` / `priceLine`; a cap problem shows `message`.
public struct ShotEstimate: Codable, Hashable, Sendable {
    public var quality: String
    public var label: String
    public var resolution: String
    public var seconds: Double
    public var takes: Int
    public var mode: String
    public var estimate: Double
    public var priceLine: String
    public var buttonLabel: String
    public var ok: Bool
    public var code: String?
    public var message: String?
    public var caps: SuiteCaps?
    public var warnings: [String]
    public var camera: SuiteEstimateCamera
    public var prompt: String?
    public var test: Bool
    public var speaking: SuiteSpeaking?
    public var cast: [SuiteCastLine]?
    public var keepAudio: Bool?
    public var engine: SuiteEngine?
    public var tried: [SuiteTried]?
    /// The Look the take will be graded with (nil = none, or grading off).
    public var look: SuiteLook?
    /// The rig check (workstream 3): clashes between the choices, or with the prompt. Empty when nothing clashes; never changes `ok`.
    public var rig: [RigWarning]

    public init(quality: String, label: String, resolution: String, seconds: Double, takes: Int, mode: String, estimate: Double, priceLine: String, buttonLabel: String,
                ok: Bool = true, code: String? = nil, message: String? = nil, caps: SuiteCaps? = nil, warnings: [String] = [], camera: SuiteEstimateCamera = SuiteEstimateCamera(),
                prompt: String? = nil, test: Bool = false, speaking: SuiteSpeaking? = nil, cast: [SuiteCastLine]? = nil, keepAudio: Bool? = nil, engine: SuiteEngine? = nil,
                rig: [RigWarning] = []) {
        self.rig = rig
        self.quality = quality
        self.label = label
        self.resolution = resolution
        self.seconds = seconds
        self.takes = takes
        self.mode = mode
        self.estimate = estimate
        self.priceLine = priceLine
        self.buttonLabel = buttonLabel
        self.ok = ok
        self.code = code
        self.message = message
        self.caps = caps
        self.warnings = warnings
        self.camera = camera
        self.prompt = prompt
        self.test = test
        self.speaking = speaking
        self.cast = cast
        self.keepAudio = keepAudio
        self.engine = engine
    }

    enum CodingKeys: String, CodingKey {
        case quality, label, resolution, seconds, takes, mode, estimate, priceLine, buttonLabel, ok, code, message, caps, warnings, camera, prompt, test, speaking
        case cast, keepAudio, engine, tried, look, rig
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        quality = c.v(.quality, "draft")
        label = c.v(.label, "")
        resolution = c.v(.resolution, "")
        seconds = c.v(.seconds, 0)
        takes = c.v(.takes, 1)
        mode = c.v(.mode, "")
        estimate = c.v(.estimate, 0)
        priceLine = c.v(.priceLine, "")
        buttonLabel = c.v(.buttonLabel, "Generate")
        ok = c.v(.ok, true)
        code = c.o(.code)
        message = c.o(.message)
        caps = c.o(.caps)
        warnings = c.v(.warnings, [])
        camera = c.v(.camera, SuiteEstimateCamera())
        prompt = c.o(.prompt)
        test = c.v(.test, false)
        speaking = c.o(.speaking)
        cast = c.o(.cast)
        keepAudio = c.o(.keepAudio)
        engine = c.o(.engine)
        tried = c.o(.tried)
        look = c.o(.look)
        rig = c.v(.rig, RigWarnings()).list
    }

    /// The line to show when it can't be made as is (a cap), or nil.
    public var problem: String? { ok ? nil : (message ?? caps?.message ?? "This shot is over the studio's limits") }
}

// MARK: Rig check (workstream 3, plans/video-composer.md "Rig check")

/// A one-tap way out of a rig clash: a JSON Merge Patch (RFC 7386) over the ShotRequest. Objects merge, a value replaces,
/// null removes. Today every patch is under `camera`; `RigFixes` applies one to the composer's choices.
public struct RigFix: Codable, Hashable, Sendable {
    public var label: String
    public var patch: JSONValue

    public init(label: String, patch: JSONValue) {
        self.label = label
        self.patch = patch
    }

    enum CodingKeys: String, CodingKey { case label, patch }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        label = c.v(.label, "")
        patch = c.v(.patch, JSONValue.object([:]))
    }
}

/// One clash the rig check found: a reason line, the fix and, when there is a natural one, a second way out.
public struct RigWarning: Codable, Hashable, Sendable, Identifiable {
    /// The rule (deep_focus, wide_close, worm_close, look_clash, prompt_move, prompt_angle, prompt_size, no_reveal, talk_move); one warning per rule.
    public var id: String
    /// "warn": the shot won't come out as chosen. "tip": a taste clash worth a look.
    public var severity: String
    public var reason: String
    public var fix: RigFix
    public var alt: RigFix?

    public init(id: String, severity: String = "warn", reason: String, fix: RigFix, alt: RigFix? = nil) {
        self.id = id
        self.severity = severity
        self.reason = reason
        self.fix = fix
        self.alt = alt
    }

    /// Anything but "tip" reads as a warning.
    public var isTip: Bool { severity == "tip" }

    enum CodingKeys: String, CodingKey { case id, severity, reason, fix, alt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        severity = c.v(.severity, "warn")
        reason = c.v(.reason, "")
        fix = try c.decode(RigFix.self, forKey: .fix)
        alt = c.o(.alt)
    }
}

/// A list of warnings that skips an entry it can't read (a newer server's shape) instead of dropping the whole list.
struct RigWarnings: Codable, Hashable, Sendable {
    var list: [RigWarning] = []
    init(_ list: [RigWarning] = []) { self.list = list }
    private struct Maybe: Decodable {
        let value: RigWarning?
        init(from d: Decoder) throws { value = try? RigWarning(from: d) }
    }
    init(from d: Decoder) throws {
        var c = try d.unkeyedContainer()
        var out: [RigWarning] = []
        while !c.isAtEnd {
            guard let m = try? c.decode(Maybe.self) else { break }
            if let w = m.value { out.append(w) }
        }
        list = out
    }
    func encode(to e: Encoder) throws { try list.encode(to: e) }
}

/// POST /v1/suite/rig-check → `{rig}`: the rig check alone, for when the estimate fails.
public struct RigCheckResult: Codable, Hashable, Sendable {
    public var rig: [RigWarning]
    public init(rig: [RigWarning] = []) { self.rig = rig }
    enum CodingKeys: String, CodingKey { case rig }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        rig = c.v(.rig, RigWarnings()).list
    }
}

/// GET /v1/suite/shots/{id}: the job and its warnings; `engine` is the owner's.
public struct SuiteShot: Codable, Hashable, Sendable {
    public var job: Job
    public var warnings: [String]
    public var engine: SuiteEngine?

    public init(job: Job, warnings: [String] = [], engine: SuiteEngine? = nil) {
        self.job = job
        self.warnings = warnings
        self.engine = engine
    }

    enum CodingKeys: String, CodingKey { case job, warnings, engine }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        job = try c.decode(Job.self, forKey: .job)
        warnings = c.v(.warnings, [])
        engine = c.o(.engine)
    }
}

// MARK: Settings (owner)

public struct SuiteLadderStep: Codable, Hashable, Sendable {
    public var model: String
    public var resolution: String
    public init(model: String, resolution: String) {
        self.model = model
        self.resolution = resolution
    }
}

public struct SuiteResolution: Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var perSec: Double
    enum CodingKeys: String, CodingKey { case id, label, perSec }
    public init(id: String, label: String, perSec: Double) {
        self.id = id
        self.label = label
        self.perSec = perSec
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        label = c.v(.label, id)
        perSec = c.v(.perSec, 0)
    }
}

/// One model of the registry as the owner sees it.
public struct SuiteRegistryModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var provider: String
    public var status: String
    public var enabled: Bool
    public var blocked: Bool
    public var blockedReason: String?
    public var needsAck: Bool
    public var configured: Bool
    public var priceScale: Double
    public var resolutions: [SuiteResolution]
    public var licence: SuiteLicence?

    public init(id: String, name: String, provider: String, status: String = "active", enabled: Bool = true, blocked: Bool = false, blockedReason: String? = nil,
                needsAck: Bool = false, configured: Bool = true, priceScale: Double = 1, resolutions: [SuiteResolution] = [], licence: SuiteLicence? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.status = status
        self.enabled = enabled
        self.blocked = blocked
        self.blockedReason = blockedReason
        self.needsAck = needsAck
        self.configured = configured
        self.priceScale = priceScale
        self.resolutions = resolutions
        self.licence = licence
    }

    enum CodingKeys: String, CodingKey { case id, name, provider, status, enabled, blocked, blockedReason, needsAck, configured, priceScale, resolutions, licence }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.v(.name, id)
        provider = c.v(.provider, "")
        status = c.v(.status, "active")
        enabled = c.v(.enabled, true)
        blocked = c.v(.blocked, false)
        blockedReason = c.o(.blockedReason)
        needsAck = c.v(.needsAck, false)
        configured = c.v(.configured, false)
        priceScale = c.v(.priceScale, 1)
        resolutions = c.v(.resolutions, [])
        licence = c.o(.licence)
    }

    public func perSec(_ resolution: String) -> Double? { resolutions.first { $0.id == resolution }.map { $0.perSec * priceScale } }
}

public struct SuiteProviders: Codable, Hashable, Sendable {
    public var replicate: Bool
    public var fal: Bool
    public var runpod: Bool
    public init(replicate: Bool = false, fal: Bool = false, runpod: Bool = false) {
        self.replicate = replicate
        self.fal = fal
        self.runpod = runpod
    }
}

/// GET/PATCH /v1/suite/settings (owner only).
public struct SuiteSettings: Codable, Hashable, Sendable {
    public var mode: String
    public var caps: SuiteCapsSetting
    public var spentToday: Double
    public var ladder: [String: [SuiteLadderStep]]
    public var defaultLadder: [String: [SuiteLadderStep]]
    public var models: [SuiteRegistryModel]
    public var providers: SuiteProviders

    public init(mode: String, caps: SuiteCapsSetting, spentToday: Double = 0, ladder: [String: [SuiteLadderStep]], defaultLadder: [String: [SuiteLadderStep]],
                models: [SuiteRegistryModel], providers: SuiteProviders) {
        self.mode = mode
        self.caps = caps
        self.spentToday = spentToday
        self.ladder = ladder
        self.defaultLadder = defaultLadder
        self.models = models
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey { case mode, caps, spentToday, ladder, defaultLadder, models, providers }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = c.v(.mode, "off")
        caps = c.v(.caps, SuiteCapsSetting(perJob: 0, perDay: 0))
        spentToday = c.v(.spentToday, 0)
        ladder = c.v(.ladder, [:])
        defaultLadder = c.v(.defaultLadder, [:])
        models = c.v(.models, [])
        providers = c.v(.providers, SuiteProviders())
    }

    public func model(_ id: String) -> SuiteRegistryModel? { models.first { $0.id == id } }
}

public struct SuiteCapsSetting: Codable, Hashable, Sendable {
    public var perJob: Double
    public var perDay: Double
    public init(perJob: Double, perDay: Double) {
        self.perJob = perJob
        self.perDay = perDay
    }
}

public struct SuiteModelPatch: Codable, Hashable, Sendable {
    public var enabled: Bool?
    public var acknowledge: Bool?
    public var priceScale: Double?
    public init(enabled: Bool? = nil, acknowledge: Bool? = nil, priceScale: Double? = nil) {
        self.enabled = enabled
        self.acknowledge = acknowledge
        self.priceScale = priceScale
    }
}

/// PATCH /v1/suite/settings. Only what is set is sent.
public struct SuiteSettingsPatch: Codable, Hashable, Sendable {
    public var models: [String: SuiteModelPatch]?
    public var capPerJob: Double?
    public var capPerDay: Double?
    public init(models: [String: SuiteModelPatch]? = nil, capPerJob: Double? = nil, capPerDay: Double? = nil) {
        self.models = models
        self.capPerJob = capPerJob
        self.capPerDay = capPerDay
    }
}

/// POST /v1/suite/camera/compile → what the camera becomes on that quality's first model. `engine`/`params` are the owner's.
public struct CameraCompileRequest: Codable, Hashable, Sendable {
    public var camera: CameraSpec
    public var quality: String?
    public var duration: Int?
    public init(camera: CameraSpec, quality: String? = nil, duration: Int? = nil) {
        self.camera = camera
        self.quality = quality
        self.duration = duration
    }
}

public struct CameraCompiled: Codable, Hashable, Sendable {
    public var text: String
    public var moves: [String]
    public var guideUsed: Bool
    public var warnings: [String]
    public var engine: String?

    public init(text: String, moves: [String] = [], guideUsed: Bool = false, warnings: [String] = [], engine: String? = nil) {
        self.text = text
        self.moves = moves
        self.guideUsed = guideUsed
        self.warnings = warnings
        self.engine = engine
    }

    enum CodingKeys: String, CodingKey { case text, moves, guideUsed, warnings, engine }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        text = c.v(.text, "")
        moves = c.v(.moves, [])
        guideUsed = c.v(.guideUsed, false)
        warnings = c.v(.warnings, [])
        // The owner's engine can be a name or an object; only a plain name is kept.
        engine = c.o(.engine)
    }
}
