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
        let ok = store.attest[0] && store.attest[1] && (store.isDemo || !store.authInvite.trimmingCharacters(in: .whitespaces).isEmpty)
        VStack(spacing: 0) {
            HStack(spacing: Space.s3) {
                Color.clear.frame(width: 64, height: 1)
                Text("MUSE Studio").scaled(t.scale.label, t.roles.ink2)
                Spacer()
                ThemeDots()
            }
            .padding(.leading, 18)
            .padding(.trailing, 16)
            .frame(height: 52)
            .background(WindowDragArea())
            .background(t.chrome)
            .overlay(alignment: .bottom) { Rectangle().fill(t.roles.hairline.opacity(t.isC ? 0 : 1)).frame(height: 1) }

            HStack(spacing: 0) {
                BrandSplash()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text(up ? "Create your account" : "Sign in").scaled(t.scale.display, t.roles.ink).accessibilityAddTraits(.isHeader)
                        if up && !store.isDemo {
                            Text("MUSE is invite-only. Use the email your invite was sent to and the code from the studio owner.")
                                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                        Group {
                            if store.isDemo {
                                // Apple and Google sign-in are mocked: demo mode only.
                                SSOButton(icon: "apple.logo", title: "Continue with Apple") { store.signInSSO("Apple") }
                                SSOButton(icon: "g.circle", title: "Continue with Google") { store.signInSSO("Google") }
                                Text("Or with email").scaled(t.scale.caption, t.roles.ink2).padding(.top, Space.s2)
                            }
                            RField("Email") {
                                TextField("you@studio.com", text: $store.authEmail).roleField().textContentType(.username)
                            }
                            RField("Password", hint: up && !store.isDemo ? "8 or more characters" : nil) {
                                PasswordField(placeholder: "Password", text: $store.authPassword, isNew: up) {
                                    up ? store.signUp() : store.signIn()
                                }
                            }
                            if !up {
                                Toggle(isOn: $store.rememberMe) {
                                    Text("Remember me on this Mac").scaled(t.scale.caption, t.roles.ink)
                                }
                                .toggleStyle(.checkbox)
                            }
                            if up {
                                RField("Invite code", hint: store.isDemo ? "Not needed in demo mode" : nil) {
                                    TextField("MUSE-XXXX-XXXX-XXXX", text: $store.authInvite)
                                        .roleField()
                                        .onSubmit { store.signUp() }
                                }
                            }
                        }
                        if up {
                            ForEach(0..<2, id: \.self) { i in
                                Toggle(isOn: $store.attest[i]) {
                                    Text(Self.attestations[i]).scaled(t.scale.caption, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        if let err = store.authError {
                            InlineNotice(err, tone: .danger)
                        }
                        RButton(store.restoring ? "Checking your session…" : store.authBusy ? (up ? "Creating account…" : "Signing in…") : up ? "Create account" : "Sign in",
                                kind: .action, fill: true, off: up && !ok) {
                            up ? store.signUp() : store.signIn()
                        }
                        .padding(.top, Space.s2)
                        HStack(spacing: Space.s1) {
                            Text(up ? "Already have an account?" : "New here?").scaled(t.scale.caption, t.roles.ink2)
                            RButton(up ? "Sign in" : "Create an account", kind: .plain, small: true) {
                                store.authError = nil
                                withAnimation(.easeOut(duration: 0.2)) { store.authTab = up ? .signIn : .signUp }
                            }
                        }
                        VStack(alignment: .leading, spacing: Space.s2) {
                            HStack(spacing: Space.s1) {
                                Text(store.isDemo ? "Demo mode: nothing leaves this Mac." : "Server: \(store.serverHost)").scaled(t.scale.caption, t.roles.ink2)
                                RButton(store.isDemo ? "Use the MUSE server" : "Try demo mode", kind: .plain, small: true) {
                                    store.authError = nil
                                    store.dataSource = store.isDemo ? .http : .fake
                                    store.applyDataSource()
                                }
                            }
                            Text("By continuing you agree to the MUSE Terms and Acceptable Use Policy.").scaled(t.scale.caption, t.roles.ink2)
                            Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")").scaled(t.scale.micro, t.roles.ink2)
                        }
                        .padding(.top, Space.s5)
                    }
                    .frame(maxWidth: 400, alignment: .leading)
                    .padding(.horizontal, Space.s7)
                    .padding(.vertical, Space.s7)
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
            HStack(spacing: Space.s2) {
                Ph(icon, 14)
                Text(title)
            }
        }
        .buttonStyle(RButtonStyle(kind: .quiet, fill: true))
    }
}

/// The sign-in panel: the wordmark and one line on a flat tone. No gradient wash, no photo of a person.
struct BrandSplash: View {
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Spacer()
            Text("MUSE").font(Fonts.font(t.scale.displayFamily, 64, .regular)).foregroundStyle(t.roles.ink)
            Text("Your models, in real motion.").scaled(t.scale.title, t.roles.ink)
            Text("Build original AI models from your own images, dress them, shoot them, and put them into real clips.")
                .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(Space.s7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(t.roles.field)
        .accessibilityElement(children: .combine)
    }
}

/// Outfit set generator: Describe it / From a photo / My own set → front, ¾, side and back on one seed → Save.
struct OutfitSheetView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var targeted = false
    @FocusState private var nameFocused: Bool
    @FocusState private var noteFocused: Bool

    var body: some View {
        if let d = store.outfitSheet {
            let model = store.models.first { $0.id == d.modelId }
            ZStack {
                Color.black.opacity(0.38).onTapGesture { withAnimation { store.outfitSheet = nil } }
                VStack(alignment: .leading, spacing: Space.s5) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New outfit").scaled(t.scale.title, t.roles.ink).accessibilityAddTraits(.isHeader)
                            Text(model.map { "For \($0.shortName)" } ?? "For this model").scaled(t.scale.caption, t.roles.ink2)
                        }
                        Spacer()
                        RIconButton(systemName: "xmark", help: "Close") { withAnimation { store.outfitSheet = nil } }
                            .keyboardShortcut(d.viewing == nil ? .cancelAction : nil) // Escape closes the full view first
                    }
                    RSeg(OutfitMode.allCases.map { ($0, $0.label) }, selection: Binding(get: { d.mode }, set: { m in
                        store.outfitSheet?.mode = m
                        store.outfitSheet?.state = .idle
                        store.outfitSheet?.outfitId = nil
                        store.outfitSheet?.images = []
                    }))
                    .frame(maxWidth: 420)
                    if d.mode != .own { baseRow(d) }
                    switch d.mode {
                    case .describe:
                        if d.fromBase { Text("What to change").scaled(t.scale.label, t.roles.ink) }
                        RTextBox(placeholder: d.fromBase ? "e.g. a pleated white tennis skirt" : "e.g. sheer crystal mini dress, silver strappy heels",
                                 text: Binding(get: { store.outfitSheet?.description ?? "" }, set: { store.outfitSheet?.description = $0 }), lines: 2)
                    case .photo, .own:
                        dropZone(d)
                    }
                    HStack(alignment: .top, spacing: Space.s4) {
                        ForEach(0..<4, id: \.self) { i in
                            let label = ["Front", "¾", "Side", "Back"][i]
                            VStack(alignment: .leading, spacing: Space.s2) {
                                switch d.state {
                                case .busy: SkeletonBlock(ratio: 0.75, radius: t.radii.container)
                                case .done:
                                    viewable(d, i) {
                                        MediaFrame(ref: d.angles.indices.contains(i) ? d.angles[i] : nil, ratio: 0.75) {
                                            if d.mode != .own { StateTag("AI", .onMedia) }
                                        }
                                    }
                                case .idle:
                                    if d.mode == .own && d.images.indices.contains(i) {
                                        viewable(d, i) { MediaFrame(ref: ImageRef(url: d.images[i].absoluteString), ratio: 0.75) }
                                    } else {
                                        Color.clear.aspectRatio(0.75, contentMode: .fit)
                                            .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(t.roles.field))
                                    }
                                }
                                Text(label).scaled(t.scale.caption, t.roles.ink2)
                            }
                        }
                    }
                    if d.state == .done {
                        // §5: named before it's added (a suggestion, never "Product look"); renamable later.
                        VStack(alignment: .leading, spacing: Space.s2) {
                            Text("Name").scaled(t.scale.label, t.roles.ink)
                            TextField("e.g. Green halter set", text: Binding(get: { store.outfitSheet?.name ?? "" },
                                                                            set: { store.outfitSheet?.name = String($0.prefix(OutfitNaming.maxLength)) }))
                                .textFieldStyle(.plain)
                                .focused($nameFocused)
                                .roleField(focused: nameFocused)
                                .frame(maxWidth: 420)
                                .onSubmit { store.outfitSave() }
                        }
                    }
                    HStack(spacing: Space.s3) {
                        Text("All four angles use one seed, so the outfit matches from every side. Never add: logos.")
                            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Space.s4)
                        if d.state == .done {
                            if d.mode != .own { RButton("Retake · \(Pricing.money(store.outfitSetEstimate))") { store.outfitGenerate() } }
                            RButton("Add to her outfits", kind: .action) { store.outfitSave() }
                                .keyboardShortcut(d.viewing == nil ? .defaultAction : nil)
                        } else {
                            if d.mode != .own { OwnerModelPill(purpose: .outfit) } // the owner's outfit model (WS6)
                            RButton(d.mode == .own ? "Use my images" : "Make 4 angles · \(Pricing.money(store.outfitSetEstimate))", kind: .action, off: d.state == .busy) {
                                store.outfitGenerate()
                            }
                        }
                    }
                }
                .padding(Space.s6)
                .floatingPanel(width: 760)
                // The angles full size (owner 2026-11-08): zoom, ← →, Escape.
                ImageLightbox(items: Self.lightboxItems(d),
                              index: Binding(get: { store.outfitSheet?.viewing }, set: { store.outfitSheet?.viewing = $0 }))
            }
        }
    }

    static let angleLabels = ["Front", "¾", "Side", "Back"]

    /// The angles that have an image, in order: generated ones once done, your own images before that.
    static func lightboxItems(_ d: OutfitDraft) -> [LightboxItem] {
        (0..<4).compactMap { i -> LightboxItem? in
            let ref: ImageRef?
            if d.state == .done {
                ref = d.angles.indices.contains(i) ? d.angles[i] : nil
            } else if d.state == .idle, d.mode == .own, d.images.indices.contains(i) {
                ref = ImageRef(url: d.images[i].absoluteString)
            } else {
                ref = nil
            }
            return ref.map { LightboxItem(label: angleLabels[i] == "¾" ? "Three-quarter" : angleLabels[i], ref: $0) }
        }
    }

    /// An angle tile that opens the full view when it has an image.
    @ViewBuilder private func viewable<Content: View>(_ d: OutfitDraft, _ i: Int, @ViewBuilder _ tile: () -> Content) -> some View {
        let items = Self.lightboxItems(d)
        let label = Self.angleLabels[i] == "¾" ? "Three-quarter" : Self.angleLabels[i]
        if let at = items.firstIndex(where: { $0.label == label }) {
            Button { withAnimation(.easeOut(duration: 0.15)) { store.outfitSheet?.viewing = at } } label: { tile() }
                .buttonStyle(.plain)
                .help("View \(label.lowercased()) full size")
                .accessibilityLabel("View \(label.lowercased()) full size")
        } else {
            tile()
        }
    }

    /// §6: start from her base photos and tick what to keep (the rest is replaced by the description or the photo).
    @ViewBuilder private func baseRow(_ d: OutfitDraft) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Toggle(isOn: Binding(get: { store.outfitSheet?.fromBase ?? false }, set: { store.outfitSheet?.fromBase = $0 })) {
                Text("Start from her base photos").scaled(t.scale.label, t.roles.ink)
            }
            .toggleStyle(.checkbox)
            if d.fromBase {
                HStack(spacing: Space.s4) {
                    Text("Keep").scaled(t.scale.caption, t.roles.ink2)
                    keepBox("Top", \.top)
                    keepBox("Bottom", \.bottom)
                    keepBox("Shoes", \.shoes)
                    keepBox("Accessories", \.accessories)
                }
                TextField("Note, e.g. the black lace bra", text: Binding(get: { store.outfitSheet?.keepNote ?? "" },
                                                                        set: { store.outfitSheet?.keepNote = String($0.prefix(200)) }))
                    .textFieldStyle(.plain)
                    .focused($noteFocused)
                    .roleField(focused: noteFocused)
                    .frame(maxWidth: 420)
                Text(d.base?.summary ?? "").scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keepBox(_ label: String, _ key: WritableKeyPath<OutfitKeep, Bool>) -> some View {
        Toggle(isOn: Binding(get: { store.outfitSheet?.keep[keyPath: key] ?? false }, set: { store.outfitSheet?.keep[keyPath: key] = $0 })) {
            Text(label).scaled(t.scale.caption, t.roles.ink)
        }
        .toggleStyle(.checkbox)
    }

    private func dropZone(_ d: OutfitDraft) -> some View {
        let photo = d.mode == .photo
        return Button {
            let urls = MediaImport.pick(MediaImport.imageTypes, multiple: !photo, prompt: "Use")
            if !urls.isEmpty { store.outfitSheet?.images = photo ? [urls[0]] : Array(urls.prefix(4)) }
        } label: {
            DropZone(title: d.images.isEmpty ? (photo ? "Drop a product photo" : "Drop your 4 angle images") : d.images.map(\.lastPathComponent).joined(separator: ", "),
                     hint: photo ? "It's used as a reference image, so the outfit matches." : "Front, ¾, side and back, in that order. Any you skip can be filled in.",
                     buttonTitle: "Choose files", targeted: targeted)
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

/// A password field with a trailing eye that swaps SecureField ↔ TextField, keeping the text and the focus. Hidden by default.
/// The content type lets macOS Passwords / iCloud Keychain offer to save and AutoFill it; MUSE never stores the password.
struct PasswordField: View {
    @Environment(\.theme) private var t
    var placeholder = "Password"
    @Binding var text: String
    /// Sign-up: `.newPassword`, so the password manager can suggest a strong one.
    var isNew = false
    var onSubmit: () -> Void = {}
    @State private var shown = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if shown {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textContentType(isNew ? NSTextContentType.newPassword : NSTextContentType.password)
            .focused($focused)
            .onSubmit(onSubmit)
            Button {
                let had = focused
                shown.toggle()
                if had { DispatchQueue.main.async { focused = true } }
            } label: {
                Ph(shown ? "eye.slash" : "eye", 13).foregroundStyle(t.roles.ink2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(shown ? "Hide password" : "Show password")
            .accessibilityLabel(shown ? "Hide password" : "Show password")
        }
        .roleField(focused: focused)
    }
}
