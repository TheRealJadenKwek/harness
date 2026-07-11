import SwiftUI

/// "Continue from desktop" — lists recent resumable Claude Code / Codex sessions found on
/// the computer. Importing one creates a harness thread bound to that session id; your
/// next message resumes it with the CLI's full context.
struct DesktopImportView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [DesktopSession] = []
    @State private var loading = true
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var importing: String?
    @State private var errorText: String?
    /// Reached via the New-thread sheet's NavigationLink (pushed), so it must NOT wrap
    /// itself in another NavigationStack — that would nest a second nav bar.
    var pushed = true

    var body: some View {
        Group {
            if pushed { content } else { NavigationStack { content } }
        }
    }

    private var content: some View {
        List {
                ForEach(sessions) { s in
                    Button { importSession(s) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: engineIcon(s.engine))
                                    .font(.system(size: 11))
                                    .foregroundStyle(s.engine == "codex" ? Color.appText : .orange)
                                Text(s.title)
                                    .font(.body).lineLimit(1).foregroundStyle(Color.appText)
                                Spacer(minLength: 6)
                                if importing == s.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(relativeTime(s.updated))
                                        .font(.caption2).foregroundStyle(Color.appSecondary)
                                }
                            }
                            HStack(spacing: 6) {
                                Text("\(s.turns) message\(s.turns == 1 ? "" : "s")")
                                    .font(.caption2).foregroundStyle(Color.appSecondary)
                                Text(shortPath(s.cwd))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Color.appSecondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .disabled(importing != nil)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { handoff(s) } label: {
                            Label(s.engine == "codex" ? "→ Claude" : "→ Codex",
                                  systemImage: "arrow.left.arrow.right")
                        }.tint(.purple)
                    }
                    .listRowBackground(Color.appBG)
                    .listRowSeparatorTint(Color.appBorder)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBG)
            .navigationTitle("Continue from desktop")
            .searchable(text: $query, prompt: "Search all your desktop chats…")
            .onChange(of: query) { _, q in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)   // debounce
                    guard !Task.isCancelled else { return }
                    await load()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBG, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if !pushed {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView(loading ? "Scanning…" : "No desktop sessions",
                                           systemImage: "desktopcomputer",
                                           description: Text("Recent Claude Code and Codex sessions on your computer appear here — tap one to keep working on it from your phone."))
                }
            }
            .alert("Couldn't import", isPresented: .init(get: { errorText != nil },
                                                         set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .task { await load() }
            .refreshable { await load() }
    }

    private func load() async {
        loading = true
        sessions = (try? await app.api.desktopSessions(query: query)) ?? []
        loading = false
    }

    private func importSession(_ s: DesktopSession) {
        importing = s.id
        Task {
            do {
                let t = try await app.api.importDesktopSession(s.id, engine: s.engine)
                await app.refresh()
                app.pendingOpenThread = t.id
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            importing = nil
        }
    }

    /// Cross-engine continue: create the handoff thread, stage the transcript-feeding
    /// message as the composer draft, and open it — the user reviews and taps send.
    private func handoff(_ s: DesktopSession) {
        importing = s.id
        Task {
            do {
                let r = try await app.api.handoffDesktopSession(s.id, engine: s.engine)
                UserDefaults.standard.set(r.draft, forKey: "draft_\(r.thread.id)")
                await app.refresh()
                app.pendingOpenThread = r.thread.id
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            importing = nil
        }
    }

    private func shortPath(_ p: String) -> String {
        let home = ("~" as NSString).expandingTildeInPath
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
