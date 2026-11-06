import MuseCore
import SwiftUI

// AI suite (workstream 1): Recast's cast list (who in the clip becomes whom, up to 4 people), shown by the composer's
// PEOPLE slot. Character swap and Recast are tools of the composer (Composer/); their requests are AppStore.swapRequest.

/// Recast: each person in the clip and the studio character who replaces them.
struct RecastCastList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    static let hints: [(String, String)] = [("left", "On the left"), ("center", "In the centre"), ("right", "On the right"), ("foreground", "In front"),
                                            ("background", "Behind"), ("first", "First to appear"), ("second", "Second"), ("third", "Third"), ("fourth", "Fourth")]

    var body: some View {
        @Bindable var suite = store.suite
        VStack(alignment: .leading, spacing: 10) {
            SuiteSectionHead(title: "Who becomes whom") { Text("\(suite.swap.cast.count) of \(suite.catalog?.recastMaxPeople ?? 4)").font(t.body(11.5)).foregroundStyle(t.muted) }
            ForEach(Array(suite.swap.cast.enumerated()), id: \.offset) { i, m in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("PERSON \(i + 1)").font(t.mono(10.5)).tracking(1)
                        Spacer()
                        Button { suite.swap.cast.remove(at: i) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                            .buttonStyle(.plain).accessibilityLabel("Remove person \(i + 1)")
                    }
                    Menu(Self.hints.first { $0.0 == m.personHint }?.1 ?? "Where in the clip") {
                        ForEach(Self.hints.indices, id: \.self) { k in Button(Self.hints[k].1) { suite.swap.cast[i].personHint = Self.hints[k].0 } }
                    }
                    Menu {
                        ForEach(store.suiteCharacters) { c in Button(c.name) { suite.swap.cast[i].characterId = c.id; suite.swap.cast[i].outfitId = nil } }
                    } label: {
                        HStack(spacing: 6) {
                            MuseImage(ref: store.character(m.characterId)?.cover).frame(width: 20, height: 24).clipped()
                            Text("Becomes \(store.character(m.characterId)?.name ?? "…")")
                        }
                    }
                    let outfits = store.outfits(for: store.character(m.characterId))
                    if !outfits.isEmpty {
                        Menu("Outfit: \(outfits.first { $0.id == m.outfitId }?.name ?? "from the clip")") {
                            Button("From the clip") { suite.swap.cast[i].outfitId = nil }
                            ForEach(outfits) { o in Button(o.name) { suite.swap.cast[i].outfitId = o.id } }
                        }
                    }
                    Menu("Speaks: \(m.speaking.map { $0 ? "yes" : "no" } ?? "as in the clip")") {
                        Button("As in the clip") { suite.swap.cast[i].speaking = nil }
                        Button("Yes") { suite.swap.cast[i].speaking = true }
                        Button("No") { suite.swap.cast[i].speaking = false }
                    }
                }
                .padding(10)
                .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
            }
            if let lines = store.suite.swapEstimate?.cast {
                ForEach(lines, id: \.self) { l in
                    Text("\(l.who.capitalized(with: nil)) → \(store.character(l.characterId)?.shortName ?? "")").font(t.body(11.5)).foregroundStyle(t.muted)
                }
            }
            if suite.swap.cast.count < (suite.catalog?.recastMaxPeople ?? 4) {
                MButton("Add a person", icon: "plus", size: .small) { store.addRecastPerson() }
            }
        }
    }
}
