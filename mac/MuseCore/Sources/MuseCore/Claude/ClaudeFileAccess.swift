import Foundation

/// Files on this Mac (owner, 2026-11-11): Claude Code in the one-Claude panel may read and write files and run commands on
/// the person's own Mac, but only after they say yes. Claude Code runs with
/// `--permission-prompt-tool mcp__muse__permission_prompt`; each question reaches the app as a `permission` live event
/// and becomes an approval card in the chat (Allow once · Always allow in this folder · Deny). Keys, passwords and tokens
/// are refused even when approved.
public enum ClaudeFileMode: String, Codable, CaseIterable, Sendable {
    /// Ask every time (the default).
    case ask
    /// Off: no file tools at all (Claude Code runs with MUSE's tools only, as before).
    case off

    public var label: String { self == .ask ? "Ask every time" : "Off" }
}

/// One folder the person always allows, for one chat.
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

/// The person's file settings on this Mac (stored per person in the app's defaults).
public struct ClaudeFileSettings: Codable, Hashable, Sendable {
    public var mode: ClaudeFileMode = .ask
    public var folders: [ClaudeAllowedFolder] = []
    public init(mode: ClaudeFileMode = .ask, folders: [ClaudeAllowedFolder] = []) {
        self.mode = mode
        self.folders = folders
    }

    public func folders(chatId: String) -> [String] { folders.filter { $0.chatId == chatId }.map(\.folder) }

    public mutating func allow(_ folder: String, chatId: String, chatTitle: String?) {
        guard !folders.contains(where: { $0.chatId == chatId && $0.folder == folder }) else { return }
        folders.append(ClaudeAllowedFolder(folder: folder, chatId: chatId, chatTitle: chatTitle))
    }

    public mutating func remove(_ id: String) { folders.removeAll { $0.id == id } }

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
    /// The folder "Always allow" would cover; nil when this kind of call always asks.
    public var folder: String?
    /// Why it always asks (deletes, moves, network, sudo, commands).
    public var alwaysAsksBecause: String?
}

public enum ClaudeFilePolicy {
    public static let credentialRefusal = "MUSE never lets Claude read or change keys, passwords or tokens (.env, SSH keys, keychains, credential files), even with your approval."
    public static let offRefusal = "Files on this Mac are off for Claude (Settings → Claude)."

    /// The tools a file-enabled run lets Claude ask for (Web stays off).
    public static let fileTools: Set<String> = ["Read", "Glob", "Grep", "LS", "Write", "Edit", "MultiEdit", "Bash"]
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
        return "/" + out.joined(separator: "/")
    }

    public static func inside(_ path: String, _ folder: String) -> Bool {
        let f = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == f || path.hasPrefix(f + "/")
    }

    /// Commands that never get "Always": deletes, moves, network, admin, installs.
    public static func riskyCommand(_ command: String) -> String? {
        let words = Set(command.lowercased().components(separatedBy: CharacterSet(charactersIn: " \t\n;|&()`$")).filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent })
        if !words.isDisjoint(with: ["rm", "rmdir", "unlink", "shred", "trash", "srm"]) { return "it deletes" }
        if !words.isDisjoint(with: ["mv", "rsync", "ditto"]) { return "it moves files" }
        if !words.isDisjoint(with: ["sudo", "su", "doas", "chown", "launchctl"]) { return "it needs admin rights" }
        if !words.isDisjoint(with: ["curl", "wget", "ssh", "scp", "sftp", "nc", "ncat", "telnet", "ftp", "git", "npm", "npx", "pip", "pip3", "brew", "gh", "open", "osascript", "ping"]) {
            return "it can reach the network"
        }
        return nil
    }

    static func str(_ input: JSONValue?, _ k: String) -> String? {
        if case .object(let o)? = input, case .string(let s)? = o[k], !s.isEmpty { return s }
        return nil
    }

    /// What to do with one question. `cwd` is the run's folder (~/MUSE/Claude/<chat>); `folders` are this chat's
    /// always-allowed folders.
    public static func verdict(_ ask: ClaudePermissionAsk, mode: ClaudeFileMode, folders: [String], cwd: String, home: String) -> ClaudeFileVerdict {
        guard mode == .ask else { return .deny(offRefusal) }
        let tool = ask.toolName
        if tool == "Bash" {
            let cmd = str(ask.input, "command") ?? ""
            if cmd.isEmpty { return .deny("Empty command") }
            if mentionsSecret(cmd) { return .deny(credentialRefusal) }
            // Every command asks: a folder can't vouch for what a command does.
            return .ask(ClaudeFileCard(action: "Run a command", detail: cmd, folder: nil,
                                       alwaysAsksBecause: riskyCommand(cmd).map { "Always asks: \($0)" } ?? "Commands ask every time"))
        }
        guard fileTools.contains(tool) else {
            return .ask(ClaudeFileCard(action: "Use \(tool)", detail: inputSummary(ask.input), folder: nil, alwaysAsksBecause: "Asks every time"))
        }
        let raw = str(ask.input, "file_path") ?? str(ask.input, "notebook_path") ?? str(ask.input, "path") ?? cwd
        let path = resolve(raw, cwd: cwd, home: home)
        if isSecret(path) { return .deny(credentialRefusal) }
        if tool == "Glob" || tool == "Grep", let pat = str(ask.input, "pattern"), isSecret(pat) || mentionsSecret(pat) { return .deny(credentialRefusal) }
        let isFile = !(tool == "Glob" || tool == "Grep" || tool == "LS")
        let folder = isFile ? (path as NSString).deletingLastPathComponent : path
        if folders.contains(where: { inside(path, $0) }) { return .allow }
        let action: String
        switch tool {
        case "Read": action = "Read a file"
        case "Write": action = "Write a file"
        case "Edit", "MultiEdit": action = "Change a file"
        case "Grep": action = "Search inside files"
        default: action = "List a folder"
        }
        var detail = path
        if tool == "Glob" || tool == "Grep", let pat = str(ask.input, "pattern") { detail += " · \(pat)" }
        return .ask(ClaudeFileCard(action: action, detail: detail, folder: folder.isEmpty ? "/" : folder, alwaysAsksBecause: nil))
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
    case alwaysFolder(String)
    case deny
}
