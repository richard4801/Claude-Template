import AppKit
import MuseCore
import SwiftUI

// Keep GPU warm: the bar across the window, the 5-minute warning banner, the nudge / cost-warning card,
// the title-bar switch and indicator, the video-studio switch and the menu-bar extra. No sounds anywhere.

/// "GPU warm · 42 min · $2.80 so far · Turn off", under the title bar on every screen while it's on.
struct WarmGpuBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let g = store.warmLive
        HStack(spacing: 10) {
            if g.isStarting {
                ProgressView().controlSize(.mini).tint(fg)
            } else {
                Image(systemName: "flame.fill").font(.system(size: 12, weight: .semibold))
            }
            Text(WarmGpuText.bar(g)).font(t.mono(12.5, .medium)).contentTransition(.numericText())
            Text("·").opacity(0.6)
            Button { store.turnOffWarm() } label: {
                Text(WarmGpuText.turnOff).font(t.body(12.5, .semibold)).underline()
            }
            .buttonStyle(.plain)
            .disabled(store.warmBusy)
            Spacer(minLength: 12)
            if g.isStarting {
                Text("Your render starts as soon as it's up").font(t.body(12)).opacity(0.8)
            } else if g.busy {
                Text("Rendering on it now").font(t.body(12)).opacity(0.8)
            } else if let left = store.warmMinutesLeft {
                Text(g.autoOffReason == "cap" ? "Time limit in \(left) min" : "Turns off by itself in \(left) min without renders").font(t.body(12)).opacity(0.8)
            }
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(bg)
        .overlay(alignment: .bottom) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(height: t.lineWidth) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(WarmGpuText.bar(g))
    }

    private var bg: Color {
        switch t.id {
        case .a: return t.ink
        case .b: return t.surface2
        case .c: return t.cta
        case .d: return t.yellow
        }
    }

    private var fg: Color {
        switch t.id {
        case .a: return t.surface
        case .b: return t.accent
        case .c: return t.ctaInk
        case .d: return Color(hex: 0x111111)
        }
    }
}

/// The warning 5 minutes before an idle or cap auto-off, with "Keep warm".
struct WarmWarningBanner: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var warning: WarmGpuWarning

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark").font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(WarmGpuText.warningTitle(warning)).font(t.body(13, .bold))
                Text(WarmGpuText.warningBody(warning, canExtend: store.warmGpu.canExtend)).font(t.body(12.5))
            }
            Spacer(minLength: 8)
            if warning.reason != "cap" || store.warmGpu.canExtend {
                MButton(WarmGpuText.keepWarm, icon: "flame", kind: .primary, size: .small, off: store.warmBusy) { store.keepWarm() }
            }
            MButton(WarmGpuText.turnOff, size: .small, off: store.warmBusy) { store.turnOffWarm() }
            IconButton(systemName: "xmark", help: "Hide") { store.dismissWarmWarning() }
        }
        .foregroundStyle(t.warnInk)
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(t.warnBg)
        .overlay(alignment: .bottom) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(height: t.lineWidth) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The nudge when creating starts and the confirmation on every switch-on: the same cost warning, [Not now] [Warm up].
struct WarmPromptView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if let p = store.warmPrompt {
            ZStack {
                Color.black.opacity(0.38).onTapGesture { store.answerWarmPrompt(warmUp: false) }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(WarmGpuText.switchLabel).styled()
                            Text(heading(p)).font(t.isA ? Fonts.font("Instrument Serif", 40, .regular) : t.display(28, t.isD ? .heavy : .bold))
                        }
                        Spacer()
                        Image(systemName: "flame.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(t.accent)
                    }
                    Text(WarmGpuText.costWarning(rate: store.warmGpu.ratePerHour, idleMinutes: store.warmGpu.idleMinutes)).font(t.body(14.5)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Pill("\(WarmGpuText.perHour(store.warmGpu.ratePerHour)) · billed per minute", .neutral)
                        Pill("Your credit \(Pricing.money(store.creditUsd))", .neutral)
                    }
                    if p.then != nil {
                        Muted("Your render goes ahead either way.")
                    }
                    HStack(spacing: 10) {
                        Spacer()
                        MButton(WarmGpuText.notNow) { store.answerWarmPrompt(warmUp: false) }
                        MButton(WarmGpuText.warmUp, icon: "flame", kind: .primary) { store.answerWarmPrompt(warmUp: true) }
                    }
                }
                .padding(26)
                .frame(width: 480)
                .surface(t.surface, radius: t.rLg)
                .shadow(color: .black.opacity(0.3), radius: 40, y: 24)
            }
        }
    }

    private func heading(_ p: WarmPrompt) -> String {
        let s = p.kind == .nudge ? WarmGpuText.nudgeTitle : "Keep a GPU warm?"
        return t.headingsUppercase ? s.uppercased() : s
    }
}

/// Title bar: "Keep GPU warm" with a switch while it's off; a live indicator ("Starting…" or "42 min · $2.80") and the switch while it's on.
struct WarmTitleControl: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let g = store.warmLive
        HStack(spacing: 8) {
            if g.isOn {
                if g.isStarting { ProgressView().controlSize(.mini) } else { LED(on: true) }
                Text(WarmGpuText.indicator(g)).font(t.mono(12)).contentTransition(.numericText())
            } else {
                Image(systemName: "flame").font(.system(size: 12, weight: .semibold))
                Text("GPU warm").font(t.body(12.5))
            }
            MToggle(isOn: Binding(get: { store.warmOn }, set: { store.setWarmSwitch($0) }))
                .scaleEffect(0.62)
                .frame(width: 32, height: 20)
                .disabled(store.warmBusy)
        }
        .foregroundStyle(g.isOn ? t.ink : t.muted)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(Capsule().fill(t.surface2))
        .help(g.isOn ? WarmGpuText.bar(g) : "\(WarmGpuText.switchLabel): renders start right away · about \(WarmGpuText.perHour(g.ratePerHour))")
    }
}

/// The video studio's switch, above Generate.
struct WarmStudioRow: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let g = store.warmLive
        OptionRow(title: WarmGpuText.switchLabel, hint: hint(g)) {
            MToggle(isOn: Binding(get: { store.warmOn }, set: { store.setWarmSwitch($0) })).disabled(store.warmBusy)
        }
    }

    private func hint(_ g: WarmGpu) -> String {
        if g.isStarting { return "Starting… · your render starts as soon as it's up" }
        if g.isOn { return "On · \(WarmGpuText.duration(g.minutes)) · \(Pricing.money(g.costUsd)) so far" }
        return "Renders start right away · about \(WarmGpuText.perHour(g.ratePerHour))"
    }
}

/// The menu-bar extra while it's on: status, Keep warm, Turn off.
struct WarmMenuBarContent: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let g = store.warmLive
        Text(WarmGpuText.bar(g))
        if let left = store.warmMinutesLeft, !g.isStarting, !g.busy {
            Text(g.autoOffReason == "cap" ? "Time limit in \(left) min" : "Turns off by itself in \(left) min without renders")
        }
        Divider()
        if store.warmWarning != nil {
            Button(WarmGpuText.keepWarm) { store.keepWarm() }
        }
        Button(WarmGpuText.turnOff) { store.turnOffWarm() }
        Divider()
        Button("Open MUSE") { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// The menu-bar label: a flame and the short status.
struct WarmMenuBarLabel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let g = store.warmLive
        HStack(spacing: 4) {
            Image(systemName: g.isStarting ? "flame" : "flame.fill")
            Text(WarmGpuText.indicator(g))
        }
    }
}
