import Foundation
import MuseCore

// New Swap (beta, plans/new-swap.md): the Swap screen's second panel. Start from a video (upload, link or Library),
// switch on what changes (Background, Outfit, Character, Look & light), Auto picks a model and says why, Generate shows
// the price. The current Swap stays as it is; the header switch flips between them.

/// Swap's header switch. Remembered on this Mac.
enum SwapVariant: String, CaseIterable {
    case classic, remix
    var label: String { self == .classic ? "Swap" : "New Swap (beta)" }
    static let defaultsKey = "suite.swapVariant"
    static var saved: SwapVariant { UserDefaults.standard.string(forKey: defaultsKey).flatMap(SwapVariant.init(rawValue:)) ?? .classic }
}

/// Which picture an upload goes to.
enum RemixPhotoTarget { case background, product, face }

extension AppStore {
    /// New Swap is on screen: the Swap tool with the header switch on New Swap.
    var isNewSwap: Bool { suite.composer.tool == .swap && suite.swapVariant == .remix }

    func setSwapVariant(_ v: SwapVariant) {
        guard suite.swapVariant != v else { return }
        suite.swapVariant = v
        UserDefaults.standard.set(v.rawValue, forKey: SwapVariant.defaultsKey)
        suiteComposerChanged(now: true) // Claude sees which Swap is open
    }

    /**
     * The composer always shares its draft (owner bug 2026-11-12: Claude couldn't reach New Swap, "no composer is open
     * on the person's page"): the page then carries the draft's id, and the screen is pushed into it as it changes, whether
     * or not Claude's panel was ever opened on this Mac. One draft per mode, as when the panel opens.
     */
    func shareSuiteDraft() async {
        let c = suite.claude
        guard screen == .suite, suite.mode != .hub, c.assist == nil || c.key != suiteClaudeKey, !c.creating, let api = suiteAssistAPI else { return }
        c.creating = true
        defer { c.creating = false }
        await newSuiteAssist(api: api, key: suiteClaudeKey)
    }

    /// What Generate sends (nil until a video is in and every turned-on toggle is complete).
    var remixRequest: ShotRequest? {
        guard let c = clip, suite.remix.missing == nil else { return nil }
        return .remix(clipId: c.id, draft: suite.remix, title: "New Swap · \(c.name)")
    }

    func estimateRemix() async {
        guard suite.enabled, suite.catalog != nil, let req = remixRequest else {
            suite.remixEstimate = nil
            suite.remixError = nil
            await loadRemixModels()
            return
        }
        do {
            suite.remixEstimate = try await api.suiteEstimate(req)
            suite.remixError = nil
        } catch let e as ApiError {
            suite.remixEstimate = nil
            suite.remixError = e.friendlyMessage
        } catch {}
        await loadRemixModels()
    }

    /// The model pill's list for these toggles and this clip (support, limits, price; Auto marked).
    func loadRemixModels() async {
        let d = suite.remix
        guard d.anyOn else {
            suite.remixModels = nil
            return
        }
        let req = RemixModelsRequest(remix: d.toggles, clipId: clip?.id, range: d.range.map { [$0.from, $0.to] })
        suite.remixModels = try? await api.suiteRemixModels(req)
    }

    func generateRemix() {
        guard let req = remixRequest else {
            showToast(clip == nil ? "Add a video first" : (suite.remix.missing ?? "Turn on a change"))
            return
        }
        if let r = suite.remixEstimate?.remix, r.trim.needed {
            showToast("Trim the clip first: this model takes up to \(Pricing.trimNum(r.trim.maxSeconds)) s")
            return
        }
        if let p = suite.remixEstimate?.problem {
            showToast(p)
            return
        }
        guard !suite.generating else { return }
        suite.generating = true
        perform { [self] in
            defer { suite.generating = false }
            let j = try await api.suiteCreateShot(req)
            upsert(j)
            suite.swapJobIds.append(j.id)
            rememberStage(j.id)
            suite.swapUsesStage = false
            balance = try await api.balance()
            showToast("Rendering \(j.engineLabel) · \(Pricing.money(j.cost))", action: "Open queue") { [weak self] in self?.go(.queue) }
        }
    }

    // MARK: Pictures and the source

    /// Upload a picture for the background, the product photo or the face swap.
    func pickRemixPhoto(_ target: RemixPhotoTarget) {
        let prompt: String
        switch target {
        case .background: prompt = "Use as the new background"
        case .product: prompt = "Use as the outfit"
        case .face: prompt = "Use this face"
        }
        guard let url = MediaImport.pick(MediaImport.imageTypes, multiple: false, prompt: prompt).first(where: MediaImport.isImage) else { return }
        perform { [self] in
            let ref = try await uploadImage(url)
            let name = url.deletingPathExtension().lastPathComponent
            switch target {
            case .background:
                suite.remix.backgroundMode = .photo
                suite.remix.backgroundImage = ref
                suite.remix.backgroundName = name
            case .product:
                suite.remix.outfitKind = .product
                suite.remix.productImage = ref
                suite.remix.productName = name
            case .face:
                suite.remix.characterKind = .face
                suite.remix.faceImage = ref
                suite.remix.faceName = name
            }
        }
    }

    /// A studio location as the new background.
    func pickRemixLocation(_ loc: SuiteLocation) {
        suite.remix.backgroundMode = .photo
        suite.remix.backgroundImage = loc.image
        suite.remix.backgroundName = loc.name
    }

    /// A finished take from the Library as the video (copied to a clip on the server; the take stays as it is).
    func useTakeAsRemixSource(_ take: Take) {
        perform { [self] in
            let c = try await withUploadProgress("Adding \(take.caption)") { _ in try await self.api.clipFromTake(take.id) }
            clip = c
            clipFile = nil
            clipThumb = take.thumb
            suite.remix.range = nil
            showToast("Added \(take.caption) · \(Pricing.trimNum(c.durationSec)) s")
        }
    }

    /// The trimmer: the part of the clip used, kept inside the clip and at most the model's length.
    func setRemixRange(from: Double, to: Double) {
        guard let c = clip else { return }
        let a = max(0, min(from, c.durationSec)), b = max(a, min(to, c.durationSec))
        suite.remix.range = (a <= 0.05 && b >= c.durationSec - 0.05) ? nil : RemixRange(from: (a * 10).rounded() / 10, to: (b * 10).rounded() / 10)
    }
}
