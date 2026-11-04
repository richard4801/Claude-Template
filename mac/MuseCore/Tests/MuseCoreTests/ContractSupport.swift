import XCTest
@testable import MuseCore

/// Helpers for the contract tests against a LOCAL server/api (never the hosted one).
extension HTTPMuseAPI {
    /// The studio balance, or nil on a server from before the app clean-up (plans/api.md "App clean-up" §4).
    func studioBalanceIfAny() async throws -> StudioBalance? {
        do {
            return try await studioBalance()
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            return nil
        }
    }

    /// Owner only: records a top-up on the local test server when what the owner can spend or send is under `atLeast`, so
    /// transfers and owner renders in the tests don't hit `over_allocation`. Returns false on an older server (no studio balance).
    @discardableResult
    func ensureStudioFunds(atLeast: Double = 50) async throws -> Bool {
        guard let sb = try await studioBalanceIfAny() else { return false }
        if sb.availableUsd < atLeast {
            let add = min(TopUpRecord.maxAmount, (atLeast - sb.availableUsd).rounded(.up) + 50)
            let after = try await recordTopUp(TopUpRecord(amountUsd: add, note: "Mac contract test"))
            XCTAssertGreaterThanOrEqual(after.availableUsd, atLeast - 0.01)
        }
        return true
    }
}
