import AppKit
import CoreFoundation
import Darwin
import MuseCore
import SwiftUI

// Owner report, build 704: "The Mac app needs proper optimization, it lags": hot, fan on, stutter everywhere. Idle MUSE
// must cost next to nothing. This check runs right after sign-in and the two checks that must come first (HDR, stream close), and for each main page
// (and with the window hidden) leaves the app alone, then measures:
//   - CPU: the MEDIAN of 2 s windows of this process's CPU time (user + system, every thread), as % of one core. The old
//     single-window gates were thrown by one busy moment on a loaded runner (once 74 % against a 60 % limit); a median
//     of several windows isn't.
//   - Wake-ups: how often the main run loop woke per second (a CFRunLoopObserver on .afterWaiting). An idle SwiftUI app
//     sleeps; a timer, a repeating animation or a polling loop shows here even when it is cheap on a fast Mac.
// A page over its limit gets a 3 s `sample` of the app and its heaviest main-thread frames printed: the evidence.
// Writes snapshots/idle-cpu-check.txt: one line per page, FAIL on any over the limit, ALL DONE at the end.
extension SnapshotRunner {
    /// Idle limits (median % of one core). Headless CI runners draw with a software renderer, so they sit above a real Mac.
    static let idleLimitLaunch = 10.0
    static let idleLimitPage = 15.0
    static let idleLimitHidden = 5.0
    /// The panel's orb and edge animating while Claude works (20 fps).
    static let idleLimitWorking = 30.0
    /// Owner, build 704: "once the Claude panel is open it starts to lag immediately". Open and idle, it draws nothing.
    static let idleLimitPanel = 5.0

    static func idleCpuCheck(_ store: AppStore, dir: URL) async {
        let url = dir.appendingPathComponent("idle-cpu-check.txt")
        var lines: [String] = []
        func write() { try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
        func note(_ s: String) { lines.append(s); print("idle cpu: \(s)"); write() }
        defer { note("ALL DONE") }

        let wake = RunLoopWakeCounter()
        wake.start()
        defer { wake.stop() }

        func measure(_ name: String, settle: Double, windows: Int = 6, limit: Double) async {
            try? await Task.sleep(for: .seconds(settle))
            var cpu: [Double] = []
            let w0 = wake.count, t0 = Date()
            for _ in 0..<windows { cpu.append(await cpuPercent(over: 2)) }
            let wakes = Double(wake.count - w0) / max(0.001, Date().timeIntervalSince(t0))
            let med = median(cpu)
            let ok = med <= limit
            note("\(ok ? "OK" : "FAIL") idle \(name): median " + String(format: "%.1f %% of one core (fails above %.0f %%), main run loop %.1f wake-ups/s; windows ", med, limit, wakes)
                 + cpu.map { String(format: "%.0f", $0) }.joined(separator: " "))
            if !ok {
                let file = dir.appendingPathComponent("idle-cpu-\(name.replacingOccurrences(of: " ", with: "_"))-sample.txt")
                await sampleApp(to: file, seconds: 3)
                for f in mainThreadTop(file, count: 40) { note("  \(f)") }
            }
        }

        store.oneClaude.open = false
        state.overlay = nil
        store.go(.home)
        await measure("after launch (Home)", settle: 8, limit: idleLimitLaunch)

        let pages: [(String, @MainActor () -> Void)] = [
            ("Library", { store.go(.gallery) }),
            ("Queue", { store.go(.queue) }),
            ("Models", { store.go(.models) }),
            ("Video suite Shot", { store.openTool(.shot); fillDemoDraft(store) }),
            ("Photo composer", { store.openPhoto(model: SampleData.demo) }),
            ("Edit home", { store.go(.edit) }),
            ("Settings", { store.openSettings(.account) }),
            ("Claude panel open, idle", { store.go(.home); store.oneClaude.open = true }),
        ]
        for (name, show) in pages {
            show()
            await measure(name, settle: 5, limit: name.hasPrefix("Claude panel") ? idleLimitPanel : idleLimitPage)
        }
        // Owner, build 704: "once the Claude panel is open it starts to lag immediately" and "mostly when Claude is working".
        // The panel stays open with the orb and the edge in the working state (what every turn shows): its own cost,
        // with no reply text (Edit's big check streams a real reply over an open edit).
        let service = ClaudeCodeService.shared
        service.orbTurnStarted()
        service.orbEvent(.text(delta: "…"))
        // Integrator, run 709: this read 0.0 %. Say what was really drawing: the orb's state and frame rate, whether the
        // window counts as visible (the orb and edge stop when it doesn't), and the orb frames drawn while measured.
        let now = ClaudeCodeService.now
        let seenVisible = OrbVisibility.shared.visible
        // Counted as visible while measured, whatever the runner's occlusion says, so the number is the orb's real cost.
        OrbVisibility.shared.force(true)
        let f0 = orbFrames, k0 = OrbTicker.shared.frame
        await measure("Claude panel open, Claude working", settle: 2, limit: idleLimitWorking)
        note("INFO orb while working: state \(service.orb.state(at: now).rawValue), wants \(Int(service.orb.frameRate(at: now))) fps, "
             + "window visible on its own \(seenVisible) (forced visible while measured), \(OrbTicker.shared.frame - k0) clock ticks and \(orbFrames - f0) orb frames drawn over the "
             + "settle and 12 s measured (no reply text streams here: Edit's big check streams a real reply)")
        OrbVisibility.shared.force(false)
        service.orbEvent(.done(ok: true, error: nil, model: nil))
        await measure("Claude panel open, after the turn", settle: 3, limit: idleLimitPanel)

        store.oneClaude.open = false
        store.go(.home)

        // Hidden: nothing on screen may draw at all (the orb, a TimelineView, a shimmer…).
        NSApp.hide(nil)
        await measure("window hidden", settle: 4, limit: idleLimitHidden)
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1))
    }

    /// Orb frames drawn (review mode only).
    static var orbFrames = 0
    static func noteOrbFrame() { if probing { orbFrames += 1 } }

    nonisolated static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// Counts the main run loop's wake-ups (an idle app's main thread sleeps in mach_msg; each timer, source or animation
/// frame wakes it once).
@MainActor
final class RunLoopWakeCounter {
    private(set) var count = 0
    private var observer: CFRunLoopObserver?

    func start() {
        guard observer == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
    }

    func stop() {
        if let o = observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
        observer = nil
    }
}
