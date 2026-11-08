import MuseCore
import SwiftUI

// The owner's model picker in the AI Suite composer (WS6, owner request 2026-11-08; ComposerModelPicker in MuseCore).
extension AppStore {
    /// Pins a registry model at a resolution (nil = Auto, the quality's ladder); Length and Shape move inside its limits.
    func pinComposerModel(_ m: SuiteRegistryModel?, resolution: String? = nil) {
        guard isOwner else { return }
        suite.composer = ComposerModelPicker.pin(suite.composer, m, resolution: resolution, catalog: suite.catalog, settings: suite.settings)
    }

    /// The Length slider's range for the composer: the pinned model's, else the quality's.
    var composerLengthRange: ClosedRange<Int> {
        ComposerModelPicker.lengthRange(suite.composer, tier: suite.catalog?.tier(suite.composer.quality), settings: suite.settings)
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
        ComposerModelPicker.pinned(suite.composer, suite.settings)?.name ?? SuiteText.tierLabel(suite.composer.quality)
    }
}
