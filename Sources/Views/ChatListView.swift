import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var store: Store
    @State private var path: [Chat] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.chats.isEmpty {
                    ContentUnavailableView("No chats", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Tap + to talk to any of 340+ models."))
                } else {
                    List {
                        ForEach(store.chats) { chat in
                            NavigationLink(value: chat) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chat.title).lineLimit(1).fontWeight(.medium)
                                    Text(shortModel(chat.model) + " · " + chat.updated.formatted(.relative(presentation: .named)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { idx in idx.map { store.chats[$0] }.forEach { store.delete($0) } }
                    }
                }
            }
            .navigationTitle("Harness Chat")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { path = [store.newChat()] } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .navigationDestination(for: Chat.self) { ChatView(chat: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear { if store.apiKey.isEmpty { showSettings = true } }
        }
    }
}

func shortModel(_ id: String) -> String { id.split(separator: "/").last.map(String.init) ?? id }
