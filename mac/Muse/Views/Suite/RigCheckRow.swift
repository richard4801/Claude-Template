import MuseCore
import SwiftUI

// Source of truth for the rules and wording: server/api/src/suite/rigcheck.ts (the demo port must match it).
// AI suite · the rig check (workstream 3, plans/video-composer.md "Rig check"): one line just above the composer's bottom
// bar when the choices clash with each other or with the prompt. A severity dot, the reason (cut short, the whole line in
// the tooltip), the one-tap fix and the alt when there is one, "+N" for the rest, × to hide a warning until the choices
// change. It never blocks Generate and takes no room when there is nothing to say.

struct RigCheckRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var expanded = false

    /// Shots only: Swap and Recast take their camera from the clip.
    private var applies: Bool {
        switch store.suite.composer.tool {
        case .shot, .talking, .ugc: return true
        default: return false
        }
    }

    var body: some View {
        let list = applies ? store.rigWarnings : []
        VStack(spacing: 0) {
            if let first = list.first {
                Rectangle().fill(t.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    line(first, more: expanded ? 0 : list.count - 1, less: expanded && list.count > 1)
                    if expanded {
                        ForEach(list.dropFirst()) { w in
                            line(w, more: 0, less: false).transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 7)
                .transition(.opacity)
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.18), value: list)
        .animation(.easeOut(duration: 0.18), value: expanded)
        .onChange(of: list.count) { _, n in
            if n <= 1 { expanded = false }
        }
    }

    private func line(_ w: RigWarning, more: Int, less: Bool) -> some View {
        let kind: String = w.isTip ? "Tip" : "Warning"
        return HStack(spacing: 8) {
            Circle().fill(w.isTip ? t.link : t.warn).frame(width: 7, height: 7)
                .help(kind)
            Text(w.reason)
                .font(t.body(12.5))
                .foregroundStyle(t.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(w.reason)
            Group {
                fixButton(w.fix, of: w, primary: true)
                if let alt = w.alt { fixButton(alt, of: w, primary: false) }
                if more > 0 {
                    Button { expanded = true } label: {
                        Text("+\(more)").font(t.mono(11, .medium)).foregroundStyle(t.muted)
                            .padding(.horizontal, 6).frame(height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(more) more")
                    .accessibilityLabel("Show \(more) more warning\(more == 1 ? "" : "s")")
                }
                if less {
                    Button { expanded = false } label: {
                        Ph("chevron.up", 9).foregroundStyle(t.muted)
                            .frame(width: 20, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show one")
                    .accessibilityLabel("Show fewer")
                }
                Button { store.dismissRigWarning(w) } label: {
                    Ph("xmark", 9).foregroundStyle(t.muted)
                        .frame(width: 20, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide until the choices change")
                .accessibilityLabel("Dismiss")
            }
            .fixedSize()
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind + ": " + w.reason)
    }

    private func fixButton(_ fix: RigFix, of w: RigWarning, primary: Bool) -> some View {
        Button { store.applyRigFix(fix, of: w) } label: {
            Text(fix.label)
                .font(t.body(12, .semibold))
                .foregroundStyle(primary ? t.ink : t.link)
                .lineLimit(1)
                .padding(.horizontal, primary ? 10 : 4)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(primary ? t.surface2 : .clear))
                .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(primary ? t.line : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(fix.label)
    }
}
