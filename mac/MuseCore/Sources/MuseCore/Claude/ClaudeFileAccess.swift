import Foundation

/// Files on this Mac (owner, 2026-11-11): Claude Code in the one-Claude panel may read and write files and run commands on
/// the person's own Mac, but only after they say yes. Claude Code runs with
/// `--permission-prompt-tool mcp__muse__permission_prompt`; each question reaches the app as a `permission` live event
/// and becomes an approval card in the chat (Allow once · Allow always · Deny; see ClaudeAlwaysRules). Keys, passwords and tokens
/// are refused even when approved.
public enum ClaudeFileMode: String, Codable, CaseIterable, Sendable {
    /// Ask every time (the default).
    case ask
    /// Off: no file tools at all (Claude Code runs with MUSE's tools only, as before).
    case off

    public var label: String { self == .ask ? "Ask every time" : "Off" }
}

/// One folder allowed for one chat (before 2026-11-12). Read only to move old settings to the "Always allowed" list.
public struct ClaudeAllowedFolder: Codable, Hashable, Sendable, Identifiable {
    public var folder: String
    public var chatId: String
    public var chatTitle: String?
    public var id: String { "\(chatId)|\(folder)" }
    public init(folder: String, chatId: String, chatTitle: String? = nil) {
        self.folder = folder
        self.chatId = chatId
        self.chatTitle = chatTitle
    }
}

/// The person's file settings on this Mac (stored per person in the app's defaults). "Always allowed" folders and command
/// rules count in every chat on this Mac (owner, 2026-11-12).
public struct ClaudeFileSettings: Codable, Hashable, Sendable {
    public var mode: ClaudeFileMode = .ask
    /// Old per-chat folders: moved to `alwaysFolders` by `migrated(home:)`, then empty.
    public var folders: [ClaudeAllowedFolder] = []
    /// When results arrive (nil = the default: Claude looks and tells).
    public var results: ClaudeResultMode?
    /// "Let Claude operate MUSE's screen" (nil = the default: on).
    public var uiControl: Bool?
    /// Folders Claude may read and write in, every chat.
    public var alwaysFolders: [String]?
    /// Kinds of command that run without a card inside the allowed folders.
    public var commandRules: [ClaudeCommandRule]?
    /// "Ask before anything": every rule is off (kept, not deleted) and every card asks.
    public var askEverything: Bool?
    /// "Allow always: shell commands" (ci_c64e3cab2c7f): one switch for every command, nil = off.
    public var shellScope: ClaudeShellScope?
    /// MUSE tools (full names, `mcp__muse__get_frame`) that run without a card.
    public var alwaysTools: [String]?
    /// "Let Claude run code it writes" (owner, bundle-24): off (nil) by default.
    public var runCode: Bool?

    public init(mode: ClaudeFileMode = .ask, folders: [ClaudeAllowedFolder] = []) {
        self.mode = mode
        self.folders = folders
    }
    public var resultMode: ClaudeResultMode { results ?? .look }
    public var uiOn: Bool { uiControl ?? true }
    public var askAll: Bool { askEverything ?? false }
    public var allowedFolders: [String] { alwaysFolders ?? [] }
    public var rules: [ClaudeCommandRule] { commandRules ?? [] }
    public var tools: [String] { alwaysTools ?? [] }
    /// What the checks use: nothing while "Ask before anything" is on.
    public var activeFolders: [String] { askAll ? [] : allowedFolders }
    public var activeRules: [ClaudeCommandRule] { askAll ? [] : rules }
    public var activeShell: ClaudeShellScope? { askAll ? nil : shellScope }
    public var activeTools: [String] { askAll ? [] : tools }
    public var runsCode: Bool { runCode ?? false }
    /// The one sentence under the switch in Settings → Claude.
    public static let runCodeHint = "Python or other code Claude writes into a command runs without asking inside your folders and temporary files, and uv may download Python packages for it; code that deletes files, runs other programs, uses the network or controls other apps still asks."
    /// "Ask before anything" pauses it too.
    public var activeRunCode: Bool { askAll ? false : runsCode }

    /// "Allow always: shell commands" (a wider scope already granted stays).
    public mutating func allowShell(_ scope: ClaudeShellScope = .folders) {
        if shellScope == .anywhere { return }
        shellScope = scope
    }
    public mutating func removeShell() { shellScope = nil }

    public mutating func allowTool(_ name: String) {
        var list = tools
        guard !list.contains(name) else { return }
        list.append(name)
        alwaysTools = list
    }
    public mutating func removeTool(_ name: String) { alwaysTools = tools.filter { $0 != name } }

    public mutating func allowFolder(_ folder: String) {
        var list = allowedFolders
        guard !list.contains(where: { ClaudeFilePolicy.inside(folder, $0) }) else { return }
        list.removeAll { ClaudeFilePolicy.inside($0, folder) }   // a wider folder replaces those inside it
        list.append(folder)
        alwaysFolders = list
    }

    public mutating func allowRule(_ rule: ClaudeCommandRule) {
        var list = rules
        guard !list.contains(rule) else { return }
        list.append(rule)
        commandRules = list
    }

    public mutating func removeFolder(_ folder: String) { alwaysFolders = allowedFolders.filter { $0 != folder } }
    public mutating func removeRule(_ id: String) { commandRules = rules.filter { $0.id != id } }

    /// Old per-chat folders become "Always allowed" folders for every chat. One too wide to always allow now (the home
    /// folder, ~/Library, a system folder) is dropped and asks again.
    public func migrated(home: String) -> ClaudeFileSettings {
        guard !folders.isEmpty else { return self }
        var s = self
        for f in folders where ClaudeAlwaysRules.tooWide(f.folder, home: home) == nil { s.allowFolder(f.folder) }
        s.folders = []
        return s
    }

    public static func key(userId: String) -> String { "claude.files.\(userId)" }
}

/// Claude Code's question, as the server relays it (`{type: "claude", op: "permission", ask}`).
public struct ClaudePermissionAsk: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var toolName: String
    public var input: JSONValue?
    public var toolUseId: String?
    public var createdAt: Double?
    public init(id: String, toolName: String, input: JSONValue? = nil, toolUseId: String? = nil, createdAt: Double? = nil) {
        self.id = id
        self.toolName = toolName
        self.input = input
        self.toolUseId = toolUseId
        self.createdAt = createdAt
    }
}

public struct ClaudePermissionList: Codable, Hashable, Sendable {
    public var asks: [ClaudePermissionAsk]
}

/// What the card shows, and what the app does without asking.
public enum ClaudeFileVerdict: Hashable, Sendable {
    case allow
    case deny(String)
    case ask(ClaudeFileCard)
}

/// The approval card: exactly what Claude wants to do.
public struct ClaudeFileCard: Hashable, Sendable {
    /// "Read a file", "Run a command", …
    public var action: String
    /// The file path, folder or command, as it will run.
    public var detail: String
    /// A file call: the folder "Allow always" would allow for every chat; nil when it can't.
    public var folder: String?
    /// Why "Allow always" isn't offered (deletes, moves, network, admin, ~/Library, chained commands…).
    public var alwaysAsksBecause: String?
    /// A command: the rule "Allow always" would save; nil when it can't.
    public var rule: ClaudeCommandRule? = nil
    /// A command: folders "Allow always" also allows (the ones it reaches outside the allowed folders).
    public var ruleFolders: [String] = []
    /// A command: "Allow always" turns on shell commands (the kind), ci_c64e3cab2c7f.
    public var shell: Bool = false
    /// A MUSE tool: "Allow always" saves this tool name.
    public var tool: String? = nil

    public init(action: String, detail: String, folder: String?, alwaysAsksBecause: String?, rule: ClaudeCommandRule? = nil, ruleFolders: [String] = [],
                shell: Bool = false, tool: String? = nil) {
        self.action = action
        self.detail = detail
        self.folder = folder
        self.alwaysAsksBecause = alwaysAsksBecause
        self.rule = rule
        self.ruleFolders = ruleFolders
        self.shell = shell
        self.tool = tool
    }

    /// The second button: "Allow always" for a file call, "Allow always: ffmpeg commands" for a command; nil when it isn't offered.
    public var alwaysLabel: String? {
        if shell { return "Allow always: shell commands" }
        if let tool { return "Allow always: \(ClaudeKindGrants.toolLabel(tool))" }
        if let rule { return "Allow always: \(rule.label)" }
        return folder != nil ? "Allow always" : nil
    }

    /// The line under the buttons' row that says what "Allow always" covers.
    public func alwaysCovers(home: String) -> String? {
        func short(_ p: String) -> String {
            if ClaudeKindGrants.isTemp(p) { return "temporary files" }
            return ClaudeFilePolicy.inside(p, home) ? "~" + p.dropFirst(home.count) : p
        }
        if tool != nil { return "This tool, in every chat" }
        if shell {
            return ruleFolders.isEmpty ? "Any command inside your folders and temporary files, in every chat"
                : "Any command inside your folders; also allows \(ruleFolders.map(short).joined(separator: ", ")), in every chat"
        }
        if rule != nil {
            return ruleFolders.isEmpty ? "Inside your allowed folders, in every chat"
                : "Also allows \(ruleFolders.map(short).joined(separator: ", ")) in every chat"
        }
        return folder.map { "Allow always covers \(short($0)) (reading, writing and uploading) in every chat" }
    }
}

public enum ClaudeFilePolicy {
    public static let credentialRefusal = "MUSE never lets Claude read or change keys, passwords or tokens (.env, SSH keys, keychains, credential files), even with your approval."
    public static let offRefusal = "Files on this Mac are off for Claude (Settings → Claude)."

    /// The tools a file-enabled run lets Claude ask for (Web stays off).
    public static let fileTools: Set<String> = ["Read", "Glob", "Grep", "LS", "Write", "Edit", "MultiEdit", "Bash", "Upload"]
    /// upload_local_file: what can go up (the chat's own limits; sound as an editor audio upload, ci_de89873ab1de).
    public static let uploadImageTypes = SuiteClaudeAttachments.extensions
    public static let uploadVideoTypes: [String: String] = ["mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime"]
    public static let uploadAudioTypes: [String: String] = ["mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav"]
    /// Sound up to 200 MB (the editor's audio upload limit).
    public static let uploadAudioMaxBytes = 200 * 1024 * 1024
    public static let uploadRefusal = "Only images (JPEG, PNG, WebP, HEIC, up to 10 MB), videos (MP4, MOV, up to 500 MB) and sound (MP3, M4A, AAC, WAV, up to 200 MB) can be uploaded."

    public enum UploadKind: String, Sendable { case image, video, audio }
    public struct UploadType: Equatable, Sendable {
        public var mime: String
        public var kind: UploadKind
        public var video: Bool { kind == .video }
        /// What the server's answer calls it: "image", "clip" (a video) or "audio".
        public var resultKind: String { kind == .video ? "clip" : kind.rawValue }
    }

    /// The upload type of a file name, or nil. An .mp4 is a video by name; the Mac reads its tracks before uploading, and
    /// one with sound only goes up as audio (`contentType(_:)`).
    public static func uploadType(_ path: String) -> UploadType? {
        let ext = (path as NSString).pathExtension.lowercased()
        if let m = uploadImageTypes[ext] { return UploadType(mime: m, kind: .image) }
        if let m = uploadVideoTypes[ext] { return UploadType(mime: m, kind: .video) }
        if let m = uploadAudioTypes[ext] { return UploadType(mime: m, kind: .audio) }
        return nil
    }

    /// The upload type from what the file is (MediaSniff's verdict), for a video or sound by name: nil when it is a
    /// picture or unreadable (the card said video or sound).
    public static func uploadType(sniffed v: MediaSniff.Verdict?) -> UploadType? {
        guard let v else { return nil }
        switch v.kind {
        case .video: return UploadType(mime: v.contentType, kind: .video)
        case .audio: return UploadType(mime: v.contentType, kind: .audio)
        case .picture: return nil
        }
    }
    static let writeTools: Set<String> = ["Write", "Edit", "MultiEdit"]

    private static let secretDirs = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".claude", ".password-store", "Keychains"]
    private static let secretNames: Set<String> = [".netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials", "credentials.json"]
    private static let secretExts: Set<String> = ["pem", "key", "p12", "pfx", "keychain", "keychain-db"]

    /// Keys, passwords and tokens (the server checks the same list).
    public static func isSecret(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains(where: { p in secretDirs.contains { $0.caseInsensitiveCompare(p) == .orderedSame } }) { return true }
        if path.lowercased().contains(".config/gh") { return true }
        guard let name = parts.last?.lowercased() else { return false }
        if name == ".env" || name.hasPrefix(".env.") { return true }
        if secretNames.contains(name) { return true }
        if ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(where: { name.hasPrefix($0) }) { return true }
        if name.hasPrefix(".mcp-") && name.hasSuffix(".json") { return true } // MUSE's own token file for the run
        if let ext = name.split(separator: ".").last.map(String.init), name.contains("."), secretExts.contains(ext) { return true }
        return false
    }

    /// A command that names a secret anywhere in it.
    public static func mentionsSecret(_ command: String) -> Bool {
        let seps = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`=;|&<>()"))
        return command.components(separatedBy: seps).contains { !$0.isEmpty && isSecret($0) }
    }

    /// `~` and relative paths against the run's folder; `..` removed.
    public static func resolve(_ path: String, cwd: String, home: String) -> String {
        var p = path
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
        if !p.hasPrefix("/") { p = cwd + "/" + p }
        var out: [Substring] = []
        for c in p.split(separator: "/") {
            if c == "." || c.isEmpty { continue }
            if c == ".." { _ = out.popLast(); continue }
            out.append(c)
        }
        // macOS: /tmp and /var are links into /private; one name for each place.
        if out.first == "private", out.count >= 2, out[1] == "tmp" || out[1] == "var" { out.removeFirst() }
        return "/" + out.joined(separator: "/")
    }

    public static func inside(_ path: String, _ folder: String) -> Bool {
        let f = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == f || path.hasPrefix(f + "/")
    }

    static func str(_ input: JSONValue?, _ k: String) -> String? {
        if case .object(let o)? = input, case .string(let s)? = o[k], !s.isEmpty { return s }
        return nil
    }

    static let askAllReason = "You chose Ask before anything (Settings → Claude)"

    /// What to do with one question. `cwd` is the run's folder (~/MUSE/Claude/<chat>); `folders` and `rules` are the
    /// person's "Always allowed" list (empty while "Ask before anything" is on, then `askAll` is true too). `isDirectory`
    /// and `readScript` look at the Mac (a command's folder arguments, an interpreter's script).
    public static func verdict(_ ask: ClaudePermissionAsk, mode: ClaudeFileMode, folders: [String], cwd: String, home: String,
                               rules: [ClaudeCommandRule] = [], askAll: Bool = false, shell: ClaudeShellScope? = nil, tools: [String] = [],
                               runCode: Bool = false,
                               isDirectory: (String) -> Bool = { _ in false }, readScript: (String) -> String? = { _ in nil }) -> ClaudeFileVerdict {
        guard mode == .ask else { return .deny(offRefusal) }
        // A folder too wide to always allow (the disk, home, ~/Library) never counts, however it got on the list.
        let folders = folders.filter { ClaudeAlwaysRules.tooWide($0, home: home) == nil }
        let tool = ask.toolName
        if tool == "Bash" {
            let cmd = str(ask.input, "command") ?? ""
            if cmd.isEmpty { return .deny("Empty command") }
            if mentionsSecret(cmd) { return .deny(credentialRefusal) }
            if askAll { return .ask(ClaudeFileCard(action: "Run a command", detail: cmd, folder: nil, alwaysAsksBecause: askAllReason)) }
            // Rules saved before 2026-11-15 (one program each) still count.
            let c = ClaudeAlwaysRules.check(cmd, folders: folders, cwd: cwd, home: home, isDirectory: isDirectory, readScript: readScript)
            if c.clean, let r = c.rule, rules.contains(r) { return .allow }
            // The kind: shell commands, inside the folders and temporary files (or anywhere).
            let k = ClaudeKindGrants.shellCheck(cmd, scope: shell ?? .folders, folders: folders, cwd: cwd, home: home, runCode: runCode,
                                                isDirectory: isDirectory, readScript: readScript)
            // "Let Claude run code it writes" covers a command whose only reason to ask was its code (inside the folders and
            // temporary files, or the shell scope given); everything else needs "shell commands".
            if k.clean, shell != nil || (runCode && k.code) { return .allow }
            if let why = k.why { return .ask(ClaudeFileCard(action: "Run a command", detail: cmd, folder: nil, alwaysAsksBecause: "Always asks: \(why)")) }
            return .ask(ClaudeFileCard(action: "Run a command", detail: cmd, folder: nil, alwaysAsksBecause: nil, ruleFolders: k.needFolders, shell: true))
        }
        guard fileTools.contains(tool) else {
            // A MUSE tool (or Blender's) that Claude Code asked about: "Allow always" by its name. MUSE's own Approve cards
            // (spending, deleting, posting) are separate and still ask.
            if ClaudeKindGrants.isServerTool(tool) {
                if !askAll, tools.contains(tool) { return .allow }
                let label = ClaudeKindGrants.toolLabel(tool)
                if askAll { return .ask(ClaudeFileCard(action: "Use \(label)", detail: inputSummary(ask.input), folder: nil, alwaysAsksBecause: askAllReason)) }
                return .ask(ClaudeFileCard(action: "Use \(label)", detail: inputSummary(ask.input), folder: nil, alwaysAsksBecause: nil, tool: tool))
            }
            return .ask(ClaudeFileCard(action: "Use \(tool)", detail: inputSummary(ask.input), folder: nil, alwaysAsksBecause: "Asks every time"))
        }
        let raw = str(ask.input, "file_path") ?? str(ask.input, "notebook_path") ?? str(ask.input, "path") ?? cwd
        let path = resolve(raw, cwd: cwd, home: home)
        if isSecret(path) { return .deny(credentialRefusal) }
        if tool == "Glob" || tool == "Grep", let pat = str(ask.input, "pattern"), isSecret(pat) || mentionsSecret(pat) { return .deny(credentialRefusal) }
        if tool == "Upload", uploadType(path) == nil { return .deny(uploadRefusal) }
        let isFile = !(tool == "Glob" || tool == "Grep" || tool == "LS")
        var folder = isFile ? (path as NSString).deletingLastPathComponent : path
        if folder.isEmpty { folder = "/" }
        let inLibrary = inside(path, home + "/Library")
        if !askAll, !inLibrary, folders.contains(where: { inside(path, $0) }) { return .allow }
        // Temporary files: shell commands always allowed already reach them, so reading and uploading them doesn't ask either.
        if !askAll, shell != nil, ClaudeKindGrants.isTemp(path) { return .allow }
        let action: String
        switch tool {
        case "Read": action = "Read a file"
        case "Write": action = "Write a file"
        case "Edit", "MultiEdit": action = "Change a file"
        case "Grep": action = "Search inside files"
        case "Upload": action = "Upload \((path as NSString).lastPathComponent) to MUSE"
        default: action = "List a folder"
        }
        var detail = path
        if tool == "Glob" || tool == "Grep", let pat = str(ask.input, "pattern") { detail += " · \(pat)" }
        if askAll { return .ask(ClaudeFileCard(action: action, detail: detail, folder: nil, alwaysAsksBecause: askAllReason)) }
        if let wide = ClaudeAlwaysRules.tooWide(folder, home: home) {
            return .ask(ClaudeFileCard(action: action, detail: detail, folder: nil, alwaysAsksBecause: "Always asks: \(wide)"))
        }
        // The project, not the one subfolder (stills/ and clips/ of the same shoot), ci_c64e3cab2c7f.
        let project = ClaudeKindGrants.projectFolder(folder, home: home)
        return .ask(ClaudeFileCard(action: action, detail: detail, folder: ClaudeAlwaysRules.tooWide(project, home: home) == nil ? project : folder, alwaysAsksBecause: nil))
    }

    static func inputSummary(_ v: JSONValue?) -> String {
        guard let v, let d = try? JSONEncoder().encode(v) else { return "" }
        return String(String(decoding: d, as: UTF8.self).prefix(300))
    }

    /// Claude Code's own deny rules, a second wall behind the card (Read rules also cover Grep and Glob).
    public static let denyRules: [String] = {
        let reads = ["~/.ssh/**", "~/.aws/**", "~/.gnupg/**", "~/.claude/**", "~/.kube/**", "~/.docker/**", "~/Library/Keychains/**",
                     "**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/*.p12", "**/id_rsa*", "**/id_ed25519*", "**/.netrc", "**/.git-credentials", "**/.mcp-*.json"]
        return reads.map { "Read(\($0))" } + reads.map { "Edit(\($0))" }
    }()
}

public enum ClaudePermissionAnswer: Hashable, Sendable {
    case allowOnce
    /// "Allow always": the card's folder, or its command rule and folders, for every chat on this Mac.
    case always
    case deny
}

/// What upload_local_file's Mac side sends back once the file is up.
public struct ClaudeLocalUpload: Codable, Hashable, Sendable {
    public var uploadId: String
    /// "image", "clip" (a video) or "audio".
    public var kind: String
    public var url: String?
    public var name: String?
    /// A sound's length (add_music needs it; ci_de89873ab1de).
    public var durationSec: Double?
    public init(uploadId: String, kind: String, url: String? = nil, name: String? = nil, durationSec: Double? = nil) {
        self.uploadId = uploadId
        self.kind = kind
        self.url = url
        self.name = name
        self.durationSec = durationSec
    }
}

/// What this Mac does with a question, for the server and so for Claude (`POST /v1/claude/permissions/:id/progress`):
/// "asking" (its card is up), "uploading" (bytes so far of the total; try n), "confirming" (the server checks the file).
public struct ClaudePermissionProgress: Codable, Hashable, Sendable {
    public var phase: String
    public var sentBytes: Int?
    public var totalBytes: Int?
    public var attempt: Int?
    public init(phase: String, sentBytes: Int? = nil, totalBytes: Int? = nil, attempt: Int? = nil) {
        self.phase = phase
        self.sentBytes = sentBytes
        self.totalBytes = totalBytes
        self.attempt = attempt
    }
    public static let asking = ClaudePermissionProgress(phase: "asking")
    public static let confirming = ClaudePermissionProgress(phase: "confirming")

    /// At most every 2 s (or a 5% step) while uploading, so a big file doesn't send hundreds of requests.
    public static func shouldSend(fraction: Double, lastFraction: Double, now: Double, lastAt: Double) -> Bool {
        fraction >= 1 || fraction - lastFraction >= 0.05 || now - lastAt >= 2
    }
}

/// upload_local_file on the Mac: turns the upload's progress into the few reports the server needs (throttled, in order):
/// uploading n of total bytes (try k), then "confirming" once every byte is up.
public final class ClaudeUploadReporter: @unchecked Sendable {
    public let total: Int
    private let send: @Sendable (ClaudePermissionProgress) async -> Void
    private let now: @Sendable () -> Double
    private let lock = NSLock()
    private var lastFraction = -1.0
    private var lastAt = 0.0
    private var attempt = 1
    private var confirming = false
    private var chain: Task<Void, Never>?

    public init(total: Int, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                send: @escaping @Sendable (ClaudePermissionProgress) async -> Void) {
        self.total = total
        self.now = now
        self.send = send
    }

    /// The upload began (the person said yes, or the folder is always allowed).
    public func started() async {
        await send(ClaudePermissionProgress(phase: "uploading", sentBytes: 0, totalBytes: total, attempt: 1))
    }

    /// For the uploader's progress callback (0…1).
    public var progress: UploadProgress { { [self] f in self.on(f) } }
    /// For the uploader's retry callback (try n is starting).
    public var retry: @Sendable (Int) -> Void { { [self] n in self.onRetry(n) } }

    func on(_ f: Double) {
        lock.lock()
        var out: ClaudePermissionProgress?
        let t = now()
        if f >= 1 {
            if !confirming { confirming = true; out = .confirming }
        } else if !confirming, ClaudePermissionProgress.shouldSend(fraction: f, lastFraction: lastFraction, now: t, lastAt: lastAt) {
            lastFraction = f
            lastAt = t
            out = ClaudePermissionProgress(phase: "uploading", sentBytes: Int((Double(total) * max(0, f)).rounded()), totalBytes: total, attempt: attempt)
        }
        lock.unlock()
        if let out { enqueue(out) }
    }

    func onRetry(_ n: Int) {
        lock.lock()
        attempt = n
        lastFraction = -1
        lastAt = now()
        confirming = false
        lock.unlock()
        enqueue(ClaudePermissionProgress(phase: "uploading", sentBytes: 0, totalBytes: total, attempt: n))
    }

    /// Reports go out one after another, so "confirming" never lands before the last byte count.
    private func enqueue(_ p: ClaudePermissionProgress) {
        lock.lock()
        let prev = chain
        let send = self.send
        let next = Task { _ = await prev?.value; await send(p) }
        chain = next
        lock.unlock()
    }

    /// Waits for every report sent so far (tests).
    public func flushed() async { let c = lock.withLock { chain }; _ = await c?.value }
}
