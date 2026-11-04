import MuseCore
import SwiftUI

/// The cost warning on every switch-on of Keep add-on engine ready.
struct WarmPrompt: Identifiable {
    let id = UUID()
}

// Keep add-on engine ready (was "Keep GPU warm"; plans/api.md "App clean-up" §6): owner only. The switch lives in
// Settings → Engines; the owner sees a small indicator in the title bar only while it's on. Members never load it and see
// no nudge, switch, bar, notification or warning.
extension AppStore {
    var warmOn: Bool { isOwner && warmGpu.isOn }
    /// As of now (minutes and cost tick between server events).
    var warmLive: WarmGpu { warmGpu.live(now: Int64(warmClock.timeIntervalSince1970 * 1000)) }
    var warmMinutesLeft: Int? { warmGpu.minutesLeft(now: Int64(warmClock.timeIntervalSince1970 * 1000)) }
    private var canWarm: Bool { warmAvailable && isOwner }

    func loadWarmGpu() async {
        guard isOwner else {
            resetWarm()
            return
        }
        do {
            let g = try await api.warmGpu()
            applyWarm(g, quiet: true)
            warmAvailable = true
        } catch let e as ApiError where ["not_found", "http_404", "owner_only"].contains(e.code) {
            // server/mock has none; owner_only should not happen for the owner.
            applyWarm(.off, quiet: true)
            warmAvailable = false
        } catch {
            // Offline: keep what we had; the next reload asks again.
        }
    }

    func resetWarm() {
        warmTicker?.cancel()
        warmTicker = nil
        warmGpu = .off
        warmAvailable = false
        warmPrompt = nil
        warmWarning = nil
        warmWarnedKey = nil
        warmBusy = false
    }

    // MARK: Switch (Settings → Engines)

    /// On always confirms with the cost warning first.
    func setWarmSwitch(_ on: Bool) {
        guard canWarm else { return }
        if on {
            guard !warmGpu.isOn, warmPrompt == nil else { return }
            withAnimation(.easeOut(duration: 0.15)) { warmPrompt = WarmPrompt() }
        } else {
            turnOffWarm()
        }
    }

    /// [Keep it ready] or [Not now].
    func answerWarmPrompt(turnOn: Bool) {
        guard warmPrompt != nil else { return }
        withAnimation(.easeIn(duration: 0.12)) { warmPrompt = nil }
        if turnOn { turnOnWarm() }
    }

    private func turnOnWarm() {
        warmBusy = true
        perform { [self] in
            defer { warmBusy = false }
            let g = try await api.setWarmGpu(.turnOn)
            applyWarm(g)
            showToast(g.isStarting ? "Getting the add-on engine ready · about 3–6 min. \(WarmGpuText.perHour(g.ratePerHour)) while it's on."
                : "Add-on engine ready · Edit renders start right away")
        }
    }

    func turnOffWarm() {
        guard warmGpu.isOn, !warmBusy else { return }
        warmBusy = true
        perform { [self] in
            defer { warmBusy = false }
            let g = try await api.setWarmGpu(.turnOff)
            applyWarm(g)
            showToast(WarmGpuText.offMessage(g.lastOff))
        }
    }

    /// "Keep ready" on the 5-minute warning: holds it another idle period, or extends the session cap once.
    func keepWarm() {
        guard warmGpu.isOn, !warmBusy else { return }
        warmBusy = true
        perform { [self] in
            defer { warmBusy = false }
            let g = try await api.setWarmGpu(.keepWarm)
            withAnimation { warmWarning = nil }
            applyWarm(g)
            showToast("Kept ready" + (g.minutesLeft(now: Int64(Date().timeIntervalSince1970 * 1000)).map { " · auto-off in \($0) min" } ?? ""))
        }
    }

    // MARK: Server updates

    /// GET/POST answers and `gpu` events (owner only). Keeps the 5-minute warning for Settings → Engines and says (as a toast)
    /// when it turned off by itself. No banners or notifications.
    func applyWarm(_ g: WarmGpu, warning: WarmGpuWarning? = nil, quiet: Bool = false) {
        guard isOwner else { return }
        let before = warmGpu
        withAnimation(.easeOut(duration: 0.25)) { warmGpu = g }
        warmClock = Date()
        if g.isOn { startWarmTicker() } else {
            warmTicker?.cancel()
            warmTicker = nil
        }

        let now = Int64(warmClock.timeIntervalSince1970 * 1000)
        if g.isOn, let w = warning ?? g.pendingWarning(now: now) {
            let key = "\(w.reason):\(w.autoOffAt)"
            if key != warmWarnedKey {
                warmWarnedKey = key
                withAnimation { warmWarning = w }
            }
        } else if warmWarning != nil, !g.isOn || g.pendingWarning(now: now) == nil {
            withAnimation { warmWarning = nil }
        }

        guard !quiet else { return }
        if before.isStarting && g.state == "warm" {
            showToast("Add-on engine ready · Edit renders start right away")
        }
        // starting/warm → stopping → off: say it once, on off. Turning it off from this Mac says so itself.
        if (before.isOn || before.state == "stopping") && g.state == "off" {
            warmWarnedKey = nil
            if !(g.lastOff?.reason == "user" && warmBusy) { showToast(WarmGpuText.offMessage(g.lastOff)) }
        }
    }

    /// Re-draws the indicator every 15 s while it's on (the server only sends news).
    private func startWarmTicker() {
        guard warmTicker == nil else { return }
        warmTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.warmClock = Date()
            }
        }
    }
}
