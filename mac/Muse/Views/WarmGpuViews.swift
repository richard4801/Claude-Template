import AppKit
import MuseCore
import SwiftUI

// Keep add-on engine ready (owner only): the cost confirmation on every switch-on, the small title-bar indicator while it's
// on, and the switch in Settings → Engines. Members see none of it. No sounds anywhere.

/// The confirmation on every switch-on: the cost warning, [Not now] [Keep it ready].
struct WarmPromptView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if store.warmPrompt != nil {
            ZStack {
                Color.black.opacity(0.38).onTapGesture { store.answerWarmPrompt(turnOn: false) }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow("Settings · Engines").styled()
                            Text(t.headingsUppercase ? WarmGpuText.confirmTitle.uppercased() : WarmGpuText.confirmTitle)
                                .font(t.isA ? Fonts.font("Instrument Serif", 40, .regular) : t.display(28, t.isD ? .heavy : .bold))
                        }
                        Spacer()
                        Image(systemName: "bolt.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(t.accent)
                    }
                    Text(WarmGpuText.costWarning(rate: store.warmGpu.ratePerHour, idleMinutes: store.warmGpu.idleMinutes)).font(t.body(14.5))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Pill("\(WarmGpuText.perHour(store.warmGpu.ratePerHour)) · billed per minute", .neutral)
                        Pill("Available \(Pricing.money(store.creditUsd))", .neutral)
                    }
                    HStack(spacing: 10) {
                        Spacer()
                        MButton(WarmGpuText.notNow) { store.answerWarmPrompt(turnOn: false) }
                        MButton(WarmGpuText.turnOn, icon: "bolt", kind: .primary) { store.answerWarmPrompt(turnOn: true) }
                    }
                }
                .padding(26)
                .frame(width: 480)
                .surface(t.surface, radius: t.rLg)
                .shadow(color: .black.opacity(0.3), radius: 40, y: 24)
            }
        }
    }
}

/// The owner's small title-bar indicator, only while it's on: "Add-on engine ready · 42 min · $2.80 · Turn off".
struct WarmIndicator: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let g = store.warmLive
        HStack(spacing: 8) {
            if g.isStarting { ProgressView().controlSize(.mini) } else { LED(on: true) }
            Text(WarmGpuText.indicator(g)).font(t.mono(12)).contentTransition(.numericText())
            Button { store.turnOffWarm() } label: {
                Text(WarmGpuText.turnOff).font(t.body(12, .semibold)).underline()
            }
            .buttonStyle(.plain)
            .disabled(store.warmBusy)
        }
        .foregroundStyle(t.ink)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(t.surface2))
        .help("Settings → Engines")
        .onTapGesture { store.openSettings(.engines) }
    }
}

/// Settings → Engines: the switch, its live status and the 5-minute warning with "Keep ready".
struct KeepReadyRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let g = store.warmLive
        VStack(alignment: .leading, spacing: 8) {
            ListRow(icon: "bolt", title: WarmGpuText.switchLabel, hint: hint(g), last: store.warmWarning == nil) {
                MToggle(isOn: Binding(get: { store.warmOn }, set: { store.setWarmSwitch($0) })).disabled(store.warmBusy || !store.warmAvailable)
            }
            if let w = store.warmWarning, g.isOn {
                HStack(spacing: 10) {
                    Image(systemName: "clock").font(.system(size: 13, weight: .semibold))
                    Text(WarmGpuText.warningTitle(w)).font(t.body(13, .semibold))
                    Spacer()
                    if w.reason != "cap" || g.canExtend {
                        MButton(WarmGpuText.keepWarm, size: .small, off: store.warmBusy) { store.keepWarm() }
                    }
                }
                .foregroundStyle(t.warnInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.warnBg))
            }
        }
    }

    private func hint(_ g: WarmGpu) -> String {
        if !store.warmAvailable { return "This server doesn't offer it." }
        if g.isStarting { return "Getting ready · about 3–6 min" }
        if g.isOn {
            let left = store.warmMinutesLeft.map { " · turns off in \($0) min without renders" } ?? ""
            return "On · \(WarmGpuText.duration(g.minutes)) · \(Pricing.money(g.costUsd)) so far\(left)"
        }
        return "Edit renders start right away · about \(WarmGpuText.perHour(g.ratePerHour)) from the studio balance · off after \(g.idleMinutes) min without renders"
    }
}
