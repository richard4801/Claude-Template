import AppKit
import Foundation
import MuseCore
import SwiftUI

// Closing a chat while Claude's reply is still streaming, in the same tick as a screen change, must not freeze the app
// (plans/claude-chat-mac.md, "Freeze: a chat closed mid-reply"). Review mode, demo relay only: nothing is sent or spent.
// Lines go to stream-close.txt (`FITS stream_close …` / `CUT stream_close …`); Mac CI fails on CUT or a missing file.
extension SnapshotRunner {
    static func streamCloseCheck(_ store: AppStore, dir: URL) async {
        let file = dir.appendingPathComponent("stream-close.txt")
        let out = StreamCloseLog(file)
        out.reset()
        let service = ClaudeCodeService.shared
        guard service.configured, service.isDemo else {
            out.add("CUT stream_close demo Claude not configured (configured \(service.configured), demo \(service.isDemo))")
            return
        }
        // The demo reply streams slowly (about 6 s), so the chat is still mid-reply when it closes.
        let delay = ClaudeCodeService.demoLineDelay
        ClaudeCodeService.demoLineDelay = 0.5
        defer { ClaudeCodeService.demoLineDelay = delay }
        let dog = MainThreadWatchdog(file: out, sampleTo: dir.appendingPathComponent("stream-close-sample.txt"))

        // Two ways in: the relay's real stream (a sent message), and the sample thread's streaming state (run 42580182117).
        for theme in [ThemeID.c, .d] {
            store.themeID = theme
            for (attempt, way) in [(1, "relay"), (2, "relay"), (3, "sample")] {
                let label = "stream_close \(theme.rawValue) try \(attempt) \(way)"
                dog.stage(label + ": chat up")
                store.closeRecreate()
                store.go(.home)
                state.chatSample = way == "sample"
                state.overlay = "chat"
                if way == "sample" { state.chatStreaming = true }
                try? await Task.sleep(for: .seconds(2))
                if way == "relay" {
                    dog.stage(label + ": sending")
                    guard let d = try? await service.openThread(contextKind: "camera", contextId: "cs_snapshot") else {
                        out.add("CUT \(label): the camera thread didn't open")
                        continue
                    }
                    service.send(threadId: d.thread.id, text: "Tighten the turn so it lands on the beat")
                    var running = false
                    for _ in 0..<40 where !running {
                        try? await Task.sleep(for: .seconds(0.1))
                        running = service.isRunning(threadId: d.thread.id)
                    }
                    try? await Task.sleep(for: .seconds(1.2))   // a few lines in: text arriving, the tool step next
                    guard service.isRunning(threadId: d.thread.id) else {
                        out.add("CUT \(label): the reply wasn't streaming when the chat closed (running \(running))")
                        state.overlay = nil
                        continue
                    }
                }
                // One tick: the chat closes mid-reply, the screen changes, Recreate opens.
                dog.stage(label + ": chat closes mid-reply, Edit + Recreate open")
                let started = Date()
                state.overlay = nil
                state.chatStreaming = false
                store.openEdit(takeId: nil)
                store.openRecreate()
                try? await Task.sleep(for: .seconds(1))
                let late = Date().timeIntervalSince(started) - 1
                var drawn = screensInWindow()
                // The old page can still be leaving at the 1 s mark on a cold first try (run 582: [edit, home] once, then
                // [edit]); a stale screen is one that stays. Give it up to 1 s more, then judge (and say how long it took).
                var settle = 0.0
                while drawn != ["\(store.screen)"] && settle < 1 {
                    try? await Task.sleep(for: .seconds(0.1))
                    settle += 0.1
                    drawn = screensInWindow()
                }
                let ok = late < 2 && drawn == ["\(store.screen)"]
                let settled = settle > 0 ? ", settled after +\(String(format: "%.1f", settle)) s" : ""
                out.add("\(ok ? "FITS" : "CUT") \(label): main thread back after \(String(format: "%.2f", late)) s late, store.screen \(store.screen), drawn [\(drawn.joined(separator: ", "))]\(settled)")
                // Let the demo reply finish before the next try (Stop isn't what this checks).
                for _ in 0..<80 where service.relayState.running.isEmpty == false { try? await Task.sleep(for: .seconds(0.1)) }
            }
            store.closeRecreate()
        }
        state.chatSample = false
        dog.stop()
        out.add("DONE stream_close")
    }
}

/// Lines written straight to a file (from any thread), so a freeze still leaves what happened.
final class StreamCloseLog: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    init(_ url: URL) { self.url = url }
    func reset() { lock.lock(); try? Data().write(to: url); lock.unlock() }
    func add(_ line: String) {
        NSLog("[snapshot] %@", line)
        lock.lock(); defer { lock.unlock() }
        let before = (try? Data(contentsOf: url)) ?? Data()
        try? (before + Data((line + "\n").utf8)).write(to: url)
    }
}

/// Off the main thread: pings the main queue every 0.5 s. No answer for 10 s is a freeze: it writes a CUT line with
/// the stage, samples the app's threads (`/usr/bin/sample`) next to it, and quits, so CI shows where it stuck.
final class MainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var label = "start"
    private var running = true
    private let file: StreamCloseLog
    private let sampleTo: URL

    init(file: StreamCloseLog, sampleTo: URL) {
        self.file = file
        self.sampleTo = sampleTo
        let t = Thread { [weak self] in self?.loop() }
        t.name = "MUSE main-thread watchdog"
        t.start()
    }

    func stage(_ s: String) {
        lock.lock(); label = s; lock.unlock()
        NSLog("[snapshot] %@", s)
    }

    func stop() { lock.lock(); running = false; lock.unlock() }

    private func loop() {
        while true {
            lock.lock(); let on = running; lock.unlock()
            guard on else { return }
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            if answered.wait(timeout: .now() + 10) == .timedOut {
                lock.lock(); let at = label; lock.unlock()
                file.add("CUT stream_close FROZE: the main thread didn't answer for 10 s during \"\(at)\" (sample in \(sampleTo.lastPathComponent))")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "3", "-file", sampleTo.path]
                try? p.run()
                p.waitUntilExit()
                file.add("CUT stream_close the app quit after the freeze")
                exit(3)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
