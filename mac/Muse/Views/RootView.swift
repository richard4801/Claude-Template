import AppKit
import MuseCore
import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let t = store.theme
        ZStack {
            t.bg
            if store.user == nil {
                AuthView().transition(.opacity)
            } else {
                Shell()
            }
            if store.outfitSheet != nil { OutfitSheetView().transition(.opacity) }
            if store.postDraft != nil { PostSheetView().transition(.opacity) }
            if store.templateForm != nil { TemplateSheetView().transition(.opacity) }
            if store.enhanceDraft != nil { EnhanceSheetView().transition(.opacity) }
            if store.dressUpDraft != nil { DressUpSheetView().transition(.opacity) }
            if store.versionsDraft != nil { SheetVersionsSheet().transition(.opacity) }
            if store.catalog != nil && store.isOwner { ModelCatalogSheet().transition(.opacity) }
            if store.paletteOpen { PaletteView().transition(.opacity) }
            if store.warmPrompt != nil && store.isOwner { WarmPromptView().transition(.opacity) }
            SnapshotOverlay()
            ToastView()
        }
        .environment(\.theme, t)
        .font(t.body(14))
        .foregroundStyle(t.ink)
        .tint(t.accent)
        .overlay { if t.isD { Rectangle().strokeBorder(Color(hex: 0x111111), lineWidth: 2.5).allowsHitTesting(false) } }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.3), value: store.user == nil)
    }
}

/// Title bar + sidebar + the current screen.
struct Shell: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                TitleBar()
                HStack(spacing: 0) {
                    // The Edit suite needs the width (plans/edit-layout.md): the sidebar is its icon rail there.
                    Sidebar(compact: g.size.width < 1240 || store.screen == .edit || store.screen == .editor)
                    ZStack(alignment: .top) {
                        screen
                            .id(store.screen)
                            .transition(MotionStyle.of(t.id).transition)
                        if let msg = store.offlineMessage {
                            // Offline: what happened, and where to fix it. Floats over the screen like a toast.
                            InlineNotice(msg, tone: .caution, actionTitle: "Check connection") { store.openSettings(.developer) }
                                .frame(maxWidth: 560)
                                .museFloat(t)
                                .padding(.top, Space.s3)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
        }
    }

    @ViewBuilder private var screen: some View {
        switch store.screen {
        case .home: HomeView()
        case .models: ModelsView()
        case .profile: ProfileView()
        case .create: CreateModelView()
        case .studio: StudioView()
        case .queue: QueueView()
        case .gallery: GalleryView()
        case .result: ResultView()
        case .settings: SettingsView()
        case .credits: CreditsView()
        case .lora: LoraView()
        case .posts: PostsView()
        case .members: MembersView()
        case .templates: TemplatesView()
        case .template: TemplateDetailView()
        case .editor: VideoEditorView()
        // AI suite (workstream 1): the Video suite and the top-level Edit.
        case .suite: SuiteRootView()
        case .edit: EditSuiteView(takeId: store.suite.editTakeId)
        }
    }
}

/// Lets the custom title bar drag the window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ThemeDots: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        HStack(spacing: 6) {
            // The label never wraps (it went one letter per line at about 1000 pt); without room it steps aside.
            ViewThatFits(in: .horizontal) {
                Text("Theme").scaled(t.scale.micro, t.roles.ink2).lineLimit(1).fixedSize().padding(.trailing, 2)
                Color.clear.frame(width: 0, height: 0)
            }
            ForEach(ThemeID.allCases) { id in
                let th = Theme.get(id)
                let on = id == store.themeID
                Button { store.setTheme(id) } label: {
                    Circle()
                        .fill(LinearGradient(stops: [.init(color: th.bg, location: 0.5), .init(color: th.accent, location: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                        .padding(2)
                        .overlay(Circle().strokeBorder(on ? t.roles.selection : .clear, lineWidth: 2))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(id.name)
                .accessibilityLabel("Theme: \(id.name)\(on ? ", selected" : "")")
            }
        }
        .padding(.horizontal, Space.s2)
    }
}

struct TitleBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 64, height: 1)
            Text("MUSE Studio").scaled(t.scale.label, t.roles.ink2)
            Spacer(minLength: 12)
            Button { store.openPalette() } label: {
                HStack(spacing: Space.s2) {
                    Ph("magnifyingglass", 12)
                    Text("Search or jump to…").font(t.scale.caption.font)
                    Spacer()
                    Text("⌘K").font(t.scale.micro.font)
                }
                .foregroundStyle(t.roles.ink2)
                .padding(.horizontal, Space.s3)
                .frame(width: 420, height: 28)
                .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search or jump to a screen (⌘K)")
            .layoutPriority(1)
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if let p = store.uploadProgress {
                    HStack(spacing: 8) {
                        Text("Uploading \(Int((p * 100).rounded()))%").font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                        RProgress(value: p).frame(width: 60)
                    }
                    .padding(.horizontal, Space.s2)
                    .frame(height: 28)
                    .help(store.uploadLabel)
                    .transition(.opacity)
                }
                if let r = store.runningJob {
                    Button { store.go(.queue) } label: {
                        HStack(spacing: Space.s2) {
                            Text(r.isWaiting ? (r.queuePosition.map { $0 <= 1 ? "Waiting to start" : "#\($0) in line" } ?? "Waiting to start") : "Rendering \(Int(r.progress.rounded()))%")
                                .font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                            RProgress(value: r.progress / 100).frame(width: 60)
                        }
                        .padding(.horizontal, Space.s2)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(r.progressLine)
                }
                // Keep add-on engine ready: the owner's small indicator, only while it's on.
                if store.warmOn { WarmIndicator() }
                ThemeDots()
                Menu {
                    Text(store.user?.studioName ?? "Studio")
                    if let u = store.user {
                        Text(u.email + (u.role.map { " · \($0)" } ?? ""))
                    }
                    Divider()
                    Button("Credit · \(Pricing.money(store.creditUsd))") { store.go(.credits) }
                    if store.isOwner {
                        Button("Members") { store.go(.members) }
                        Button("Invite someone…") { store.go(.members) }
                    }
                    Button("Settings") { store.go(.settings) }
                    Divider()
                    Button("Sign out", role: .destructive) { store.signOut() }
                } label: {
                    Image(nsImage: Ph.menuImage("person.crop.circle", 16)).foregroundStyle(t.ink) // Menu labels ignore frames
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 34, height: 34)
                .help("Account")
                .accessibilityLabel("Account: \(store.user?.email ?? "signed in")")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(WindowDragArea())
        .background(t.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(t.isD ? t.roles.hairline : t.roles.hairline.opacity(t.isC ? 0 : 1)).frame(height: 1) }
    }
}

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var compact: Bool

    var body: some View {
        // Scrolls when the window is shorter than the list (owner fix A2: "Balance" was cut off); fills it otherwise, so
        // Settings and Balance stay at the bottom.
        GeometryReader { g in
            ScrollView(.vertical, showsIndicators: false) {
                list.frame(minHeight: g.size.height, alignment: .top)
            }
        }
        .frame(width: compact ? 72 : 228)
        .background(t.sidebarBg)
        .overlay(alignment: .trailing) { Rectangle().fill(t.isC || t.isD ? .clear : t.roles.hairline).frame(width: 1) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            wordmark.padding(.horizontal, compact ? 0 : 10).padding(.top, 4).padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                // The same name in the icon rail ("M") as in full ("MUSE"): nothing in the chrome changes label (Edit opens it).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("MUSE")
            ForEach(NavItem.main) { item in
                let q = store.activeJobs.count
                NavRow(icon: item.icon, title: item.title, on: store.screen.navParent == item.screen, compact: compact,
                       trailing: item.screen == .queue && q > 0 ? .count(q) : .key("⌘\(item.key)")) {
                    // AI suite (workstream 1): Video suite opens its hub.
                    if item.screen == .suite { store.openSuite(.hub) } else { store.go(item.screen) }
                }
                // AI suite: Templates (the Photo presets) and the top-level Edit under Video suite. The modes are no longer listed
                // here (owner decision 2026-11-08): the composer title's menu chooses them (SuiteModeMenu).
                if item.screen == .suite {
                    NavRow(icon: "square.on.square.dashed", title: "Templates", on: store.screen.navParent == .templates, compact: compact,
                           trailing: .key("⇧⌘T")) { store.openTemplates() }
                        .padding(.leading, compact ? 0 : 14)
                    NavRow(icon: "scissors", title: "Edit", on: store.screen.navParent == .edit, compact: compact, trailing: .none) { store.openEdit() } // AI suite (workstream 1)
                }
            }
            if !compact {
                groupLabel("Create")
            } else {
                Divider().padding(.vertical, 8)
            }
            NavRow(icon: "plus", title: "New video", on: false, compact: compact, trailing: .key("⌘N")) { store.go(.studio) }
            NavRow(icon: "person.badge.plus", title: "New model", on: store.screen == .create, compact: compact, trailing: .none) { store.go(.create) }
            if store.isOwner {
                if !compact {
                    groupLabel("Studio")
                } else {
                    Divider().padding(.vertical, 8)
                }
                NavRow(icon: "person.2", title: "Members", on: store.screen == .members, compact: compact, trailing: .key("⌘8")) { store.go(.members) }
            }
            Spacer()
            NavRow(icon: "slider.horizontal.3", title: "Settings", on: store.screen.navParent == .settings, compact: compact, trailing: .key("⌘,")) { store.go(.settings) }
            if !compact { BalanceBox().padding(.top, 8) }
        }
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.top, t.isC ? 22 : 18)
        .padding(.bottom, 14)
    }

    /// A sidebar group label: sentence case in the caption step, not tracked caps.
    private func groupLabel(_ text: String) -> some View {
        Text(text).scaled(t.scale.caption, t.isD ? .white.opacity(0.8) : t.roles.ink2)
            .padding(.horizontal, 10).padding(.top, Space.s5).padding(.bottom, Space.s1)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var wordmark: some View {
        let text = compact ? "M" : "MUSE"
        switch t.id {
        case .a: Text(text).font(Fonts.font("Instrument Serif", 40, .regular)).tracking(compact ? 0 : 4.8)
        case .b:
            HStack(alignment: .top, spacing: 4) {
                Text(text).font(Fonts.font("Barlow Condensed", 26, .bold)).tracking(compact ? 0 : 7.8)
                Circle().fill(t.rec).frame(width: 6, height: 6).padding(.top, 4)
            }
        case .c: Text(text).font(Fonts.font("Outfit", 30, .bold)).tracking(1.2)
        case .d: Text(text).font(Fonts.font("Bricolage Grotesque", 34, .heavy)).tracking(-0.7).foregroundStyle(.white)
        }
    }
}

struct NavRow: View {
    enum Trailing { case none, key(String), count(Int) }
    @Environment(\.theme) private var t
    var icon: String
    var title: String
    var on: Bool
    var compact: Bool
    var trailing: Trailing
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Ph(icon, 14).frame(width: 20)
                if !compact {
                    Text(title).font(t.scale.label.font).lineLimit(1)
                    Spacer(minLength: 4)
                    switch trailing {
                    case .none: EmptyView()
                    case .key(let k): Text(k).font(t.scale.micro.font).opacity(0.6)
                    case .count(let n): Text("\(n)").font(t.scale.micro.font).monospacedDigit().accessibilityLabel("\(n) in the queue")
                    }
                }
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .background(background)
            .overlay(alignment: .leading) {
                // The one selection mark: a short accent bar (Creator Pop marks it with its outline instead).
                if on && !t.isD { Capsule().fill(t.roles.accent).frame(width: 3, height: 16) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(compact ? title : "")
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .onHover { hover = $0 }
    }

    private var fg: Color {
        if t.isD { return on ? Color(hex: 0x111111) : .white }
        return on || hover ? t.roles.ink : t.roles.ink2
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.control, style: .continuous)
        if t.isD {
            if on {
                shape.fill(t.yellow).overlay(shape.strokeBorder(Color(hex: 0x111111), lineWidth: 2))
            } else {
                shape.fill(hover ? .white.opacity(0.14) : .clear)
            }
        } else {
            shape.fill(on ? t.roles.field : hover ? t.roles.field.opacity(0.6) : .clear)
        }
    }
}

/// "Balance" at the bottom of the sidebar (`.balbox`). Members see their wallet; the owner sees what they can spend or send.
struct BalanceBox: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        // Creator Pop's sidebar is blue: white text there; ink elsewhere. No box: the figure sits on the sidebar.
        let ink: Color = t.isD ? .white : t.roles.ink
        let ink2: Color = t.isD ? .white.opacity(0.8) : t.roles.ink2
        Button { store.go(.credits) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Balance").scaled(t.scale.caption, ink2)
                Text(Pricing.money(store.creditUsd)).monospacedDigit().scaled(t.scale.title, ink)
                Text("About \(Pricing.videosLeft(store.creditUsd)) Draft videos").scaled(t.scale.caption, ink2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open credit")
    }
}

struct ToastView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack {
            if let toast = store.toast {
                HStack(spacing: Space.s3) {
                    Text(toast.message).scaled(t.scale.caption, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                    if let label = toast.actionLabel {
                        Button {
                            store.toast = nil
                            toast.action?()
                        } label: {
                            Text(label).font(t.scale.label.font).foregroundStyle(t.roles.link)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Space.s4).padding(.vertical, Space.s3)
                .frame(maxWidth: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.raised))
                .overlay(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).strokeBorder(t.roles.hairline, lineWidth: t.isDark ? 1 : 0))
                .museFloat(t)
                .id(toast.id)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .background(SnapshotFrame(key: "toast"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // Recreate's 56 pt top bar holds the cost line and Build on the right: the toast sits under it there.
        .padding(.top, store.screen == .edit && store.recreate.open ? 66 + 56 : 66)
        .padding(.trailing, 20)
        .animation(.easeOut(duration: 0.2), value: store.toast?.id)
    }
}

/// ⌘K command palette.
struct PaletteView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        let cmds = store.paletteCommands
        ZStack(alignment: .top) {
            Color.black.opacity(0.3).onTapGesture { store.closePalette() }
            VStack(spacing: 0) {
                TextField("Type a command or screen…", text: $store.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(t.scale.body.font)
                    .padding(.horizontal, Space.s4)
                    .frame(height: 48)
                    .focused($focused)
                    .onChange(of: store.paletteQuery) { store.paletteIndex = 0 }
                Rectangle().fill(t.roles.hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            if cmds.isEmpty { Text("Nothing matches. Try a screen name, like Library.").foregroundStyle(t.roles.ink2).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                            ForEach(Array(cmds.enumerated()), id: \.offset) { i, c in
                                Button { store.runPalette(i) } label: {
                                    HStack(spacing: 12) {
                                        Text(c.title).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                                        Spacer()
                                        if !c.shortcut.isEmpty { Text(c.shortcut).font(t.scale.micro.font).foregroundStyle(t.roles.ink2) }
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(i == store.paletteIndex ? t.roles.field : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(i)
                                .onHover { if $0 { store.paletteIndex = i } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: store.paletteIndex) { proxy.scrollTo(store.paletteIndex) }
                }
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(t.roles.raised))
            .clipShape(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous))
            .museFloat(t)
            .padding(.top, 120)
        }
        .onAppear { focused = true }
    }
}
