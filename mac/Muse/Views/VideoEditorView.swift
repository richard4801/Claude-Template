import MuseCore
import SwiftUI

/// The editor screen (Screen.editor) now shows the Edit suite on the take that was opened with Edit (Result, Gallery).
/// Old v1 edited versions open there too: their edit list becomes a v2 project through EditV2.fromV1.
struct VideoEditorView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        EditSuiteView(takeId: store.editor?.take.id ?? store.openTakeId)
            .id(store.editor?.take.id ?? store.openTakeId ?? "edit-home")
    }
}
