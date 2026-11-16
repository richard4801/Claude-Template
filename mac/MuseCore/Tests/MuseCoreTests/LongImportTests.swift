import XCTest
@testable import MuseCore

/// Long imports (owner 2026-11-16: "import up to 1 hr long, about 2 GB max … edit file videos"): the words, the device
/// fetch's import limits and timeout, and the resumable multipart upload's plan and progress.
final class LongImportTests: XCTestCase {
    func testLimitWords() {
        XCTAssertEqual(ImportLimitText.limit(maxSec: 3600, maxMb: 2048), "Up to 60 minutes and 2 GB")
        XCTAssertEqual(ImportLimitText.duration(42), "42 s")
        XCTAssertEqual(ImportLimitText.duration(725), "12 min")
        XCTAssertEqual(ImportLimitText.duration(3725), "1 h 2 min")
        XCTAssertEqual(ImportLimitText.size(150 * 1_048_576), "150 MB")
        XCTAssertEqual(ImportLimitText.size(Int(2.5 * 1024 * 1_048_576)), "2.5 GB")
        XCTAssertNil(ImportLimitText.problem(durationSec: 3600, bytes: 2047 * 1_048_576))
        XCTAssertEqual(ImportLimitText.problem(durationSec: 3725, bytes: 10),
                       "This video is 1 h 2 min long · the limit is 60 minutes (imports: up to 60 minutes and 2 GB)")
        XCTAssertEqual(ImportLimitText.problem(durationSec: 600, bytes: Int(2.5 * 1024 * 1_048_576)),
                       "This video is 2.5 GB · the limit is 2 GB (imports: up to 60 minutes and 2 GB)")
    }

    func testDeviceFetchUsesTheImportLimitsAndWords() {
        let s = RecreateLinkSettings(maxSec: 3600, maxMb: 2048)
        let imp = RecreateDeviceFetch.Limits(s, forImport: true), ref = RecreateDeviceFetch.Limits()
        XCTAssertEqual(RecreateDeviceFetch.timeoutSec(ref), 120)
        XCTAssertEqual(RecreateDeviceFetch.timeoutSec(imp), 7200)
        XCTAssertEqual(imp.text, "Up to 60 minutes and 2 GB")
        XCTAssertEqual(RecreateDeviceFetch.matchFilters(imp).first, "duration<=?3600 & availability=?public")
        let long = RecreateDeviceFetch.Info.parse(Data(#"{"duration":3725,"availability":"public"}"#.utf8))!
        XCTAssertEqual(RecreateDeviceFetch.check(long, limits: imp)?.message,
                       "This video is 1 h 2 min long · the limit is 60 minutes (imports: up to 60 minutes and 2 GB)")
        let hour = RecreateDeviceFetch.Info.parse(Data(#"{"duration":3500,"availability":"public"}"#.utf8))!
        XCTAssertNil(RecreateDeviceFetch.check(hour, limits: imp))
        // References keep their words.
        XCTAssertEqual(RecreateDeviceFetch.check(RecreateDeviceFetch.Info.parse(Data(#"{"duration":90}"#.utf8))!, limits: ref)?.code, "too_long")
        XCTAssertTrue(RecreateDeviceFetch.check(RecreateDeviceFetch.Info.parse(Data(#"{"duration":90}"#.utf8))!, limits: ref)!.message.hasPrefix("References can be up to 60 s"))
        XCTAssertEqual(RecreateDeviceFetch.tooBig(Double(2.5 * 1024 * 1_048_576), imp), "This video is 2.5 GB · the limit is 2 GB (imports: up to 60 minutes and 2 GB)")
    }

    func testMultipartPlan() throws {
        XCTAssertFalse(MultipartUpload.usesParts(size: 99 * 1_048_576))
        XCTAssertTrue(MultipartUpload.usesParts(size: 100 * 1_048_576))
        XCTAssertFalse(MultipartUpload.usesParts(size: nil))
        let part = 64 * 1_048_576, total = 2 * part + 10
        XCTAssertEqual(MultipartUpload.range(part: 1, partSize: part, total: total), 0..<part)
        XCTAssertEqual(MultipartUpload.range(part: 3, partSize: part, total: total), (2 * part)..<total)
        // One part read from disk at a time.
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("mp-\(UUID().uuidString).bin")
        try Data((0..<100).map { UInt8($0) }).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertEqual(try MultipartUpload.read(f, 10..<14), Data([10, 11, 12, 13]))
        XCTAssertThrowsError(try MultipartUpload.read(f, 90..<110))
        XCTAssertEqual([1, 2, 3, 9].map { MultipartUpload.pause(attempt: $0) }, [2, 6, 15, 15])
        XCTAssertTrue(MultipartUpload.retryable(URLError(.networkConnectionLost)))
        XCTAssertTrue(MultipartUpload.retryable(ApiError("http_503", "x")))
        XCTAssertTrue(MultipartUpload.retryable(ApiError("offline", "x")))
        XCTAssertFalse(MultipartUpload.retryable(ApiError("http_403", "x")))
        XCTAssertFalse(MultipartUpload.retryable(ApiError("too_big", "x")))
    }

    func testMultipartMeterAndTicket() throws {
        let m = MultipartUpload.Meter(total: 200)
        m.finish(1, bytes: 100)
        m.sending(2, bytes: 50)
        XCTAssertEqual(m.fraction, 0.75, accuracy: 1e-9)
        m.drop(2)
        XCTAssertEqual(m.fraction, 0.5, accuracy: 1e-9)
        m.finish(2, bytes: 100)
        XCTAssertEqual(m.fraction, 1, accuracy: 1e-9)
        let t = try JSONDecoder().decode(MultipartUpload.Ticket.self, from: Data(#"{"uploadId":"up_1","multipartId":"mp","partSize":67108864,"partCount":2,"done":[{"n":1,"etag":"abc","size":67108864}],"parts":[{"n":2,"url":"https://r2/p2"}],"expiresAt":1}"#.utf8))
        XCTAssertEqual(t.done?.first?.etag, "abc")
        XCTAssertEqual(t.parts.map(\.n), [2])
    }

    func testClaudeTakesEditFootageUpTo2GB() {
        XCTAssertEqual(ClaudeFilePolicy.uploadVideoMaxBytes, 2 * 1024 * 1_048_576)
        XCTAssertTrue(ClaudeFilePolicy.uploadRefusal.contains("videos (MP4, MOV, up to 2 GB)"))
    }

    func testWaveformBlocksStayBoundedOnLongFiles() {
        XCTAssertEqual(EditSuite.Peaks.block(seconds: 30, rate: 48_000), 64)
        let b = EditSuite.Peaks.block(seconds: 3600, rate: 48_000)
        XCTAssertLessThanOrEqual(Int((3600 * 48_000 / Double(b)).rounded(.up)), 65_536)
        XCTAssertEqual(EditSuite.Peaks.block(seconds: .nan, rate: 48_000), 64)
    }
}
