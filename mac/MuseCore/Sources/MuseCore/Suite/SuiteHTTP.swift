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
    public func suiteRigCheck(_ req: ShotRequest) async throws -> [RigWarning] {
        var r = req
        r.dryRun = nil
        return (try await suiteCall("POST", "v1/suite/rig-check", body: body(r)) as RigCheckResult).rig
    }
    // Photo tool (workstream 3)
    public func suitePhotoEstimate(_ req: PhotoRequest) async throws -> PhotoEstimate {
        try await suiteCall("POST", "v1/suite/photos/estimate", body: body(req))
    }
    public func suiteCreatePhotos(_ req: PhotoRequest) async throws -> [Take] {
        (try await suiteCall("POST", "v1/suite/photos", body: body(req)) as PhotoResult).takes.map(absolutize)
    }
    public func suiteStartPhotos(_ req: PhotoRequest) async throws -> Job {
        var o = (try JSONSerialization.jsonObject(with: body(req)) as? [String: Any]) ?? [:]
        o["async"] = true
        let r: PhotoResult = try await suiteCall("POST", "v1/suite/photos", body: try JSONSerialization.data(withJSONObject: o))
        guard let j = r.job else { throw ApiError("bad_response", "The server didn't start the photos") }
        return absolutize(j)
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
    public func suiteLocations() async throws -> [SuiteLocation] {
        let list: [SuiteLocation] = try await suiteCall("GET", "v1/suite/locations")
        return list.map(absolutizePlace)
    }
    public func createSuiteLocation(_ new: NewSuiteLocation) async throws -> SuiteLocation {
        absolutizePlace(try await suiteCall("POST", "v1/suite/locations", body: body(new)))
    }
    private func placePath(_ id: String) -> String { "v1/suite/locations/\(Self.pathKey(id))" }
    private func absolutizePlace(_ l: SuiteLocation) -> SuiteLocation {
        var l = l
        l.image = absolutize(l.image)
        l.images = l.images.map { PlaceImage(image: absolutize($0.image), source: $0.source) }
        return l
    }
    public func createPlace(_ new: NewPlace) async throws -> SuiteLocation {
        absolutizePlace(try await suiteCall("POST", "v1/suite/locations", body: body(new)))
    }
    public func updatePlace(id: String, _ patch: PlacePatch) async throws -> SuiteLocation {
        absolutizePlace(try await suiteCall("PATCH", placePath(id), body: body(patch)))
    }
    public func addPlaceImage(id: String, image: ImageRef) async throws -> SuiteLocation {
        absolutizePlace(try await suiteCall("POST", placePath(id) + "/images", body: body(["image": image])))
    }
    public func removePlaceImage(id: String, index: Int) async throws -> SuiteLocation {
        absolutizePlace(try await suiteCall("DELETE", placePath(id) + "/images/\(index)"))
    }
    public func placePhotoEstimate(id: String, _ req: PlacePhotoRequest) async throws -> PlacePhotoEstimate {
        var r = req
        r.maxUsd = nil
        return try await suiteCall("POST", placePath(id) + "/generate/estimate", body: body(r))
    }
    public func makePlacePhoto(id: String, _ req: PlacePhotoRequest) async throws -> PlacePhotoResult {
        var r: PlacePhotoResult = try await suiteCall("POST", placePath(id) + "/generate", body: body(req))
        r.place = absolutizePlace(r.place)
        return r
    }
    public func copyPlace(id: String, toModel modelId: String) async throws -> SuiteLocation {
        absolutizePlace(try await suiteCall("POST", placePath(id) + "/copy", body: body(["modelId": modelId])))
    }
    public func deleteSuiteLocation(id: String) async throws {
        try await suiteSend("DELETE", "v1/suite/locations/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id)")
    }

    // Build step 2: saved rigs, a model's default rig and the takes feed (Suite/SuiteRigsFeed.swift).
    public func suiteRigs() async throws -> [SuiteRigView] { try await suiteCall("GET", "v1/suite/rigs") }
    public func createSuiteRig(name: String, rig: SuiteRig) async throws -> SuiteRigView {
        try await suiteCall("POST", "v1/suite/rigs", body: body(NewSuiteRig(name: name, rig: rig)))
    }
    public func updateSuiteRig(id: String, name: String?, rig: SuiteRig?) async throws -> SuiteRigView {
        try await suiteCall("PATCH", "v1/suite/rigs/\(Self.pathKey(id))", body: body(SuiteRigPatch(name: name, rig: rig)))
    }
    public func deleteSuiteRig(id: String) async throws {
        try await suiteSend("DELETE", "v1/suite/rigs/\(Self.pathKey(id))")
    }
    public func setModelDefaultRig(modelId: String, rig: SuiteRig?) async throws -> MuseModel {
        absolutize(try await suiteCall("PATCH", "v1/models/\(Self.pathKey(modelId))", body: body(DefaultRigPatch(defaultRig: rig))) as MuseModel)
    }
    public func suiteFeed(_ q: SuiteFeedQuery) async throws -> SuiteFeedPage {
        var page: SuiteFeedPage = try await suiteCall("GET", q.path)
        page.items = page.items.map { item in
            var it = item
            it.poster = absolutize(item.poster)
            if let v = item.videoUrl, v.hasPrefix("/") { it.videoUrl = absolutize(ImageRef(url: v)).url }
            return it
        }
        return page
    }
}
