import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// upload_local_file / Bash / Read timing out in MUSE's Claude (ci_5c0e35ee5488, ci_9c7fc3adb445, ci_947db244af2b, ci_1d271380f0de).
final class ClaudeUploadTimeoutsTests: XCTestCase {
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T { lock.withLock { v } }
        func update(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
    }

    func testClaudeCodeWaitsAsLongAsTheServerForMuseTools() {
        let env = ClaudeCommand.environment([:], executable: "/bin/claude", home: "/Users/me")
        // Claude Code 2.1 aborts an HTTP MCP call after MCP_TOOL_TIMEOUT (60 s when unset) with "The operation timed out."
        XCTAssertEqual(env["MCP_TOOL_TIMEOUT"], "3700000")
        XCTAssertEqual(env["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"], "3700000")
    }

    func testTheAppSaysItAcksCardsAndTheEventStreamCarriesIt() {
        XCTAssertTrue(HTTPClaudeAPI.capabilities.split(separator: ",").contains("acks"))
        XCTAssertTrue(HTTPClaudeAPI.capabilities.split(separator: ",").contains("files"))
        let r = LiveEventHub.request(baseURL: URL(string: "https://muse.example")!, token: "t")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Muse-Caps"), HTTPClaudeAPI.capabilities)
    }

    func testADroppedPutIsTriedAgainThenSucceeds() async throws {
        let tries = Box(0), heard = Box<[Int]>([])
        try await ClaudeUploadRetry.run(onRetry: { n in heard.update { $0.append(n) } }, sleep: { _ in }) {
            tries.update { $0 += 1 }
            if tries.value < 3 { throw URLError(.networkConnectionLost) }
        }
        XCTAssertEqual(tries.value, 3)
        XCTAssertEqual(heard.value, [2, 3])
    }

    func testItGivesUpWithWhyInPlainWords() async {
        let tries = Box(0)
        do {
            try await ClaudeUploadRetry.run(onRetry: nil, sleep: { _ in }) { tries.update { $0 += 1 }; throw URLError(.timedOut) }
            XCTFail("should throw")
        } catch let e as ApiError {
            XCTAssertEqual(tries.value, ClaudeUploadRetry.maxAttempts)
            XCTAssertEqual(e.message, "The upload didn't finish after 3 tries: the connection stalled (nothing moved for 10 minutes).")
        } catch { XCTFail("\(error)") }
    }

    func testARefusalIsNotRetried() async {
        let tries = Box(0)
        do {
            try await ClaudeUploadRetry.run(onRetry: nil, sleep: { _ in }) { tries.update { $0 += 1 }; throw ApiError("http_403", "Upload refused (403)") }
            XCTFail("should throw")
        } catch let e as ApiError {
            XCTAssertEqual(tries.value, 1)
            XCTAssertEqual(e.message, "The upload didn't finish after 1 try: Upload refused (403).")
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(ClaudeUploadRetry.retryable(ApiError("http_503", "x")))
        XCTAssertFalse(ClaudeUploadRetry.retryable(ApiError("http_413", "x")))
    }

    func testTheReporterSendsFewReportsInOrderThenConfirming() async {
        let sent = Box<[ClaudePermissionProgress]>([]), clock = Box(0.0)
        let total = 112 * 1024 * 1024
        let r = ClaudeUploadReporter(total: total, now: { clock.value }) { p in sent.update { $0.append(p) } }
        await r.started()
        // Many small steps within a second: only 5% steps go out.
        for i in 1...40 { r.progress(Double(i) / 1000) }
        r.progress(0.06)
        clock.update { $0 = 3 }
        r.progress(0.07) // 2 s passed
        r.retry(2)
        r.progress(0.5)
        r.progress(1)
        r.progress(1)
        await r.flushed()
        let v = sent.value
        XCTAssertEqual(v.map(\.phase), ["uploading", "uploading", "uploading", "uploading", "uploading", "uploading", "confirming"])
        XCTAssertEqual(v[0], ClaudePermissionProgress(phase: "uploading", sentBytes: 0, totalBytes: total, attempt: 1))
        XCTAssertEqual(v[1].sentBytes, Int((Double(total) * 0.001).rounded()))
        XCTAssertEqual(v[2].sentBytes, Int((Double(total) * 0.06).rounded()))
        XCTAssertEqual(v[3].sentBytes, Int((Double(total) * 0.07).rounded()))
        XCTAssertEqual(v[4], ClaudePermissionProgress(phase: "uploading", sentBytes: 0, totalBytes: total, attempt: 2))
        XCTAssertEqual(v[5].attempt, 2)
    }

    func testProgressEncodesAsTheServerReadsIt() throws {
        let d = try JSONEncoder().encode(ClaudePermissionProgress(phase: "uploading", sentBytes: 5, totalBytes: 10, attempt: 2))
        let o = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        XCTAssertEqual(o?["phase"] as? String, "uploading")
        XCTAssertEqual(o?["sentBytes"] as? Int, 5)
        XCTAssertEqual(o?["totalBytes"] as? Int, 10)
        let asking = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(ClaudePermissionProgress.asking)) as? [String: Any]
        XCTAssertEqual(asking?.keys.sorted(), ["phase"])
    }
}
