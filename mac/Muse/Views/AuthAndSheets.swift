import MuseCore
import SwiftUI

/// Sign in / sign up. Sign-up has two required attestations, unticked by default. No consent screens.
struct AuthView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    static let attestations = [
        "I'm 18 or older. I'll only upload clips and images I have the rights to use, and only create original characters.",
        "I'll label AI content when I post it.",
    ]

    var body: some View {
        @Bindable var store = store
        let up = store.authTab == .signUp
        let ok = store.attest[0] && store.attest[1]
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Color.clear.frame(width: 64, height: 1)
                Text("MUSE Studio").font(t.body(13, .semibold)).foregroundStyle(t.muted)
                Spacer()
                ThemeDots()
            }
            .padding(.leading, 18)
            .padding(.trailing, 16)
            .frame(height: 52)
            .background(WindowDragArea())
            .background(t.chrome)
            .overlay(alignment: .bottom) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(height: t.lineWidth) }

            HStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    MuseImage(ref: ImageRef(asset: "hero"), symbol: "person.fill")
                    LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AI MODEL STUDIO").font(t.mono(11)).tracking(1.3).foregroundStyle(.white.opacity(0.8))
                        Text(t.headingsUppercase ? "YOUR MODELS.\nREAL MOTION." : "Your models.\nReal motion.").font(t.h1).foregroundStyle(.white)
                        Text("Build original AI models from your own images, dress them, shoot them, and put them into real clips.")
                            .font(t.body(14)).foregroundStyle(.white.opacity(0.9)).frame(maxWidth: 420, alignment: .leading)
                    }
                    .padding(44)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(up ? "Create account" : "Welcome back").styled()
                        H1(up ? "Join MUSE" : "Sign in")
                        Group {
                            SSOButton(icon: "apple.logo", title: "Continue with Apple") { store.signInSSO("Apple") }
                            SSOButton(icon: "g.circle", title: "Continue with Google") { store.signInSSO("Google") }
                            HStack {
                                Rectangle().fill(t.line).frame(height: 1)
                                Text("or with email").font(t.body(12)).foregroundStyle(t.muted).fixedSize()
                                Rectangle().fill(t.line).frame(height: 1)
                            }
                            TextField("you@studio.com", text: $store.authEmail).fieldChrome().textContentType(.username)
                            SecureField("Password", text: $store.authPassword).fieldChrome().textContentType(.password)
                                .onSubmit { up ? store.signUp() : store.signIn() }
                        }
                        if up {
                            ForEach(0..<2, id: \.self) { i in
                                Button { store.attest[i].toggle() } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 5).fill(store.attest[i] ? t.accent : .clear)
                                            RoundedRectangle(cornerRadius: 5).strokeBorder(store.attest[i] ? t.accent : t.line, lineWidth: 1.5)
                                            if store.attest[i] { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(t.accentInk) }
                                        }
                                        .frame(width: 20, height: 20)
                                        .padding(.top, 1)
                                        Text(Self.attestations[i]).font(t.body(13)).foregroundStyle(t.ink).multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        MButton(store.authBusy ? "…" : up ? "Create account" : "Sign in", kind: .primary, size: .big, off: up && !ok) {
                            up ? store.signUp() : store.signIn()
                        }
                        HStack(spacing: 4) {
                            Text(up ? "Already have an account?" : "New here?").font(t.body(12)).foregroundStyle(t.muted)
                            LinkText(up ? "Sign in" : "Create an account") {
                                withAnimation { store.authTab = up ? .signIn : .signUp }
                            }
                        }
                        Text("By continuing you agree to the MUSE Terms and Acceptable Use Policy.").font(t.body(12)).foregroundStyle(t.muted)
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                    .padding(.horizontal, 56)
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity, minHeight: 600)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct SSOButton: View {
    @Environment(\.theme) private var t
    var icon: String
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(t.body(14, .semibold))
            }
            .foregroundStyle(t.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: t.isC ? 23 : t.controlRadius).fill(t.surface))
            .overlay(RoundedRectangle(cornerRadius: t.isC ? 23 : t.controlRadius).strokeBorder(t.isC ? .clear : t.strongLine, lineWidth: t.lineWidth))
            .modifier(ThemeShadow(kind: .button, radius: t.isC ? 23 : t.controlRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Outfit set generator: Describe it / From a photo / My own set → front, ¾, side and back on one seed → Save.
struct OutfitSheetView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var targeted = false

    var body: some View {
        if let d = store.outfitSheet {
            let model = store.models.first { $0.id == d.modelId }
            ZStack {
                Color.black.opacity(0.38).onTapGesture { withAnimation { store.outfitSheet = nil } }
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(model?.shortName ?? "Model").styled()
                            Text(t.headingsUppercase ? "NEW OUTFIT SET" : "New outfit set").font(t.isA ? Fonts.font("Instrument Serif", 48, .regular) : t.display(32, t.isD ? .heavy : .bold))
                        }
                        Spacer()
                        IconButton(systemName: "xmark", help: "Close") { withAnimation { store.outfitSheet = nil } }
                    }
                    Seg(OutfitMode.allCases.map { ($0, $0.label) }, selection: Binding(get: { d.mode }, set: { m in
                        store.outfitSheet?.mode = m
                        store.outfitSheet?.state = .idle
                        store.outfitSheet?.outfitId = nil
                        store.outfitSheet?.images = []
                    }))
                    switch d.mode {
                    case .describe:
                        TextBox(placeholder: "e.g. sheer crystal mini dress, silver strappy heels",
                                text: Binding(get: { store.outfitSheet?.description ?? "" }, set: { store.outfitSheet?.description = $0 }), lines: 2)
                    case .photo, .own:
                        dropZone(d)
                    }
                    HStack(spacing: 16) {
                        ForEach(0..<4, id: \.self) { i in
                            let label = ["Front", "¾", "Side", "Back"][i]
                            VStack(alignment: .leading, spacing: 6) {
                                switch d.state {
                                case .busy: Shimmer()
                                case .done:
                                    Media(ref: d.angles.indices.contains(i) ? d.angles[i] : nil, ratio: 0.75) {
                                        Pill(d.mode == .own ? "yours" : "AI", d.mode == .own ? .yours : .acc)
                                    }
                                case .idle:
                                    if d.mode == .own && d.images.indices.contains(i) {
                                        Media(ref: ImageRef(url: d.images[i].absoluteString), ratio: 0.75) { Pill("yours", .yours) }
                                    } else {
                                        EmptyTile(icon: "tshirt", text: label)
                                    }
                                }
                                Text(label).font(t.body(12))
                            }
                        }
                    }
                    Muted("All four angles use one seed, so the outfit matches from every side. Never add: logos.")
                    HStack {
                        Spacer()
                        if d.state == .done {
                            if d.mode != .own { MButton("Retake · \(Pricing.money(Pricing.outfitSetCost))") { store.outfitGenerate() } }
                            MButton("Save outfit", kind: .primary) { store.outfitSave() }
                        } else {
                            MButton(d.mode == .own ? "Use my images" : "Generate 4 angles · \(Pricing.money(Pricing.outfitSetCost))", kind: .primary, off: d.state == .busy) {
                                store.outfitGenerate()
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(width: 760)
                .background(RoundedRectangle(cornerRadius: t.rLg).fill(t.bg))
                .overlay(RoundedRectangle(cornerRadius: t.rLg).strokeBorder(t.strongLine, lineWidth: t.lineWidth))
                .modifier(ThemeShadow(kind: .card, radius: t.rLg))
                .shadow(color: .black.opacity(0.35), radius: 40, y: 30)
            }
        }
    }

    private func dropZone(_ d: OutfitDraft) -> some View {
        let photo = d.mode == .photo
        return Button {
            let urls = MediaImport.pick(MediaImport.imageTypes, multiple: !photo, prompt: "Use")
            if !urls.isEmpty { store.outfitSheet?.images = photo ? [urls[0]] : Array(urls.prefix(4)) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.images.isEmpty ? (photo ? "Drop a product photo" : "Drop your 4 angle images") : d.images.map(\.lastPathComponent).joined(separator: ", "))
                        .font(t.body(14, .bold)).lineLimit(1)
                    Muted(photo ? "It's used as a reference image, so the outfit matches." : "Front, ¾, side and back, in that order. Any you skip can be filled in.")
                }
                Spacer()
            }
            .foregroundStyle(t.ink)
            .padding(20)
            .background(RoundedRectangle(cornerRadius: t.cardRadius).fill(targeted ? t.accent.opacity(0.08) : t.surface))
            .overlay(RoundedRectangle(cornerRadius: t.cardRadius).strokeBorder(targeted ? t.accent : t.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            let imgs = urls.filter(MediaImport.isImage)
            guard !imgs.isEmpty else { return false }
            store.outfitSheet?.images = photo ? [imgs[0]] : Array(imgs.prefix(4))
            return true
        } isTargeted: { targeted = $0 }
    }
}
