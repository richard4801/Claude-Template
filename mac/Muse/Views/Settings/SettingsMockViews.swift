import MuseCore
import SwiftUI

// The proposed Settings structure (owner request 2026-11-08, plans/settings-redesign.md): a MOCK for the owner's review,
// drawn with the real components and themes but static sample data. Only review mode shows it (SnapshotRunner sets
// `state.settingsMock`); nothing in a normal launch reaches it. Once the owner approves, the real Settings is rebuilt on
// this layout and this file goes.

enum SettingsMockSection: String, CaseIterable {
    case account, studio, members, spending, providers, apps, advanced

    var title: String {
        switch self {
        case .account: return "Account"
        case .studio: return "Studio"
        case .members: return "Members"
        case .spending: return "AI & spending"
        case .providers: return "Providers"
        case .apps: return "Apps & devices"
        case .advanced: return "Advanced"
        }
    }

    var intro: String {
        switch self {
        case .account: return "You, how MUSE looks, and when it tells you things."
        case .studio: return "How new videos and photos start, the studio's prompts, and archived models."
        case .members: return "Who works in the studio, what each person can spend, and invitations."
        case .spending: return "Your balance, spend caps and the models behind each quality."
        case .providers: return "Your own accounts with AI providers. Their models join the AI Suite's model picker."
        case .apps: return "Claude, Blender and your phone working with MUSE."
        case .advanced: return "Server, testing and performance tools. Hidden unless turned on under Account."
        }
    }

    var ownerOnly: Bool { self == .members || self == .providers || self == .apps }
}

/// What the mock shows: a section, the Providers states, and the member's view.
struct SettingsMockState {
    var section: SettingsMockSection
    var member = false
    /// Providers: "empty" (nothing connected), "add" (the add-key form), "models" (connected, its model list).
    var providers = "models"
    /// AI & spending scrolled to its Default models (the shot shows that part).
    var modelsOnly = false
}

struct SettingsMockView: View {
    @Environment(\.theme) private var t
    var state: SettingsMockState

    private var sections: [SettingsMockSection] {
        SettingsMockSection.allCases.filter { (!$0.ownerOnly || !state.member) && $0 != .advanced }
    }

    var body: some View {
        ScreenPage {
            ScreenTitle("Settings")
            HStack(alignment: .top, spacing: Space.s6) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.self) { s in
                        SettingsNavRow(title: s.title, on: state.section == s) {}
                    }
                    if !state.member {
                        // Shown only while "Show advanced settings" is on (Account).
                        SettingsNavRow(title: SettingsMockSection.advanced.title, on: state.section == .advanced) {}
                            .padding(.top, Space.s5)
                    }
                }
                .frame(width: 200)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.section.intro).scaled(t.scale.body, t.roles.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Space.s5)
                    content
                }
                .frame(maxWidth: 680, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch state.section {
        case .account: MockAccount(member: state.member)
        case .studio: MockStudio(member: state.member)
        case .members: MockMembers()
        case .spending:
            if state.modelsOnly { MockDefaultModels() } else { MockSpending(member: state.member) }
        case .providers: MockProviders(mode: state.providers)
        case .apps: MockApps()
        case .advanced: MockAdvanced()
        }
    }
}

// MARK: Account

private struct MockAccount: View {
    @Environment(\.theme) private var t
    var member: Bool

    var body: some View {
        Group { who; appearance }
        Group { notifications }
        Group { about }
    }

    @ViewBuilder private var who: some View {
        SettingRow(member ? "Jess Moreno" : "Maya Studio", hint: member ? "jess@studio.com, member of Maya Studio" : "you@studio.com, owner") {
            RButton("Sign out", kind: .danger, small: true) {}
        }
    }

    @ViewBuilder private var appearance: some View {
        SectionTitle("Appearance")
        HStack(alignment: .top, spacing: Space.s4) {
            ForEach(ThemeID.allCases) { id in
                let on = id == t.id
                let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
                VStack(alignment: .leading, spacing: Space.s2) {
                    ThemePreview(theme: Theme.get(id)).aspectRatio(16 / 10, contentMode: .fit)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(t.roles.hairline, lineWidth: 1))
                        .overlay(shape.strokeBorder(t.roles.selection, lineWidth: on ? 2 : 0).padding(-4))
                    Text(id.name).scaled(t.scale.label, on ? t.roles.ink : t.roles.ink2)
                }
            }
        }
    }

    @ViewBuilder private var notifications: some View {
        SectionTitle("Notifications")
        SettingRow("Render finished") { RSwitch(label: "Render finished", isOn: .constant(true)) }
        SettingRow("Render failed") { RSwitch(label: "Render failed", isOn: .constant(true)) }
        SettingRow("Balance below $5") { RSwitch(label: "Balance below $5", isOn: .constant(false)) }
        SettingRow("Also notify my Android phone") { RSwitch(label: "Also notify my Android phone", isOn: .constant(true)) }
        HStack(spacing: Space.s3) {
            RButton("Send a test notification", small: true) {}
            RButton("Sound and banners in System Settings", kind: .plain, small: true) {}
        }
        .padding(.top, Space.s2)
    }

    @ViewBuilder private var about: some View {
        SectionTitle("About")
        SettingRow("Version") { RowValue("0.1 (build 412)") }
        SettingRow("Terms and policies") {
            HStack(spacing: Space.s3) {
                RButton("Terms of Service", kind: .plain, small: true) {}
                RButton("Acceptable Use", kind: .plain, small: true) {}
            }
        }
        if !member {
            SettingRow("Show advanced settings", hint: "Server, testing and performance tools") {
                RSwitch(label: "Show advanced settings", isOn: .constant(true))
            }
            .padding(.top, Space.s4)
        }
    }
}

// MARK: Studio

private struct MockStudio: View {
    @Environment(\.theme) private var t
    var member: Bool

    var body: some View {
        SectionTitle("New videos and photos", top: 0)
        SettingRow("Start at", hint: "The quality new shots use. Change it per shot in the AI Suite.") {
            RSeg([("draft", "Draft"), ("standard", "Standard"), ("hd", "HD"), ("cinema", "Cinema")], selection: .constant("standard")).frame(width: 340)
        }
        SettingRow("Show the prompt behind each render", hint: "Read and edit what the AI is asked to make") {
            RSwitch(label: "Show the prompt behind each render", isOn: .constant(false))
        }
        SettingRow("Click on each camera stop", hint: "A soft tick as the camera wheels turn") {
            RSwitch(label: "Click on each camera stop", isOn: .constant(false))
        }
        SettingRow("Test renders are kept for") { RowValue("30 days") }
        if !member {
            SectionTitle("Prompts and house style")
            SettingRow("Prompt library", hint: "The house style added to every photo, and each prompt MUSE writes") {
                RButton("Open prompts", small: true) {}
            }
            SectionTitle("Archived models")
            SettingRow("3 archived models", hint: "Hidden from every list. Their photos, renders and posts are kept.") {
                RButton("Show", small: true) {}
            }
        }
    }
}

// MARK: Members

private struct MockMembers: View {
    @Environment(\.theme) private var t

    var body: some View {
        HStack(spacing: Space.s3) {
            RButton("Invite someone", kind: .action) {}
            Text("2 members, 1 invitation waiting").scaled(t.scale.caption, t.roles.ink2)
        }
        SectionTitle("People")
        row("Jess Moreno", "jess@studio.com", "$4.10 of $10.00 today")
        row("Sam Park", "sam@studio.com", "$0.00 of $10.00 today")
        row("ari@studio.com", "Invited 6 Nov, not joined yet", nil)
        SectionTitle("Defaults for new members")
        SettingRow("Spend cap per person per day", hint: "Set someone's own cap from their row") { RowValue("$10.00") }
        SettingRow("Credit for new members") { RowValue("$0.00") }
    }

    private func row(_ name: String, _ hint: String, _ today: String?) -> some View {
        SettingRow(name, hint: hint) {
            HStack(spacing: Space.s3) {
                if let today { Text(today).monospacedDigit().scaled(t.scale.caption, t.roles.ink2) }
                RButton(today == nil ? "Resend" : "Manage", small: true) {}
            }
        }
    }
}

// MARK: AI & spending

private struct MockSpending: View {
    @Environment(\.theme) private var t
    var member: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.s7) {
            fact("Balance", member ? "$12.40" : "$84.20")
            fact("This month", member ? "$6.10" : "$41.10")
            fact("A 10 s Draft video", "About $0.65")
            Spacer(minLength: 0)
            RButton(member ? "Ask for credit" : "Add credit", kind: .action) {}
        }
        SectionTitle("Spend caps")
        if member {
            SettingRow("Per job", hint: "Set by the studio owner") { RowValue("$5.00") }
            SettingRow("My cap per day", hint: "Set by the studio owner") { RowValue("$10.00") }
        } else {
            SettingRow("Per job", hint: "LoRA training is not capped") { RowValue("$5.00") }
            SettingRow("Whole studio per day", hint: "Running jobs count towards today") { RowValue("$60.00") }
            RButton("Change caps", small: true) {}.padding(.top, Space.s1)
        }
        SettingRow("Warn me before a job goes over budget") { RSwitch(label: "Warn me before a job goes over budget", isOn: .constant(true)) }
        if !member {
            SectionTitle("AI editing helpers")
            SettingRow("Captions, background removal and voice clean-up", hint: "Off: hidden in Edit and nothing is charged. $2.00 a day at most, $0.40 used today.") {
                RSwitch(label: "AI editing helpers", isOn: .constant(true))
            }
            MockDefaultModels()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).scaled(t.scale.caption, t.roles.ink2)
            Text(value).monospacedDigit().scaled(t.scale.title, t.roles.ink)
        }
    }
}

/// Default models (owner request 2026-11-08: "anywhere I generate images or video, let me pick the model"): one row per
/// purpose, Auto or a model. Each screen's Model pill starts from these; picking there changes only that run.
private struct MockDefaultModels: View {
    @Environment(\.theme) private var t

    static let rows: [(String, String, String?)] = [
        ("Shots on Draft", "MiniMax H3 Lite, 768p", "Members see the quality, never the model"),
        ("Shots on Standard", "Auto", nil),
        ("Shots on HD", "MiniMax H3 on Higgsfield, 2K", nil),
        ("Shots on Cinema", "Kling 4.0, 1080p", nil),
        ("Photos", "FLUX.2 [pro]", "Photo tool, model photos and outfits"),
        ("Character swap", "Auto", nil),
        ("Recast", "Kling O1 Edit, 1080p", nil),
        ("Extend", "Auto", nil),
        ("Upscale", "SeedVR2", nil),
        ("Remove background", "Auto", "Edit's AI helpers"),
        ("Captions", "Auto", nil),
    ]

    var body: some View {
        SectionTitle("Default models") {
            Text("All running").scaled(t.scale.caption, t.roles.positive)
        }
        Text("What each kind of work uses unless you pick a model on the screen itself. Auto lets MUSE choose.")
            .scaled(t.scale.caption, t.roles.ink2).padding(.bottom, Space.s2)
        ForEach(Self.rows, id: \.0) { row in
            SettingRow(row.0, hint: row.2) {
                HStack(spacing: Space.s1) {
                    Text(row.1).scaled(t.scale.body, row.1 == "Auto" ? t.roles.ink2 : t.roles.ink)
                    Ph("chevron.down", 10).foregroundStyle(t.roles.ink2)
                }
                .padding(.horizontal, Space.s3).frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).strokeBorder(t.roles.hairline, lineWidth: 1))
            }
        }
        disclosure("Our own GPUs", "2 at once, off after 15 idle minutes")
        disclosure("Price corrections", "Every model at its listed price")
    }

    private func disclosure(_ title: String, _ summary: String) -> some View {
        HStack(spacing: Space.s2) {
            Ph("chevron.right", 12).foregroundStyle(t.roles.ink2)
            Text(title).scaled(t.scale.body, t.roles.ink)
            Text(summary).scaled(t.scale.caption, t.roles.ink2)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 36)
    }
}

// MARK: Providers (new; the owner's own provider accounts)

private struct MockProviders: View {
    @Environment(\.theme) private var t
    var mode: String

    var body: some View {
        switch mode {
        case "empty":
            EmptyState("No providers yet", "Add an API key for an AI provider you use. Its image and video models can then be picked per shot. Members never see them.",
                       actionTitle: "Add a provider", actionKind: .action) {}
                .frame(maxWidth: .infinity)
                .padding(.top, Space.s5)
        case "add":
            addForm
        case "nokeys":
            VStack(alignment: .leading, spacing: Space.s4) {
                InlineNotice("Provider keys aren't set up on the server yet. Adding a key works once they are.", tone: .caution)
                EmptyState("No providers yet", "Add an API key for an AI provider you use. Its image and video models can then be picked per shot. Members never see them.",
                           actionTitle: "Add a provider", actionKind: .quiet) {}
                    .frame(maxWidth: .infinity)
            }
        default:
            connected
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("Add a provider").scaled(t.scale.heading, t.roles.ink)
            RField("Provider") {
                RSeg([("replicate", "Replicate"), ("fal", "fal")], selection: .constant("fal")).frame(width: 220)
            }
            RField("API key", hint: "Saved encrypted on the MUSE server, checked with fal first. Afterwards you only see its last 4 characters.") {
                SecureField("Paste the key", text: .constant("fal_live_1234567890abcdef"))
                    .roleField(focused: true)
                    .frame(width: 420)
            }
            HStack(spacing: Space.s3) {
                RButton("Save key", kind: .action) {}
                RButton("Cancel", kind: .plain) {}
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                RButton("Add a provider", small: true) {}
            }
            SettingRow("fal", hint: "Key ending 4f2a, added 8 Nov. 9 of 48 models on.") {
                HStack(spacing: Space.s3) {
                    RButton("Replace key", kind: .plain, small: true) {}
                    RButton("Remove", kind: .plain, small: true) {}
                }
            }
            SettingRow("Replicate", hint: "Key ending 91c0, added 2 Nov. 4 of 112 models on.") {
                HStack(spacing: Space.s3) {
                    RButton("Replace key", kind: .plain, small: true) {}
                    RButton("Remove", kind: .plain, small: true) {}
                }
            }
            SectionTitle("fal models") {
                RSeg([("all", "All"), ("video", "Video"), ("image", "Image"), ("on", "On")], selection: .constant("all")).frame(width: 300)
            }
            RTextField(placeholder: "Search 48 models", text: .constant(""))
                .frame(maxWidth: 360)
                .padding(.bottom, Space.s2)
            model("Kling 2.5 Turbo Pro", "kling-video/v2.5-turbo/pro", "Video", "$0.07/s", on: true, renamed: nil)
            model("Seedance 1 Pro", "bytedance/seedance/v1/pro", "Video", "$0.12/s", on: true, renamed: "Seedance (sharp)")
            model("Wan 2.5", "wan-25-preview/text-to-video", "Video", "$0.05/s", on: false, renamed: nil)
            model("FLUX.1 Kontext Pro", "flux-pro/kontext", "Image", "$0.04", on: true, renamed: nil)
            model("Imagen 4", "imagen4/preview", "Image", "$0.05", on: false, renamed: nil)
        }
    }

    private func model(_ name: String, _ id: String, _ kind: String, _ price: String, on: Bool, renamed: String?) -> some View {
        HStack(spacing: Space.s3) {
            RSwitch(label: "Use \(name)", isOn: .constant(on))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s2) {
                    Text(renamed ?? name).scaled(t.scale.body, t.roles.ink)
                    MockBadge(text: kind)
                }
                Text(renamed == nil ? id : "\(name), \(id)").scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
            }
            Spacer(minLength: Space.s3)
            Text(price).monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
            RButton("Rename", kind: .plain, small: true) {}
        }
        .frame(minHeight: 44)
    }
}

/// A small information-bearing tag (Image / Video): caption text in a hairline outline at the chip radius.
private struct MockBadge: View {
    @Environment(\.theme) private var t
    var text: String

    var body: some View {
        Text(text).scaled(t.scale.caption, t.roles.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).strokeBorder(t.roles.hairline, lineWidth: 1))
    }
}

// MARK: Apps & devices

private struct MockApps: View {
    @Environment(\.theme) private var t

    var body: some View {
        SectionTitle("Claude", top: 0) {
            RButton("Setup guide", kind: .plain, small: true) {}
        }
        SettingRow("Chat with Claude inside MUSE", hint: "Uses Claude Code on this Mac, signed in as you") { Text("Connected").scaled(t.scale.caption, t.roles.positive) }
        SettingRow("Claude Desktop", hint: "Token made 2 Nov, last used today") { RButton("Revoke", kind: .plain, small: true) {} }
        SettingRow("Claude Code on the studio Mac", hint: "Token made 5 Nov, last used yesterday") { RButton("Revoke", kind: .plain, small: true) {} }
        RButton("Connect another Claude app", small: true) {}.padding(.top, Space.s1)
        SectionTitle("Blender")
        SettingRow("Run Blender for MUSE on this Mac", hint: "Directed shots render their guides here") {
            RSwitch(label: "Run Blender for MUSE on this Mac", isOn: .constant(true))
        }
        SettingRow("Blender add-on", hint: "Installed, version 1.2") { RButton("How to install", kind: .plain, small: true) {} }
        SectionTitle("Phones")
        SettingRow("MUSE for Android", hint: "Signed in on 1 phone. Renders finished there show up here too.") { RowValue("1 phone") }
    }
}

// MARK: Advanced

private struct MockAdvanced: View {
    @Environment(\.theme) private var t

    var body: some View {
        SectionTitle("Server", top: 0)
        RSeg([("http", "MUSE server"), ("fake", "Demo mode (no server)")], selection: .constant("http")).frame(maxWidth: 420)
        RField("Server address", hint: "Remote servers need HTTPS") {
            HStack(spacing: Space.s2) {
                RTextField(placeholder: "https://", text: .constant("https://api.muse.studio"))
                RButton("Test connection") {}
            }
        }
        .padding(.top, Space.s3)
        SectionTitle("Testing")
        SettingRow("Fail the next render", hint: "Stops partway and refunds, to test failure handling. Demo and dev servers only.") {
            RButton("Fail next render", small: true) {}
        }
        SettingRow("Reload everything", hint: "Fetches models, outfits, jobs, takes and balance again") { RButton("Reload", small: true) {} }
        SectionTitle("Performance")
        SettingRow("Cold start to first content") { RowValue("0.9 s") }
        SettingRow("Library scroll", hint: "Frames drawn on time over the last minute") { RowValue("119 fps") }
    }
}
