import Foundation

/// "Always allow" by KIND (owner report ci_c64e3cab2c7f, 2026-11-15: "Always allow does not stick: I'm asked again every
/// time, in every session"). The 2026-11-12 rules were too narrow to ever match real work: a rule per program
/// ("ffmpeg commands" did not cover "ffprobe" or "python3 scripts"), nothing chained (`cd … && ffmpeg … && ffmpeg …`, a `for`
/// loop, a `$f`) ever offered "Allow always", a python script that called ffmpeg through subprocess never did, files in
/// /tmp never did (a "top-level folder"), a file grant covered only that file's own subfolder (stills/ but not clips/), and
/// MUSE's own tools had no "Allow always" at all. One "Allow always" now covers the kind:
/// - shell commands: one switch, scoped to the allowed folders, the chat's own folder and temporary files (or anywhere);
/// - reading, writing and uploading files: the whole project folder (~/Desktop/GRWM, not just ~/Desktop/GRWM/stills) and
///   temporary files;
/// - each MUSE tool by name.
/// Kept for every chat on this Mac and across launches (ClaudeFileSettings, stored per person), listed in Settings → Claude
/// with Remove. The hard walls stay: keys, passwords and tokens are refused outright; admin rights, deleting, moving,
/// the network and installs, stopping programs and other apps always ask; ~/Library is never always allowed.
public enum ClaudeShellScope: String, Codable, CaseIterable, Sendable {
    /// Paths a command names must be inside the allowed folders, the chat's folder or temporary files.
    case folders
    /// Any path (still never ~/Library, never keys).
    case anywhere

    public var label: String { self == .folders ? "Inside your folders and temporary files" : "Anywhere on this Mac" }
    /// For the Settings picker (a narrow column): "Folders + temp", "Anywhere".
    public var shortLabel: String { self == .folders ? "Folders + temp" : "Anywhere" }
}

/// What "Allow always: shell commands" makes of one command.
public struct ClaudeShellCheck: Hashable, Sendable {
    /// Why it always asks (one line, no "Always asks:" prefix); nil when the kind covers it.
    public var why: String?
    /// Folders outside the allowed ones it reaches (scoped only); "Allow always" adds them.
    public var needFolders: [String] = []
    public var clean: Bool { why == nil && needFolders.isEmpty }
}

public enum ClaudeKindGrants {
    // MARK: Temporary files

    /// /tmp (macOS: /private/tmp, which `resolve` turns into /tmp) and the per-user temp folder (/var/folders/xx/yyyy/T).
    public static func isTemp(_ path: String) -> Bool { tempRoot(path) != nil }

    /// The temporary folder a path is in: "/tmp" or "/var/folders/xx/yyyy/T"; nil when it isn't in one.
    public static func tempRoot(_ path: String) -> String? {
        if ClaudeFilePolicy.inside(path, "/tmp") { return "/tmp" }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 5, parts[0] == "var", parts[1] == "folders", parts[4] == "T" { return "/" + parts[0..<5].joined(separator: "/") }
        return nil
    }

    // MARK: The project folder

    /// The folder "Allow always" saves for a file in `folder`: the project, not the one subfolder. Inside the home folder
    /// that is two levels down (~/Desktop/GRWM for ~/Desktop/GRWM/stills/a.png; ~/Desktop for a file right on the
    /// Desktop); on a disk, the folder at the disk's top (/Volumes/Work/Footage); temporary files: their temp folder.
    public static func projectFolder(_ folder: String, home: String) -> String {
        if let t = tempRoot(folder) { return t }
        if ClaudeFilePolicy.inside(folder, home), folder != home {
            let rel = folder.dropFirst(home.count).split(separator: "/").map(String.init)
            if rel.first == "Library" { return folder }
            return home + "/" + rel.prefix(2).joined(separator: "/")
        }
        let parts = folder.split(separator: "/").map(String.init)
        if parts.first == "Volumes", parts.count > 3 { return "/" + parts.prefix(3).joined(separator: "/") }
        return folder
    }

    // MARK: MUSE tools

    /// A tool of an MCP server Claude Code runs with ("mcp__muse__get_frame", "mcp__blender__get_scene_info").
    public static func isServerTool(_ name: String) -> Bool {
        name.hasPrefix("mcp__") && name != ClaudeCommand.permissionPromptTool && name.split(separator: "_", omittingEmptySubsequences: true).count >= 2
    }

    /// "get_frame" for mcp__muse__get_frame, "blender get_scene_info" for another server's tool.
    public static func toolLabel(_ name: String) -> String {
        if name.hasPrefix("mcp__muse__") { return String(name.dropFirst("mcp__muse__".count)) }
        let rest = name.dropFirst("mcp__".count)
        if let r = rest.range(of: "__") { return "\(rest[..<r.lowerBound]) \(rest[r.upperBound...])" }
        return String(rest)
    }

    // MARK: Shell commands

    /// Words that are commands in a shell but ordinary names in code typed into one (`python3 -c "open(…)"`): they count
    /// only where a command starts.
    static let codeWords: Set<String> = ["open", "defaults", "security", "port", "mount", "file", "time", "kill"]

    /// Read-only places a command may name in any scope (programs, fonts, /dev/null).
    static let harmlessPrefixes = ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin", "/usr", "/bin", "/sbin", "/opt/homebrew",
                                   "/System/Library/Fonts", "/Library/Fonts"]

    static func harmless(_ p: String) -> Bool { harmlessPrefixes.contains { ClaudeFilePolicy.inside(p, $0) } }

    /// Absolute or ~ paths written inside a word (code, option values, `concat:/a|/b`).
    static let embeddedPath = try! NSRegularExpression(pattern: #"(?:^|[\s"'(=,:|<>\[{])(~/[^\s"'),;|\]}]*|/[A-Za-z][^\s"'),;|\]}]*)"#,
                                                         options: [.anchorsMatchLines])

    /// What "Allow always: shell commands" makes of `command`. Chains, pipes, loops, variables, interpreters and scripts
    /// are all the one kind; what still asks is what can hurt beyond the folders: admin rights, deleting, moving, the
    /// network and installs, stopping programs, other apps and system settings, ~/Library, keys, and (scoped) paths
    /// outside the folders. `folders` are the allowed folders; the chat's folder (`cwd`) and temporary files always count.
    public static func shellCheck(_ command: String, scope: ClaudeShellScope, folders: [String], cwd: String, home: String,
                                  isDirectory: (String) -> Bool = { _ in false }, readScript: (String) -> String? = { _ in nil }) -> ClaudeShellCheck {
        var r = ClaudeShellCheck()
        guard let tokens = ClaudeAlwaysRules.lex(command) else { r.why = "MUSE can't read this command"; return r }
        // The programs: the first word of each command (after ; && || | ( and the shell's own keywords).
        var programs: Set<String> = []
        var atStart = true
        let keywords: Set<String> = ["do", "then", "else", "elif", "if", "while", "until", "for", "in", "!", "{", "}", "done", "fi", "time"]
        for t in tokens {
            switch t {
            case .op(let op):
                if op.contains(">") || op.contains("<") { continue }   // a redirect: the same command goes on
                atStart = true
            case .word(let w):
                if atStart {
                    let name = (w.text as NSString).lastPathComponent.lowercased()
                    if keywords.contains(name) { continue }
                    // `VAR=value cmd`: the program comes after.
                    if let eq = w.text.firstIndex(of: "="), w.text[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !w.text.hasPrefix("=") { continue }
                    programs.insert(name)
                    atStart = false
                }
            }
        }
        // The hard kinds: wherever the word is (a `bash -c "rm …"` too), except plain code words outside a command's start.
        let words = Set(ClaudeAlwaysRules.words(command)).subtracting(codeWords).union(programs)
        for (set, why) in ClaudeAlwaysRules.riskWords where !words.isDisjoint(with: set) { r.why = why; return r }
        for p in programs where ["git"].contains(p) {
            // git: history-changing subcommands still ask, as before.
            let parts = ClaudeAlwaysRules.words(command)
            if let i = parts.firstIndex(of: "git"), parts.dropFirst(i + 1).contains(where: { ClaudeAlwaysRules.gitRisky.contains($0) }) {
                r.why = "it can change or send your git history"; return r
            }
        }
        if programs.contains("find"), command.contains("-delete") { r.why = "it deletes files"; return r }
        // Network addresses anywhere.
        for case .word(let w) in tokens {
            if w.text.contains("://") { r.why = "it uses the network or installs software"; return r }
            if let c = w.text.firstIndex(of: ":"), ClaudeAlwaysRules.networkSchemes.contains(w.text[..<c].lowercased()) {
                r.why = "it uses the network or installs software"; return r
            }
        }

        if scope == .folders, ["expanduser", "path.home", "getenv", "environ"].contains(where: { command.lowercased().contains($0) }) {
            r.why = "it works outside your allowed folders"; return r
        }

        // Every path it names.
        let allowed = folders.filter { ClaudeAlwaysRules.tooWide($0, home: home) == nil }
        func inScope(_ p: String) -> Bool {
            harmless(p) || isTemp(p) || ClaudeFilePolicy.inside(p, cwd) || allowed.contains { ClaudeFilePolicy.inside(p, $0) }
        }
        var need: [String] = []
        var runCwd = cwd
        var prevWasCd = false
        var scripts: [String] = []
        var prevProgram: String?
        func consider(_ p: String) -> String? {
            if ClaudeFilePolicy.isSecret(p) { return "it names keys, passwords or tokens" }
            if ClaudeFilePolicy.inside(p, home + "/Library") { return "it reaches a folder that can't be always allowed (it's in ~/Library)" }
            if scope == .anywhere || inScope(p) { return nil }
            let dir = isDirectory(p) ? p : (p as NSString).deletingLastPathComponent
            let folder = projectFolder(dir.isEmpty ? "/" : dir, home: home)
            if let wide = ClaudeAlwaysRules.tooWide(folder, home: home) { return "it reaches a folder that can't be always allowed (\(wide))" }
            if !need.contains(where: { ClaudeFilePolicy.inside(folder, $0) }) {
                need.removeAll { ClaudeFilePolicy.inside($0, folder) }
                need.append(folder)
            }
            return nil
        }
        atStart = true
        for t in tokens {
            guard case .word(let w) = t else {
                if case .op(let op) = t, !(op.contains(">") || op.contains("<")) { atStart = true; prevProgram = nil }
                prevWasCd = false
                continue
            }
            var text = w.text
            for v in ["${HOME}", "$HOME"] where text.hasPrefix(v) { text = home + text.dropFirst(v.count) }
            for v in ["${TMPDIR}", "$TMPDIR"] where text.hasPrefix(v) { text = "/tmp" + text.dropFirst(v.count) }
            let isProgram = atStart
            if atStart {
                let name = (text as NSString).lastPathComponent.lowercased()
                if !keywords.contains(name), !(text.contains("=") && !text.hasPrefix("/")) { atStart = false; prevProgram = name }
            }
            if text.hasPrefix("~"), text != "~", !text.hasPrefix("~/") { r.why = "MUSE can't tell which files it reaches"; return r }
            // A path with a variable in it ("/tmp/grwm/${f%.mp4}.png"): the folder before the variable counts.
            if text.contains("$"), text.hasPrefix("/") || text.hasPrefix("~/") {
                let lit = String(text[..<text.firstIndex(of: "$")!])
                let dir = lit.hasSuffix("/") ? lit : (lit as NSString).deletingLastPathComponent
                if let why = consider(ClaudeFilePolicy.resolve(dir.isEmpty ? "/" : dir, cwd: runCwd, home: home) + "/x") { r.why = why; return r }
            }
            // An option with a path glued on ("-o/etc/x"): that path counts.
            if text.hasPrefix("-"), !text.contains("="), let i = text.firstIndex(where: { $0 == "/" || $0 == "~" }), !text.contains("$") {
                if let why = consider(ClaudeFilePolicy.resolve(String(text[i...]), cwd: runCwd, home: home)) { r.why = why; return r }
            }
            let pathLike = text.hasPrefix("/") || text.hasPrefix("~") || (text.contains("/") && text.split(separator: "/").contains(".."))
                || (prevWasCd && !text.contains("$")) || (!text.hasPrefix("-") && text.contains(where: { "*?".contains($0) }))
            if pathLike && !text.contains("$") {
                guard let ps = ClaudeAlwaysRules.paths(in: text, cwd: runCwd, home: home) else { r.why = "MUSE can't tell which files it reaches"; return r }
                for p in ps where !(isProgram && harmless(p)) { if let why = consider(p) { r.why = why; return r } }
                if prevWasCd, let p = ps.first { runCwd = p }
            }
            if !(text.hasPrefix("/") || text.hasPrefix("~")) {
                // Paths inside the word: code typed into the command, an option's value.
                let ns = text as NSString
                for m in embeddedPath.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    var p = ns.substring(with: m.range(at: 1))
                    if p.contains("$") { p = String(p[..<p.firstIndex(of: "$")!]) }
                    if p.isEmpty || p == "/" && text.contains("$") { continue }
                    if let why = consider(ClaudeFilePolicy.resolve(p, cwd: runCwd, home: home)) { r.why = why; return r }
                }
            }
            if let prog = prevProgram, !isProgram, ClaudeAlwaysRules.interpreters.contains(prog), !text.hasPrefix("-"),
               !text.contains("$"), text.contains(".") {
                scripts.append(ClaudeFilePolicy.resolve(text, cwd: runCwd, home: home))
                prevProgram = nil
            }
            prevWasCd = isProgram && text == "cd"
        }
        r.needFolders = need
        // A script it runs: keys, the network and (scoped) its paths, like the command itself.
        for sp in scripts {
            guard let text = readScript(sp) else { continue }
            if let why = scriptCheck(text, scope: scope, folders: allowed + need, cwd: cwd, home: home) { r.why = "the script \(why.replacingOccurrences(of: "it ", with: ""))"; return r }
        }
        return r
    }

    /// Calls in a script that reach the network or need admin rights (deleting inside the folders is the person's own work).
    static let scriptNetwork = ["socket", "requests", "urllib", "http.client", "httpx", "aiohttp", "ftplib", "smtplib", "fetch(", "require('http",
                                "require(\"http", "net/http", "sudo "]

    static func scriptCheck(_ text: String, scope: ClaudeShellScope, folders: [String], cwd: String, home: String) -> String? {
        if text.utf8.count > 512 * 1024 { return "it is too long to check" }
        let lower = text.lowercased()
        for n in scriptNetwork where lower.contains(n) { return n == "sudo " ? "it needs admin rights" : "it uses the network" }
        if scope == .folders, ["expanduser", "path.home", "$home", "getenv", "environ"].contains(where: { lower.contains($0) }) {
            return "it works outside your allowed folders"
        }
        let ns = text as NSString
        for m in embeddedPath.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if text.hasPrefix("#!"), m.range.location < ns.range(of: "\n").location { continue }
            let p = ClaudeFilePolicy.resolve(ns.substring(with: m.range(at: 1)), cwd: cwd, home: home)
            if ClaudeFilePolicy.isSecret(p) { return "it names keys, passwords or tokens" }
            if ClaudeFilePolicy.inside(p, home + "/Library") { return "it works in ~/Library" }
            if scope == .anywhere || harmless(p) || isTemp(p) || ClaudeFilePolicy.inside(p, cwd) || folders.contains(where: { ClaudeFilePolicy.inside(p, $0) }) { continue }
            return "it works outside your allowed folders"
        }
        return nil
    }
}
