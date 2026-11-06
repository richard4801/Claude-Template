import MuseCore
import SwiftUI

/// AI suite (workstream 1): the Video suite's modes under its sidebar item (D1/D2).
struct SuiteNavGroup: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SuiteMode.group) { m in
                let on = store.screen == .suite && store.suite.mode == m
                Button { store.openSuite(m) } label: {
                    HStack(spacing: 8) {
                        Rectangle().fill(on ? t.accent : .clear).frame(width: 5, height: 5)
                        Text(m.title).font(t.body(13, on ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 4)
                        if store.isComingSoon(m) { Text("Soon").font(t.mono(9.5)).opacity(0.7) }
                    }
                    .foregroundStyle(t.isD ? .white : on ? t.ink : t.muted)
                    .padding(.leading, 22)
                    .padding(.trailing, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(m.title)\(store.isComingSoon(m) ? ", coming soon" : "")\(on ? ", selected" : "")")
            }
        }
    }
}
