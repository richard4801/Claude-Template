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
    /// It runs code Claude wrote (typed in, or fed by a here-document) or installs Python packages with uv.
    public var code: Bool = false
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

    /// Programs that run code given to them: the code typed into the command (`-c`, `-e`) or fed in by a here-document is
    /// "code Claude wrote" (bundle-24). Shells' code is shell, checked like the command itself.
    static func isInterpreter(_ name: String) -> Bool {
        name.hasPrefix("python") || ["node", "nodejs", "ruby", "perl", "deno", "bun", "bash", "sh", "zsh"].contains(name)
    }
    static func isShell(_ name: String) -> Bool { ["bash", "sh", "zsh"].contains(name) }
    static let codeFlags: Set<String> = ["-c", "-e", "-p", "--eval", "--print", "-ce", "-pe"]

    /// Calls in code Claude wrote that still ask with "Let Claude run code it writes" on (owner, bundle-24).
    static let codeRisks: [(String, String)] = [
        ("subprocess", "runs other programs"), ("os.system", "runs other programs"), ("os.popen", "runs other programs"),
        ("os.exec", "runs other programs"), ("os.spawn", "runs other programs"), ("child_process", "runs other programs"),
        ("execsync", "runs other programs"), ("pty.spawn", "runs other programs"), ("system(", "runs other programs"),
        ("shutil.rmtree", "deletes files"), ("rmtree(", "deletes files"), ("os.remove", "deletes files"), ("os.unlink", "deletes files"),
        ("os.rmdir", "deletes files"), (".unlink(", "deletes files"), (".rmdir(", "deletes files"), ("fs.rm", "deletes files"),
        ("fs.unlink", "deletes files"), ("unlinksync", "deletes files"), ("file.delete", "deletes files"),
        ("urllib", "uses the network"), ("requests", "uses the network"), ("http.client", "uses the network"), ("httpx", "uses the network"),
        ("aiohttp", "uses the network"), ("socket", "uses the network"), ("ftplib", "uses the network"), ("smtplib", "uses the network"),
        ("fetch(", "uses the network"), ("require('http", "uses the network"), ("require(\"http", "uses the network"), ("net/http", "uses the network"),
        ("https.get", "uses the network"), ("http.get", "uses the network"),
        ("osascript", "controls other apps"), ("appscript", "controls other apps"), ("applescript", "controls other apps"),
        ("sudo ", "needs admin rights"),
    ]

    public static let codeReason = "it runs code Claude wrote (Settings → Claude can allow this)"
    public static let codeAndPackagesReason = "it runs code Claude wrote and installs Python packages (Settings → Claude can allow this)"
    public static let packagesReason = "it installs Python packages with uv (Settings → Claude can allow this)"

    /// What "Allow always: shell commands" makes of `command`. Chains, pipes, loops, variables and script files are all
    /// the one kind; what still asks is what can hurt beyond the folders: admin rights, deleting, moving, the network and
    /// installs, stopping programs, other apps and system settings, ~/Library, keys, and (scoped) paths outside the folders.
    /// Code Claude typed into the command (`python3 -c`, `node -e`, a here-document fed to python or bash, `uv run … python`)
    /// still asks when it deletes, runs programs, uses the network or controls apps; otherwise "shell commands" covers it,
    /// and `runCode` ("Let Claude run code it writes") lets it run without that grant and lets `uv --with` fetch packages. Risk words count only in
    /// the shell itself, never inside such code (the owner's `open(p)` in Python is not the macOS `open`). `folders` are
    /// the allowed folders; the chat's folder (`cwd`) and temporary files always count.
    public static func shellCheck(_ command: String, scope: ClaudeShellScope, folders: [String], cwd: String, home: String,
                                  runCode: Bool = false, isDirectory: (String) -> Bool = { _ in false },
                                  readScript: (String) -> String? = { _ in nil }, depth: Int = 0) -> ClaudeShellCheck {
        var r = ClaudeShellCheck()
        guard depth < 4 else { r.why = "MUSE can't read this command"; return r }
        guard let tokens = ClaudeAlwaysRules.lex(command) else { r.why = "MUSE can't read this command"; return r }
        let keywords: Set<String> = ["do", "then", "else", "elif", "if", "while", "until", "for", "in", "!", "{", "}", "done", "fi", "time"]
        func base(_ w: String) -> String { (w as NSString).lastPathComponent.lowercased() }
        func isAssign(_ w: String) -> Bool {
            guard let eq = w.firstIndex(of: "="), !w.hasPrefix("=") else { return false }
            return w[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        // Shell functions (`R() { uv run … python -I "$@"; }`): the interpreter each one runs.
        var functions: [String: String] = [:]
        for k in tokens.indices where k + 2 < tokens.count {
            guard case .word(let f) = tokens[k], tokens[k + 1] == .op("("), tokens[k + 2] == .op(")") else { continue }
            var interp: String?
            for t in tokens[(k + 3)...] {
                guard case .word(let w) = t else { continue }
                if w.text == "}" { break }
                if interp == nil, isInterpreter(base(w.text)) { interp = base(w.text) }
            }
            if let interp { functions[f.text.lowercased()] = interp }
        }
        // One pass: the programs, the code typed in (`-c CODE`), and what each here-document feeds.
        var programs: Set<String> = []
        var codeArgs: [Int: Bool] = [:]          // token index → it is shell code
        var heredocTargets: [String?] = []       // per `<<`, in order: the interpreter it feeds (nil: data, e.g. `cat > x`)
        var codes: [(String, Bool, Bool)] = []   // (code, is shell, from a here-document)
        var dataHeredocs: [String] = []
        var atStart = true
        var segInterp: String?
        var prevWord: String?
        var heredocIndex = 0
        for (idx, t) in tokens.enumerated() {
            switch t {
            case .op(let op):
                if op == "<<" || op == "<<-" { heredocTargets.append(segInterp); continue }
                if op.contains(">") || op.contains("<") { continue }   // a redirect: the same command goes on
                atStart = true; segInterp = nil; prevWord = nil
            case .heredoc(let body):
                let target = heredocIndex < heredocTargets.count ? heredocTargets[heredocIndex] : nil
                heredocIndex += 1
                if let target { codes.append((body, isShell(target), true)) } else { dataHeredocs.append(body) }
            case .word(let w):
                let name = base(w.text)
                if atStart {
                    if keywords.contains(name) || isAssign(w.text) { continue }
                    programs.insert(name)
                    atStart = false
                    if let f = functions[name] { segInterp = f }
                }
                if segInterp == nil, isInterpreter(name) { segInterp = name }
                if let interp = segInterp, let pw = prevWord, codeFlags.contains(pw) {
                    codeArgs[idx] = isShell(interp)
                    codes.append((w.text, isShell(interp), false))
                }
                prevWord = w.text
            }
        }
        // A here-document saved to a file in a command that also runs an interpreter (`cat > a.py <<EOF … EOF; python3 a.py`)
        // is code Claude wrote too.
        if !dataHeredocs.isEmpty, programs.contains(where: isInterpreter) || !functions.isEmpty {
            codes += dataHeredocs.map { ($0, false, true) }
        }
        // The shell itself: every word but the code typed in.
        let shellWords = tokens.enumerated().compactMap { (i, t) -> String? in
            if case .word(let w) = t, codeArgs[i] == nil { return w.text }
            return nil
        }
        let shellText = shellWords.joined(separator: " ")
        let words = Set(ClaudeAlwaysRules.words(shellText)).subtracting(codeWords).union(programs)
        for (set, why) in ClaudeAlwaysRules.riskWords where !words.isDisjoint(with: set) { r.why = why; return r }
        if programs.contains("git") {
            // git: history-changing subcommands still ask, as before.
            let parts = ClaudeAlwaysRules.words(shellText)
            if let i = parts.firstIndex(of: "git"), parts.dropFirst(i + 1).contains(where: { ClaudeAlwaysRules.gitRisky.contains($0) }) {
                r.why = "it can change or send your git history"; return r
            }
        }
        if programs.contains("find"), shellWords.contains("-delete") { r.why = "it deletes files"; return r }
        // Network addresses in the shell's words.
        for w in shellWords {
            if w.contains("://") { r.why = "it uses the network or installs software"; return r }
            if let c = w.firstIndex(of: ":"), ClaudeAlwaysRules.networkSchemes.contains(w[..<c].lowercased()) {
                r.why = "it uses the network or installs software"; return r
            }
        }
        // `uv run --with numpy …` downloads packages from PyPI: allowed only with "Let Claude run code it writes".
        let lowerWords = shellWords.map { $0.lowercased() }
        let uvInstall = (programs.contains("uv") || programs.contains("uvx") || functions.values.contains { _ in lowerWords.contains("uv") })
            && lowerWords.contains { $0 == "--with" || $0.hasPrefix("--with=") || $0.hasPrefix("--with-requirements") || $0.hasPrefix("--with-editable") }

        // Code that reaches the home folder itself (`Path.home()`, `expanduser('~')`, `getenv('HOME')`): no folder to name, so it
        // asks. A `~/MUSE/…` written in the code is a path like any other (build 676: `expanduser` alone made the owner's
        // project command ask "outside your allowed folders" with no Always).
        if scope == .folders, homeMarkers.contains(where: { command.lowercased().contains($0) }) {
            r.why = "it works outside your allowed folders"; return r
        }

        // Every path it names.
        let allowed = folders.filter { ClaudeAlwaysRules.tooWide($0, home: home) == nil }
        func inScope(_ p: String) -> Bool {
            harmless(p) || isTemp(p) || ClaudeFilePolicy.inside(p, cwd) || isMuseFolder(p, home: home) || allowed.contains { ClaudeFilePolicy.inside(p, $0) }
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
        for (idx, t) in tokens.enumerated() {
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
            if codeArgs[idx] == nil, let prog = prevProgram, !isProgram, ClaudeAlwaysRules.interpreters.contains(prog), !text.hasPrefix("-"),
               !text.contains("$"), text.contains(".") {
                scripts.append(ClaudeFilePolicy.resolve(text, cwd: runCwd, home: home))
                prevProgram = nil
            }
            prevWasCd = isProgram && text == "cd"
        }
        // Paths written in code or a script: like the command's own, a folder outside the allowed ones that can be always
        // allowed is offered on the card (and added by Allow always), not refused.
        func scanPaths(_ text: String, base: String) -> String? {
            let ns = text as NSString
            let all = NSRange(location: 0, length: ns.length)
            // Quoted paths whole, spaces and all ("~/Movies/Gamified GRWM/a.png"), then unquoted ones outside them.
            let quoted = quotedPath.matches(in: text, range: all)
            for m in quoted {
                if let why = consider(ClaudeFilePolicy.resolve(ns.substring(with: m.range(at: 2)), cwd: base, home: home)) { return why }
            }
            for m in embeddedPath.matches(in: text, range: all) {
                if quoted.contains(where: { NSLocationInRange(m.range(at: 1).location, $0.range) }) { continue }
                if text.hasPrefix("#!"), m.range.location < ns.range(of: "\n").location { continue }
                var p = ns.substring(with: m.range(at: 1))
                if let d = p.firstIndex(of: "$") { p = String(p[..<d]) }
                if p.isEmpty { continue }
                if let why = consider(ClaudeFilePolicy.resolve(p, cwd: base, home: home)) { return why }
            }
            return nil
        }
        func plain(_ why: String) -> String { why.replacingOccurrences(of: "it ", with: "") }
        // A script it runs: keys, the network and (scoped) its paths, like the command itself.
        for sp in scripts {
            guard let text = readScript(sp) else { continue }
            if scope == .folders, homeMarkers.contains(where: { text.lowercased().contains($0) }) { r.why = "the script works outside your allowed folders"; return r }
            if let why = scanPaths(text, base: cwd) { r.why = "the script \(plain(why))"; return r }
            if let why = scriptCheck(text, scope: .anywhere, folders: [], cwd: cwd, home: home) { r.why = "the script \(plain(why))"; return r }
        }
        // Code Claude wrote: shell code is checked like the command; other code for what still asks with the switch on.
        for (code, shell, _) in codes {
            if shell {
                let inner = shellCheck(code, scope: scope, folders: allowed + need, cwd: runCwd, home: home, runCode: true,
                                       isDirectory: isDirectory, readScript: readScript, depth: depth + 1)
                if let why = inner.why { r.why = why; return r }
                for f in inner.needFolders where !need.contains(where: { ClaudeFilePolicy.inside(f, $0) }) { need.append(f) }
            } else {
                let lower = code.lowercased()
                for (needle, why) in codeRisks where lower.contains(needle) { r.why = "the code Claude wrote \(why)"; return r }
                if let why = scanPaths(code, base: runCwd) ?? scriptCheck(code, scope: .anywhere, folders: [], cwd: runCwd, home: home) {
                    r.why = "the code Claude wrote \(plain(why))"; return r
                }
            }
        }
        r.needFolders = need
        r.code = !codes.isEmpty || uvInstall
        // Code typed into the command (`python3 -c …`) with none of the risky calls above is part of "shell commands" (as
        // since bundle-22: a `python3 -c` read in /tmp must not ask again). A here-document of code and downloading packages
        // (`uv --with`) need "Let Claude run code it writes" (coordinator, build 676); the switch also lets code run without
        // the shell grant.
        let heredocCode = codes.contains { $0.2 }
        if !runCode, uvInstall || heredocCode {
            r.why = uvInstall ? (codes.isEmpty ? packagesReason : codeAndPackagesReason) : codeReason
            r.needFolders = []
        }
        return r
    }

    /// A path written as a string in code: from its opening quote to the same closing quote on that line.
    static let quotedPath = try! NSRegularExpression(pattern: #"(["'])((?:~/|/[A-Za-z])[^"'\n$]*)\1"#)

    /// Code that reaches the home folder itself: no folder to name or always allow.
    static let homeMarkers = ["path.home(", "homedir(", "expanduser('~')", "expanduser(\"~\")", "getenv('home')", "getenv(\"home\")",
                              "environ['home']", "environ[\"home\"]", "environ.get('home'", "environ.get(\"home\""]

    /// ~/MUSE, MUSE's own project folder: inside "Folders + temp" by default (coordinator, build 676).
    public static func isMuseFolder(_ p: String, home: String) -> Bool { ClaudeFilePolicy.inside(p, home + "/MUSE") }

    /// Calls in a script that reach the network or need admin rights (deleting inside the folders is the person's own work).
    static let scriptNetwork = ["socket", "requests", "urllib", "http.client", "httpx", "aiohttp", "ftplib", "smtplib", "fetch(", "require('http",
                                "require(\"http", "net/http", "sudo "]

    static func scriptCheck(_ text: String, scope: ClaudeShellScope, folders: [String], cwd: String, home: String) -> String? {
        if text.utf8.count > 512 * 1024 { return "it is too long to check" }
        let lower = text.lowercased()
        for n in scriptNetwork where lower.contains(n) { return n == "sudo " ? "it needs admin rights" : "it uses the network" }
        if scope == .folders, (homeMarkers + ["$home"]).contains(where: { lower.contains($0) }) {
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
