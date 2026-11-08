import Foundation

/// The headless Claude Code command MUSE runs for one turn, and its `--mcp-config` file.
/// One process per turn; `--resume` carries the conversation on. Tools are MUSE's MCP (plus Blender's when the relay is on);
/// Bash, file edits and the web are off, and nothing asks for permission (anything not allowed is refused).
public struct ClaudeCommand: Hashable, Sendable {
    /// Where Blender's MCP server (`uvx mcp-for-blender`) is, when the Blender relay is on.
    public struct Blender: Hashable, Sendable {
        public var uvx: String
        public init(uvx: String = "uvx") { self.uvx = uvx }
    }

    public var mcpURL: String
    public var token: String
    public var blender: Blender?
    public var resume: String?
    /// The thread's brief (recreate and edit threads): appended to Claude Code's system prompt.
    public var appendSystemPrompt: String?

    public init(mcpURL: String, token: String, blender: Blender? = nil, resume: String? = nil, appendSystemPrompt: String? = nil) {
        self.mcpURL = mcpURL
        self.token = token
        self.blender = blender
        self.resume = resume
        self.appendSystemPrompt = appendSystemPrompt
    }

    public static let disallowed = ["Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch"]

    /// The arguments after the executable. `configPath` is the mcp config file written for this run.
    public func arguments(configPath: String) -> [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                 "--mcp-config", configPath, "--strict-mcp-config",
                 "--allowedTools", "mcp__muse"]
        if blender != nil { a.append("mcp__blender") }
        a.append("--disallowedTools")
        a += Self.disallowed
        a += ["--permission-mode", "dontAsk", "--setting-sources", "user"]
        if let p = appendSystemPrompt, !p.isEmpty { a += ["--append-system-prompt", p] }
        if let resume, !resume.isEmpty { a += ["--resume", resume] }
        return a
    }

    /// `{"mcpServers":{"muse":{"type":"http","url":…,"headers":{"Authorization":"Bearer …"}}}}` (+ `blender` over stdio).
    /// Written 0600 and deleted after the run; the token goes nowhere else.
    public func mcpConfigJSON() -> Data {
        var servers: [String: JSONValue] = [
            "muse": .object(["type": .string("http"), "url": .string(mcpURL), "headers": .object(["Authorization": .string("Bearer \(token)")])]),
        ]
        if let blender {
            servers["blender"] = .object([
                "type": .string("stdio"), "command": .string(blender.uvx), "args": .array([.string("mcp-for-blender")]),
                "env": .object(["DISABLE_TELEMETRY": .string("true"), "BLENDER_MCP_SAFE_MODE": .string("1")]),
            ])
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(JSONValue.object(["mcpServers": .object(servers)]))) ?? Data()
    }

    /// The one stdin line: `{"type":"user","message":{"role":"user","content":"…"},"parent_tool_use_id":null}`.
    public static func stdinLine(_ text: String) -> String {
        let msg: JSONValue = .object(["type": .string("user"), "message": .object(["role": .string("user"), "content": .string(text)]), "parent_tool_use_id": .null])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? enc.encode(msg)) ?? Data(), as: UTF8.self) + "\n"
    }

    /// The environment for the run: the app's own plus the usual bin folders, without anything that would bill the API
    /// instead of the owner's plan (ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN) or make Claude Code think it is nested.
    public static func environment(_ base: [String: String], executable: String, home: String) -> [String: String] {
        var env = base
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] { env[k] = nil }
        let dir = (executable as NSString).deletingLastPathComponent
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for p in [dir, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !path.contains(p) { path.append(p) }
        env["PATH"] = path.joined(separator: ":")
        env["HOME"] = env["HOME"] ?? home
        return env
    }
}

/// Finding Claude Code and reading `claude --version` / `claude auth status`. MUSE never reads Claude's credentials or config.
public enum ClaudeCodeLocator {
    /// PATH first, then the official installer's ~/.local/bin, Homebrew and /usr/local.
    public static func candidates(home: String, path: String?) -> [String] {
        var out: [String] = []
        for dir in (path ?? "").split(separator: ":") where !dir.isEmpty { out.append("\(dir)/claude") }
        out += ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    public static func find(home: String, path: String?, fileManager: FileManager = .default) -> String? {
        candidates(home: home, path: path).first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// "2.1.211 (Claude Code)" → "2.1.211".
    public static func version(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let tok = line.split(separator: " ").first, tok.first?.isNumber == true else { return nil }
        return String(tok)
    }

    /// `claude auth status`: exit 0 = signed in. The JSON's `authMethod` is kept for the status line when present.
    public static func auth(exitCode: Int32, output: String) -> (signedIn: Bool, method: String?) {
        var method: String?
        if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)), case .object(let o) = v {
            method = o.jStr("authMethod")
            if case .bool(let b)? = o["loggedIn"] { return (b && exitCode == 0, method) }
        }
        return (exitCode == 0, method)
    }

    /// `brew`-less places uv's installer drops `uvx` (for Blender's MCP server).
    public static func findUvx(home: String, path: String?, fileManager: FileManager = .default) -> String? {
        var c = (path ?? "").split(separator: ":").map { "\($0)/uvx" }
        c += ["\(home)/.local/bin/uvx", "\(home)/.cargo/bin/uvx", "/opt/homebrew/bin/uvx", "/usr/local/bin/uvx"]
        return c.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// The small Terminal scripts for Install and Sign in: they run the official commands in a window the owner sees.
    public static func installScript() -> String {
        """
        #!/bin/bash
        # MUSE: installs Anthropic's Claude Code with its official installer (https://claude.ai/install.sh).
        echo "Installing Claude Code (Anthropic's official installer)…"
        curl -fsSL https://claude.ai/install.sh | bash
        echo
        echo "Done. Next, sign in to your Claude account:"
        "$HOME/.local/bin/claude" auth login || claude auth login
        echo
        echo "You can close this window and go back to MUSE."
        """
    }

    public static func signInScript(executable: String) -> String {
        """
        #!/bin/bash
        # MUSE: opens Claude's own sign-in. MUSE never sees your password or keys.
        "\(executable.replacingOccurrences(of: "\"", with: ""))" auth login
        echo
        echo "You can close this window and go back to MUSE."
        """
    }
}
