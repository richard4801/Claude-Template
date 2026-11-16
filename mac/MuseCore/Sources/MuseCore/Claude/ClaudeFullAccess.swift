import Foundation

/// "Full access" (owner, bundle-26): ONE switch for terminal work in any folder, answered once. While it is on, any
/// command, script or code (heredocs, python/node/uv…), in any folder including the home folder, the network and
/// installs, mv/chmod/kill/open/osascript, and reading, writing, uploading and saving files anywhere run without a card.
/// The owner's choice is "everything except deleting":
/// - deleting files or folders outside the temporary folders still asks ("it deletes files", Allow once / Deny only):
///   rm/rmdir/unlink/trash/srm/shred, find -delete, git clean, rsync --delete, and rmtree/os.remove/unlink/fs.rm/rimraf
///   in code; deleting inside /tmp or the per-user temp folder runs;
/// - sudo/su/admin still asks (they need a password anyway);
/// - ~/Library still asks.
/// Never, even on: keys, passwords and tokens (ClaudeFilePolicy's secret rules). Spending and posting in MUSE keep their
/// own Approve cards (server-side). "Ask before anything" pauses it. Off by default.
public enum ClaudeFullAccess {
    public static let deletesReason = "it deletes files"
    public static let adminReason = "it needs admin rights"
    public static let libraryReason = "it reaches ~/Library"
    /// git reset --hard, truncate, dd of=, `: > f`, AppleScript delete (integrator review, bundle-26).
    public static let wipesReason = "it deletes or overwrites files"
    /// The program is a variable, eval or a substitution: MUSE can't tell what runs.
    public static let unreadableReason = "it runs a command it builds at run time"

    /// What the confirmation says when the switch is turned on, in plain words.
    public static let confirmTitle = "Give Claude full access on this Mac?"
    public static let confirmAllows = "Claude can run any command, script or code it writes, use the internet and install software, and read, change and upload files in any folder, without asking you first."
    public static let confirmStillAsks = "It still asks before commands that delete or overwrite files (rm, trash, git reset and the like). It can't catch every way a program might delete something. It also asks before anything that needs your admin password and before touching ~/Library. It never reads or uploads keys, passwords or tokens, and spending or posting in MUSE still asks as before."
    public static let confirmOff = "You can turn this off at any time in Settings → Claude."
    public static let rowHint = "On: Claude works in any folder without asking, except deleting or overwriting files, admin rights and ~/Library. Keys, passwords and tokens stay off limits."

    /// A string in code, from its opening quote to the same closing quote on that line.
    static let quotedString = try! NSRegularExpression(pattern: #"(["'])([^"'\n]+)\1"#)
    static let deletePrograms: Set<String> = ["rm", "rmdir", "unlink", "trash", "srm", "shred"]
    static let adminPrograms: Set<String> = ["sudo", "su", "doas", "visudo"]
    static let codeDeletes = ["shutil.rmtree", "rmtree(", "os.remove", "os.unlink", "os.rmdir", ".unlink(", ".rmdir(", "fs.rm", "fs.unlink",
                              "unlinksync", "rmdirsync", "rmsync", ").rm(", "rimraf", "unlink ", "unlink(", "remove_tree", "rm_rf", "file.delete", "send2trash", "fileutils.rm", "deleteitem", "removeitem"]

    /// Why a command still asks with Full access on (nil: it runs). `secret` is set when it names keys (refused outright).
    public struct Check: Hashable, Sendable {
        public var why: String?
        public var secret = false
    }

    /// Inside a temporary folder, and not the temporary folder itself.
    static func deletable(_ p: String) -> Bool {
        guard let root = ClaudeKindGrants.tempRoot(p) else { return false }
        return p != root
    }

    /// `fileExists` and `isDirectory` look at the Mac when it asks: mv/cp or `>` onto a file that already exists overwrites it.
    public static func check(_ command: String, cwd: String, home: String, readScript: (String) -> String? = { _ in nil },
                             fileExists: (String) -> Bool = { _ in false }, isDirectory: (String) -> Bool = { _ in false },
                             depth: Int = 0) -> Check {
        var r = Check()
        guard depth < 4, let tokens = ClaudeAlwaysRules.lex(command) else { r.why = "MUSE can't read this command"; return r }
        let library = home + "/Library"
        func base(_ w: String) -> String { (w as NSString).lastPathComponent.lowercased() }
        func expand(_ w: String) -> String {
            var t = w
            for v in ["${HOME}", "$HOME"] where t.hasPrefix(v) { t = home + t.dropFirst(v.count) }
            for v in ["${TMPDIR}", "$TMPDIR"] where t.hasPrefix(v) { t = "/tmp" + t.dropFirst(v.count) }
            return t
        }
        /// Every path written in a text (quoted whole, or unquoted): keys refuse, ~/Library asks.
        func scanText(_ text: String, base b: String) -> Check? {
            let ns = text as NSString
            let all = NSRange(location: 0, length: ns.length)
            var ps = ClaudeKindGrants.quotedPath.matches(in: text, range: all).map { ns.substring(with: $0.range(at: 2)) }
            ps += ClaudeKindGrants.embeddedPath.matches(in: text, range: all).map { ns.substring(with: $0.range(at: 1)) }
            for raw in ps {
                let p = ClaudeFilePolicy.resolve(raw, cwd: b, home: home)
                if ClaudeFilePolicy.isSecret(p) { return Check(why: ClaudeFilePolicy.credentialRefusal, secret: true) }
                if ClaudeFilePolicy.inside(p, library) { return Check(why: libraryReason) }
            }
            return nil
        }
        /// Code that deletes: fine only when every path it names (absolute, or a relative "a.png" / "work/x" against the
        /// folder it runs in) is inside a temporary folder, and it names at least one or runs in one.
        func codeDeletes(_ text: String, base b: String) -> Bool {
            let lower = text.lowercased()
            guard Self.codeDeletes.contains(where: { lower.contains($0) }) else { return false }
            let ns = text as NSString
            let all = NSRange(location: 0, length: ns.length)
            var ps = ClaudeKindGrants.embeddedPath.matches(in: text, range: all).map { ns.substring(with: $0.range(at: 1)) }
            for m in quotedString.matches(in: text, range: all) {
                let q = ns.substring(with: m.range(at: 2))
                let looksLikePath = q.hasPrefix("/") || q.hasPrefix("~/") || q.contains("/")
                    || q.range(of: #"^[^\s]+\.[A-Za-z0-9]{1,5}$"#, options: .regularExpression) != nil
                if looksLikePath { ps.append(q) }
            }
            if ps.isEmpty { return !ClaudeKindGrants.isTemp(b) }
            return ps.contains { !ClaudeKindGrants.isTemp(ClaudeFilePolicy.resolve($0, cwd: b, home: home)) }
        }

        // Split into simple commands; follow `cd`; collect here-document targets as in ClaudeKindGrants.shellCheck.
        var runCwd = cwd
        var segment: [String] = []
        var heredocTargets: [String?] = []
        var heredocIndex = 0
        var functions: [String: String] = [:]
        for k in tokens.indices where k + 2 < tokens.count {
            guard case .word(let f) = tokens[k], tokens[k + 1] == .op("("), tokens[k + 2] == .op(")") else { continue }
            for t in tokens[(k + 3)...] {
                guard case .word(let w) = t else { continue }
                if w.text == "}" { break }
                if ClaudeKindGrants.isInterpreter(base(w.text)) { functions[f.text.lowercased()] = base(w.text); break }
            }
        }
        let keywords: Set<String> = ["do", "then", "else", "elif", "if", "while", "until", "for", "in", "!", "{", "}", "done", "fi", "time"]
        func isAssign(_ w: String) -> Bool {
            guard let eq = w.firstIndex(of: "="), !w.hasPrefix("=") else { return false }
            return w[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        func interpreterOf(_ seg: [String]) -> String? {
            for w in seg {
                let b = base(w)
                if let f = functions[b] { return f }
                if ClaudeKindGrants.isInterpreter(b) { return b }
            }
            return nil
        }
        /// One simple command: admin, deletes outside temp, code typed in, scripts it runs.
        func finish() -> Check? {
            defer { segment = [] }
            let words = segment.drop(while: { keywords.contains(base($0)) || isAssign($0) })
            guard let first = words.first else { return nil }
            let prog = base(first)
            if first.hasPrefix("$") || first.hasPrefix("`") || prog == "eval" { return Check(why: unreadableReason) }
            // `source x.sh` / `. venv/bin/activate`: the file's commands, read like a shell script.
            if prog == "source" || prog == "." {
                guard let f = words.dropFirst().first, !f.contains("$"),
                      let text = readScript(ClaudeFilePolicy.resolve(expand(f), cwd: runCwd, home: home)) else { return Check(why: unreadableReason) }
                let inner = check(text, cwd: runCwd, home: home, readScript: readScript, fileExists: fileExists, isDirectory: isDirectory, depth: depth + 1)
                return inner.why != nil ? inner : nil
            }
            if segment.contains(where: { adminPrograms.contains(base($0)) }) { return Check(why: adminReason) }
            let args = Array(words.dropFirst())
            if prog == "cd" {
                if let d = args.first, !d.contains("$") || d.hasPrefix("$HOME") || d.hasPrefix("${HOME}") {
                    runCwd = ClaudeFilePolicy.resolve(expand(d), cwd: runCwd, home: home)
                }
                return nil
            }
            func targetsInTemp(_ ts: [String]) -> Bool {
                guard !ts.isEmpty else { return false }
                return ts.allSatisfy { t in
                    let e = expand(t)
                    if e.contains("$") {
                        // A variable in it: the folder before it must be inside a temp folder.
                        let lit = String(e[..<e.firstIndex(of: "$")!])
                        let dir = lit.hasSuffix("/") ? lit : (lit as NSString).deletingLastPathComponent
                        let p = ClaudeFilePolicy.resolve(dir.isEmpty ? "." : dir, cwd: runCwd, home: home)
                        return ClaudeKindGrants.isTemp(p) && (deletable(p) || lit.hasSuffix("/") && !lit.isEmpty)
                    }
                    return deletable(ClaudeFilePolicy.resolve(e, cwd: runCwd, home: home))
                }
            }
            let plain = args.filter { !$0.hasPrefix("-") }
            // Deleting programs, also behind xargs/env/nohup/time.
            if deletePrograms.contains(prog) { return targetsInTemp(plain) ? nil : Check(why: deletesReason) }
            if ["xargs", "env", "nohup", "nice", "command", "builtin", "exec", "timeout"].contains(prog),
               args.contains(where: { deletePrograms.contains(base($0)) }) {
                return Check(why: deletesReason)
            }
            if prog == "find", args.contains("-delete") || args.contains(where: { deletePrograms.contains(base($0)) }) {
                let roots = Array(args.prefix(while: { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" }))
                return targetsInTemp(roots.isEmpty ? ["."] : roots) ? nil : Check(why: deletesReason)
            }
            let inTemp = ClaudeKindGrants.isTemp(runCwd)
            if prog == "git" {
                let rest = args.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
                let sub = rest.first ?? ""
                if sub == "clean" { return inTemp ? nil : Check(why: deletesReason) }
                // Throwing away work: reset --hard, checkout -- / . / -f, restore, stash drop/clear.
                let wipes = (sub == "reset" && args.contains("--hard")) || sub == "restore"
                    || (sub == "checkout" && (args.contains("--") || args.contains(".") || args.contains("-f") || args.contains("--force")))
                    || (sub == "stash" && rest.dropFirst().contains { $0 == "drop" || $0 == "clear" })
                if wipes, !inTemp { return Check(why: wipesReason) }
            }
            // AppleScript can delete through Finder.
            if prog == "osascript",
               ["delete", "to trash", "empty trash", "do shell script"].contains(where: { segment.joined(separator: " ").lowercased().contains($0) }) {
                return Check(why: wipesReason)
            }
            if prog == "truncate" {
                var ts: [String] = []
                var skip = false
                for a in args { if skip { skip = false; continue }; if a == "-s" || a == "-r" { skip = true; continue }; if !a.hasPrefix("-") { ts.append(a) } }
                return targetsInTemp(ts) ? nil : Check(why: wipesReason)
            }
            if prog == "dd", let of = args.first(where: { $0.hasPrefix("of=") }) {
                return targetsInTemp([String(of.dropFirst(3))]) ? nil : Check(why: wipesReason)
            }
            if prog == "cp", plain.first == "/dev/null", plain.count >= 2 {
                return targetsInTemp(Array(plain.dropFirst())) ? nil : Check(why: wipesReason)
            }
            // mv/cp onto a file that already exists (outside temp) overwrites it; -n / --no-clobber never does.
            if prog == "mv" || prog == "cp",
               !args.contains(where: { $0 == "--no-clobber" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("n")) }) {
                var dest: String?
                var srcs = plain
                if let ti = args.firstIndex(of: "-t"), ti + 1 < args.count {
                    dest = args[ti + 1]; srcs.removeAll { $0 == args[ti + 1] }
                } else if plain.count >= 2 {
                    dest = plain.last; srcs = Array(plain.dropLast())
                }
                if let d = dest, !d.contains("$") {
                    let dp = ClaudeFilePolicy.resolve(expand(d), cwd: runCwd, home: home)
                    let targets = isDirectory(dp) ? srcs.map { dp + "/" + (expand($0) as NSString).lastPathComponent } : [dp]
                    if targets.contains(where: { fileExists($0) && !deletable($0) }) { return Check(why: wipesReason) }
                }
            }
            if prog == "rsync", args.contains(where: { $0.hasPrefix("--delete") || $0 == "--remove-source-files" }) {
                return targetsInTemp(Array(plain.suffix(1))) ? nil : Check(why: deletesReason)
            }
            // Code typed in: shell code is checked like a command, other code for deleting calls.
            if let interp = interpreterOf(Array(words)) {
                for (i, w) in args.enumerated() where i > 0 && ClaudeKindGrants.codeFlags.contains(args[i - 1]) {
                    if ClaudeKindGrants.isShell(interp) {
                        let inner = check(w, cwd: runCwd, home: home, readScript: readScript, fileExists: fileExists, isDirectory: isDirectory, depth: depth + 1)
                        if inner.why != nil { return inner }
                    } else if codeDeletes(w, base: runCwd) { return Check(why: deletesReason) }
                }
                // A script file it runs.
                if let script = args.first(where: { !$0.hasPrefix("-") && $0.contains(".") && !$0.contains("$") }),
                   let text = readScript(ClaudeFilePolicy.resolve(expand(script), cwd: runCwd, home: home)) {
                    if ClaudeKindGrants.isShell(interp) {
                        let inner = check(text, cwd: runCwd, home: home, readScript: readScript, fileExists: fileExists, isDirectory: isDirectory, depth: depth + 1)
                        if inner.why != nil { return inner }
                    } else if codeDeletes(text, base: runCwd) { return Check(why: deletesReason) }
                }
            }
            return nil
        }

        var truncating = false
        var heredocPrograms: [String] = []
        for t in tokens {
            switch t {
            case .word(let w):
                if truncating {
                    // A `>` target: emptying a file that exists outside temp overwrites it (a new file is fine).
                    truncating = false
                    let e = expand(w.text)
                    let p = ClaudeFilePolicy.resolve(e, cwd: runCwd, home: home)
                    if !e.contains("$"), !ClaudeKindGrants.harmless(p), fileExists(p), !deletable(p) { return Check(why: wipesReason) }
                    continue
                }
                segment.append(w.text)
            case .op(let op):
                if op == "<<" || op == "<<-" {
                    heredocTargets.append(interpreterOf(segment))
                    heredocPrograms.append(segment.first.map(base) ?? "")
                    continue
                }
                // `> f`, `: > f`, `cmd > f`, `2> f`, `&> f` empty f first (`>>` appends, `>&` duplicates).
                if op == ">" || op == ">|" || op == "&>" || (op.count > 1 && op.hasSuffix(">") && op.dropLast().allSatisfy(\.isNumber)) {
                    truncating = true; continue
                }
                if op.contains(">") || op.contains("<") { continue }
                if let c = finish() { return c }
            case .heredoc(let body):
                let target = heredocIndex < heredocTargets.count ? heredocTargets[heredocIndex] : nil
                let feeds = heredocIndex < heredocPrograms.count ? heredocPrograms[heredocIndex] : ""
                heredocIndex += 1
                if feeds == "osascript", ["delete", "to trash", "empty trash", "do shell script"].contains(where: { body.lowercased().contains($0) }) {
                    return Check(why: wipesReason)
                }
                if let target, ClaudeKindGrants.isShell(target) {
                    let inner = check(body, cwd: runCwd, home: home, readScript: readScript, fileExists: fileExists, isDirectory: isDirectory, depth: depth + 1)
                    if inner.why != nil { return inner }
                } else if codeDeletes(body, base: runCwd) {
                    // Python/node code, or a file being written that may be run next: deleting outside temp asks.
                    return Check(why: deletesReason)
                }
            }
        }
        if let c = finish() { return c }
        // Keys anywhere in it (code included) are refused; ~/Library asks.
        if let c = scanText(command, base: cwd) { return c }
        for case .word(let w) in tokens {
            let e = expand(w.text)
            guard e.hasPrefix("/") || e.hasPrefix("~") || e.contains("..") else { continue }
            let p = ClaudeFilePolicy.resolve(e, cwd: runCwd, home: home)
            if ClaudeFilePolicy.isSecret(p) { return Check(why: ClaudeFilePolicy.credentialRefusal, secret: true) }
            if ClaudeFilePolicy.inside(p, library) { return Check(why: libraryReason) }
        }
        return r
    }
}
