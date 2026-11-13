import Foundation

/// "Allow always" (owner, 2026-11-12: "When I give it access to a folder or bash once, it shouldn't ask again"). A command
/// rule is a kind of command: the program, plus its first subcommand where that is what decides what it does (`git status`),
/// or "scripts" for an interpreter (`python3 <script>`). A command matching a rule runs without a card only when every path
/// it names is inside an always-allowed folder (or the chat's own run folder), nothing in it can delete, move, reach the
/// network, install, need admin rights, stop programs, touch ~/Library or keys, and it is ONE plain command: no `;`, `||`,
/// `&`, `$( )`, backticks, variables or here-documents; the only extras allowed are a leading `cd <dir> &&` (dir inside the
/// folders) and a trailing pipe into plain filters (head, tail, grep, wc, sort, uniq, cut, tr). Everything else keeps asking; the dangerous kinds never offer
/// "Allow always" at all.
public struct ClaudeCommandRule: Codable, Hashable, Sendable, Identifiable {
    /// The program's name ("ffmpeg", "git", "python3").
    public var program: String
    /// Its first subcommand ("status" for git), "script" for an interpreter running a script file, nil for the program alone.
    public var sub: String?
    public init(program: String, sub: String? = nil) {
        self.program = program
        self.sub = sub
    }
    public var id: String { sub.map { "\(program) \($0)" } ?? program }
    /// "ffmpeg commands", "git status commands", "python3 scripts".
    public var label: String {
        if sub == ClaudeAlwaysRules.scriptSub { return "\(program) scripts" }
        return "\(id) commands"
    }
}

/// What MUSE makes of one command.
public struct ClaudeCommandCheck: Hashable, Sendable {
    /// The rule "Allow always" would save; nil when this command never offers it.
    public var rule: ClaudeCommandRule?
    /// Why it always asks (one line, no "Always asks:" prefix), when it does.
    public var why: String?
    /// Folders outside the allowed ones this command reaches; "Allow always" adds them too (all are allowable).
    public var needFolders: [String] = []
    /// The command may run without a card once its rule is saved (no folders missing, nothing risky).
    public var clean: Bool { rule != nil && why == nil && needFolders.isEmpty }
}

public enum ClaudeAlwaysRules {
    static let scriptSub = "script"

    // MARK: What never offers "Allow always"

    /// Words that make a command (or a script) always ask, wherever they appear in it, and the one-line why.
    static let riskWords: [(Set<String>, String)] = [
        (["rm", "rmdir", "unlink", "shred", "trash", "srm"], "it deletes files"),
        (["mv"], "it moves or renames files"),
        (["sudo", "su", "doas", "visudo"], "it needs admin rights"),
        (["chmod", "chown", "chgrp", "chflags", "xattr"], "it changes file permissions"),
        (["kill", "killall", "pkill"], "it stops programs"),
        (["curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "ncat", "netcat", "telnet", "ftp", "ping",
          "brew", "pip", "pip3", "npm", "npx", "yarn", "pnpm", "gem", "softwareupdate", "installer", "port"], "it uses the network or installs software"),
        (["osascript", "open", "launchctl", "defaults", "shutdown", "reboot", "halt", "diskutil", "csrutil", "tccutil", "security",
          "crontab", "systemsetup", "networksetup", "pmset", "mount", "umount", "kextload", "spctl", "dscl"], "it changes system settings or controls other apps"),
    ]

    /// Programs that run other commands or code given to them: never "Allow always".
    static let runners: Set<String> = ["xargs", "env", "eval", "exec", "source", ".", "nohup", "nice", "timeout", "time", "command",
                                       "builtin", "make", "sh", "bash", "zsh", "awk", "gawk", "sed", "perl", "ruby", "node", "python", "python3",
                                       "swift", "parallel", "watch", "script", "screen", "tmux", "at", "batch"]

    /// Programs that can be always allowed by name (media and reading tools; writes are checked against the folders).
    static let plainPrograms: Set<String> = ["ffmpeg", "ffprobe", "afconvert", "afinfo", "sips", "mdls", "exiftool", "mediainfo", "identify",
                                             "ls", "cat", "head", "tail", "wc", "file", "stat", "du", "pwd", "echo", "printf",
                                             "grep", "egrep", "fgrep", "rg", "find", "sort", "uniq", "cut", "tr", "diff", "cmp", "md5", "shasum",
                                             "basename", "dirname", "realpath", "mkdir", "touch", "cp", "tee", "jq"]

    /// Interpreters: "Allow always" covers their scripts (a file), never code typed into the command.
    static let interpreters: Set<String> = ["python3", "python", "node", "ruby", "perl", "bash", "sh", "zsh", "swift"]
    /// Interpreter options that are fine before the script; anything else (-c, -m, -e, …) asks every time.
    static func interpreterFlags(_ program: String) -> Set<String> {
        switch program {
        case "python3", "python": return ["-u", "-B", "-O", "-OO", "-s", "-E", "-I", "-q"]
        case "bash", "sh", "zsh": return ["-x"]
        default: return []
        }
    }

    /// git: subcommands that read or record locally may be always allowed; these change or send history and never are.
    static let gitSafe: Set<String> = ["status", "log", "diff", "show", "ls-files", "rev-parse", "blame", "shortlog", "describe", "grep", "add", "commit"]
    static let gitRisky: Set<String> = ["push", "pull", "fetch", "clone", "reset", "clean", "checkout", "switch", "restore", "rm", "mv", "rebase",
                                        "merge", "cherry-pick", "revert", "stash", "gc", "prune", "filter-branch", "filter-repo", "remote",
                                        "submodule", "config", "update-ref", "reflog", "branch", "tag", "worktree", "am", "apply", "init", "send-email"]

    /// Options of an always-allowable program that run something or delete: never "Allow always".
    static func riskyOption(_ program: String, _ arg: String) -> String? {
        switch program {
        case "find":
            if arg == "-delete" { return "it deletes files" }
            if ["-exec", "-execdir", "-ok", "-okdir"].contains(arg) { return "it runs other commands" }
            if arg.hasPrefix("-fprint") || arg == "-fls" { return "it writes files outside the command's output" }
        case "sort": if arg.hasPrefix("--compress-program") { return "it runs other commands" }
        case "rg": if arg.hasPrefix("--pre") { return "it runs other commands" }
        case "exiftool": if arg.lowercased().hasPrefix("-delete_original") { return "it deletes files" }
        case "git":
            if arg == "-O" || arg.hasPrefix("--open-files-in-pager") || arg.hasPrefix("--ext-diff") || arg.hasPrefix("--exec") { return "it runs other commands" }
        default: break
        }
        return nil
    }

    static let networkSchemes: Set<String> = ["http", "https", "ftp", "ftps", "tcp", "udp", "rtmp", "rtmps", "rtsp", "rtp", "srt", "tls", "unix",
                                              "sftp", "smb", "gopher", "ws", "wss", "mms", "hls", "icecast"]

    /// Paths that may be named without being in an allowed folder.
    static let harmless: Set<String> = ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin"]

    // MARK: Folders

    /// Why a folder can't be always allowed (too wide, a system folder, ~/Library), or nil when it can.
    public static func tooWide(_ folder: String, home: String) -> String? {
        let parts = folder.split(separator: "/").map(String.init)
        if ClaudeFilePolicy.inside(folder, home + "/Library") { return "it's in ~/Library" }
        if parts.count <= 1 { return "a top-level folder is too wide to always allow" }
        if folder == home || ClaudeFilePolicy.inside(home, folder) { return "your whole home folder is too wide to always allow" }
        if ["System", "Library", "usr", "bin", "sbin", "etc", "private", "var", "Applications", "opt", "dev", "cores", "Network"].contains(parts[0]) {
            return "it's a system folder"
        }
        if parts[0] == "Users", parts.count == 2 { return "a whole home folder is too wide to always allow" }
        if parts[0] == "Volumes", parts.count == 2 { return "a whole disk is too wide to always allow" }
        return nil
    }

    // MARK: Reading a command

    struct Word: Equatable {
        var text: String
        /// It expands at run time: a variable, `$( )`, backticks or braces (outside single quotes).
        var expands: Bool
    }
    enum Token: Equatable { case word(Word), op(String) }

    /// The command as the shell splits it (quotes removed), or nil when it can't be read (an open quote).
    static func lex(_ s: String) -> [Token]? {
        var out: [Token] = []
        var cur = "", inWord = false, expands = false, quotedAny = false
        func flush() {
            if inWord { out.append(.word(Word(text: cur, expands: expands))) }
            cur = ""; inWord = false; expands = false; quotedAny = false
        }
        let cs = Array(s)
        var i = 0
        while i < cs.count {
            let c = cs[i]
            switch c {
            case " ", "\t": flush()
            case "\n", "\r": flush(); out.append(.op(";"))
            case "'":
                inWord = true; quotedAny = true
                guard let end = cs[(i + 1)...].firstIndex(of: "'") else { return nil }
                cur += String(cs[(i + 1)..<end]); i = end
            case "\"":
                inWord = true; quotedAny = true
                var j = i + 1, closed = false
                while j < cs.count {
                    let d = cs[j]
                    if d == "\\", j + 1 < cs.count { cur.append(cs[j + 1]); j += 2; continue }
                    if d == "\"" { closed = true; break }
                    if d == "$" || d == "`" { expands = true }
                    cur.append(d); j += 1
                }
                guard closed else { return nil }
                i = j
            case "\\":
                guard i + 1 < cs.count else { return nil }
                if cs[i + 1] == "\n" { i += 2; continue }
                inWord = true; cur.append(cs[i + 1]); i += 1
            case "$", "`", "{", "}":
                inWord = true; expands = true; cur.append(c)
            case "#" where !inWord:
                // A comment: the shell ignores the rest of the line.
                while i < cs.count, cs[i] != "\n" { i += 1 }
                continue
            case ";", "&", "|", "(", ")", "<", ">":
                // "2>" and "2>>": a file-descriptor number glued to the redirect.
                var op = ""
                if (c == "<" || c == ">"), inWord, !quotedAny, !cur.isEmpty, cur.allSatisfy(\.isNumber) { op = cur; cur = ""; inWord = false }
                flush()
                op.append(c)
                let pairs: Set<String> = ["&&", "||", "|&", ";;", ">>", ">|", "&>", "<<", "<&", ">&", "<>"]
                while i + 1 < cs.count, pairs.contains(String(op.last!) + String(cs[i + 1])) || (op.hasSuffix("<<") && cs[i + 1] == "<") || (op == "&>" && cs[i + 1] == ">") {
                    op.append(cs[i + 1]); i += 1
                }
                out.append(.op(op))
            default:
                inWord = true; cur.append(c)
            }
            i += 1
        }
        flush()
        return out
    }

    /// Every lower-case word in the text, split at anything but letters, digits, `_ . + -` (so "/bin/rm" holds "rm").
    static func words(_ s: String) -> [String] {
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.+-"))
        return s.lowercased().components(separatedBy: keep.inverted).filter { !$0.isEmpty }
    }

    static func riskIn(_ s: String) -> String? {
        let w = Set(words(s))
        for (set, why) in riskWords where !w.isDisjoint(with: set) { return why }
        return nil
    }

    /// The paths one argument names: the whole word, and each part after `=`, `:`, `,`, `|` or `@` that starts like a path
    /// ("movie=/x", "concat:/a|/b"). nil when a part can't be judged (`~user`, a hidden folder matched by a pattern).
    static func paths(in arg: String, cwd: String, home: String) -> [String]? {
        var parts = [arg]
        parts += arg.components(separatedBy: CharacterSet(charactersIn: "=:,|@")).dropFirst().filter { $0.hasPrefix("/") || $0.hasPrefix("~") || $0.hasPrefix("..") }
        var out: [String] = []
        for p in parts where !p.isEmpty {
            if p.hasPrefix("~"), p != "~", !p.hasPrefix("~/") { return nil }
            // ".*" also matches "..": a pattern on a dot-segment can leave the folder.
            for seg in p.split(separator: "/") where seg.hasPrefix(".") && seg.contains(where: { "*?[".contains($0) }) { return nil }
            if p == arg, p.hasPrefix("-") {
                // An option: its "=…" parts were taken above; "-o/x" glues a path MUSE can't place.
                if !p.contains("="), p.contains("/") || p.contains("~") { return nil }
                continue
            }
            out.append(ClaudeFilePolicy.resolve(p, cwd: cwd, home: home))
        }
        return out
    }

    /// The plain command's own risks: one program, its arguments and redirects.
    struct Parsed { var argv: [String]; var targets: [String] }

    /// Programs a command may pipe into and still be covered by its rule: they only read their input and print.
    static let filters: Set<String> = ["head", "tail", "grep", "egrep", "fgrep", "wc", "sort", "uniq", "cut", "tr"]

    struct Why: Error { var text: String }
    struct Segment { var argv: [Word]; var targets: [String] }

    /// One simple command: its words and redirect targets (`2>&1` and `>&2` name none). Any other operator, or a
    /// here-document, fails with the one-line why.
    static func parseSegment(_ tokens: [Token]) -> Result<Segment, Why> {
        var argv: [Word] = [], targets: [String] = []
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case .word(let w): argv.append(w)
            case .op(let op):
                let redirect = op.last == ">" || op.last == "<" || op == ">|" || op.hasSuffix(">>") || op == "<>"
                if op.hasPrefix("<<") { return .failure(Why(text: "it feeds text into the command")) }
                if op.hasSuffix(">&") || op.hasSuffix("<&") {
                    // 2>&1 is fine; >&file writes a file.
                    guard i + 1 < tokens.count, case .word(let t) = tokens[i + 1] else { return .failure(Why(text: "MUSE can't read this command")) }
                    if t.expands { return .failure(Why(text: "it uses shell variables or substitutions")) }
                    if !(t.text == "-" || t.text.allSatisfy(\.isNumber)) { targets.append(t.text) }
                    i += 2; continue
                }
                if redirect {
                    guard i + 1 < tokens.count, case .word(let t) = tokens[i + 1] else { return .failure(Why(text: "MUSE can't read this command")) }
                    if t.expands { return .failure(Why(text: "it uses shell variables or substitutions")) }
                    targets.append(t.text)
                    i += 2; continue
                }
                return .failure(Why(text: "it chains several commands"))
            }
            i += 1
        }
        return .success(Segment(argv: argv, targets: targets))
    }

    // MARK: The check

    /// What MUSE makes of `command`: the rule it falls under, why it always asks, and the folders it reaches outside the
    /// allowed ones. `cwd` is the chat's run folder (Claude Code keeps its shell there). `isDirectory` tells a folder
    /// argument from a file one; `readScript` reads an interpreter's script so its contents can be checked too.
    public static func check(_ command: String, folders: [String], cwd: String, home: String,
                             isDirectory: (String) -> Bool = { _ in false }, readScript: (String) -> String? = { _ in nil }) -> ClaudeCommandCheck {
        var r = ClaudeCommandCheck()
        if let why = riskIn(command) { r.why = why; return r }
        if command.contains("$(") || command.contains("`") { r.why = "it uses shell variables or substitutions"; return r }
        // A folder too wide to always allow never counts, however it got on the list.
        let folders = folders.filter { tooWide($0, home: home) == nil }
        guard var tokens = lex(command) else { r.why = "MUSE can't read this command"; return r }
        // A leading `cd <dir> &&`: the rest runs in <dir>, which must be inside the folders like any other path.
        var runCwd = cwd
        var cdDir: String?
        if tokens.count >= 3, case .word(let c) = tokens[0], c.text == "cd", !c.expands, case .word(let d) = tokens[1], tokens[2] == .op("&&") {
            if d.expands { r.why = "it uses shell variables or substitutions"; return r }
            guard let ps = paths(in: d.text, cwd: cwd, home: home), ps.count == 1 else { r.why = "MUSE can't tell which files it reaches"; return r }
            runCwd = ps[0]
            cdDir = ps[0]
            tokens.removeFirst(3)
        }
        // A trailing pipe chain into plain filters only (`2>&1 | tail -n 40`).
        var segments: [[Token]] = [[]]
        for t in tokens {
            if t == .op("|") { segments.append([]) } else { segments[segments.count - 1].append(t) }
        }
        guard let main = segments.first, !main.isEmpty, segments.allSatisfy({ !$0.isEmpty }) else { r.why = "it chains several commands"; return r }
        var argv: [Word] = [], targets: [String] = []
        switch parseSegment(main) {
        case .failure(let why): r.why = why.text; return r
        case .success(let got): argv = got.argv; targets = got.targets
        }
        var filterArgs: [String] = []
        for seg in segments.dropFirst() {
            guard case .success(let got) = parseSegment(seg), let f = got.argv.first, !got.argv.contains(where: \.expands),
                  !f.text.contains("/"), filters.contains(f.text.lowercased()),
                  got.targets.allSatisfy({ harmless.contains($0) }) else { r.why = "it chains several commands"; return r }
            let fname = f.text.lowercased()
            for a in got.argv.dropFirst() { if let why = riskyOption(fname, a.text) { r.why = why; return r } }
            filterArgs += got.argv.dropFirst().map(\.text)
        }
        guard let first = argv.first else { r.why = "MUSE can't read this command"; return r }
        let name = (first.text as NSString).lastPathComponent.lowercased()
        for a in argv.dropFirst() { if let why = riskyOption(name, a.text) { r.why = why; return r } }
        if argv.contains(where: \.expands) { r.why = "it uses shell variables or substitutions"; return r }
        let args = argv.map(\.text)
        if let eq = args[0].firstIndex(of: "="), args[0][..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            r.why = "it sets environment variables"; return r
        }
        var program = (first.text as NSString).lastPathComponent
        if first.text.contains("/") {
            let dir = (first.text as NSString).deletingLastPathComponent
            guard ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/usr/sbin", "/sbin"].contains(dir) else {
                r.why = "it runs a program by its path"; return r
            }
        }
        program = program.lowercased()
        // Network addresses anywhere ("https://…", "rtmp:…", "tcp:…").
        for a in args.dropFirst() + targets {
            if a.contains("://") { r.why = "it uses the network or installs software"; return r }
            if let c = a.firstIndex(of: ":"), networkSchemes.contains(a[..<c].lowercased()) { r.why = "it uses the network or installs software"; return r }
        }

        // The rule this command falls under.
        var rest = Array(args.dropFirst())
        var scriptPath: String?
        if program == "git" {
            var j = 0
            while j < rest.count, rest[j].hasPrefix("-") {
                if rest[j] == "-C", j + 1 < rest.count { j += 2; continue }
                if rest[j] == "--no-pager" || rest[j] == "-P" { j += 1; continue }
                r.why = "it uses git options MUSE can't check"; return r
            }
            guard j < rest.count else { r.why = "MUSE can't read this command"; return r }
            let sub = rest[j].lowercased()
            if gitRisky.contains(sub) { r.why = "it can change or send your git history"; return r }
            guard gitSafe.contains(sub) else { r.why = "MUSE can't be sure what git \(sub) does"; return r }
            r.rule = ClaudeCommandRule(program: "git", sub: sub)
            rest.remove(at: j)
            rest.removeAll { $0 == "-C" || $0 == "--no-pager" || $0 == "-P" }
        } else if interpreters.contains(program) {
            var j = 0
            while j < rest.count, rest[j].hasPrefix("-") {
                if rest[j] == "-" || rest[j] == "--" { break }
                guard interpreterFlags(program).contains(rest[j]) else {
                    r.why = ["-c", "-e", "-E", "-m", "-p", "--eval", "--print"].contains(where: { rest[j].hasPrefix($0) })
                        ? "it runs code typed into the command" : "it uses \(program) options MUSE can't check"
                    return r
                }
                j += 1
            }
            guard j < rest.count, rest[j] != "-", rest[j] != "--" else { r.why = "it runs code typed into the command"; return r }
            if program == "swift", !rest[j].hasSuffix(".swift") { r.why = "MUSE can't be sure what swift \(rest[j]) does"; return r }
            scriptPath = ClaudeFilePolicy.resolve(rest[j], cwd: runCwd, home: home)
            r.rule = ClaudeCommandRule(program: program, sub: scriptSub)
        } else if plainPrograms.contains(program) {
            r.rule = ClaudeCommandRule(program: program)
        } else if runners.contains(program) {
            r.why = "it runs other commands"; return r
        } else {
            r.why = "MUSE can't be sure what \(program) does"; return r
        }
        for a in rest { if let why = riskyOption(program, a) { r.rule = nil; r.why = why; return r } }

        // Every path it names: inside the allowed folders or the chat's own folder, or a folder "Allow always" may add.
        var need: [String] = []
        let inside: (String) -> Bool = { p in harmless.contains(p) || ClaudeFilePolicy.inside(p, cwd) || folders.contains { ClaudeFilePolicy.inside(p, $0) } }
        let named = (cdDir.map { [$0] } ?? []) + rest + targets + filterArgs
        for a in named {
            guard let ps = paths(in: a, cwd: runCwd, home: home) else { r.rule = nil; r.why = "MUSE can't tell which files it reaches"; return r }
            for p in ps where !inside(p) || ClaudeFilePolicy.inside(p, home + "/Library") {
                if ClaudeFilePolicy.isSecret(p) { r.rule = nil; r.why = "it names keys, passwords or tokens"; return r }
                let folder = isDirectory(p) || p == cdDir ? p : (p as NSString).deletingLastPathComponent
                if let wide = tooWide(folder, home: home) { r.rule = nil; r.why = "it reaches a folder that can't be always allowed (\(wide))"; return r }
                if !need.contains(where: { ClaudeFilePolicy.inside(folder, $0) }) {
                    need.removeAll { ClaudeFilePolicy.inside($0, folder) }
                    need.append(folder)
                }
            }
        }
        r.needFolders = need

        // An interpreter's script is read: the same risks as a command, and no paths outside the folders.
        if let sp = scriptPath {
            guard let text = readScript(sp) else { r.why = "MUSE couldn't read the script"; return r }
            if let why = scriptRisk(text, folders: folders + need, cwd: cwd, home: home, shell: ["bash", "sh", "zsh"].contains(program)) { r.why = "the script \(why.replacingOccurrences(of: "it ", with: ""))"; return r }
        }
        return r
    }

    /// Calls in a script that delete, move, run other programs or reach the network.
    static let scriptCalls: [(String, String)] = [
        ("os.remove", "deletes files"), ("os.unlink", "deletes files"), ("os.rmdir", "deletes files"), ("rmtree", "deletes files"),
        (".unlink(", "deletes files"), (".rmdir(", "deletes files"), ("fs.rm", "deletes files"), ("fs.unlink", "deletes files"),
        ("shutil.move", "moves or renames files"), ("os.rename", "moves or renames files"), ("os.replace", "moves or renames files"),
        (".rename(", "moves or renames files"), ("fs.rename", "moves or renames files"),
        ("subprocess", "runs other programs"), ("os.system", "runs other programs"), ("os.popen", "runs other programs"),
        ("os.exec", "runs other programs"), ("os.spawn", "runs other programs"), ("child_process", "runs other programs"),
        ("eval(", "runs other programs"), ("exec(", "runs other programs"), ("__import__", "runs other programs"), ("ctypes", "runs other programs"),
        ("popen", "runs other programs"), ("system(", "runs other programs"), ("`", "runs other programs"), ("$(", "runs other programs"),
        ("socket", "uses the network"), ("requests", "uses the network"), ("urllib", "uses the network"), ("http.client", "uses the network"),
        ("httpx", "uses the network"), ("aiohttp", "uses the network"), ("ftplib", "uses the network"), ("smtplib", "uses the network"),
        ("fetch(", "uses the network"), ("require('http", "uses the network"), ("require(\"http", "uses the network"), ("net/http", "uses the network"),
        ("expanduser", "works outside your allowed folders"), ("path.home", "works outside your allowed folders"), ("environ", "works outside your allowed folders"),
        ("$home", "works outside your allowed folders"), ("getenv", "works outside your allowed folders"),
    ]

    /// Why a script always asks, or nil. The same risk words as a command, the calls above, and every absolute path written
    /// in it must be inside the folders.
    public static func scriptRisk(_ text: String, folders: [String], cwd: String, home: String, shell: Bool = false) -> String? {
        if text.utf8.count > 512 * 1024 { return "it is too long to check" }
        if shell {
            if let why = riskIn(text) { return why }
        } else {
            // Words that are commands in a shell but ordinary names in code (Python's open(), a "port" number) don't count.
            let w = Set(words(text)).subtracting(["open", "defaults", "security", "port", "mount", "file", "time", "kill"])
            for (set, why) in riskWords where !w.isDisjoint(with: set) { return why }
        }
        let lower = text.lowercased()
        for (needle, why) in scriptCalls where lower.contains(needle) { return "it \(why)" }
        // Absolute paths written in it: after a quote, a space, "(", "=" or the line start.
        let re = try! NSRegularExpression(pattern: #"(?:^|[\s"'(=,])(~/[^\s"'),;]*|/[A-Za-z][^\s"'),;]*)"#, options: [.anchorsMatchLines])
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let p = ClaudeFilePolicy.resolve(ns.substring(with: m.range(at: 1)), cwd: cwd, home: home)
            if harmless.contains(p) { continue }
            // The #! line names the interpreter.
            if text.hasPrefix("#!"), m.range.location < ns.range(of: "\n").location { continue }
            if ClaudeFilePolicy.isSecret(p) { return "it names keys, passwords or tokens" }
            if !(ClaudeFilePolicy.inside(p, cwd) || folders.contains { ClaudeFilePolicy.inside(p, $0) }) { return "it works outside your allowed folders" }
        }
        return nil
    }
}
