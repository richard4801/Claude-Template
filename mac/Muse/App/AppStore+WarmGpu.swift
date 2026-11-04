import MuseCore
import SwiftUI

/// The nudge when creating starts, or the cost warning on a switch-on. Both say the same thing; neither has "don't ask again".
struct WarmPrompt: Identifiable {
    enum Kind { case nudge, confirm }
    let id = UUID()
    var kind: Kind
    /// What creating was about to do (Generate). Runs after either answer.
    var then: (@MainActor () -> Void)?
}

// Keep GPU warm (plans/backend.md): the nudge, the switch, the bar, the 5-minute warning and auto-off.
extension AppStore {
    var warmOn: Bool { warmGpu.isOn }
    /// The warm GPU as of now (minutes and cost tick between server events).
    var warmLive: WarmGpu { warmGpu.live(now: Int64(warmClock.timeIntervalSince1970 * 1000)) }
    var warmMinutesLeft: Int? { warmGpu.minutesLeft(now: Int64(warmClock.timeIntervalSince1970 * 1000)) }
    private var canWarm: Bool { warmAvailable && user != nil }

    func loadWarmGpu() async {
        do {
            let g = try await api.warmGpu()
            applyWarm(g, quiet: true)
        } catch let e as ApiError where ["not_found", "http_404"].contains(e.code) {
            // server/mock has no warm GPU.
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
        warmPrompt = nil
        warmWarning = nil
        warmWarnedKey = nil
        warmBusy = false
        Notifier.shared.clearWarmWarning()
    }

    // MARK: Nudge and switch

    /// Creating starts (a clip picked or dropped in the video studio, or Generate pressed). Asks to warm a GPU when none is
    /// running for this user. `then` (Generate) runs after the answer, whichever it is.
    /// Returns false when nothing was shown and the caller should carry on itself.
    @discardableResult
    func creatingStarted(then: (@MainActor () -> Void)? = nil) -> Bool {
        guard canWarm, !warmGpu.isOn, warmPrompt == nil, !warmBusy else { return false }
        withAnimation(.easeOut(duration: 0.15)) { warmPrompt = WarmPrompt(kind: .nudge, then: then) }
        return true
    }

    /// The "Keep GPU warm" switch (video studio, title bar, menus). On always confirms with the cost warning first.
    func setWarmSwitch(_ on: Bool) {
        guard canWarm else { return }
        if on {
            guard !warmGpu.isOn, warmPrompt == nil else { return }
            withAnimation(.easeOut(duration: 0.15)) { warmPrompt = WarmPrompt(kind: .confirm) }
        } else {
            turnOffWarm()
        }
    }

    /// [Warm up] or [Not now].
    func answerWarmPrompt(warmUp: Bool) {
        guard let p = warmPrompt else { return }
        withAnimation(.easeIn(duration: 0.12)) { warmPrompt = nil }
        if warmUp { turnOnWarm(then: p.then) } else { p.then?() }
    }

    private func turnOnWarm(then: (@MainActor () -> Void)?) {
        warmBusy = true
        let api = self.api
        Task { [weak self] in
            do {
                let g = try await api.setWarmGpu(.turnOn)
                guard let self else { return }
                self.warmBusy = false
                self.applyWarm(g)
                self.showToast(g.isStarting ? "Starting a warm GPU · about 3–6 min. \(WarmGpuText.perHour(g.ratePerHour)) while it's on." : "GPU warm · your renders start right away")
            } catch let e as ApiError {
                self?.warmBusy = false
                self?.handle(e)
            } catch {
                self?.warmBusy = false
                self?.showToast(error.localizedDescription)
            }
            then?()
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

    /// "Keep warm" on the 5-minute warning: holds it another idle period, or extends the session cap once.
    func keepWarm() {
        guard warmGpu.isOn, !warmBusy else { return }
        warmBusy = true
        perform { [self] in
            defer { warmBusy = false }
            let g = try await api.setWarmGpu(.keepWarm)
            withAnimation { warmWarning = nil }
            Notifier.shared.clearWarmWarning()
            applyWarm(g)
            showToast("Kept warm" + (g.minutesLeft(now: Int64(Date().timeIntervalSince1970 * 1000)).map { " · auto-off in \($0) min" } ?? ""))
        }
    }

    func dismissWarmWarning() {
        withAnimation { warmWarning = nil }
    }

    // MARK: Server updates

    /// GET/POST answers and `gpu` events (`warning` set on `event: "warning"`). Says when it's ready, warns 5 minutes before an
    /// auto-off (banner and notification), and says when it turned off.
    func applyWarm(_ g: WarmGpu, warning: WarmGpuWarning? = nil, quiet: Bool = false) {
        let before = warmGpu
        withAnimation(.easeOut(duration: 0.25)) { warmGpu = g }
        // The owner can keep the switch to themselves (studio setting warmGpuAllowed); the bar still shows a GPU already on.
        warmAvailable = g.allowed || g.isOn
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
                // A warning found on a reload is shown as a banner only.
                if warning != nil && !quiet {
                    Notifier.shared.postWarmWarning(title: WarmGpuText.warningTitle(w), body: WarmGpuText.warningBody(w, canExtend: g.canExtend))
                }
            }
        } else if warmWarning != nil, !g.isOn || g.pendingWarning(now: now) == nil {
            // Kept warm (here or on another device), or off.
            withAnimation { warmWarning = nil }
            Notifier.shared.clearWarmWarning()
        }

        guard !quiet else { return }
        if before.isStarting && g.state == "warm" {
            showToast("Warm GPU ready · your next render starts right away")
        }
        // starting/warm → stopping → off: say it once, on off.
        if (before.isOn || before.state == "stopping") && g.state == "off" {
            warmWarnedKey = nil
            Notifier.shared.clearWarmWarning()
            // Turning it off from this Mac says so itself; auto-offs (and a switch-off elsewhere) are told here.
            if !(g.lastOff?.reason == "user" && warmBusy) {
                let msg = WarmGpuText.offMessage(g.lastOff)
                showToast(msg)
                if g.lastOff?.reason != "user" { Notifier.shared.post(title: "Warm GPU turned off", body: msg) }
            }
        }
    }

    /// Re-draws the bar and the indicators every 15 s while it's on (the server only sends news).
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
