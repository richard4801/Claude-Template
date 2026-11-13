import Foundation

/// XL HDR export colour (owner bug 2026-11-12: "HDR (HLG)" exports looked warmer, more saturated and orange at the start
/// and now and then, in the file itself).
///
/// The Mac's HDR compositor gets each source frame as a half-float buffer and reads its colour from the buffer's own
/// attachments. A frame that arrives without colour primaries (an AI take is often written without them) was taken as
/// already being in the output's BT.2020 primaries, so BT.709 colour skipped its 709 → 2020 conversion: skin went orange
/// and oversaturated. Frames that did carry the tags were converted correctly, so the file mixed the two looks.
/// The composed output buffers had the same gap for the YCbCr matrix (Core Image used its default instead of BT.2020).
///
/// The fix: every frame's colour is resolved by `resolve` (the frame's own complete tags, else the source track's, else
/// BT.709 SDR), and every output buffer carries `output` before it is drawn. This file holds that rule and the
/// BT.709 SDR ↔ BT.2100 HLG maths the Mac check uses to read the colour back out of an exported file.
public extension EditV2 {
    enum HDRColor {
        /// A frame's or track's colour tags, spelled as CoreVideo spells them (kCVImageBufferColorPrimaries_… values).
        public struct Tags: Equatable, Hashable, Sendable {
            public var primaries: String?
            public var transfer: String?
            public var matrix: String?
            public init(primaries: String? = nil, transfer: String? = nil, matrix: String? = nil) {
                self.primaries = primaries; self.transfer = transfer; self.matrix = matrix
            }
            /// Primaries and transfer both known: enough to place the frame's colour.
            public var isComplete: Bool { primaries?.isEmpty == false && transfer?.isEmpty == false }
        }

        // CoreVideo's spellings (kCVImageBufferColorPrimaries_ITU_R_709_2 etc.).
        public static let bt709 = "ITU_R_709_2"
        public static let bt2020 = "ITU_R_2020"
        public static let hlg = "ITU_R_2100_HLG"

        /// What an untagged SDR source is: BT.709 primaries, transfer and matrix (as the SDR export treats it).
        public static let sdrDefault = Tags(primaries: bt709, transfer: bt709, matrix: bt709)
        /// What every HDR output frame is, and what the file says it is.
        public static let output = Tags(primaries: bt2020, transfer: hlg, matrix: bt2020)
        public static let pq = "SMPTE_ST_2084_PQ"

        /// Whether a source track is HDR (HLG or PQ).
        public static func isHDR(_ t: Tags?) -> Bool { t?.transfer == hlg || t?.transfer == pq }

        /// Round 5 (Mac run 587): the colour space the HDR export's video composition works in. With it set to BT.2020 / HLG,
        /// AVFoundation itself converted every SDR source frame to HLG before the compositor saw it, and converted the first
        /// one differently (3 hot frames at 60 fps). So: every source SDR → BT.709, AVFoundation converts nothing and the
        /// compositor places SDR in HLG itself, the same way on every frame. Any HDR source → BT.2020 / HLG as before (its
        /// highlights must not be tone-mapped to SDR first).
        public static func compositionSpace(_ sources: [Tags]) -> Tags {
            sources.contains(where: isHDR) ? output : sdrDefault
        }

        /// The colour a source frame is read with. A frame with complete tags keeps them (they describe its pixels);
        /// otherwise the source track's complete tags; otherwise BT.709 SDR. Never a mix of a frame's partial tags and
        /// a fallback (a lone HLG transfer with 709 primaries would be wrong both ways). The matrix comes along from the
        /// same place, falling back the same way.
        public static func resolve(frame: Tags, track: Tags?) -> Tags {
            let base: Tags
            if frame.isComplete { base = frame } else if let track, track.isComplete { base = track } else { base = sdrDefault }
            let matrix = base.matrix ?? frame.matrix ?? track?.matrix ?? sdrDefault.matrix
            return Tags(primaries: base.primaries, transfer: base.transfer, matrix: matrix)
        }

        /// The colour space a source track's frames are in: its own complete tags, else BT.709 SDR (matrix filled in).
        public static func trackSpace(_ track: Tags?) -> Tags {
            resolve(frame: Tags(), track: track)
        }

        /// Round 2 (owner 2026-11-12, build 582: still orange at the START). A frame's own tags are trusted only when they
        /// describe one of the two spaces the frame can really be in: its track's (decoded as is) or the composition's
        /// (converted by AVFoundation). Anything else (missing, partial, or a mix such as BT.2020 primaries with an SDR
        /// curve, which reads BT.709 colour as BT.2020: orange skin) is read as the track's space.
        public static func resolve(frame: Tags, track: Tags?, composition: Tags) -> Tags {
            let space = trackSpace(track)
            func same(_ a: Tags, _ b: Tags) -> Bool { a.primaries == b.primaries && a.transfer == b.transfer }
            guard frame.isComplete else { return space }
            if same(frame, space) { return Tags(primaries: space.primaries, transfer: space.transfer, matrix: frame.matrix ?? space.matrix) }
            if same(frame, composition) { return Tags(primaries: frame.primaries, transfer: frame.transfer, matrix: frame.matrix ?? composition.matrix) }
            return space
        }

        // MARK: Maths (BT.709, BT.2020, BT.2100 HLG, BT.2408 SDR placement)

        public typealias RGB = (r: Double, g: Double, b: Double)

        /// Linear BT.709 → linear BT.2020 (BT.2087).
        static let m709to2020: [Double] = [0.627404, 0.329283, 0.043313,
                                           0.069097, 0.919540, 0.011362,
                                           0.016391, 0.088013, 0.895595]
        static let m2020to709: [Double] = [1.660491, -0.587641, -0.072850,
                                           -0.124550, 1.132900, -0.008349,
                                           -0.018151, -0.100579, 1.118730]
        static func mul(_ m: [Double], _ c: RGB) -> RGB {
            (m[0] * c.r + m[1] * c.g + m[2] * c.b, m[3] * c.r + m[4] * c.g + m[5] * c.b, m[6] * c.r + m[7] * c.g + m[8] * c.b)
        }

        /// BT.709 OETF and its inverse (signal 0…1 ↔ linear 0…1).
        public static func oetf709(_ l: Double) -> Double { let l = max(0, l); return l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099 }
        public static func eotf709(_ v: Double) -> Double { let v = max(0, v); return v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45) }

        static let a = 0.17883277, b = 0.28466892, c = 0.55991073
        /// BT.2100 HLG OETF (scene linear 0…1 → signal) and inverse.
        public static func hlgOETF(_ e: Double) -> Double { let e = max(0, e); return e <= 1.0 / 12 ? (3 * e).squareRoot() : a * log(12 * e - b) + c }
        public static func hlgInverseOETF(_ v: Double) -> Double { let v = max(0, v); return v <= 0.5 ? v * v / 3 : (exp((v - c) / a) + b) / 12 }

        /// HLG system gamma at a 1000 cd/m² display, and SDR reference white's display level (203 / 1000, BT.2408).
        static let gamma = 1.2
        static let refWhite = 0.203
        static func lum2020(_ c: RGB) -> Double { 0.2627 * c.r + 0.6780 * c.g + 0.0593 * c.b }

        /// An SDR BT.709 pixel (signal 0…1) as HLG BT.2020 signal (0…1): SDR white lands on HLG reference white (75 %).
        /// `convertPrimaries` false is the bug: BT.709 colour placed in BT.2020 as if it were already there.
        public static func hlgSignal(sdr p: RGB, convertPrimaries: Bool = true) -> RGB {
            let lin: RGB = (eotf709(p.r) * refWhite, eotf709(p.g) * refWhite, eotf709(p.b) * refWhite)
            let d = convertPrimaries ? mul(m709to2020, lin) : lin
            // Inverse OOTF (display → scene light) on luminance, as BT.2100 defines it.
            let y = lum2020(d)
            let k = y > 0 ? pow(y, (1 - gamma) / gamma) : 0
            return (hlgOETF(d.r * k), hlgOETF(d.g * k), hlgOETF(d.b * k))
        }

        /// HLG BT.2020 signal back to SDR BT.709 signal (0…1, clipped): the inverse of `hlgSignal`.
        public static func sdrSignal(hlg v: RGB) -> RGB {
            let s: RGB = (hlgInverseOETF(v.r), hlgInverseOETF(v.g), hlgInverseOETF(v.b))
            let ys = lum2020(s)
            let k = ys > 0 ? pow(ys, gamma - 1) : 0   // OOTF
            let d = mul(m2020to709, (s.r * k / refWhite, s.g * k / refWhite, s.b * k / refWhite))
            func clip(_ x: Double) -> Double { min(1, max(0, oetf709(x))) }
            return (clip(d.r), clip(d.g), clip(d.b))
        }

        /// Kr, Kb of a YCbCr matrix by CoreVideo name (BT.601 when unknown, as Core Image assumes for an untagged buffer).
        public static func kr(_ matrix: String) -> (kr: Double, kb: Double) {
            switch matrix {
            case bt2020: return (0.2627, 0.0593)
            case bt709: return (0.2126, 0.0722)
            default: return (0.299, 0.114)
            }
        }

        /// R'G'B' signal → 10-bit video-range Y'CbCr codes with `matrix`.
        public static func codes10(_ p: RGB, matrix: String) -> (y: Int, cb: Int, cr: Int) {
            let (kr, kb) = kr(matrix), kg = 1 - kr - kb
            let y = kr * p.r + kg * p.g + kb * p.b
            let cb = (p.b - y) / (2 * (1 - kb)), cr = (p.r - y) / (2 * (1 - kr))
            func q(_ v: Double, _ lo: Int, _ hi: Int) -> Int { min(hi, max(lo, Int(v.rounded()))) }
            return (q(64 + 876 * y, 4, 1019), q(512 + 896 * cb, 4, 1019), q(512 + 896 * cr, 4, 1019))
        }

        /// 10-bit video-range Y'CbCr codes → R'G'B' signal with `matrix`.
        public static func signal(codes c: (y: Int, cb: Int, cr: Int), matrix: String) -> RGB {
            let (kr, kb) = kr(matrix), kg = 1 - kr - kb
            let y = (Double(c.y) - 64) / 876, cb = (Double(c.cb) - 512) / 896, cr = (Double(c.cr) - 512) / 896
            let r = y + 2 * (1 - kr) * cr, b = y + 2 * (1 - kb) * cb
            return (r, (y - kr * r - kb * b) / kg, b)
        }

        /// What a viewer shows for a pixel of an HDR (BT.2020 HLG) file, as SDR 0…255: decoded with the file's BT.2020
        /// matrix and tone-mapped back so SDR content compares with the SDR export.
        public static func sdr255(fromHLGCodes c: (y: Int, cb: Int, cr: Int)) -> (r: Int, g: Int, b: Int) {
            let s = sdrSignal(hlg: signal(codes: c, matrix: bt2020))
            return (Int((s.r * 255).rounded()), Int((s.g * 255).rounded()), Int((s.b * 255).rounded()))
        }

        /// The HDR file's codes for an SDR pixel (0…255) drawn with `source` tags read for the frame, written with
        /// `matrix` (the output buffer's), and how a viewer then shows it. `resolve` + `output` give the SDR colour back.
        public static func shown(sdr255 p: (r: Int, g: Int, b: Int), readAs source: Tags, writtenWith matrix: String) -> (r: Int, g: Int, b: Int) {
            let s: RGB = (Double(p.r) / 255, Double(p.g) / 255, Double(p.b) / 255)
            // A frame read as BT.2020 is not converted from 709; read as 709 it is.
            let v = hlgSignal(sdr: s, convertPrimaries: source.primaries != bt2020)
            return sdr255(fromHLGCodes: codes10(v, matrix: matrix))
        }

        /// The largest channel difference of two pixels.
        public static func distance(_ x: (r: Int, g: Int, b: Int), _ y: (r: Int, g: Int, b: Int)) -> Int {
            max(abs(x.r - y.r), abs(x.g - y.g), abs(x.b - y.b))
        }
    }
}
