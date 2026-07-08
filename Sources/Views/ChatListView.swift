import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var store: Store
    @State private var path: [String] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.chats.isEmpty {
                    ContentUnavailableView("No chats", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Tap + to start — synced with the web app."))
                } else {
                    List {
                        ForEach(store.chats) { chat in
                            NavigationLink(value: chat.id) {
                                HStack(spacing: 8) {
                                    if store.live.contains(chat.id) {
                                        Text("✳").font(.caption)
                                            .foregroundStyle(Color(red: 0.79, green: 0.39, blue: 0.26))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(chat.title).lineLimit(1).fontWeight(.medium)
                                        Text(shortModel(chat.model) + " · " + chat.updated.formatted(.relative(presentation: .named)))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contextMenu {
                                Button { if let f = store.fork(chatID: chat.id, msgIndex: nil) { path = [f.id] } } label: {
                                    Label("Fork", systemImage: "arrow.triangle.branch")
                                }
                                Button(role: .destructive) { store.delete(chat) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { idx in idx.map { store.chats[$0] }.forEach { store.delete($0) } }
                    }
                    .refreshable { await store.syncPull() }
                }
            }
            .navigationTitle("Harness Chat")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { path = [store.newChat().id] } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .navigationDestination(for: String.self) { ChatView(chatID: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task {
                await store.syncPull()
                if store.profile == nil { await store.loadProfile() }
                if store.profile?.hasKey == false { showSettings = true }
            }
        }
    }
}

func shortModel(_ id: String) -> String { id.split(separator: "/").last.map(String.init) ?? id }
