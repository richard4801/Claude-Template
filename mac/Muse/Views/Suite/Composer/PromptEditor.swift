import AppKit
import MuseCore
import SwiftUI

// AI suite (workstream 1): the composer's prompt with inline tokens (C5). An NSTextView where @character and #move
// chips are text attachments: typing `@` or `#` opens a suggestion list (↑/↓, Return, Esc), at most two moves, and
// clicking a chip opens intensity (subtle → strong, moves) and Remove. The rules live in MuseCore (PromptTokens).

/// What is being typed at the caret: the trigger, the text part it is in and the caret's place in that part.
struct TypedTrigger: Equatable {
    var trigger: PromptTrigger
    var part: Int
    var caret: Int
}

/// Lets the SwiftUI side insert a suggestion and move the caret after it.
final class PromptController {
    weak var textView: TokenTextView?
    /// Keys the suggestion list handles while it is open (true = handled).
    var onKey: ((PromptKey) -> Bool)?
    var suggesting = false
}

enum PromptKey { case up, down, enter, escape }

struct ComposerPromptBox: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var placeholder: String
    var minHeight: CGFloat = 104
    @State private var typed: TypedTrigger?
    @State private var highlight = 0
    @State private var controller = PromptController()

    private var tokens: Binding<PromptTokens> {
        Binding(get: { store.suite.composer.tokens }, set: { store.suite.composer.tokens = $0 })
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TokenTextEditor(tokens: tokens, controller: controller, theme: t, onTrigger: { tr in
                if tr != typed { highlight = 0 }
                typed = tr
                controller.suggesting = tr != nil && !suggestions.isEmpty
            }, onTokenClick: { key, rect, view in showTokenMenu(key, rect, view) })
            if store.suite.composer.tokens.isEmpty {
                HStack(spacing: 0) {
                    Rectangle().fill(t.accent).frame(width: 2, height: 21)
                    Text(placeholder).font(t.body(16)).foregroundStyle(t.muted).padding(.leading, 3).lineLimit(2)
                }
                .padding(.top, 4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(minHeight: minHeight, maxHeight: max(minHeight, 180))
        .overlay(alignment: .bottomLeading) {
            if let typed, !suggestions.isEmpty {
                suggestionList(typed).alignmentGuide(.bottom) { $0[.top] - 4 }
            }
        }
        .onAppear {
            controller.onKey = { k in handleKey(k) }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Suggestions

    private struct Suggestion: Identifiable {
        var id: String
        var title: String
        var line: String
        var kind: String
        var image: ImageRef?
        var move: SuiteMoveOption?
    }

    private var suggestions: [Suggestion] {
        guard let typed else { return [] }
        let q = typed.trigger.query.lowercased()
        if typed.trigger.char == "#" {
            return PromptTokens.searchMoves(store.suite.camera, q).prefix(8).map {
                Suggestion(id: "m:\($0.id)", title: $0.label, line: $0.description, kind: "move", move: $0)
            }
        }
        var out = store.suiteCharacters.filter { q.isEmpty || $0.name.lowercased().contains(q) }.prefix(6).map {
            Suggestion(id: "c:\($0.id)", title: $0.name, line: "Character · \($0.niche)", kind: "character", image: $0.cover)
        }
        if let lead = store.composerCharacter {
            out += store.outfits(for: lead).filter { q.isEmpty || $0.name.lowercased().contains(q) }.prefix(4).map {
                Suggestion(id: "o:\($0.id)", title: $0.name, line: "\(lead.shortName)’s outfit", kind: "outfit", image: $0.angles.compactMap { $0 }.first)
            }
        }
        // Locations, then "+ New location" last.
        out += store.suite.locations.filter { q.isEmpty || $0.name.lowercased().contains(q) }.prefix(4).map {
            Suggestion(id: "l:\($0.id)", title: $0.name, line: "Location · a reference image", kind: "location", image: $0.image)
        }
        out.append(Suggestion(id: "new-location", title: "+ New location", line: "A photo of a place, named for @", kind: "newLocation"))
        return out
    }

    private func suggestionList(_ typed: TypedTrigger) -> some View {
        let list = suggestions
        return VStack(alignment: .leading, spacing: 0) {
            Text(typed.trigger.char == "#" ? "CAMERA MOVES · UP TO \(PromptTokens.maxMoves)" : "YOUR CAST · OUTFITS · LOCATIONS")
                .font(t.mono(10, .medium)).tracking(1.2).foregroundStyle(t.muted)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                Button { pick(s, typed) } label: {
                    HStack(spacing: 10) {
                        if s.kind == "move" {
                            Ph("arrow.up.and.down.and.arrow.left.and.right", 11).foregroundStyle(t.surface)
                                .frame(width: 24, height: 24).background(t.ink)
                        } else if s.kind == "newLocation" {
                            Ph("plus", 11)
                                .frame(width: 24, height: 24).overlay(Rectangle().strokeBorder(t.line, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        } else {
                            MuseImage(ref: s.image).frame(width: 24, height: 24).clipped()
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(t.body(13, .semibold)).lineLimit(1)
                            Text(s.line).font(t.body(11.5)).foregroundStyle(t.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(i == highlight ? t.surface2 : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlight = i } }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 300, alignment: .leading)
        .background(t.surface)
        .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    private func handleKey(_ k: PromptKey) -> Bool {
        guard let typed, !suggestions.isEmpty else { return false }
        switch k {
        case .up: highlight = max(0, highlight - 1)
        case .down: highlight = min(suggestions.count - 1, highlight + 1)
        case .enter: pick(suggestions[min(highlight, suggestions.count - 1)], typed)
        case .escape:
            self.typed = nil
            controller.suggesting = false
        }
        return true
    }

    private func pick(_ s: Suggestion, _ typed: TypedTrigger) {
        let cat = store.suite.camera
        let (cut, caret) = store.suite.composer.tokens.removingTrigger(typed.trigger, part: typed.part, caret: typed.caret)
        var result: (PromptTokens, String?)
        switch s.kind {
        case "location":
            let id = String(s.id.dropFirst(2))
            guard let loc = store.suite.locations.first(where: { $0.id == id }) else { return }
            // The References limit refuses it with a message (toast); the typed @word is still taken out.
            result = (store.addLocation(loc, to: cut, at: caret), nil)
        case "newLocation":
            store.suite.composer.tokens = cut
            self.typed = nil
            controller.suggesting = false
            let st = store
            let ctl = controller
            Task { @MainActor in
                guard let loc = await st.newLocation() else { return }
                st.suite.composer.tokens = st.addLocation(loc, to: st.suite.composer.tokens, at: caret)
                ctl.textView?.placeCaretAfter(key: st.suite.composer.tokens.lastKey)
            }
            return
        case "move":
            guard let m = s.move else { return }
            result = cut.addMove(m, at: caret, catalog: cat)
        case "outfit":
            result = (cut, nil)
            store.suite.composer.outfitId = String(s.id.dropFirst(2))
        default:
            let id = String(s.id.dropFirst(2))
            let label = store.character(id)?.shortName ?? s.title
            result = cut.addMention(kind: "character", id: id, label: label, at: caret)
            if let m = store.character(id), !(store.outfits(for: m).contains { $0.id == store.suite.composer.outfitId }) {
                store.suite.composer.outfitId = store.outfits(for: m).first?.id
            }
        }
        if let note = result.1, s.kind == "move" {
            store.showToast(note)
            store.suite.composer.tokens = cut
        } else {
            if let note = result.1 { store.showToast(note) }
            store.suite.composer.tokens = result.0
        }
        self.typed = nil
        controller.suggesting = false
        controller.textView?.placeCaretAfter(key: store.suite.composer.tokens.lastKey)
    }

    // MARK: Clicking a token

    private func showTokenMenu(_ key: Int, _ rect: NSRect, _ view: NSView) {
        guard let part = store.suite.composer.tokens.parts.first(where: { $0.key == key }) else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        let theme = t
        let store = self.store
        let content = TokenMenu(part: part, theme: theme, onIntensity: { v in
            store.suite.composer.tokens = store.suite.composer.tokens.setIntensity(key: key, v)
        }, onRemove: {
            if case .mention(let kind, _, _, _) = part, kind == "character" { store.suite.composer.outfitId = nil }
            store.suite.composer.tokens = store.suite.composer.tokens.remove(key: key)
            pop.performClose(nil)
        })
        pop.contentViewController = NSHostingController(rootView: content)
        pop.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
}

/// The popover of a clicked chip: a move's intensity (subtle → strong) and Remove.
struct TokenMenu: View {
    var part: PromptPart
    var theme: Theme
    var onIntensity: (Int) -> Void
    var onRemove: () -> Void
    @State private var value: Double = 50

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: 12) {
            switch part {
            case .move(_, let label, _, let intensity, _):
                Text("#\(label)").font(t.body(14, .semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text("INTENSITY").font(t.mono(10, .medium)).tracking(1.2).foregroundStyle(t.muted)
                    Slider(value: $value, in: 0...100, step: 5) { Text("Intensity") }
                        .labelsHidden()
                        .onChange(of: value) { onIntensity(Int(value)) }
                        .onAppear { value = Double(intensity) }
                    HStack {
                        Text("Subtle").font(t.body(11.5)).foregroundStyle(t.muted)
                        Spacer()
                        Text("Strong").font(t.body(11.5)).foregroundStyle(t.muted)
                    }
                }
            case .mention(_, _, let label, _):
                Text("@\(label)").font(t.body(14, .semibold))
            case .text:
                EmptyView()
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove", ph: "trash").font(t.body(13, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(t.rec)
        }
        .padding(16)
        .frame(width: 240, alignment: .leading)
        .foregroundStyle(t.ink)
        .background(t.surface)
        .environment(\.theme, t)
    }
}

// MARK: The text view

private extension NSAttributedString.Key {
    static let museToken = NSAttributedString.Key("studio.muse.promptToken")
}

/// The NSTextView: plain text with chip attachments; reports the trigger at the caret and clicks on chips.
final class TokenTextView: NSTextView {
    weak var controller: PromptController?
    var onTokenClick: ((Int, NSRect) -> Void)?
    /// A chip dragged to a new place: its key and the character index it was dropped at.
    var onTokenDrop: ((Int, Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 {
            let local = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
            let g = lm.glyphIndex(for: local, in: tc)
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            let ch = lm.characterIndexForGlyph(at: g)
            if rect.contains(local), ch < storage.length, let key = storage.attribute(.museToken, at: ch, effectiveRange: nil) as? Int,
               (storage.string as NSString).character(at: ch) == 0xFFFC {
                // A click opens the chip's menu; a drag moves the chip to where it is dropped (the caret shows where).
                let start = event.locationInWindow
                var dragging = false
                while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                    let at = characterIndexForInsertion(at: convert(next.locationInWindow, from: nil))
                    if next.type == .leftMouseUp {
                        NSCursor.arrow.set()
                        if dragging { onTokenDrop?(key, at) } else { onTokenClick?(key, rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)) }
                        break
                    }
                    if !dragging, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 {
                        dragging = true
                        NSCursor.closedHand.set()
                    }
                    if dragging { setSelectedRange(NSRange(location: min(at, storage.length), length: 0)) }
                }
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if let c = controller, c.suggesting, let handler = c.onKey {
            let key: PromptKey? = {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): return .up
                case #selector(NSResponder.moveDown(_:)): return .down
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): return .enter
                case #selector(NSResponder.cancelOperation(_:)): return .escape
                default: return nil
                }
            }()
            if let key, handler(key) { return }
        }
        super.doCommand(by: selector)
    }

    /// After an insert: the caret right after the token with `key` (or at the end).
    func placeCaretAfter(key: Int?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = self.textStorage else { return }
            var loc = storage.length
            if let key {
                storage.enumerateAttribute(.museToken, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
                    if (v as? Int) == key {
                        loc = r.location + r.length
                        stop.pointee = true
                    }
                }
            }
            self.window?.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: loc, length: 0))
        }
    }
}

struct TokenTextEditor: NSViewRepresentable {
    @Binding var tokens: PromptTokens
    var controller: PromptController
    var theme: Theme
    var onTrigger: (TypedTrigger?) -> Void
    var onTokenClick: (Int, NSRect, NSView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = TokenTextView(usingTextLayoutManager: false)
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.textContainer?.lineFragmentPadding = 2
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.insertionPointColor = NSColor(theme.accent)
        tv.delegate = context.coordinator
        tv.controller = controller
        tv.setAccessibilityLabel("Prompt")
        let coord = context.coordinator
        tv.onTokenClick = { [weak tv] key, rect in
            guard let tv else { return }
            coord.parent.onTokenClick(key, rect, tv)
        }
        tv.onTokenDrop = { [weak tv] key, index in
            guard let tv else { return }
            coord.drop(key: key, at: index, in: tv)
        }
        controller.textView = tv
        scroll.documentView = tv
        coord.apply(tokens, to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? TokenTextView else { return }
        // A theme switch re-draws the text and chips too (they carry the old theme's ink and plate colours otherwise).
        if context.coordinator.shown != tokens || context.coordinator.shownTheme != theme.id {
            let sel = tv.selectedRange()
            context.coordinator.apply(tokens, to: tv)
            tv.insertionPointColor = NSColor(theme.accent)
            tv.setSelectedRange(NSRange(location: min(sel.location, tv.textStorage?.length ?? 0), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TokenTextEditor
        /// The tokens the view shows now.
        var shown = PromptTokens()
        /// The theme they were drawn in.
        var shownTheme: ThemeID?
        private var applying = false

        init(_ parent: TokenTextEditor) { self.parent = parent }

        private var font: NSFont { Fonts.nsFont(parent.theme.bodyFamily, 16, .regular) ?? .systemFont(ofSize: 16) }
        private var plain: [NSAttributedString.Key: Any] {
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.35
            return [.font: font, .foregroundColor: NSColor(parent.theme.ink), .paragraphStyle: para]
        }

        func apply(_ tokens: PromptTokens, to tv: TokenTextView) {
            applying = true
            defer { applying = false }
            let out = NSMutableAttributedString()
            for p in tokens.parts {
                if let t = p.text {
                    out.append(NSAttributedString(string: t, attributes: plain))
                } else if let key = p.key {
                    let att = NSTextAttachment()
                    let img = chipImage(p)
                    att.image = img
                    att.bounds = CGRect(x: 0, y: -7, width: img.size.width, height: img.size.height)
                    let s = NSMutableAttributedString(attachment: att)
                    var attrs = plain
                    attrs[.museToken] = key
                    s.addAttributes(attrs, range: NSRange(location: 0, length: s.length))
                    out.append(s)
                }
            }
            tv.textStorage?.setAttributedString(out)
            tv.typingAttributes = plain
            shown = tokens
            shownTheme = parent.theme.id
        }

        /// The tokens the view holds now (chips by key, everything else text).
        private func read(_ tv: NSTextView) -> PromptTokens {
            guard let storage = tv.textStorage else { return shown }
            var parts: [PromptPart] = []
            var buf = ""
            var used = Set<Int>()
            let ns = storage.string as NSString
            storage.enumerateAttribute(.museToken, in: NSRange(location: 0, length: storage.length)) { v, range, _ in
                for i in range.location..<(range.location + range.length) {
                    let c = ns.character(at: i)
                    if c == 0xFFFC {
                        if let key = v as? Int, !used.contains(key), let tok = shown.parts.first(where: { $0.key == key }) {
                            if !buf.isEmpty { parts.append(.text(buf)); buf = "" }
                            parts.append(tok)
                            used.insert(key)
                        }
                    } else {
                        buf += ns.substring(with: NSRange(location: i, length: 1))
                    }
                }
            }
            if !buf.isEmpty { parts.append(.text(buf)) }
            return PromptTokens(parts)
        }

        func textDidChange(_ note: Notification) {
            guard !applying, let tv = note.object as? TokenTextView else { return }
            let t = read(tv)
            // A token that lost its chip (deleted) is gone; keep the attributes clean for typing.
            tv.typingAttributes = plain
            shown = t
            if parent.tokens != t { parent.tokens = t }
            report(tv)
        }

        /// Drag to reorder: the chip goes where it was dropped (PromptTokens.move), then the caret sits after it.
        func drop(key: Int, at index: Int, in tv: TokenTextView) {
            let moved = shown.move(key: key, to: shown.caret(utf16: index))
            guard moved != shown else { return }
            parent.tokens = moved
            tv.placeCaretAfter(key: key)
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard !applying, let tv = note.object as? TokenTextView else { return }
            tv.typingAttributes = plain
            report(tv)
        }

        /// Works out the `@` / `#` word being typed at the caret.
        private func report(_ tv: NSTextView) {
            let sel = tv.selectedRange()
            guard sel.length == 0 else { return parent.onTrigger(nil) }
            var pos = 0
            for (i, p) in shown.parts.enumerated() {
                if let t = p.text {
                    let len = (t as NSString).length
                    if sel.location >= pos && sel.location <= pos + len {
                        let idx = String.Index(utf16Offset: sel.location - pos, in: t)
                        let caret = t.distance(from: t.startIndex, to: idx)
                        if let trig = PromptTokens.activeTrigger(t, caret: caret) {
                            return parent.onTrigger(TypedTrigger(trigger: trig, part: i, caret: caret))
                        }
                        return parent.onTrigger(nil)
                    }
                    pos += len
                } else {
                    pos += 1
                }
            }
            parent.onTrigger(nil)
        }

        /// A chip drawn as an image: "@Noor" on a light plate, or "# Dolly in" with a dark move icon.
        private func chipImage(_ p: PromptPart) -> NSImage {
            let th = parent.theme
            let isMove = p.move != nil
            let isPlace: Bool = { if case .mention(let k, _, _, _) = p { return k == "location" }; return false }()
            let label: String = {
                switch p {
                case .move(_, let l, _, _, _): return l
                case .mention(_, _, let l, _): return l
                case .text(let t): return t
                }
            }()
            let bold = Fonts.nsFont(th.bodyFamily, 14, .semibold) ?? .boldSystemFont(ofSize: 14)
            let mono = Fonts.nsFont(th.monoFamily, 13, .medium) ?? .monospacedSystemFont(ofSize: 13, weight: .medium)
            // `link`, not the accent: the accent on the chip plate was 3.3:1 in Soft Tactile and 2.0:1 in Creator Pop.
            let sigil = NSAttributedString(string: isMove ? "#" : "@", attributes: [.font: mono, .foregroundColor: NSColor(th.link)])
            let text = NSAttributedString(string: label, attributes: [.font: bold, .foregroundColor: NSColor(th.ink)])
            let icon: CGFloat = 21, h: CGFloat = 27, gap: CGFloat = 6
            let w = 3 + icon + gap + sigil.size().width + 1 + text.size().width + 9
            let surface2 = NSColor(th.surface2), line = NSColor(th.line), ink = NSColor(th.ink), surface = NSColor(th.surface)
            return NSImage(size: NSSize(width: ceil(w), height: h), flipped: false) { r in
                let plate = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: th.controlRadius, yRadius: th.controlRadius)
                surface2.setFill()
                plate.fill()
                line.setStroke()
                plate.lineWidth = 1
                plate.stroke()
                let iconRect = NSRect(x: 3, y: (h - icon) / 2, width: icon, height: icon)
                if isMove {
                    ink.setFill()
                    NSBezierPath(rect: iconRect).fill()
                    let arrows = NSAttributedString(string: "✥", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: surface])
                    arrows.draw(at: NSPoint(x: iconRect.midX - arrows.size().width / 2, y: iconRect.midY - arrows.size().height / 2))
                } else {
                    line.setFill()
                    // A place has a square plate, a character a round one.
                    if isPlace { NSBezierPath(roundedRect: iconRect.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3).fill() } else { NSBezierPath(ovalIn: iconRect.insetBy(dx: 2, dy: 2)).fill() }
                    let initial = NSAttributedString(string: String(label.prefix(1)), attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: ink])
                    initial.draw(at: NSPoint(x: iconRect.midX - initial.size().width / 2, y: iconRect.midY - initial.size().height / 2))
                }
                var x = 3 + icon + gap
                sigil.draw(at: NSPoint(x: x, y: (h - sigil.size().height) / 2))
                x += sigil.size().width + 1
                text.draw(at: NSPoint(x: x, y: (h - text.size().height) / 2))
                return true
            }
        }
    }
}
