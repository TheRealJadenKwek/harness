import SwiftUI

struct ThreadListView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNew = false
    @State private var search = ""
    @State private var renameTarget: ThreadSummary?
    @State private var renameText = ""
    @State private var showArchived = false
    @State private var showImport = false
    @State private var showTrash = false
    @State private var showUsage = false

    private var filtered: [ThreadSummary] {
        guard !search.isEmpty else { return app.threads }
        return app.threads.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(search) ||
            $0.provider.localizedCaseInsensitiveContains(search) ||
            ($0.cwd ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    @ViewBuilder
    private func row(_ t: ThreadSummary) -> some View {
        NavigationLink(value: t.id) { ThreadRow(t: t, unseen: app.isUnseen(t)) }
            .listRowBackground(Color.appBG)
            .listRowSeparatorTint(Color.appBorder)
            .contextMenu {
                Button { renameTarget = t; renameText = t.title ?? "" } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    Task {
                        if let f = try? await app.api.fork(t.id) {
                            await app.refresh()
                            app.pendingOpenThread = f.id
                        }
                    }
                } label: {
                    Label("Fork", systemImage: "arrow.triangle.branch")
                }
                Button(role: .destructive) { Task { await app.delete(t.id) } } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { Task { await app.delete(t.id) } } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button { Task { await app.archive(t.id, true) } } label: {
                    Label("Archive", systemImage: "archivebox")
                }.tint(.indigo)
                Button { renameTarget = t; renameText = t.title ?? "" } label: {
                    Label("Rename", systemImage: "pencil")
                }.tint(Color.appSecondary)
            }
    }

    var body: some View {
        List {
            if !app.status.isEmpty {
                Text(app.status).foregroundStyle(.red).font(.footnote)
            }
            ForEach(filtered) { t in row(t) }
            .onDelete { idx in
                let ids = idx.map { filtered[$0].id }
                Task { for id in ids { await app.delete(id) } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.appBG)
        .searchable(text: $search)
        .refreshable { await app.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.refresh() } }   // foreground -> fresh list + running flags
        }
        .navigationDestination(for: String.self) { id in
            ChatView(threadID: id).environmentObject(app)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if app.servers.count > 1 {
                        Picker("Server", selection: Binding(
                            get: { app.activeServerID },
                            set: { if let id = $0 { app.switchTo(id) } }
                        )) {
                            ForEach(app.servers) { s in
                                Label(s.name, systemImage: "desktopcomputer").tag(Optional(s.id))
                            }
                        }
                        Divider()
                    }
                    Button { showImport = true } label: { Label("Continue from desktop", systemImage: "desktopcomputer.and.arrow.down") }
                    Button { showUsage = true } label: { Label("Usage limits", systemImage: "gauge.with.dots.needle.bottom.50percent") }
                    Button { showArchived = true } label: { Label("Archived", systemImage: "archivebox") }
                    Button { showTrash = true } label: { Label("Recently Deleted", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $showNew) {
            NewThreadSheet().environmentObject(app)
        }
        .sheet(isPresented: $showImport) { DesktopImportView().environmentObject(app) }
        .sheet(isPresented: $showArchived) { ArchivedThreadsView().environmentObject(app) }
        .sheet(isPresented: $showTrash) { TrashView().environmentObject(app) }
        .sheet(isPresented: $showUsage) { UsageView().environmentObject(app) }
        .alert("Rename thread",
               isPresented: Binding(get: { renameTarget != nil },
                                    set: { if !$0 { renameTarget = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let t = renameTarget { Task { await app.rename(t.id, title: renameText) } }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .overlay {
            if filtered.isEmpty && !app.loading {
                ContentUnavailableView(search.isEmpty ? "No threads" : "No matches",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text(search.isEmpty ? "Tap the pencil to start one." : "Try another search."))
            }
        }
    }
}

struct ThreadRow: View {
    let t: ThreadSummary
    var unseen: Bool = false

    private var snippet: String? {
        guard let last = t.last, !last.isEmpty else { return nil }
        return (t.last_role == "user" ? "You: " : "") + last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if unseen {
                    Circle().fill(Color.blue).frame(width: 7, height: 7)
                }
                Text(t.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled")
                    .font(.body).fontWeight(unseen ? .semibold : .regular)
                    .lineLimit(1).foregroundStyle(Color.appText)
                if t.running == true { ProgressView().controlSize(.mini) }
                Spacer(minLength: 6)
                Text(relativeTime(t.updated)).font(.caption2).foregroundStyle(Color.appSecondary)
            }
            if t.awaiting == true && t.running != true {
                Label("Waiting for your answer", systemImage: "questionmark.circle.fill")
                    .font(.caption2).bold().foregroundStyle(.orange).lineLimit(1)
            } else if let s = snippet {
                Text(s).font(.caption).foregroundStyle(Color.appSecondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                Image(systemName: engineIcon(t.engine)).foregroundStyle(Color.appSecondary)
                Text(t.model ?? t.engine)
                if let cost = t.total_cost, cost > 0 { Text(String(format: "· ~$%.2f", cost)) }
                Spacer()
                if let c = t.message_count { Text("\(c) msgs") }
            }
            .font(.caption2).foregroundStyle(Color.appSecondary)
        }
        .padding(.vertical, 4)
    }
}

/// Compact "2m ago" / "3h ago" / "Jun 18" from a unix timestamp.
func relativeTime(_ ts: Double?) -> String {
    guard let ts, ts > 0 else { return "" }
    let secs = Date().timeIntervalSince1970 - ts
    if secs < 60 { return "now" }
    if secs < 3600 { return "\(Int(secs / 60))m ago" }
    if secs < 86_400 { return "\(Int(secs / 3600))h ago" }
    if secs < 604_800 { return "\(Int(secs / 86_400))d ago" }
    let f = DateFormatter(); f.dateFormat = "MMM d"
    return f.string(from: Date(timeIntervalSince1970: ts))
}
