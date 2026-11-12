import XCTest
@testable import MuseCore

/// Owner bug 2026-11-12: HDR (HLG) exports turned skin warmer / orange at the start and now and then. Every frame must
/// take the same colour path, whatever tags its buffer happens to carry.
final class EditV2HDRColorTests: XCTestCase {
    typealias H = EditV2.HDRColor
    let skin = (r: 224, g: 172, b: 140)
    let wall = (r: 200, g: 150, b: 110)

    /// A decoder buffer (tagged 709), a converted buffer without tags (as on caption frames / the first frames), and an
    /// AI take whose file has no primaries: all read the same way.
    func testEveryFrameResolvesTheSame() {
        let aiTake = H.Tags(primaries: nil, transfer: nil, matrix: H.bt709)
        let tagged = H.resolve(frame: H.Tags(primaries: H.bt709, transfer: H.bt709, matrix: H.bt709), track: aiTake)
        let untagged = H.resolve(frame: H.Tags(), track: aiTake)
        let partial = H.resolve(frame: H.Tags(primaries: nil, transfer: H.bt709), track: aiTake)
        XCTAssertEqual(tagged, H.sdrDefault)
        XCTAssertEqual(untagged, H.sdrDefault)
        XCTAssertEqual(partial, H.sdrDefault)
        // An HDR source frame keeps its own tags (they describe its pixels).
        let hdrFrame = H.Tags(primaries: H.bt2020, transfer: H.hlg, matrix: H.bt2020)
        XCTAssertEqual(H.resolve(frame: hdrFrame, track: nil), hdrFrame)
        // A tagged track fills in for an untagged frame.
        let p3 = H.Tags(primaries: "P3_D65", transfer: H.bt709, matrix: H.bt709)
        XCTAssertEqual(H.resolve(frame: H.Tags(), track: p3), p3)
    }

    /// The bug, measured: a frame read as if already BT.2020 (no 709 → 2020) comes out warmer and more saturated than a
    /// correctly read frame; the BT.601 default matrix on a fresh output buffer shifts it too.
    func testTheShiftTheOwnerSaw() {
        let good = H.shown(sdr255: skin, readAs: H.sdrDefault, writtenWith: H.bt2020)
        let noConversion = H.shown(sdr255: skin, readAs: H.Tags(primaries: H.bt2020, transfer: H.bt709), writtenWith: H.bt2020)
        let wrongMatrix = H.shown(sdr255: skin, readAs: H.sdrDefault, writtenWith: "")
        XCTAssertGreaterThan(noConversion.r - good.r, 15, "warmer: \(noConversion) vs \(good)")
        XCTAssertLessThan(noConversion.b, good.b, "more saturated: \(noConversion) vs \(good)")
        XCTAssertGreaterThan(H.distance(wrongMatrix, good), 1, "matrix: \(wrongMatrix) vs \(good)")
    }

    /// Fixed path: caption frame vs plain frame, first frame vs middle frame, all within 1/255 of each other and of the
    /// SDR export's colour once tone-mapped back.
    func testFixedPathMatchesSDR() {
        let aiTake = H.Tags(matrix: H.bt709)
        let frames: [H.Tags] = [H.Tags(), H.Tags(primaries: H.bt709, transfer: H.bt709, matrix: H.bt709), H.Tags(transfer: H.bt709)]
        for px in [skin, wall, (r: 128, g: 128, b: 128), (r: 220, g: 30, b: 30)] {
            let shown = frames.map { H.shown(sdr255: px, readAs: H.resolve(frame: $0, track: aiTake), writtenWith: H.output.matrix!) }
            for s in shown {
                XCTAssertLessThanOrEqual(H.distance(s, shown[0]), 1, "\(px): \(shown)")
                XCTAssertLessThanOrEqual(H.distance(s, px), 1, "\(px) → \(s)")
            }
        }
    }

    /// SDR white is HLG reference white (BT.2408: 75 %), grey stays neutral.
    func testReferenceWhite() {
        let w = H.hlgSignal(sdr: (1, 1, 1))
        XCTAssertEqual(w.r, 0.75, accuracy: 0.002)
        XCTAssertEqual(w.g, w.b, accuracy: 1e-9)
        let c = H.codes10(w, matrix: H.bt2020)
        XCTAssertEqual(c.cb, 512); XCTAssertEqual(c.cr, 512)
    }
}
