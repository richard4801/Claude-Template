import MuseCore
import SwiftUI

// The cinematic Suite's takes rail (mock 1-shot): renders in progress with live progress at the top, then the takes,
// newest first. The take on the stage carries the accent ring; the hovered one lifts and shows its four actions plus More.
// Photo shows its stills in two columns. Reuse settings and Vary wait for the server's saved drafts (build step 2).

struct CinemaTakesRail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Binding var picked: String?

    private var photo: Bool { store.suite.composer.tool == .photo }

    var body: some View {
        let takes = Array(store.cinemaTakes(photo: photo).prefix(40))
        let running = photo ? [] : store.cinemaRunning
        let onStage = picked ?? (photo ? takes.first?.id : (store.takes(of: store.shotJob).last ?? takes.first)?.id)
        VStack(alignment: .leading, spacing: 0) {
            Text(photo ? "Photos" : "Takes").font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.ink)
                .frame(height: 44, alignment: .center).padding(.top, 8)
            if takes.isEmpty && running.isEmpty || SnapshotRunner.state.cinemaEmpty {
                Text(photo ? "Photos land here as they render, newest on top." : "Takes land here as they render, newest on top.")
                    .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    let cols = photo ? [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)] : [GridItem(.flexible())]
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(running) { j in CinemaRunningCard(job: j) }
                        ForEach(takes) { take in
                            CinemaTakeCard(take: take, photo: photo, selected: take.id == onStage) {
                                withAnimation(.easeInOut(duration: 0.25)) { picked = take.id }
                            }
                        }
                    }
                    .padding(.top, 4).padding(.bottom, 60).padding(.trailing, 2)
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
        .padding(.leading, 8).padding(.trailing, 20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct CinemaRunningCard: View {
    @Environment(\.theme) private var t
    var job: Job

    var body: some View {
        let state = SuiteResultState.of(job)
        let pct: Int = { if case .rendering(let p, _) = state { return p } else { return 0 } }()
        ZStack(alignment: .bottomLeading) {
            Color.clear.overlay(MuseImage(ref: job.thumb).blur(radius: 10).brightness(-0.25)).clipped()
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(pct > 0 ? "\(pct)%" : state.queueLine).font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.ink)
                    Spacer()
                    if job.secondsLeft > 0 {
                        Text("About \(Int(job.secondsLeft.rounded())) s left").font(t.scale.micro.font).foregroundStyle(t.roles.ink.opacity(0.75))
                    }
                }
                Capsule().fill(t.roles.ink.opacity(0.2)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in Capsule().fill(t.roles.accent).frame(width: g.size.width * CGFloat(pct) / 100).shadow(color: t.roles.accent, radius: 5) }
                    }
            }
            .padding(12)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: max(t.radii.control - 4, 8)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rendering, \(pct) percent")
    }
}

struct CinemaTakeCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var take: Take
    var photo: Bool
    var selected: Bool
    var onPick: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(t.radii.control - 4, 8))
        ZStack(alignment: .bottomLeading) {
            Color.clear.overlay(MuseImage(ref: take.thumb)).clipped()
            if hover {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 4) { actions }.padding(8)
            }
        }
        .aspectRatio(photo ? 4 / 5 : 16 / 9, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? t.roles.accent : .clear, lineWidth: 2))
        .shadow(color: selected ? t.roles.accent.opacity(0.5) : .clear, radius: 12)
        .shadow(color: hover ? .black.opacity(0.55) : .clear, radius: 14, y: 10)
        .offset(y: hover && !reduceMotion ? -3 : 0)
        .contentShape(shape)
        .onTapGesture(count: 2) { store.openTake(take.id) }
        .onTapGesture { onPick() }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(take.displayLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Open") { store.openTake(take.id) }
    }

    @ViewBuilder private var actions: some View {
        action("shuffle", "Vary") { store.showToast("Vary arrives with saved drafts") }
        if !photo { action("arrow-line-right", "Extend") { store.openExtend(take) } }
        action("frame-corners", "Use as start frame") { useAsStart() }
        if !photo { action("scissors", "Open in Edit") { store.openEdit(takeId: take.id) } }
        Menu {
            Button("Open") { store.openTake(take.id) }
            Button("Reuse settings") { store.showToast("Reuse settings arrives with saved drafts") }
            Button("Post…") { store.openPostSheet(take) }
        } label: {
            Ph("dots-three", 15).foregroundStyle(.white).frame(width: 28, height: 28)
                .background(.black.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More")
    }

    private func action(_ icon: String, _ name: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Ph(icon, 15).foregroundStyle(.white).frame(width: 28, height: 28)
                .background(.black.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }

    /// The take's frame goes into the Shot composer's start frame.
    private func useAsStart() {
        let slots = store.suite.composerSlots
        slots.slots = slots.slots.put(SlotId(.start), SlotValue(name: take.displayLabel, image: take.thumb))
        if store.suite.composer.tool != .shot { store.openTool(.shot) }
        store.showToast("Start frame set from \(take.displayLabel)")
    }
}
