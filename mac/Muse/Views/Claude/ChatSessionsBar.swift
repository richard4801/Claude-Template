import MuseCore
import SwiftUI

/// WS18: the chats of this place over the transcript. The open chat's name opens the list (each with when it was last
/// used; Rename and Delete for the open one); "+" starts a new chat. Every place keeps its own list on the server: the
/// AI Suite one per composer tool, Recreate, Edit and Camera one per reference, session or camera.
struct ChatSessionsBar: View {
    @Environment(\.theme) private var t
    let model: ClaudeChatModel
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false

    var body: some View {
        let current = model.thread
        let name = current.map { cur in ClaudeSessions.displayTitle(model.threads.first(where: { $0.id == cur.id }) ?? cur) } ?? "New chat"
        HStack(spacing: Space.s2) {
            Menu {
                Section("Chats") {
                    ForEach(model.threads) { th in
                        Button { Task { await model.open(th) } } label: {
                            if th.id == current?.id {
                                Label("\(ClaudeSessions.displayTitle(th)), \(ClaudeSessions.lastUsed(th.updatedAt))", systemImage: "checkmark")
                            } else {
                                Text("\(ClaudeSessions.displayTitle(th)), \(ClaudeSessions.lastUsed(th.updatedAt))")
                            }
                        }
                        .disabled(model.busy && th.id != current?.id)
                    }
                }
                Divider()
                Button("Rename chat…") {
                    newTitle = current?.title ?? ""
                    renaming = true
                }
                .disabled(current == nil)
                Button("Delete chat…", role: .destructive) { confirmDelete = true }
                    .disabled(current == nil)
            } label: {
                HStack(spacing: Space.s1) {
                    Text(name).scaled(t.scale.label, t.roles.ink).lineLimit(1).truncationMode(.tail)
                    Ph("caret-down", 12).foregroundStyle(t.roles.ink2)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help("Your chats here: switch, rename or delete")
            .accessibilityLabel("Chat: \(name). Open the list of chats")
            Spacer(minLength: Space.s2)
            Button { Task { await model.newChat() } } label: {
                Ph("plus", 16).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isEmptyChat || model.busy ? t.roles.ink2.opacity(0.5) : t.roles.ink2)
            .disabled(model.isEmptyChat || model.busy)
            .help(model.isEmptyChat ? "This chat is new" : "New chat")
            .accessibilityLabel("New chat")
        }
        .padding(.horizontal, Space.s4)
        .frame(height: 40)
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "chat sessions") } }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
            Button("Rename") { if let c = current { Task { await model.rename(c, to: newTitle) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to name it by its first message.")
        }
        .confirmationDialog("Delete this chat?", isPresented: $confirmDelete) {
            Button("Delete chat", role: .destructive) { if let c = current { Task { await model.delete(c) } } }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Its messages are deleted on every device. The composer stays as it is.")
        }
    }
}
