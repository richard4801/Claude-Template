import MuseCore
import SwiftUI

// AI suite (workstream 1): D9, the owner's Engines view (Shot builder drawer and Settings → Engines).

// MARK: D9: Engines (owner only)

/// What each tier runs today, where this shot goes, the compiled camera prompt, flags and the cost. Owner only: members
/// never see provider or model names.
struct SuiteEnginesPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var estimate: ShotEstimate?
    var showToggle = false

    var body: some View {
        let s = store.suite
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Engines").font(t.body(16, .semibold))
                Spacer()
                SuiteTag(text: "Owner only", color: t.rec)
            }
            Muted("Members only ever see Draft · Standard · HD · Cinema. This shows what each tier runs today.")
            ForEach(s.catalog?.tiers ?? []) { tier in
                let first = tier.models?.first
                HStack(alignment: .firstTextBaseline) {
                    Text(tier.label).font(t.body(13.5, .semibold)).frame(width: 74, alignment: .leading)
                    Text(first.map { "\($0.name) \($0.resolution)" } ?? (tier.available ? "—" : "Nothing set up")).font(t.body(13)).lineLimit(1)
                    Spacer()
                    Text(perSec(first).map { "$\(String(format: "%.4g", $0))/s" } ?? "").font(t.mono(11.5))
                }
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(t.line).frame(height: 1) }
            }
            if let e = estimate, let eng = e.engine {
                Text("This shot → \(eng.name) \(eng.resolution)\(e.tried?.isEmpty == false ? " (after \(e.tried!.map { "\($0.model): \($0.why ?? "skipped")" }.joined(separator: ", ")))" : "")")
                    .font(t.body(12)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("CAMERA → PROMPT (COMPILED FOR \(eng.name.uppercased()))").font(t.mono(10.5)).tracking(1)
                    Text(e.prompt ?? "").font(t.mono(11)).textSelection(.enabled).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
                }
            }
            if let set = s.settings {
                VStack(alignment: .leading, spacing: 8) {
                    Text("FLAGS").font(t.mono(10.5)).tracking(1)
                    FlowLayout(spacing: 6) {
                        SuiteTag(text: "Mode · \(set.mode)")
                        SuiteTag(text: "Budget cap \(Pricing.money(set.caps.perDay))/day")
                        SuiteTag(text: "Spent today \(Pricing.money(set.spentToday))")
                        ForEach(set.models.filter { $0.blocked || $0.needsAck }) { m in
                            SuiteTag(text: "\(m.name) · \(m.blocked ? (m.blockedReason ?? "blocked") : "needs ack")", color: t.warn)
                        }
                    }
                }
            }
            if let e = estimate {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cost this shot (\(e.takes) take\(e.takes == 1 ? "" : "s"))").font(t.body(13))
                    Spacer()
                    Text(Pricing.money(e.estimate)).font(t.isA ? Fonts.font("Instrument Serif", 28, .regular) : t.mono(18))
                }
                if let eng = e.engine {
                    HStack {
                        Text("Provider cost").font(t.body(12)).foregroundStyle(t.muted)
                        Spacer()
                        Text(Pricing.money(eng.perSec * (eng.billedPerTake ?? e.seconds) * Double(e.takes))).font(t.mono(12))
                    }
                }
            }
            if let set = s.settings {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MODELS").font(t.mono(10.5)).tracking(1)
                    ForEach(set.models.filter { $0.status != "removed" }) { m in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name).font(t.body(12.5, .semibold))
                                Text("\(m.provider)\(m.configured ? "" : " · not set up")").font(t.body(11)).foregroundStyle(t.muted)
                            }
                            Spacer()
                            if m.blocked {
                                SuiteTag(text: "Blocked", color: t.warn)
                            } else {
                                MToggle(isOn: Binding(get: { m.enabled }, set: { store.setSuiteModel(m.id, enabled: $0) }))
                            }
                        }
                    }
                }
            }
        }
        .task {
            if store.suite.catalog == nil { await store.loadSuite() }
            if store.suite.settings == nil { await store.loadSuiteSettings() }
        }
    }

    private func perSec(_ m: SuiteTierModel?) -> Double? {
        guard let m else { return nil }
        return store.suite.settings?.model(m.model)?.perSec(m.resolution)
    }
}
