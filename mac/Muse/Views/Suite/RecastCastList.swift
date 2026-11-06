import MuseCore
import SwiftUI

// AI suite (workstream 1): Recast's cast list (who in the clip becomes whom, up to 4 people), beside the first frame in
// RecastFacePicker. Each person has their marker number, the face tapped (or not yet), position chips (the fallback when
// no face is tapped; a picked chip wins over the face's third), who replaces them, the outfit and whether they speak.

/// Recast: each person in the clip and the studio character who replaces them.
struct RecastCastList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Binding var selected: UUID?

    static let chips: [(String, String)] = [("left", "Left"), ("center", "Centre"), ("right", "Right")]
    static let hints: [(String, String)] = [("foreground", "In front"), ("background", "Behind"), ("first", "First to appear"), ("second", "Second"),
                                            ("third", "Third"), ("fourth", "Fourth")]

    var body: some View {
        let people = store.suite.swap.people
        let limit = store.suite.catalog?.recastMaxPeople ?? 4
        VStack(alignment: .leading, spacing: 10) {
            SuiteSectionHead(title: "Who becomes whom") { Text("\(people.count) of \(limit)").font(t.body(11.5)).foregroundStyle(t.muted) }
            ForEach(Array(people.enumerated()), id: \.element.id) { i, p in row(i, p) }
            if let lines = store.suite.swapEstimate?.cast {
                ForEach(lines, id: \.self) { l in
                    Text("\(l.who.capitalized(with: nil)) → \(store.character(l.characterId)?.shortName ?? "")").font(t.body(11.5)).foregroundStyle(t.muted)
                }
            }
            if people.count < limit {
                MButton("Add a person", icon: "plus", size: .small) {
                    store.addRecastPerson()
                    selected = store.suite.swap.people.last?.id
                }
                Text("Or click a face on the frame.").font(t.body(11.5)).foregroundStyle(t.muted)
            }
        }
    }

    private func row(_ i: Int, _ p: RecastPerson) -> some View {
        let on = p.id == selected
        let m = p.member
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("\(i + 1)").font(t.mono(11, .semibold)).foregroundStyle(t.accentInk)
                    .frame(width: 20, height: 20).background(Circle().fill(t.accent))
                Text("Person \(i + 1)").font(t.scale.label.font)
                Spacer()
                Button {
                    store.suite.swap.people.removeAll { $0.id == p.id }
                    if on { selected = store.suite.swap.people.first?.id }
                } label: { Ph("xmark", 10) }
                    .buttonStyle(.plain).accessibilityLabel("Remove person \(i + 1)")
            }
            Text(faceLine(p)).font(t.body(11.5)).foregroundStyle(t.muted)
            HStack(spacing: 4) {
                ForEach(Self.chips, id: \.0) { id, label in chip(label, on: m.personHint == id && m.personIndex == nil) { store.setPersonHint(p.id, id) } }
                Menu(Self.hints.first { $0.0 == m.personHint }?.1 ?? "More") {
                    ForEach(Self.hints, id: \.0) { id, label in Button(label) { store.setPersonHint(p.id, id) } }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(t.body(11.5))
            }
            Menu {
                ForEach(store.suiteCharacters) { c in
                    Button(c.name) {
                        store.setPerson(p.id) { q in
                            q.member.characterId = c.id
                            q.member.outfitId = nil
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    MuseImage(ref: store.character(m.characterId)?.cover).frame(width: 20, height: 24).clipped()
                    Text("Becomes \(store.character(m.characterId)?.name ?? "…")")
                }
            }
            let outfits = store.outfits(for: store.character(m.characterId))
            if !outfits.isEmpty {
                Menu("Outfit: \(outfits.first { $0.id == m.outfitId }?.name ?? "from the clip")") {
                    Button("From the clip") { store.setPerson(p.id) { $0.member.outfitId = nil } }
                    ForEach(outfits) { o in Button(o.name) { store.setPerson(p.id) { $0.member.outfitId = o.id } } }
                }
            }
            Menu("Speaks: \(m.speaking.map { $0 ? "yes" : "no" } ?? "as in the clip")") {
                Button("As in the clip") { store.setPerson(p.id) { $0.member.speaking = nil } }
                Button("Yes") { store.setPerson(p.id) { $0.member.speaking = true } }
                Button("No") { store.setPerson(p.id) { $0.member.speaking = false } }
            }
        }
        .padding(10)
        .background(on ? t.surface2 : Color.clear)
        .overlay(Rectangle().strokeBorder(on ? t.accent : t.line, lineWidth: on ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { selected = p.id }
    }

    private func faceLine(_ p: RecastPerson) -> String {
        if p.uploading { return "Face picked · sending it…" }
        if p.member.faceCrop != nil { return "Face picked on the frame" }
        if p.face != nil { return "Face picked · the position is used" }
        return "No face yet · click it on the frame, or pick where they stand"
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(t.body(11.5, on ? .semibold : .regular))
                .foregroundStyle(on ? t.accentInk : t.ink)
                .padding(.horizontal, 9).frame(height: 24)
                .background(Capsule().fill(on ? t.accent : t.surface))
                .overlay(Capsule().strokeBorder(on ? .clear : t.line, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)\(on ? ", selected" : "")")
    }
}
