import Darwin
import Foundation
import MuseCore

// "Paste a link" fetched on this Mac (Release 1 owner decision; the pure rules are MuseCore's RecreateDeviceFetch).
//
// Why the binary is downloaded on first use, not bundled: the app isn't sandboxed (mac/project.yml has no entitlements,
// ad-hoc signing, hardened runtime off), so it can run a helper it downloaded. Bundling would put a ~35 MB third-party
// executable in the repo and inside the app, and every executable inside a notarized app must be re-signed with our
// Developer ID and the hardened runtime, which a PyInstaller build doesn't take well. A helper downloaded into
// ~/Library/Application Support/MUSE/bin/ stays outside the bundle, so notarization later only covers our own code.
// The download is pinned to one release and its SHA-256: a file that doesn't match is deleted and never run. If the
// app is ever sandboxed, this path stops working and the server's link endpoint (the fallback) is used.
//
// Never used in demo mode or review mode (CI): those keep the instant fake path.
actor DeviceLinkFetcher {
    static let shared = DeviceLinkFetcher()

    /// The binary already checked this launch.
    private var ready: URL?

    private var binDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MUSE/bin", isDirectory: true)
    }

    /// The pinned, checked binary: from the bin folder, or downloaded there first. nil when it can't be had.
    func binary() async -> URL? {
        if let ready, FileManager.default.isExecutableFile(atPath: ready.path) { return ready }
        let fm = FileManager.default
        let dest = binDir.appendingPathComponent(RecreateDeviceFetch.binaryName)
        if fm.fileExists(atPath: dest.path) {
            if RecreateDeviceFetch.verify(dest) { return prepare(dest) }   // a file that fails is deleted
        }
        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            var req = URLRequest(url: RecreateDeviceFetch.downloadURL)
            req.timeoutInterval = 60
            let (tmp, response) = try await URLSession.shared.download(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { try? fm.removeItem(at: tmp); return nil }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            NSLog("[link] couldn't download the helper: %@", error.localizedDescription)
            return nil
        }
        guard RecreateDeviceFetch.verify(dest) else {
            NSLog("[link] the helper's checksum didn't match; deleted")
            return nil
        }
        // Earlier pinned versions are removed.
        for f in (try? fm.contentsOfDirectory(atPath: binDir.path)) ?? [] where f.hasPrefix("yt-dlp_macos") && f != RecreateDeviceFetch.binaryName {
            try? fm.removeItem(at: binDir.appendingPathComponent(f))
        }
        return prepare(dest)
    }

    private func prepare(_ file: URL) -> URL? {
        chmod(file.path, 0o755)
        removexattr(file.path, "com.apple.quarantine", 0)
        guard FileManager.default.isExecutableFile(atPath: file.path) else { return nil }
        ready = file
        return file
    }

    /// A tool the Mac already has (Homebrew or /usr/local), for merging (ffmpeg) or YouTube's JavaScript (deno, node).
    nonisolated static func tool(_ names: [String]) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            for n in names {
                let p = "\(dir)/\(n)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Downloads the link's video into a new temporary folder under the studio's link rules: the metadata is read and
    /// checked first (public, the duration and size caps), TikTok's page when the creator's "downloads off" is refused,
    /// then the file is downloaded. Stops after 120 s, or when the task is cancelled. `progress` gets 0…1 while the
    /// download reports it.
    func fetch(_ link: String, platform: String?, settings: RecreateLinkSettings, progress: @escaping @Sendable (Double?) -> Void) async -> Result<Fetched, RecreateDeviceFetch.Failure> {
        guard let bin = await binary() else { return .failure(.unavailable("no helper")) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-link-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return .failure(.unavailable("no folder")) }
        let deadline = Date().addingTimeInterval(RecreateDeviceFetch.timeoutSec)
        let ffmpeg = Self.tool(["ffmpeg"]), js = Self.tool(["deno", "node"])
        func fail(_ f: RecreateDeviceFetch.Failure) -> Result<Fetched, RecreateDeviceFetch.Failure> {
            try? FileManager.default.removeItem(at: dir)
            return .failure(f)
        }

        // 1. The metadata (one request to the platform), checked like the server checks it.
        progress(nil)
        let info = await Self.run(bin, RecreateDeviceFetch.infoArgs(url: link, ffmpeg: ffmpeg, jsRuntime: js), cwd: dir, deadline: deadline, onLine: nil)
        if Task.isCancelled { return fail(.unavailable("cancelled")) }
        guard info.status == 0, let meta = RecreateDeviceFetch.Info.parse(info.stdout) else {
            return fail(info.timedOut ? .unavailable("timed out") : RecreateDeviceFetch.failure(output: info.text))
        }
        let limits = RecreateDeviceFetch.Limits(settings)
        if let p = RecreateDeviceFetch.check(meta, limits: limits) { return fail(.refused(p)) }
        // Strict rules honour TikTok's "downloads off" (the server can't see this download); a page that can't be read
        // refuses the link rather than risk it.
        if RecreateDeviceFetch.needsTikTokPage(platform: platform, link: link, settings: settings) {
            guard let html = await Self.page(meta.webpageUrl ?? link, deadline: deadline) else {
                return fail(Task.isCancelled ? .unavailable("cancelled") : .refused(RecreateDeviceFetch.pageUnreadable))
            }
            if RecreateDeviceFetch.tiktokDownloadsOff(html: html) == true {
                return fail(.refused(RecreateLinkProblem(code: "link_downloads_off", message: RecreateDeviceFetch.downloadsOffMessage)))
            }
        }
        let infoFile = dir.appendingPathComponent("info.json")
        do { try info.stdout.write(to: infoFile) } catch { return fail(.unavailable("no folder")) }

        // 2. The download, from that metadata.
        let args = RecreateDeviceFetch.downloadArgs(infoFile: infoFile.path, dir: dir.path, limits: limits, ffmpeg: ffmpeg, jsRuntime: js)
        let dl = await Self.run(bin, args, cwd: dir, deadline: deadline) { line in
            if let v = RecreateDeviceFetch.progress(line) { progress(v) }
        }
        if Task.isCancelled { return fail(.unavailable("cancelled")) }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let video = files.first { $0.lastPathComponent.hasPrefix("video.") && $0.pathExtension != "json" && $0.pathExtension != "part" }
        guard dl.status == 0, let video else {
            return fail(dl.timedOut ? .unavailable("timed out") : RecreateDeviceFetch.failure(output: dl.text))
        }
        let size = (try? video.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > limits.maxBytes { return fail(.refused(RecreateLinkProblem(code: "link_too_big", message: RecreateDeviceFetch.tooBigMessage))) }
        return .success(Fetched(file: video, title: meta.title))
    }

    /// A public page read like the server reads it: no cookies, no stored sign-ins (an ephemeral session). nil when it
    /// can't be read.
    private static func page(_ link: String, deadline: Date) async -> String? {
        guard let url = URL(string: link), url.scheme == "https" || url.scheme == "http" else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.timeoutInterval = max(1, min(20, deadline.timeIntervalSinceNow))
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("en", forHTTPHeaderField: "Accept-Language")
        guard let got = try? await session.data(for: req), (got.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: got.0, encoding: .utf8)
    }

    /// The downloaded file (in its own temporary folder: delete the folder when done) and the video's title.
    struct Fetched: Sendable {
        var file: URL
        var title: String?
    }

    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var text: String
        var timedOut: Bool
    }

    /// Runs the helper with a plain environment (no user config), reading its output line by line. It is stopped at
    /// the deadline or when the calling task is cancelled.
    private static func run(_ bin: URL, _ args: [String], cwd: URL, deadline: Date, onLine: (@Sendable (String) -> Void)?) async -> Output {
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": cwd.path, "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let box = OutputBox()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            box.appendOut(d)
            if let onLine, let s = String(data: d, encoding: .utf8) {
                for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) { onLine(String(line)) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { box.appendErr(d) }
        }
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
                p.terminationHandler = { proc in c.resume(returning: proc.terminationStatus) }
                do { try p.run() } catch {
                    p.terminationHandler = nil
                    c.resume(returning: -1)
                    return
                }
                let wait = max(0, deadline.timeIntervalSinceNow)
                DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
                    if p.isRunning { box.markTimedOut(); p.terminate() }
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let rest = (try? out.fileHandleForReading.readToEnd()) ?? nil
        if let rest, !rest.isEmpty { box.appendOut(rest) }
        let restErr = (try? err.fileHandleForReading.readToEnd()) ?? nil
        if let restErr, !restErr.isEmpty { box.appendErr(restErr) }
        return box.output(status)
    }
}

/// The helper's output, collected from the pipes' handlers.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var timedOut = false

    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
    func output(_ status: Int32) -> DeviceLinkFetcher.Output {
        lock.lock(); defer { lock.unlock() }
        let text = (String(data: err, encoding: .utf8) ?? "") + "\n" + (String(data: out.suffix(8192), encoding: .utf8) ?? "")
        return DeviceLinkFetcher.Output(status: status, stdout: out, text: text, timedOut: timedOut)
    }
}
