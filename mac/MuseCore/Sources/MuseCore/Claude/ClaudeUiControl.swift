import Foundation

// Claude operates the MUSE window (owner, 2026-11-11: "Claude cursor control: MUSE window only"). A fallback for anything
// no dedicated tool covers. The app reads its OWN accessibility tree in-process (SwiftUI ids and labels) and acts on its
// own controls, so it needs no macOS Accessibility or Screen Recording permission and never reaches other apps. The
// server relays Claude's ui_snapshot / ui_act / ui_wait as `{type: "claude", op: "uiCall", call}`; one of the person's
// Macs claims the call, does it and posts the answer (server/api/src/claude/uiControl.ts). This file is the pure part:
// the call, the control list Claude sees, finding a control again, the refusal list and what each action means.

/// One call from Claude, as the server relays it.
public struct UiCall: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var args: JSONValue
    public var expiresAt: Double?
    public init(id: String, kind: String, args: JSONValue = .object([:]), expiresAt: Double? = nil) {
        self.id = id
        self.kind = kind
        self.args = args
        self.expiresAt = expiresAt
    }
}

public struct UiCallList: Codable, Hashable, Sendable {
    public var calls: [UiCall]
}

/// The reason codes the server understands (and keeps out of Claude's auto-reported issues for stopped/off/protected).
public enum UiErrorCode: String, Codable, Sendable {
    case stopped, off, protected
    case notFound = "not_found"
    case failed
}

public struct UiError: Error, Hashable, Sendable {
    public var code: UiErrorCode
    public var message: String
    public init(_ code: UiErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public static let stopped = UiError(.stopped, "The person pressed Esc to stop Claude using MUSE's screen. Don't try again this turn: ask them what they want.")
    public static let off = UiError(.off, "The person turned off “Let Claude operate MUSE's screen” (Settings → Claude). Tell them what to press instead, or ask them to turn it on.")
}

public enum UiAction: String, CaseIterable, Codable, Sendable {
    case press, focus, select, toggle, scroll, menu, key
    case setText = "set_text"
    case setValue = "set_value"
}

public enum UiWaitFor: String, CaseIterable, Codable, Sendable {
    case appears, disappears, enabled, idle
}

/// What Claude asked for, checked.
public enum UiRequest: Hashable, Sendable {
    case snapshot(screenshot: Bool, within: String?)
    case act(action: UiAction, target: String?, value: String?)
    case wait(for: UiWaitFor, target: String?, timeout: Double)

    public static func parse(_ c: UiCall) throws -> UiRequest {
        let o: [String: JSONValue]
        if case .object(let x) = c.args { o = x } else { o = [:] }
        func s(_ k: String) -> String? {
            if case .string(let v)? = o[k] { let t = v.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : v }
            return nil
        }
        switch c.kind {
        case "snapshot":
            var shot = false
            if case .bool(let b)? = o["screenshot"] { shot = b }
            return .snapshot(screenshot: shot, within: s("within"))
        case "act":
            guard let a = s("action").flatMap(UiAction.init(rawValue:)) else { throw UiError(.failed, "Unknown action") }
            return .act(action: a, target: s("target")?.trimmingCharacters(in: .whitespacesAndNewlines), value: s("value"))
        case "wait":
            guard let f = s("for").flatMap(UiWaitFor.init(rawValue:)) else { throw UiError(.failed, "Unknown wait") }
            var t = 10.0
            if case .number(let n)? = o["timeout"] { t = min(30, max(1, n)) }
            return .wait(for: f, target: s("target")?.trimmingCharacters(in: .whitespacesAndNewlines), timeout: t)
        default:
            throw UiError(.failed, "This MUSE app doesn't know “\(c.kind)”. Update MUSE.")
        }
    }
}

// MARK: The control tree

/// The kinds of control Claude is told about (from the AppKit accessibility role and subrole).
public enum UiRole: String, Codable, Sendable {
    case button, link, textField, textArea, secureField, slider, stepper, toggle, picker, tab, row, menuButton, comboBox
    case scrollArea, list, group, image, text, other

    /// AppKit's role/subrole strings (NSAccessibility.Role / .Subrole raw values) → a role.
    public static func from(axRole: String, subrole: String? = nil) -> UiRole {
        if subrole == "AXSecureTextField" { return .secureField }
        if subrole == "AXSwitch" || subrole == "AXToggle" { return .toggle }
        if subrole == "AXTabButton" { return .tab }
        switch axRole {
        case "AXButton": return .button
        case "AXLink": return .link
        case "AXTextField", "AXSearchField": return .textField
        case "AXTextArea": return .textArea
        case "AXSlider": return .slider
        case "AXIncrementor", "AXStepper": return .stepper
        case "AXCheckBox", "AXSwitch", "AXDisclosureTriangle": return .toggle
        case "AXPopUpButton": return .picker
        case "AXRadioButton", "AXTab": return .tab
        case "AXRow", "AXCell", "AXOutlineRow": return .row
        case "AXMenuButton": return .menuButton
        case "AXComboBox": return .comboBox
        case "AXScrollArea": return .scrollArea
        case "AXList", "AXTable", "AXOutline", "AXTabGroup", "AXRadioGroup", "AXSegmentedControl": return .list
        case "AXGroup", "AXSplitGroup", "AXToolbar", "AXLayoutArea": return .group
        case "AXImage": return .image
        case "AXStaticText", "AXHeading": return .text
        default: return .other
        }
    }

    /// Something a person can operate.
    public var interactive: Bool {
        switch self {
        case .button, .link, .textField, .textArea, .secureField, .slider, .stepper, .toggle, .picker, .tab, .row, .menuButton, .comboBox, .scrollArea: return true
        default: return false
        }
    }
    public var takesText: Bool { self == .textField || self == .textArea || self == .comboBox }
}

public struct UiRect: Codable, Hashable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

/// One element the app read from its own accessibility tree (the app fills it; MuseCore turns it into controls).
public struct UiElement: Hashable, Sendable {
    public var identifier: String?
    public var role: UiRole
    public var label: String?
    public var value: String?
    public var enabled: Bool
    public var selected: Bool?
    /// In window points, top-left origin (nil: not on screen).
    public var frame: UiRect?
    public var children: [UiElement]
    public init(identifier: String? = nil, role: UiRole, label: String? = nil, value: String? = nil, enabled: Bool = true, selected: Bool? = nil,
                frame: UiRect? = nil, children: [UiElement] = []) {
        self.identifier = identifier
        self.role = role
        self.label = label
        self.value = value
        self.enabled = enabled
        self.selected = selected
        self.frame = frame
        self.children = children
    }
}

/// What Claude sees for one control.
public struct UiControl: Codable, Hashable, Sendable {
    public var id: String
    public var role: UiRole
    public var label: String?
    public var value: String?
    public var enabled: Bool
    public var selected: Bool?
    /// The person's own: Claude must not operate it (keys, prices, sign-out, payments, deletes, passwords).
    public var protected: Bool?
    public var frame: UiRect?
    public init(id: String, role: UiRole, label: String? = nil, value: String? = nil, enabled: Bool = true, selected: Bool? = nil, protected: Bool? = nil, frame: UiRect? = nil) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.enabled = enabled
        self.selected = selected
        self.protected = protected
        self.frame = frame
    }
}

public struct UiFlat: Hashable, Sendable {
    public var controls: [UiControl]
    /// Each control's place in the tree (child indexes from the root), so the app finds the element again.
    public var paths: [String: [Int]]
    public var truncated: Bool
}

public enum UiTree {
    public static let maxControls = 400
    static let maxText = 200

    static func clean(_ s: String?, _ max: Int = maxText) -> String? {
        guard let s else { return nil }
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > max ? String(t.prefix(max)) + "…" : t
    }

    /// A short, stable word from a label: "Add to queue" → "add-to-queue".
    public static func slug(_ s: String) -> String {
        var out = ""
        var dash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch); dash = false } else if !dash && !out.isEmpty { out.append("-"); dash = true }
            if out.count >= 32 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// The tree → the flat list Claude sees. Ids: the SwiftUI accessibility identifier when there is one; otherwise the
    /// nearest identified container + role + label ("suite.composer/button:generate"); repeats get "#2", "#3". Only
    /// controls, labelled text and images, and identified containers are listed. `within`: only inside that container.
    public static func flatten(_ root: UiElement, within: String? = nil, limit: Int = maxControls) -> UiFlat {
        var controls: [UiControl] = []
        var paths: [String: [Int]] = [:]
        var seen: [String: Int] = [:]
        var truncated = false

        func unique(_ base: String) -> String {
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return n == 1 ? base : "\(base)#\(n)"
        }

        func walk(_ e: UiElement, path: [Int], scope: String?, inside: Bool) {
            let ident = clean(e.identifier, 120)
            let label = clean(e.label)
            let nowInside = inside || (within != nil && ident == within)
            var childScope = scope
            let listed = e.role.interactive || ((e.role == .text || e.role == .image) && label != nil) || (ident != nil && (e.role == .group || e.role == .list || e.role == .other))
            if listed && nowInside {
                if controls.count >= limit { truncated = true; return }
                let base: String
                if let ident { base = ident } else {
                    let word = slug(label ?? clean(e.value, 40) ?? "")
                    base = "\(scope.map { "\($0)/" } ?? "")\(e.role.rawValue)\(word.isEmpty ? "" : ":\(word)")"
                }
                let id = unique(base)
                var c = UiControl(id: id, role: e.role, label: label, value: e.role == .secureField ? nil : clean(e.value), enabled: e.enabled, selected: e.selected, frame: e.frame)
                if UiRefusal.reason(c) != nil { c.protected = true }
                controls.append(c)
                paths[id] = path
            }
            if ident != nil, e.role == .group || e.role == .list || e.role == .scrollArea || e.role == .other { childScope = ident }
            for (i, ch) in e.children.enumerated() {
                if truncated { return }
                walk(ch, path: path + [i], scope: childScope, inside: nowInside)
            }
        }
        walk(root, path: [], scope: nil, inside: within == nil)
        return UiFlat(controls: controls, paths: paths, truncated: truncated)
    }

    /// The element at a path (nil when the screen changed under it).
    public static func element(_ root: UiElement, at path: [Int]) -> UiElement? {
        var e = root
        for i in path {
            guard i < e.children.count else { return nil }
            e = e.children[i]
        }
        return e
    }

    /// Finds Claude's target: an exact id, else a unique label (exact, then contained), preferring enabled controls.
    public static func resolve(_ target: String, in controls: [UiControl]) throws -> UiControl {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = controls.first(where: { $0.id == t }) { return c }
        let low = t.lowercased()
        func pick(_ list: [UiControl]) throws -> UiControl? {
            guard !list.isEmpty else { return nil }
            if list.count == 1 { return list[0] }
            let live = list.filter { $0.enabled && $0.role.interactive }
            if live.count == 1 { return live[0] }
            let ids = list.prefix(6).map(\.id).joined(separator: ", ")
            throw UiError(.notFound, "“\(t)” matches \(list.count) controls (\(ids)\(list.count > 6 ? ", …" : "")). Use one id from ui_snapshot.")
        }
        if let c = try pick(controls.filter { $0.label?.lowercased() == low }) { return c }
        if let c = try pick(controls.filter { ($0.label?.lowercased().contains(low) ?? false) || $0.id.lowercased().hasSuffix(low) }) { return c }
        throw UiError(.notFound, "No control “\(t)” on the MUSE window now. Take a fresh ui_snapshot (the screen may have changed).")
    }

    /// A short fingerprint of what the window shows (ui_wait idle: unchanged twice in a row).
    public static func signature(_ controls: [UiControl]) -> String {
        controls.map { "\($0.id)|\($0.label ?? "")|\($0.value ?? "")|\($0.enabled)|\($0.selected ?? false)" }.joined(separator: "\n")
    }

    /// ui_wait: is the condition met in this list?
    public static func met(_ f: UiWaitFor, target: String?, controls: [UiControl]) -> (met: Bool, control: UiControl?) {
        guard let target else { return (false, nil) }
        let c = try? resolve(target, in: controls)
        switch f {
        case .appears: return (c != nil, c)
        case .disappears: return (c == nil, nil)
        case .enabled: return ((c?.enabled ?? false), c)
        case .idle: return (false, nil)
        }
    }
}

// MARK: Never Claude's

/// Controls Claude never operates (the server's claude/uiControl.ts keeps the same list): keys, providers, prices,
/// sign-out, account deletion, payments, delete confirmations, passwords. Claude can open these screens; the person presses.
public enum UiRefusal {
    static let rules: [(String, String)] = [
        (#"\b(api[\s_-]?key|secret|token|password|passcode|credential)s?\b"#, "keys, tokens and passwords"),
        (#"\bprovider(s)?\b|\bproviders?[._-]"#, "provider settings"),
        (#"\b(price|prices|pricing|markup|margin|per[\s_-]?second rate)\b"#, "prices"),
        (#"\b(sign|log)[\s_-]?out\b|\bsignout\b|\blogout\b"#, "signing out"),
        (#"\b(delete|close|remove)[\s_-]?(my[\s_-]?)?account\b|\baccount[._\s-]?delet"#, "deleting the account"),
        (#"\b(top[\s_-]?up|topup|payment|pay now|checkout|buy credits|add credits|add funds|billing|card number|transfer credits)\b"#, "payments and top-ups"),
        (#"(^|[._\s-])(confirm[\s_-]?)?(delete|discard|erase)\b"#, "deleting"),
        (#"\$\s?\d|\b\d+(\.\d+)?\s?credits?\b|\b(generate|regenerate|run queue|run again|retry|upscale|train|retrain|post now|post|publish|schedule post)\b"#, "spending or posting"),
        (#"\b(approve|allow once|always allow|allow)\b"#, "go-ahead cards"),
    ]
    static let compiled: [(NSRegularExpression, String)] = rules.compactMap { r in
        (try? NSRegularExpression(pattern: r.0, options: [.caseInsensitive])).map { ($0, r.1) }
    }
    /// Menu items that would quit, close or hide MUSE (Claude stays inside the window).
    static let menuWords: Set<String> = ["quit", "close", "close window", "close all", "hide", "hide muse", "hide others", "minimize", "minimise", "zoom", "enter full screen"]

    public static func reason(text: String) -> String? {
        let r = NSRange(text.startIndex..., in: text)
        for (re, why) in compiled where re.firstMatch(in: text, range: r) != nil { return why }
        return nil
    }

    public static func reason(_ c: UiControl) -> String? {
        if c.role == .secureField { return "keys, tokens and passwords" }
        if c.id.hasPrefix("claude.chat") { return "the person's own chat box" }
        return reason(text: c.id) ?? c.label.flatMap { reason(text: $0) }
    }

    public static func menuReason(_ path: [String]) -> String? {
        for p in path {
            let w = p.lowercased().replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
            if menuWords.contains(w) || w.hasPrefix("quit ") || w.hasPrefix("hide ") { return "quitting, closing or hiding MUSE" }
            if let why = reason(text: p) { return why }
        }
        return nil
    }

    public static func refusal(_ why: String) -> UiError {
        UiError(.protected, "That control is for the person, not Claude (\(why)). Use the dedicated tool, which asks them with a go-ahead card, or open the screen and tell them what to press.")
    }
}

// MARK: What each action does

public enum UiScroll: String, Sendable { case up, down, top, bottom }

/// A key Claude may press in the MUSE window (the server allows the same list).
public struct UiKey: Hashable, Sendable {
    public var keyCode: UInt16
    public var characters: String
    public var command: Bool
    public var shift: Bool

    public static let table: [String: UiKey] = [
        "return": UiKey(keyCode: 36, characters: "\r", command: false, shift: false),
        "escape": UiKey(keyCode: 53, characters: "\u{1b}", command: false, shift: false),
        "tab": UiKey(keyCode: 48, characters: "\t", command: false, shift: false),
        "shift+tab": UiKey(keyCode: 48, characters: "\t", command: false, shift: true),
        "space": UiKey(keyCode: 49, characters: " ", command: false, shift: false),
        "up": UiKey(keyCode: 126, characters: "\u{F700}", command: false, shift: false),
        "down": UiKey(keyCode: 125, characters: "\u{F701}", command: false, shift: false),
        "left": UiKey(keyCode: 123, characters: "\u{F702}", command: false, shift: false),
        "right": UiKey(keyCode: 124, characters: "\u{F703}", command: false, shift: false),
        "delete": UiKey(keyCode: 51, characters: "\u{7f}", command: false, shift: false),
        "cmd+z": UiKey(keyCode: 6, characters: "z", command: true, shift: false),
        "cmd+shift+z": UiKey(keyCode: 6, characters: "z", command: true, shift: true),
        "cmd+a": UiKey(keyCode: 0, characters: "a", command: true, shift: false),
        "cmd+c": UiKey(keyCode: 8, characters: "c", command: true, shift: false),
        "cmd+v": UiKey(keyCode: 9, characters: "v", command: true, shift: false),
        "cmd+f": UiKey(keyCode: 3, characters: "f", command: true, shift: false),
    ]
    public static func parse(_ s: String) -> UiKey? { table[s.trimmingCharacters(in: .whitespaces).lowercased()] }
}

/// One concrete operation the app performs.
public enum UiOp: Hashable, Sendable {
    case press
    case setText(String)
    case setValue(Double)
    case select(String?)
    case toggle(Bool?)
    case scroll(UiScroll)
    case menu([String])
    case focus
    case key(UiKey)

    /// Does this act need a control on the window? (menu and key don't.)
    public var needsControl: Bool {
        switch self { case .menu, .key: return false; default: return true }
    }
}

public enum UiActionPlan {
    /// Claude's action + the control it named → the operation, or a plain error Claude can correct.
    public static func plan(_ action: UiAction, value: String?, target: String?, control: UiControl?) throws -> UiOp {
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .key:
            guard let k = v.flatMap(UiKey.parse) else { throw UiError(.failed, "Unknown key “\(v ?? "")”.") }
            return .key(k)
        case .menu:
            let path = (target ?? "").components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard path.count >= 2 else { throw UiError(.failed, "menu: give the path, like “File > Export”.") }
            if let why = UiRefusal.menuReason(path) { throw UiRefusal.refusal(why) }
            return .menu(path)
        default: break
        }
        guard let c = control else { throw UiError(.notFound, "No control named.") }
        if let why = UiRefusal.reason(c) { throw UiRefusal.refusal(why) }
        let name = c.label.map { "“\($0)”" } ?? c.id
        if !c.enabled, action != .scroll, action != .focus { throw UiError(.failed, "\(name) is greyed out right now (something else is needed first).") }
        switch action {
        case .press:
            if c.role.takesText { throw UiError(.failed, "\(name) is a text field: use set_text.") }
            if c.role == .slider { throw UiError(.failed, "\(name) is a slider: use set_value.") }
            // Opening a pop-up menu would hold the app until it closes: pick the option directly instead.
            if c.role == .picker || c.role == .menuButton { throw UiError(.failed, "\(name) opens a menu: use select with the option's label as value.") }
            return .press
        case .setText:
            guard c.role.takesText else { throw UiError(.failed, "\(name) is a \(c.role.rawValue), not a text field.") }
            return .setText(value ?? "")
        case .setValue:
            guard c.role == .slider || c.role == .stepper else { throw UiError(.failed, "\(name) is a \(c.role.rawValue): set_value is for sliders and steppers.") }
            guard let s = v, let n = Double(s.replacingOccurrences(of: ",", with: ".")), n.isFinite else { throw UiError(.failed, "set_value needs a number.") }
            return .setValue(n)
        case .select:
            guard [.picker, .tab, .row, .comboBox, .menuButton, .list, .button].contains(c.role) else { throw UiError(.failed, "\(name) is a \(c.role.rawValue): nothing to select.") }
            if let v, let why = UiRefusal.reason(text: v) { throw UiRefusal.refusal(why) }
            return .select(v?.isEmpty == true ? nil : v)
        case .toggle:
            guard c.role == .toggle else { throw UiError(.failed, "\(name) is a \(c.role.rawValue), not a switch or checkbox.") }
            switch v?.lowercased() {
            case nil, "": return .toggle(nil)
            case "on", "true", "yes", "1": return .toggle(true)
            case "off", "false", "no", "0": return .toggle(false)
            default: throw UiError(.failed, "toggle: value “on” or “off” (or leave it out to flip).")
            }
        case .scroll:
            guard let d = UiScroll(rawValue: (v ?? "down").lowercased()) else { throw UiError(.failed, "scroll: up, down, top or bottom.") }
            return .scroll(d)
        case .focus: return .focus
        case .menu, .key: fatalError("handled above")
        }
    }

    /// Is a toggle in the state asked for already? (on/off is read from its value "1"/"0".)
    public static func isOn(_ c: UiControl) -> Bool? {
        switch c.value?.lowercased() {
        case "1", "on", "true": return true
        case "0", "off", "false": return false
        default: return c.selected
        }
    }
}

// MARK: The picture

public enum UiShot {
    /// The window picture's size: at most `maxSide` on its long side, never upscaled.
    public static func size(width: Double, height: Double, maxSide: Double = 1280) -> (Int, Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let s = min(1, maxSide / max(width, height))
        return (max(1, Int((width * s).rounded())), max(1, Int((height * s).rounded())))
    }
}

/// The answer the Mac posts to POST /v1/claude/ui/:id.
public struct UiAnswer: Encodable, Sendable {
    public var result: JSONValue?
    public var image: String?
    public var error: String?
    public var code: UiErrorCode?
    public init(result: JSONValue) { self.result = result }
    public init(result: JSONValue, image: String?) { self.result = result; self.image = image }
    public init(error: UiError) { self.error = error.message; self.code = error.code }
}

public extension UiControl {
    /// As JSON for Claude (no frame: it's for the app's ring; Claude reads ids, labels and values).
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "role": .string(role.rawValue), "enabled": .bool(enabled)]
        if let label { o["label"] = .string(label) }
        if let value { o["value"] = .string(value) }
        if let selected { o["selected"] = .bool(selected) }
        if protected == true { o["protected"] = .bool(true) }
        return .object(o)
    }
}
