// What the person sees while Claude operates MUSE's window: a soft ring on each control Claude touches, and a small pill
// "Claude is using MUSE · Esc to stop" at the top of the window. Esc stops at once: the call running now and every
// ui_* call until the person writes to Claude again. Both are child windows of the MUSE window that ignore the mouse,
// so they never get in the person's way and never appear in the window picture Claude sees.

import AppKit
import MuseCore
import SwiftUI

@MainActor
final class ClaudeUiOverlay {
    static let shared = ClaudeUiOverlay()

    /// The person pressed Esc: no ui_* call runs until they write to Claude again.
    private(set) var stopped = false
    private var pill: NSWindow?
    private var rings: [NSWindow] = []
    private var hideTask: Task<Void, Never>?
    private var escMonitor: Any?
    /// Claude is working the window now (a call is running, or ran in the last few seconds).
    private(set) var busy = false

    func owns(_ w: NSWindow) -> Bool { w === pill || rings.contains { $0 === w } }

    /// A new message from the person: Claude may use the screen again.
    func reset() { stopped = false }

    func checkNotStopped() throws { if stopped { throw UiError.stopped } }

    /// Shows the pill (and listens for Esc) while Claude works; hides a few seconds after the last call.
    func active(on w: NSWindow) {
        busy = true
        installEsc()
        showPill(on: w)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        busy = false
        if let p = pill { p.parent?.removeChildWindow(p); p.orderOut(nil) }
        pill = nil
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    private func installEsc() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 53, self.busy, !MuseUiBridge.shared.synthesizing else { return e }
            self.stopped = true
            self.hide()
            return nil // the person's Esc stops Claude; it doesn't also close what's open
        }
    }

    private func showPill(on w: NSWindow) {
        if let p = pill, p.parent === w { position(p, on: w); return }
        if let p = pill { p.parent?.removeChildWindow(p); p.orderOut(nil) }
        let host = NSHostingView(rootView: ClaudeUiPill())
        host.frame.size = host.fittingSize
        let p = Self.overlayWindow(size: host.fittingSize)
        p.contentView = host
        w.addChildWindow(p, ordered: .above)
        position(p, on: w)
        pill = p
    }

    private func position(_ p: NSWindow, on w: NSWindow) {
        let s = p.frame.size
        p.setFrameOrigin(NSPoint(x: w.frame.midX - s.width / 2, y: w.frame.maxY - s.height - 44))
    }

    /// A soft ring around a control (screen rect), fading out after a moment.
    func ring(_ r: NSRect, on w: NSWindow) {
        guard r.width > 0, r.height > 0 else { return }
        let box = r.insetBy(dx: -4, dy: -4)
        let win = Self.overlayWindow(size: box.size)
        win.setFrame(box, display: false)
        let v = NSView(frame: NSRect(origin: .zero, size: box.size))
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 2.5
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        win.contentView = v
        w.addChildWindow(win, ordered: .above)
        rings.append(win)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            // The completion-handler form: inside a Task the trailing-closure call picks the async overload.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                win.animator().alphaValue = 0
            }, completionHandler: nil)
            try? await Task.sleep(nanoseconds: 400_000_000)
            win.parent?.removeChildWindow(win)
            win.orderOut(nil)
            self?.rings.removeAll { $0 === win }
        }
    }

    private static func overlayWindow(size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.collectionBehavior = [.transient, .ignoresCycle]
        return w
    }
}

/// "Claude is using MUSE · Esc to stop".
private struct ClaudeUiPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            Text("Claude is using MUSE")
                .font(.system(size: 12, weight: .medium))
            Text("·").foregroundStyle(.secondary)
            Text("Esc to stop")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .padding(4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude is using MUSE. Press Escape to stop.")
    }
}
