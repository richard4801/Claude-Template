import Foundation

/// Delete chats: what a chat leaves on this Mac goes with it. Its Claude Code run folder (~/MUSE/Claude/<chat>), its
/// attachment cache, and Claude Code's own saved conversation for that folder (the one `--resume` reads:
/// ~/.claude/projects/<the folder's path with every other character as "-">). Nothing else under ~/.claude is touched.
public enum ClaudeLocalSessions {
    /// Claude Code's project folder name for a working folder: "/Users/me/MUSE/Claude/ct_1" → "-Users-me-MUSE-Claude-ct-1".
    public static func projectName(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The folders that hold a chat on this Mac (they may not exist).
    public static func folders(chatId: String, home: URL, runRoot: URL) -> [URL] {
        guard !chatId.isEmpty, chatId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return [] }
        let run = runRoot.appendingPathComponent(chatId, isDirectory: true)
        let project = home.appendingPathComponent(".claude/projects", isDirectory: true).appendingPathComponent(projectName(run.path), isDirectory: true)
        return [run, project, ClaudeAttachmentCache.directory(threadId: chatId)]
    }

    /// Removes them (missing ones are fine).
    public static func forget(chatId: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, runRoot: URL = ClaudeTurnRunner.defaultRoot) {
        for u in folders(chatId: chatId, home: home, runRoot: runRoot) { try? FileManager.default.removeItem(at: u) }
    }
}
