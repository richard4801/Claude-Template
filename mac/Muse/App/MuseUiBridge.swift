// Claude operates the MUSE window (owner, 2026-11-11: "MUSE window only"). The app reads its OWN accessibility tree
// in-process (the SwiftUI ids and labels the screens already carry) and acts on its own controls, so it needs no macOS
// Accessibility or Screen Recording permission and can't reach other apps. The window picture is drawn from MUSE's own
// view (cacheDisplay), never a screen capture. MuseCore (ClaudeUiControl.swift) holds the pure parts: ids, finding a
// control, the refusal list, what each action means.

import AppKit
import MuseCore

@MainActor
final class MuseUiBridge {
    static let shared = MuseUiBridge()

    /// True while the bridge itself sends a key (its own Escape must not count as the person's "stop").
    private(set) var synthesizing = false

    /// The live element behind each node, in the same shape as the UiElement tree.
    private final class Live {
        let obj: NSAccessibilityProtocol
        var children: [Live] = []
        init(_ obj: NSAccessibilityProtocol) { self.obj = obj }
    }

    private struct Read {
        let window: NSWindow
        let root: UiElement
        let live: Live
        let flat: UiFlat
    }

    /// The MUSE window Claude works in: the main window (never a panel, sheet or Claude's own overlays).
    func window() -> NSWindow? {
        if let w = NSApp.mainWindow, w.isVisible, !(w is NSPanel), !ClaudeUiOverlay.shared.owns(w) { return w }
        return NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) && !ClaudeUiOverlay.shared.owns($0) }
    }

    // MARK: Reading

    private static let maxNodes = 6000
    private static let maxDepth = 80

    private func read(within: String? = nil) throws -> Read {
        guard let w = window(), let content = w.contentView else { throw UiError(.failed, "MUSE has no window open right now.") }
        // An open sheet (a confirmation, a picker) is what the person sees: read it instead of the window under it.
        let top: NSView = w.attachedSheet?.contentView ?? content
        let bounds = (w.attachedSheet ?? w).frame
        var count = 0
        func walk(_ obj: NSAccessibilityProtocol, depth: Int) -> (UiElement, Live)? {
            count += 1
            if count > Self.maxNodes || depth > Self.maxDepth { return nil }
            let f = obj.accessibilityFrame()
            let onScreen = f.width > 0 && f.height > 0 && f.intersects(bounds)
            let role = UiRole.from(axRole: obj.accessibilityRole()?.rawValue ?? "", subrole: obj.accessibilitySubrole()?.rawValue)
            let live = Live(obj)
            var kids: [UiElement] = []
            for c in obj.accessibilityChildren() ?? [] {
                guard let a = c as? NSAccessibilityProtocol, let got = walk(a, depth: depth + 1) else { continue }
                kids.append(got.0)
                live.children.append(got.1)
            }
            // Off-screen leaves (rows scrolled away) are left out; containers stay for their visible children.
            if !onScreen && kids.isEmpty && f.width > 0 { return nil }
            let ident = obj.accessibilityIdentifier() ?? ""
            let label = obj.accessibilityLabel() ?? obj.accessibilityTitle() ?? obj.accessibilityPlaceholderValue()
            let el = UiElement(identifier: ident.isEmpty ? nil : ident, role: role, label: label, value: Self.text(obj.accessibilityValue()),
                               enabled: obj.isAccessibilityEnabled(), selected: role == .tab || role == .row ? obj.isAccessibilitySelected() : nil,
                               frame: onScreen ? Self.windowRect(f, in: w) : nil, children: kids)
            return (el, live)
        }
        guard let got = walk(top, depth: 0) else { throw UiError(.failed, "MUSE couldn't read its window.") }
        return Read(window: w, root: got.0, live: got.1, flat: UiTree.flatten(got.0, within: within))
    }

    private static func text(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let a as NSAttributedString: return a.string
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Screen rect → window points, top-left origin.
    private static func windowRect(_ r: NSRect, in w: NSWindow) -> UiRect {
        let local = w.convertFromScreen(r)
        let h = w.contentView?.bounds.height ?? w.frame.height
        return UiRect(x: local.minX.rounded(), y: (h - local.maxY).rounded(), w: local.width.rounded(), h: local.height.rounded())
    }

    private func live(_ r: Read, _ id: String) -> NSAccessibilityProtocol? {
        guard let path = r.flat.paths[id] else { return nil }
        var l = r.live
        for i in path {
            guard i < l.children.count else { return nil }
            l = l.children[i]
        }
        return l.obj
    }

    // MARK: Snapshot

    func snapshot(screenshot: Bool, within: String?, page: String?) throws -> (JSONValue, String?) {
        let r = try read(within: within)
        var o: [String: JSONValue] = [
            "window": .object(["title": .string(r.window.title), "width": .number(r.window.frame.width.rounded()), "height": .number(r.window.frame.height.rounded())]),
            "controls": .array(r.flat.controls.map(\.json)),
        ]
        if let page { o["page"] = .string(page) }
        if r.window.attachedSheet != nil { o["sheet"] = .bool(true) }
        if r.flat.truncated { o["truncated"] = .bool(true) }
        if r.flat.controls.isEmpty { o["note"] = .string("No controls could be read on this screen. Try screenshot: true, and report_issue so it gets fixed.") }
        return (.object(o), screenshot ? picture(r.window) : nil)
    }

    /// A small JPEG of the MUSE window only, drawn from its own views (the overlay windows aren't in it).
    func picture(_ w: NSWindow) -> String? {
        guard let view = w.contentView?.superview ?? w.contentView, view.bounds.width > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let (pw, ph) = UiShot.size(width: view.bounds.width, height: view.bounds.height)
        guard pw > 0, let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: pw, height: ph))
        NSGraphicsContext.restoreGraphicsState()
        return small.representation(using: .jpeg, properties: [.compressionFactor: 0.6])?.base64EncodedString()
    }

    // MARK: Acting

    func act(action: UiAction, target: String?, value: String?) async throws -> JSONValue {
        let r = try read()
        let control = try target.flatMap { t -> UiControl? in
            if action == .menu || action == .key { return nil }
            return try UiTree.resolve(t, in: r.flat.controls)
        }
        let op = try UiActionPlan.plan(action, value: value, target: target, control: control)
        var obj: NSAccessibilityProtocol?
        if op.needsControl {
            guard let c = control, let o = live(r, c.id) else { throw UiError(.notFound, "That control is gone. Take a fresh ui_snapshot.") }
            obj = o
            ClaudeUiOverlay.shared.ring(o.accessibilityFrame(), on: r.window)
        }
        ClaudeUiOverlay.shared.active(on: r.window)
        try await perform(op, obj, control, r)
        try? await Task.sleep(nanoseconds: 250_000_000) // let SwiftUI update before reading the result
        var out: [String: JSONValue] = ["done": .bool(true), "action": .string(action.rawValue)]
        if let c = control, let after = try? read(), let now = (try? UiTree.resolve(c.id, in: after.flat.controls)) ?? after.flat.controls.first(where: { $0.label == c.label && $0.role == c.role }) {
            out["control"] = now.json
        }
        return .object(out)
    }

    private func perform(_ op: UiOp, _ obj: NSAccessibilityProtocol?, _ c: UiControl?, _ r: Read) async throws {
        switch op {
        case .press:
            guard let obj else { return }
            if !obj.accessibilityPerformPress() { try click(obj, r.window) }
        case .focus:
            guard let obj else { return }
            focus(obj, r.window)
        case .setText(let text):
            guard let obj else { return }
            focus(obj, r.window)
            try await Task.sleep(nanoseconds: 80_000_000)
            if let tv = (r.window.attachedSheet ?? r.window).firstResponder as? NSTextView {
                tv.selectAll(nil)
                tv.insertText(text, replacementRange: tv.selectedRange())
            } else {
                obj.setAccessibilityValue(text)
            }
        case .setValue(let n):
            guard let obj else { return }
            obj.setAccessibilityValue(NSNumber(value: n))
            // Sliders that ignore a set value move step by step towards it.
            for _ in 0..<200 {
                guard let now = Double(Self.text(obj.accessibilityValue()) ?? ""), abs(now - n) > 1e-6 else { break }
                let moved = now < n ? obj.accessibilityPerformIncrement() : obj.accessibilityPerformDecrement()
                guard moved, let after = Double(Self.text(obj.accessibilityValue()) ?? ""), after != now else { break }
                if (now < n && after > n) || (now > n && after < n) { break }
            }
        case .toggle(let want):
            guard let obj, let c else { return }
            if let want, UiActionPlan.isOn(c) == want { return }
            if !obj.accessibilityPerformPress() { try click(obj, r.window) }
        case .select(let option):
            guard let obj else { return }
            try select(obj, option: option, c, r)
        case .scroll(let dir):
            guard let obj else { return }
            scroll(obj, dir, r.window)
        case .menu(let path):
            try menu(path)
        case .key(let k):
            key(k, r.window)
        }
    }

    private func focus(_ obj: NSAccessibilityProtocol, _ w: NSWindow) {
        let win = w.attachedSheet ?? w
        if let v = obj as? NSView, v.acceptsFirstResponder, win.makeFirstResponder(v) { return }
        obj.setAccessibilityFocused(true)
        if win.firstResponder is NSTextView { return }
        try? click(obj, w) // SwiftUI fields take focus from a click
    }

    /// A click in the middle of the control, inside MUSE's own window (the up event is queued first, so a control that
    /// tracks the mouse returns at once instead of waiting).
    private func click(_ obj: NSAccessibilityProtocol, _ w: NSWindow) throws {
        let target = w.attachedSheet ?? w
        let f = obj.accessibilityFrame()
        guard f.width > 0, f.height > 0 else { throw UiError(.failed, "That control isn't on screen. Scroll to it first.") }
        let p = target.convertPoint(fromScreen: NSPoint(x: f.midX, y: f.midY))
        let t = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: t, windowNumber: target.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: t + 0.05, windowNumber: target.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { throw UiError(.failed, "MUSE couldn't press that.") }
        NSApp.postEvent(up, atStart: false)
        target.sendEvent(down)
    }

    private func select(_ obj: NSAccessibilityProtocol, option: String?, _ c: UiControl?, _ r: Read) throws {
        guard let option else {
            obj.setAccessibilitySelected(true)
            if !obj.isAccessibilitySelected(), !obj.accessibilityPerformPress() { try click(obj, r.window) }
            return
        }
        // A pop-up menu (a menu-style Picker): choose the item directly, without opening the menu.
        if let pop = obj as? NSPopUpButton {
            guard let item = pop.itemArray.first(where: { $0.title.caseInsensitiveCompare(option) == .orderedSame }) ?? pop.itemArray.first(where: { $0.title.localizedCaseInsensitiveContains(option) }) else {
                throw UiError(.notFound, "“\(option)” isn't an option here. Options: \(pop.itemTitles.prefix(20).joined(separator: ", ")).")
            }
            if let why = UiRefusal.reason(text: item.title) { throw UiRefusal.refusal(why) }
            pop.select(item)
            if let action = pop.action { _ = NSApp.sendAction(action, to: pop.target, from: pop) }
            return
        }
        // Segments, tabs, list rows: the child with that label.
        func find(_ o: NSAccessibilityProtocol, depth: Int) -> NSAccessibilityProtocol? {
            if depth > 6 { return nil }
            for ch in o.accessibilityChildren() ?? [] {
                guard let a = ch as? NSAccessibilityProtocol else { continue }
                let l = a.accessibilityLabel() ?? a.accessibilityTitle() ?? Self.text(a.accessibilityValue()) ?? ""
                if l.caseInsensitiveCompare(option) == .orderedSame { return a }
                if let hit = find(a, depth: depth + 1) { return hit }
            }
            return nil
        }
        guard let opt = find(obj, depth: 0) else {
            if c?.role == .picker || c?.role == .menuButton {
                throw UiError(.failed, "This menu can't be opened by Claude yet (it would hold the app until it closes). Tell the person which option to pick, and report_issue.")
            }
            throw UiError(.notFound, "“\(option)” isn't an option of that control. Take a ui_snapshot with within: its id.")
        }
        if let why = UiRefusal.reason(text: option) { throw UiRefusal.refusal(why) }
        opt.setAccessibilitySelected(true)
        if !opt.isAccessibilitySelected(), !opt.accessibilityPerformPress() { try click(opt, r.window) }
    }

    private func scroll(_ obj: NSAccessibilityProtocol, _ dir: UiScroll, _ w: NSWindow) {
        // The nearest scroll view, when AppKit's own is reachable; else a scroll-wheel event over the control.
        var cur: Any? = obj
        for _ in 0..<12 {
            if let sv = cur as? NSScrollView, let doc = sv.documentView {
                let clip = sv.contentView
                var y = clip.bounds.origin.y
                let page = clip.bounds.height * 0.85
                let maxY = max(0, doc.frame.height - clip.bounds.height)
                let flipped = doc.isFlipped
                switch dir {
                case .down: y += flipped ? page : -page
                case .up: y += flipped ? -page : page
                case .top: y = flipped ? 0 : maxY
                case .bottom: y = flipped ? maxY : 0
                }
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(maxY, max(0, y))))
                sv.reflectScrolledClipView(clip)
                return
            }
            cur = (cur as? NSAccessibilityProtocol)?.accessibilityParent()
            if cur == nil { break }
        }
        let f = obj.accessibilityFrame()
        let p = w.convertPoint(fromScreen: NSPoint(x: f.midX, y: f.midY))
        let lines: Int32 = dir == .top ? 400 : dir == .bottom ? -400 : dir == .up ? 8 : -8
        // Straight to the view under the control (its scroll view takes the wheel through the responder chain).
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0),
              let e = NSEvent(cgEvent: cg), let cv = w.contentView,
              let hit = cv.hitTest(cv.superview?.convert(p, from: nil) ?? p) else { return }
        hit.scrollWheel(with: e)
    }

    private func menu(_ path: [String]) throws {
        guard var menu = NSApp.mainMenu else { throw UiError(.failed, "MUSE has no menu bar.") }
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces).lowercased() }
        for (i, name) in path.enumerated() {
            menu.update()
            guard let idx = menu.items.firstIndex(where: { norm($0.title) == norm(name) && !$0.isHidden }) else {
                let have = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title).prefix(25).joined(separator: ", ")
                throw UiError(.notFound, "No menu item “\(name)”. There: \(have).")
            }
            let item = menu.items[idx]
            if i == path.count - 1 {
                guard item.isEnabled else { throw UiError(.failed, "“\(item.title)” is greyed out right now.") }
                if let why = UiRefusal.menuReason([item.title]) { throw UiRefusal.refusal(why) }
                menu.performActionForItem(at: idx)
                return
            }
            guard let sub = item.submenu else { throw UiError(.notFound, "“\(item.title)” has no submenu.") }
            menu = sub
        }
    }

    private func key(_ k: UiKey, _ w: NSWindow) {
        let target = w.attachedSheet ?? w
        var flags: NSEvent.ModifierFlags = []
        if k.command { flags.insert(.command) }
        if k.shift { flags.insert(.shift) }
        let plain = k.characters
        let chars = k.shift && k.command ? k.characters.uppercased() : k.characters
        synthesizing = true
        defer { synthesizing = false }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: target.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: plain,
                                           isARepeat: false, keyCode: k.keyCode) else { continue }
            NSApp.sendEvent(e)
        }
    }

    // MARK: Waiting

    func wait(for f: UiWaitFor, target: String?, timeout: Double) async throws -> JSONValue {
        let start = Date()
        var last: String?
        var steady = 0
        while true {
            let r = try read()
            if f == .idle {
                let sig = UiTree.signature(r.flat.controls)
                steady = sig == last ? steady + 1 : 0
                last = sig
                if steady >= 2 { return .object(["met": .bool(true), "waitedMs": .number((Date().timeIntervalSince(start) * 1000).rounded())]) }
            } else {
                let m = UiTree.met(f, target: target, controls: r.flat.controls)
                if m.met {
                    var o: [String: JSONValue] = ["met": .bool(true), "waitedMs": .number((Date().timeIntervalSince(start) * 1000).rounded())]
                    if let c = m.control { o["control"] = c.json }
                    return .object(o)
                }
            }
            if Date().timeIntervalSince(start) >= timeout { return .object(["met": .bool(false), "waitedMs": .number((timeout * 1000).rounded())]) }
            try await Task.sleep(nanoseconds: 300_000_000)
            try ClaudeUiOverlay.shared.checkNotStopped()
        }
    }
}
