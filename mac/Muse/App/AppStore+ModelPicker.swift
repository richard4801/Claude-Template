import MuseCore
import SwiftUI

// The owner's model picker in the AI Suite composer (WS6, owner request 2026-11-08; ComposerModelPicker in MuseCore):
// Shot-like tools pin a video model (`engineModel` + `resolution`), Photo pins an image model (`imageModel`).
extension AppStore {
    /// Every model the owner can pick for the composer's tool, the quality's ladder first.
    func composerModelOptions(search: String = "") -> [SuiteModelOption] {
        ComposerModelPicker.options(suite.catalog, suite.settings, tool: suite.composer.tool, quality: suite.composer.quality, search: search)
    }

    /// Pins a video model at a resolution (nil = Auto, the quality's ladder); Length and Shape move inside its limits.
    func pinComposerModel(_ m: SuiteModelOption?, resolution: String? = nil) {
        // 4c: members pin a model too (the server checks it is one they may use).
        if suite.composer.tool == .photo {
            suite.photo.imageModel = m?.model
            return
        }
        suite.composer = ComposerModelPicker.pin(suite.composer, m, resolution: resolution, catalog: suite.catalog, settings: suite.settings)
    }

    /// The model the composer's tool is pinned to (nil = Auto).
    var composerPinnedModel: String? { suite.composer.tool == .photo ? suite.photo.imageModel : suite.composer.engineModel }

    /// The Model pill's words: "Auto", "Kling 4.0, 1080p", "FLUX.2 [pro]".
    var composerModelLabel: String {
        suite.composer.tool == .photo ? ComposerModelPicker.imageLabel(suite.photo, catalog: suite.catalog)
            : ComposerModelPicker.label(suite.composer, catalog: suite.catalog, settings: suite.settings)
    }

    /// The Length slider's range for the composer: the pinned model's, else the quality's.
    var composerLengthRange: ClosedRange<Int> {
        ComposerModelPicker.lengthRange(suite.composer, catalog: suite.catalog, settings: suite.settings)
    }

    /// Sets the composer's length, snapped to the pinned model's allowed lengths (Veo: 4, 6 or 8 s).
    func setComposerLength(_ seconds: Int) {
        var d = suite.composer
        d.duration = seconds
        suite.composer = ComposerModelPicker.fitted(d, catalog: suite.catalog, settings: suite.settings)
    }

    /// The shapes on offer: the pinned model's, else the catalog's.
    var composerShapes: [String] { ComposerModelPicker.aspects(suite.composer, catalog: suite.catalog, settings: suite.settings) }

    /// "on Standard" or "on Veo 3.1 Lite" under the Length slider.
    var composerLengthSource: String {
        ComposerModelPicker.pinned(suite.composer, suite.catalog, suite.settings)?.shownName ?? SuiteText.tierLabel(suite.composer.quality)
    }

    /// After the catalog reloads: pins the list no longer offers go back to Auto.
    func revalidateModelPins() {
        suite.composer = ComposerModelPicker.validated(suite.composer, catalog: suite.catalog, settings: suite.settings)
        suite.photo = ComposerModelPicker.validatedImage(suite.photo, suite.catalog)
    }
}
