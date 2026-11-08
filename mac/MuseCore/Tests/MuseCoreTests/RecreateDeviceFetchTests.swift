import XCTest
@testable import MuseCore

/// "Paste a link" fetched on this Mac: the pure rules only. Nothing here downloads, reads a page or runs the helper.
final class RecreateDeviceFetchTests: XCTestCase {
    func testPinnedRelease() {
        XCTAssertEqual(RecreateDeviceFetch.version, "2026.10.26")
        XCTAssertEqual(RecreateDeviceFetch.sha256.count, 64)
        XCTAssertEqual(RecreateDeviceFetch.downloadURL.absoluteString, "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp_macos")
        XCTAssertEqual(RecreateDeviceFetch.binaryName, "yt-dlp_macos-2026.10.26")
        let l = RecreateDeviceFetch.Limits()
        XCTAssertEqual(l.maxSec, 60)
        XCTAssertEqual(l.maxBytes, 80 * 1_048_576)
        XCTAssertEqual(RecreateDeviceFetch.Limits(RecreateLinkSettings(maxSec: 30, maxMb: 40)).maxBytes, 40 * 1_048_576)
    }

    func testInfoArgsKeepToOnePublicVideoWithoutCookies() {
        let a = RecreateDeviceFetch.infoArgs(url: "https://www.tiktok.com/@a/video/123456")
        for f in ["--ignore-config", "--no-cookies", "--no-cookies-from-browser", "--no-cache-dir", "--no-playlist", "--no-remote-components", "--skip-download", "--dump-single-json"] {
            XCTAssertTrue(a.contains(f), f)
        }
        XCTAssertFalse(a.contains("--cookies"))
        XCTAssertFalse(a.contains("--cookies-from-browser"))
        XCTAssertEqual(Array(a.suffix(2)), ["--", "https://www.tiktok.com/@a/video/123456"])
        XCTAssertFalse(a.contains("--js-runtimes"))
        let js = RecreateDeviceFetch.infoArgs(url: "https://youtu.be/abcdefghijk", jsRuntime: "/opt/homebrew/bin/deno")
        XCTAssertEqual(js[js.firstIndex(of: "--js-runtimes")! + 1], "deno:/opt/homebrew/bin/deno")
    }

    func testDownloadArgsCapDurationAndSize() {
        let a = RecreateDeviceFetch.downloadArgs(infoFile: "/tmp/x/info.json", dir: "/tmp/x")
        XCTAssertEqual(a[a.firstIndex(of: "--max-filesize")! + 1], String(80 * 1_048_576))
        let filters = a.indices.filter { a[$0] == "--match-filter" }.map { a[$0 + 1] }
        XCTAssertEqual(filters, ["duration<=?60 & availability=?public", "duration<=?60 & availability=?unlisted"])
        XCTAssertEqual(a[a.firstIndex(of: "-o")! + 1], "/tmp/x/video.%(ext)s")
        XCTAssertEqual(Array(a.suffix(2)), ["--load-info-json", "/tmp/x/info.json"])
        XCTAssertTrue(a.contains("--no-cookies-from-browser"))
        // No ffmpeg: single-file formats only, nothing to merge.
        XCTAssertEqual(a[a.firstIndex(of: "-f")! + 1], "b[ext=mp4][height<=1080]/b[ext=mp4]/b[height<=1080]/b")
        XCTAssertFalse(a.contains("--merge-output-format"))
        XCTAssertFalse(a.contains("--ffmpeg-location"))
        // With ffmpeg: video and sound may be merged into mp4.
        let m = RecreateDeviceFetch.downloadArgs(infoFile: "/i.json", dir: "/d", ffmpeg: "/opt/homebrew/bin/ffmpeg")
        XCTAssertEqual(m[m.firstIndex(of: "--merge-output-format")! + 1], "mp4")
        XCTAssertEqual(m[m.firstIndex(of: "--ffmpeg-location")! + 1], "/opt/homebrew/bin/ffmpeg")
        XCTAssertTrue(m[m.firstIndex(of: "-f")! + 1].contains("bv*[ext=mp4][height<=1080]+ba[ext=m4a]"))
        // The server's caps.
        let c = RecreateDeviceFetch.downloadArgs(infoFile: "/i.json", dir: "/d", limits: .init(maxSec: 45, maxMb: 50))
        XCTAssertEqual(c[c.firstIndex(of: "--max-filesize")! + 1], String(50 * 1_048_576))
        XCTAssertEqual(c[c.firstIndex(of: "--match-filter")! + 1], "duration<=?45 & availability=?public")
    }

    private func info(_ json: String) throws -> RecreateDeviceFetch.Info {
        try XCTUnwrap(RecreateDeviceFetch.Info.parse(Data(json.utf8)))
    }

    func testMetadataChecksMatchTheServer() throws {
        XCTAssertNil(RecreateDeviceFetch.check(try info(#"{"duration":42,"availability":"public","filesize":1000}"#)))
        // Platforms that don't report availability pass; unlisted is anyone with the link.
        XCTAssertNil(RecreateDeviceFetch.check(try info(#"{"duration":30}"#)))
        XCTAssertNil(RecreateDeviceFetch.check(try info(#"{"duration":20,"availability":"unlisted"}"#)))
        let long = RecreateDeviceFetch.check(try info(#"{"duration":94.2}"#))
        XCTAssertEqual(long?.code, "too_long")
        XCTAssertEqual(long?.message, "References can be up to 60 s for now (this one is 94 s)")
        XCTAssertNil(RecreateDeviceFetch.check(try info(#"{"duration":60.4}"#)))
        XCTAssertEqual(RecreateDeviceFetch.check(try info(#"{"duration":50}"#), limits: .init(maxSec: 45, maxMb: 80))?.code, "too_long")
        let big = RecreateDeviceFetch.check(try info(#"{"duration":20,"filesize_approx":222298112}"#))
        XCTAssertEqual(big?.code, "link_too_big")
        XCTAssertEqual(big?.message, "This video is too big to fetch (212 MB; the limit is 80 MB)")
        let merged = RecreateDeviceFetch.check(try info(#"{"duration":20,"requested_formats":[{"filesize":60000000},{"filesize_approx":40000000}]}"#))
        XCTAssertEqual(merged?.code, "link_too_big")
        XCTAssertEqual(RecreateDeviceFetch.check(try info(#"{"_type":"playlist"}"#))?.code, "link_unsupported")
        XCTAssertEqual(RecreateDeviceFetch.check(try info(#"{"is_live":true}"#))?.code, "link_unsupported")
        XCTAssertTrue(RecreateLinkProblem(code: "too_long", message: "").offersFile)
        // Not public, or age-gated: refused whatever the strict setting (as on the server).
        let priv = RecreateDeviceFetch.check(try info(#"{"duration":20,"availability":"needs_auth"}"#))
        XCTAssertEqual(priv?.code, "link_private")
        XCTAssertEqual(priv?.message, "This video isn’t public, so MUSE won’t fetch it. Save it yourself and drop the file in")
        XCTAssertEqual(RecreateDeviceFetch.check(try info(#"{"duration":20,"age_limit":18}"#))?.code, "link_private")
    }

    private func tiktokPage(_ item: String) -> String {
        #"<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">{"__DEFAULT_SCOPE__":{"webapp.video-detail":{"itemInfo":{"itemStruct":"#
            + item + "}}}}</script></html>"
    }

    func testTikTokDownloadsOffLikeTheServer() {
        XCTAssertEqual(RecreateDeviceFetch.tiktokDownloadsOff(html: tiktokPage(#"{"downloadSetting":0,"author":{"downloadSetting":0}}"#)), false)
        XCTAssertEqual(RecreateDeviceFetch.tiktokDownloadsOff(html: tiktokPage(#"{"downloadSetting":3}"#)), true)
        XCTAssertEqual(RecreateDeviceFetch.tiktokDownloadsOff(html: tiktokPage(#"{"downloadSetting":0,"author":{"downloadSetting":3}}"#)), true)
        XCTAssertEqual(RecreateDeviceFetch.tiktokDownloadsOff(html: tiktokPage(#"{"itemControl":{"can_download":false}}"#)), true)
        XCTAssertEqual(RecreateDeviceFetch.tiktokDownloadsOff(html: tiktokPage(#"{"itemControl":{"can_download":true}}"#)), false)
        XCTAssertNil(RecreateDeviceFetch.tiktokDownloadsOff(html: tiktokPage(#"{"id":"1","downloadSetting":null}"#)))
        XCTAssertNil(RecreateDeviceFetch.tiktokDownloadsOff(html: "<html>no data</html>"))
        XCTAssertNil(RecreateDeviceFetch.tiktokDownloadsOff(html: tiktokPage("not json")))
        // Only strict rules with "refuse" read the page, and only for TikTok.
        let strict = RecreateLinkSettings()
        XCTAssertTrue(RecreateDeviceFetch.needsTikTokPage(platform: "tiktok", link: "https://www.tiktok.com/@a/video/123456", settings: strict))
        XCTAssertTrue(RecreateDeviceFetch.needsTikTokPage(platform: nil, link: "https://vm.tiktok.com/ZMabc/", settings: strict))
        XCTAssertFalse(RecreateDeviceFetch.needsTikTokPage(platform: "youtube", link: "https://youtu.be/abcdefghijk", settings: strict))
        XCTAssertFalse(RecreateDeviceFetch.needsTikTokPage(platform: "tiktok", link: "x", settings: RecreateLinkSettings(strictLinks: false)))
        XCTAssertFalse(RecreateDeviceFetch.needsTikTokPage(platform: "tiktok", link: "x", settings: RecreateLinkSettings(strictLinks: true, tiktokDownloadsOff: "allow")))
        XCTAssertEqual(RecreateDeviceFetch.pageUnreadable.code, "link_blocked")
        XCTAssertTrue(RecreateDeviceFetch.pageUnreadable.offersFile)
    }

    func testInfoDecodesLeniently() throws {
        let i = try info(#"{"title":"Dance","webpage_url":"https://www.tiktok.com/@a/video/1","duration":"n/a","availability":null,"filesize":12.5,"somethingNew":[1]}"#)
        XCTAssertEqual(i.title, "Dance")
        XCTAssertEqual(i.webpageUrl, "https://www.tiktok.com/@a/video/1")
        XCTAssertNil(i.duration)
        XCTAssertEqual(i.size, 12.5)
        XCTAssertNil(RecreateDeviceFetch.Info.parse(Data("ERROR: nope".utf8)))
    }

    func testRefusalsFromTheHelpersOutput() {
        func code(_ s: String) -> String? {
            if case .refused(let p) = RecreateDeviceFetch.failure(output: s) { return p.code }
            return nil
        }
        XCTAssertEqual(code("ERROR: [youtube] abc: Private video. Sign in if you've been granted access to this video"), "link_private")
        XCTAssertEqual(code("ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users."), "link_private")
        XCTAssertEqual(code("ERROR: [youtube] abc: This video is available to this channel's members-only"), "link_private")
        XCTAssertEqual(code("[download] File is larger than max-filesize (90000000 bytes > 83886080 bytes). Aborting."), "link_too_big")
        XCTAssertEqual(code("ERROR: Unsupported URL: https://example.com"), "link_unsupported")
        // The Mac being refused, not the video: the server tries next.
        XCTAssertNil(code("ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication."))
        XCTAssertNil(code("ERROR: [Instagram] abc: Requested content is not available, rate-limit reached or login required."))
        XCTAssertNil(code("ERROR: unable to download video data: HTTP Error 403: Forbidden"))
        XCTAssertNil(code("[download] Dance does not pass filter (duration<=?60), skipping .."))
        XCTAssertNil(code(""))
        XCTAssertEqual(RecreateDeviceFetch.failure(output: "ERROR: Sign in to confirm you're not a bot"), .unavailable("sign-in wall"))
    }

    func testProgressLines() {
        XCTAssertEqual(RecreateDeviceFetch.progress("[download]  42.3% of   12.34MiB at    1.23MiB/s ETA 00:05") ?? -1, 0.423, accuracy: 0.0001)
        XCTAssertEqual(RecreateDeviceFetch.progress("[download] 100% of   12.34MiB in 00:00:03 at 3.9MiB/s"), 1)
        XCTAssertEqual(RecreateDeviceFetch.progress("[download]   0.0% of ~  5.00MiB at  Unknown B/s ETA Unknown"), 0)
        XCTAssertNil(RecreateDeviceFetch.progress("[info] abc: Downloading 1 format(s): 18"))
        XCTAssertNil(RecreateDeviceFetch.progress("[download] Destination: /tmp/x/video.mp4"))
        XCTAssertEqual(RecreateDeviceFetch.statusLine(fetched: nil), "Fetching the video…")
        XCTAssertEqual(RecreateDeviceFetch.statusLine(fetched: 0.42), "Fetching the video… 42%")
    }

    func testMemberFacingWordsNeverNameTheHelper() {
        let words = [RecreateDeviceFetch.statusLine(fetched: nil), RecreateDeviceFetch.statusLine(fetched: 0.5), RecreateDeviceFetch.privateMessage,
                     RecreateDeviceFetch.ageMessage, RecreateDeviceFetch.tooBigMessage, RecreateDeviceFetch.downloadsOffMessage, RecreateDeviceFetch.pageUnreadable.message]
        for w in words { XCTAssertFalse(w.lowercased().contains("yt-dlp"), w) }
    }

    func testContentTypes() {
        XCTAssertEqual(RecreateDeviceFetch.contentType(URL(fileURLWithPath: "/d/video.mp4")), "video/mp4")
        XCTAssertEqual(RecreateDeviceFetch.contentType(URL(fileURLWithPath: "/d/video.webm")), "video/webm")
        XCTAssertEqual(RecreateDeviceFetch.contentType(URL(fileURLWithPath: "/d/video.mov")), "video/quicktime")
    }

    #if canImport(CryptoKit)
    func testChecksumAcceptsTheRightFileAndDeletesAWrongOne() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muse-sha-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("tool")
        try Data("abc".utf8).write(to: f)
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(RecreateDeviceFetch.sha256Hex(of: f), abc)
        XCTAssertTrue(RecreateDeviceFetch.verify(f, expected: abc.uppercased()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        // The pinned hash doesn't match these bytes: the file is deleted, never run.
        XCTAssertFalse(RecreateDeviceFetch.verify(f))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertFalse(RecreateDeviceFetch.verify(dir.appendingPathComponent("missing")))
    }
    #endif

    func testLinkSettingsDecodeLeniently() throws {
        let full = try JSONDecoder().decode(RecreateLinkSettings.self, from: Data(#"{"strictLinks":false,"platforms":["any"],"tiktokDownloadsOff":"allow","maxSec":60,"maxMb":80,"serverFetch":true,"cookies":false,"canEdit":true}"#.utf8))
        XCTAssertFalse(full.strictLinks)
        XCTAssertEqual(full.platforms, ["any"])
        XCTAssertFalse(full.refusesTikTokDownloadsOff)
        XCTAssertTrue(full.canEdit)
        let empty = try JSONDecoder().decode(RecreateLinkSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.strictLinks)
        XCTAssertTrue(empty.refusesTikTokDownloadsOff)
        XCTAssertEqual(empty.maxSec, 60)
        XCTAssertEqual(empty.maxMb, 80)
        XCTAssertFalse(empty.cookies)
        XCTAssertFalse(empty.canEdit)
        let odd = try JSONDecoder().decode(RecreateLinkSettings.self, from: Data(#"{"strictLinks":"yes","maxMb":"lots","somethingNew":1}"#.utf8))
        XCTAssertTrue(odd.strictLinks)
        XCTAssertEqual(odd.maxMb, 80)
    }

    func testLinkCheckDecodes() throws {
        let ok = try JSONDecoder().decode(RecreateLinkCheck.self, from: Data(#"{"allowed":true,"url":"https://www.youtube.com/shorts/abcdefghijk","platform":"youtube"}"#.utf8))
        XCTAssertTrue(ok.allowed)
        XCTAssertNil(ok.problem)
        XCTAssertNil(ok.cached)
        let hit = try JSONDecoder().decode(RecreateLinkCheck.self, from: Data(#"{"allowed":true,"url":"u","platform":"tiktok","cached":{"id":"rx_1","state":"ready"}}"#.utf8))
        XCTAssertEqual(hit.cached?.id, "rx_1")
        let no = try JSONDecoder().decode(RecreateLinkCheck.self, from: Data(#"{"allowed":false,"code":"link_unsupported","reason":"MUSE only fetches public web links"}"#.utf8))
        XCTAssertEqual(no.problem?.code, "link_unsupported")
        XCTAssertEqual(no.problem?.message, "MUSE only fetches public web links")
        XCTAssertTrue(no.problem?.offersFile == true)
    }

    func testDemoLinkRulesAndCheck() async throws {
        let api = FakeRecreateAPI()
        let s = try await api.linkSettings()
        XCTAssertTrue(s.strictLinks)
        XCTAssertTrue(s.canEdit)
        let ok = try await api.checkLink(FakeRecreateAPI.demoLink)
        XCTAssertTrue(ok.allowed)
        XCTAssertEqual(ok.platform, "tiktok")
        XCTAssertNil(ok.cached)
        let other = try await api.checkLink("https://example.com/a.mp4")
        XCTAssertEqual(other.code, "link_unsupported")
        let priv = try await api.checkLink("https://www.tiktok.com/@a/video/123456-private")
        XCTAssertEqual(priv.code, "link_private")
        _ = try await api.createReference(link: FakeRecreateAPI.demoLink, name: nil)
        let again = try await api.checkLink(FakeRecreateAPI.demoLink)
        XCTAssertNotNil(again.cached)
        let off = try await api.setStrictLinks(false)
        XCTAssertFalse(off.strictLinks)
        let anyLink = try await api.checkLink("https://example.com/a.mp4")
        XCTAssertEqual(anyLink.platform, "other")
    }
}
