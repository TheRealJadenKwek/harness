import SwiftUI

struct ArchivedThreadsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.archivedThreads) { t in
                    NavigationLink(value: t.id) { ThreadRow(t: t) }
                        .listRowBackground(Color.appBG)
                        .listRowSeparatorTint(Color.appBorder)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await app.delete(t.id); await app.loadArchived() }
                            } label: { Label("Delete", systemImage: "trash") }
                            Button {
                                Task { await app.archive(t.id, false); await app.loadArchived() }
                            } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }.tint(.indigo)
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBG)
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                ChatView(threadID: id).environmentObject(app)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .overlay {
                if app.archivedThreads.isEmpty {
                    ContentUnavailableView("No archived chats", systemImage: "archivebox",
                                           description: Text("Swipe a chat and tap Archive to tuck it away here."))
                }
            }
        }
        .task { await app.loadArchived() }
    }
}

struct TrashView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("Deleted chats are removed permanently after 30 days.")
                    .font(.caption2).foregroundStyle(Color.appSecondary)) {
                    ForEach(app.trashedThreads) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            ThreadRow(t: t)
                            if let d = t.deleted_at {
                                Text("Deleted \(relativeTime(d))").font(.caption2).foregroundStyle(.red)
                            }
                        }
                        .listRowBackground(Color.appBG)
                        .listRowSeparatorTint(Color.appBorder)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await app.deletePermanent(t.id); await app.loadTrash() }
                            } label: { Label("Delete", systemImage: "trash.fill") }
                            Button {
                                Task { await app.restore(t.id); await app.loadTrash() }
                            } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.green)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBG)
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .overlay {
                if app.trashedThreads.isEmpty {
                    ContentUnavailableView("Nothing deleted", systemImage: "trash",
                                           description: Text("Deleted chats land here and can be restored for 30 days."))
                }
            }
        }
        .task { await app.loadTrash() }
    }
}
