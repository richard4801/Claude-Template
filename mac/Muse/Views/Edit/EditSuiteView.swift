import SwiftUI

// Entry point for workstream 3 (the Edit suite). Stub: workstream 3 replaces this file at merge.

/// Edit (top level), or a take opened in Edit.
struct EditSuiteView: View {
    @Environment(AppStore.self) private var store
    let takeId: String?
    init(takeId: String? = nil) { self.takeId = takeId }
    var body: some View {
        ContentUnavailableView("Edit", systemImage: "scissors", description: Text(takeId == nil ? "Cut, colour and finish your takes." : "Opening this take in Edit."))
    }
}
