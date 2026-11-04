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
            if store.paletteOpen { PaletteView().transition(.opacity) }
            if store.warmPrompt != nil && store.isOwner { WarmPromptView().transition(.opacity) }
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
                    Sidebar(compact: g.size.width < 1240)
                    ZStack(alignment: .top) {
                        screen
                            .id(store.screen)
                            .transition(MotionStyle.of(t.id).transition)
                        if let msg = store.offlineMessage {
                            Note(icon: "wifi.exclamationmark", warn: true, text: Text("\(msg) · ") + Text("Settings → Developer").bold())
                                .frame(maxWidth: 560)
                                .padding(.top, 10)
                                .onTapGesture { store.openSettings(.developer) }
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
        case .shoot: ShootView()
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
            Text("Theme").font(t.body(11)).foregroundStyle(t.muted).padding(.trailing, 2)
            ForEach(ThemeID.allCases) { id in
                let th = Theme.get(id)
                let on = id == store.themeID
                Button { store.setTheme(id) } label: {
                    Circle()
                        .fill(LinearGradient(stops: [.init(color: th.bg, location: 0.5), .init(color: th.accent, location: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                        .padding(2)
                        .overlay(Circle().strokeBorder(on ? t.accent : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(id.name)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(t.strongLine, lineWidth: t.lineWidth))
    }
}

struct TitleBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 64, height: 1)
            Text("MUSE Studio").font(t.body(13, .semibold)).foregroundStyle(t.muted)
            Spacer(minLength: 12)
            Button { store.openPalette() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 12))
                    Text("Search or jump to…").font(t.body(13))
                    Spacer()
                    KeyCap("⌘K")
                }
                .foregroundStyle(t.muted)
                .padding(.horizontal, 10)
                .frame(width: 420, height: 32)
                .background(RoundedRectangle(cornerRadius: t.isC ? 16 : t.controlRadius).fill(t.isD ? t.surface2 : t.surface2))
                .overlay(RoundedRectangle(cornerRadius: t.isC ? 16 : t.controlRadius).strokeBorder(t.isC ? .clear : t.strongLine, lineWidth: t.lineWidth))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if let p = store.uploadProgress {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle").font(.system(size: 12))
                        Text("\(Int((p * 100).rounded()))%").font(t.mono(12))
                        ProgressLine(value: p, height: 4).frame(width: 60)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Capsule().fill(t.surface2))
                    .help(store.uploadLabel)
                    .transition(.opacity)
                }
                if let r = store.runningJob {
                    Button { store.go(.queue) } label: {
                        HStack(spacing: 8) {
                            LED(on: !r.isWaiting)
                            Text(r.isWaiting ? (r.queuePosition.map { $0 <= 1 ? "Waiting to start" : "#\($0) in line" } ?? "Waiting to start") : "\(Int(r.progress.rounded()))%")
                                .font(t.mono(12))
                            ProgressLine(value: r.progress / 100, height: 4).frame(width: 60)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().fill(t.surface2))
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
                    Image(systemName: "person.crop.circle").font(.system(size: 16)).foregroundStyle(t.ink)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 34, height: 34)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(WindowDragArea())
        .background(t.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(height: t.lineWidth) }
    }
}

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            wordmark.padding(.horizontal, compact ? 0 : 10).padding(.top, 4).padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            ForEach(NavItem.main) { item in
                let q = store.activeJobs.count
                NavRow(icon: item.icon, title: item.title, on: store.screen.navParent == item.screen, compact: compact,
                       trailing: item.screen == .queue && q > 0 ? .count(q) : .key("⌘\(item.key)")) { store.go(item.screen) }
                if item.screen == .shoot {
                    // Photoshoot → Templates
                    NavRow(icon: "square.on.square.dashed", title: "Templates", on: store.screen.navParent == .templates, compact: compact,
                           trailing: .key("⇧⌘T")) { store.openTemplates() }
                        .padding(.leading, compact ? 0 : 14)
                }
            }
            if !compact {
                Text("CREATE").font(t.mono(10.5)).tracking(1).foregroundStyle(t.isD ? .white.opacity(0.75) : t.muted).padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
            } else {
                Divider().padding(.vertical, 8)
            }
            NavRow(icon: "plus", title: "New video", on: false, compact: compact, trailing: .key("⌘N")) { store.go(.studio) }
            NavRow(icon: "person.badge.plus", title: "New model", on: store.screen == .create, compact: compact, trailing: .none) { store.go(.create) }
            if store.isOwner {
                if !compact {
                    Text("STUDIO").font(t.mono(10.5)).tracking(1).foregroundStyle(t.isD ? .white.opacity(0.75) : t.muted).padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
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
        .frame(width: compact ? 72 : 228)
        .background(t.sidebarBg)
        .overlay(alignment: .trailing) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(width: t.lineWidth) }
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
                Image(systemName: icon).font(.system(size: 15, weight: on ? .semibold : .regular)).frame(width: 20)
                if !compact {
                    Text(t.navUppercase ? title.uppercased() : title).font(t.navFont).tracking(t.isA ? 1 : t.isB ? 1.2 : 0).lineLimit(1)
                    Spacer(minLength: 4)
                    switch trailing {
                    case .none: EmptyView()
                    case .key(let k): Text(k).font(t.mono(10.5)).opacity(0.7)
                    case .count(let n):
                        Text("\(n)").font(t.mono(11)).foregroundStyle(t.accentInk).padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(t.accent))
                    }
                }
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .frame(height: t.isA ? 38 : 40)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .background(background)
            .overlay(alignment: .leading) {
                if on && t.isA { Rectangle().fill(t.accent).frame(width: 2).padding(.vertical, 10) }
                if on && t.isB { Rectangle().fill(t.accent).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(compact ? title : "")
        .onHover { hover = $0 }
    }

    private var fg: Color {
        if t.isD { return on ? Color(hex: 0x111111) : .white }
        if on { return t.isA || t.isB ? t.accent : t.ink }
        return hover ? t.ink : t.muted
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: t.isA ? 0 : t.isC ? 14 : t.isD ? 12 : t.r, style: .continuous)
        switch t.id {
        case .a: Color.clear
        case .b: shape.fill(on ? Color(hex: 0x24282B) : hover ? t.surface2 : .clear)
        case .c:
            if on { shape.fill(t.surface).modifier(ThemeShadow(kind: .button, radius: 14)) } else { shape.fill(hover ? t.surface2 : .clear) }
        case .d:
            if on {
                shape.fill(t.yellow).overlay(shape.strokeBorder(Color(hex: 0x111111), lineWidth: 2.5)).modifier(ThemeShadow(kind: .button, radius: 12))
            } else {
                shape.fill(hover ? .white.opacity(0.14) : .clear)
            }
        }
    }
}

/// "Balance" at the bottom of the sidebar (`.balbox`). Members see their wallet; the owner sees what they can spend or send.
struct BalanceBox: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let onDark = t.isC
        Button { store.go(.credits) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Lbl("Balance", color: onDark ? .white.opacity(0.75) : nil)
                Text(Pricing.money(store.creditUsd))
                    .font(t.isA ? Fonts.font("Instrument Serif", 34, .regular) : t.mono(22, .medium))
                    .foregroundStyle(onDark ? .white : t.ink)
                Text("≈ \(Pricing.videosLeft(store.creditUsd)) Draft videos").font(t.body(12)).foregroundStyle(onDark ? .white.opacity(0.75) : t.muted)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(onDark ? .white.opacity(0.25) : t.line)
                        Capsule().fill(onDark ? .white : t.accent).frame(width: g.size.width * min(1, store.creditUsd / 25))
                    }
                }
                .frame(height: 4)
                .padding(.top, 6)
            }
            .padding(t.isA ? EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4) : EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
            .overlay(alignment: .top) { if t.isA { Rectangle().fill(t.ink).frame(height: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var bg: some View {
        let shape = RoundedRectangle(cornerRadius: t.rLg, style: .continuous)
        switch t.id {
        case .a: Color.clear
        case .b: shape.fill(t.surface2)
        case .c: shape.fill(Color(hex: 0x5A6E52))
        case .d: shape.fill(.white).overlay(shape.strokeBorder(Color(hex: 0x111111), lineWidth: 2.5)).modifier(ThemeShadow(kind: .card, radius: t.rLg))
        }
    }
}

struct ToastView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack {
            if let toast = store.toast {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle").font(.system(size: 13))
                    Text(toast.message).font(t.body(13.5)).fixedSize(horizontal: false, vertical: true)
                    if let label = toast.actionLabel {
                        Button {
                            store.toast = nil
                            toast.action?()
                        } label: {
                            Text(label).font(t.body(13.5, .semibold)).foregroundStyle(t.isD ? t.pink : t.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(t.bg)
                .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 12)
                .frame(maxWidth: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.ink).shadow(color: .black.opacity(0.3), radius: 15, y: 12))
                .id(toast.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 66)
        .padding(.trailing, 20)
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
                    .font(t.body(16))
                    .padding(.horizontal, 18)
                    .frame(height: 54)
                    .focused($focused)
                    .onChange(of: store.paletteQuery) { store.paletteIndex = 0 }
                Rectangle().fill(t.strongLine).frame(height: t.lineWidth)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            if cmds.isEmpty { Text("No matches").foregroundStyle(t.muted).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                            ForEach(Array(cmds.enumerated()), id: \.offset) { i, c in
                                Button { store.runPalette(i) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: c.icon).frame(width: 18)
                                        Text(c.title).font(t.body(13.5, t.isD ? .bold : .regular))
                                        Spacer()
                                        if !c.shortcut.isEmpty { KeyCap(c.shortcut) }
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 36)
                                    .background(RoundedRectangle(cornerRadius: t.controlRadius * 0.6).fill(i == store.paletteIndex ? t.surface2 : .clear))
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
            .surface(t.surface, radius: t.rLg)
            .clipShape(RoundedRectangle(cornerRadius: t.rLg))
            .shadow(color: .black.opacity(0.35), radius: 40, y: 30)
            .padding(.top, 120)
        }
        .onAppear { focused = true }
    }
}
