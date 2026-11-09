import Foundation

/// A thread for the review screenshots and the chat's tests (demo mode, no server): every kind of row the chat draws.
/// The stored messages carry the plumbing a real thread can hold (a context line, a suggestion's tool names, an id and a
/// path, a system brief) so the screenshots prove none of it is shown. Not used in a normal launch.
public enum ClaudeChatSample {
    public static func messages(threadId: String, kind: String) -> [ClaudeMessage] {
        var t = 1_700_000_000_000.0
        func m(_ role: String, _ text: String = "", tool: ClaudeToolRef? = nil) -> ClaudeMessage {
            t += 1000
            return ClaudeMessage(id: "sample_\(Int(t))", threadId: threadId, role: role, source: "mac", text: text, tool: tool, createdAt: t)
        }
        let context = kind == "suite" ? "[Suite composer: draft 3 · tool shot]\n" : kind == "recreate" ? "[Recreate reference rr_12 · edit session es_9]\n" : ""
        return [
            m("user", context + "Make the intro warmer and tighter. Use get_recipe."),
            m("tool", tool: ClaudeToolRef(id: "toolu_s1", name: "mcp__muse__get_edit", ok: true, summary: "Read the edit")),
            m("tool", tool: ClaudeToolRef(id: "toolu_s2", name: "mcp__muse__apply_edit_ops", ok: true, summary: "Trimmed 0:00–0:02")),
            m("tool", tool: ClaudeToolRef(id: "toolu_s3", name: "mcp__muse__apply_look", ok: false, summary: "Applied Look · Golden warmth")),
            m("assistant", """
            <system-reminder>You are MUSE's editor.</system-reminder>## Intro, tighter and warmer

            I trimmed the **first two seconds** and set the *Golden warmth* look on shots 1–3 (take tk_8f3a2c, saved in /Users/ann/Library/Caches/MUSE/es_9.json).

            1. Trim `0:00–0:02`
            2. Look: **Golden warmth**
               - grain stays ~~high~~ low
            3. Music ducks under the voice

            > Nothing new is generated, so nothing is spent.

            | Shot | Length | Look |
            |:-----|:------:|-----:|
            | 1 | 2.4 s | Golden warmth |
            | 2 | 3.1 s | Golden warmth |

            ```bash
            ffmpeg -i intro.mov -ss 2 out.mov
            ```
            ---
            Say **undo** to put it back, or see [the guide](https://muse.studio/guide).
            """),
            m("user", "Long one: " + String(repeating: "keep the camera low and slow, then push in as she turns to the window; ", count: 4)),
        ]
    }

    /// The live turn after the stored ones: the user's line, a tool still running, and text mid-stream with markup open.
    public static let liveEvents: [ClaudeEvent] = [
        .user(text: "Now match the colour of shot 4 to shot 1"),
        .tool(id: "toolu_live", name: "mcp__muse__get_frame", status: .running, summary: "Looking at shot 4", input: nil),
        .text(delta: "Shot 4 reads cooler than shot 1. I'll warm it with **Golden war"),
    ]
}
