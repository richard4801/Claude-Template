import Foundation

// AI suite (workstream 1): the /v1/suite endpoints over HTTP.
extension HTTPMuseAPI {
    private func body<B: Encodable>(_ b: B) throws -> Data { try JSONEncoder().encode(b) }

    public func suiteCatalog() async throws -> SuiteCatalog { try await suiteCall("GET", "v1/suite/catalog") }
    public func suiteCamera() async throws -> CameraCatalog { try await suiteCall("GET", "v1/suite/camera") }
    public func suiteCompileCamera(_ req: CameraCompileRequest) async throws -> CameraCompiled {
        try await suiteCall("POST", "v1/suite/camera/compile", body: body(req))
    }
    public func suiteEstimate(_ req: ShotRequest) async throws -> ShotEstimate {
        try await suiteCall("POST", "v1/suite/shots/estimate", body: body(req))
    }
    public func suiteCreateShot(_ req: ShotRequest) async throws -> Job {
        var r = req
        r.dryRun = nil
        return absolutize(try await suiteCall("POST", "v1/suite/shots", body: body(r)) as Job)
    }
    public func suiteShot(id: String) async throws -> SuiteShot {
        var s: SuiteShot = try await suiteCall("GET", "v1/suite/shots/\(id)")
        s.job = absolutize(s.job)
        return s
    }
    public func suiteSettings() async throws -> SuiteSettings { try await suiteCall("GET", "v1/suite/settings") }
    public func updateSuiteSettings(_ patch: SuiteSettingsPatch) async throws -> SuiteSettings {
        try await suiteCall("PATCH", "v1/suite/settings", body: body(patch))
    }
}
