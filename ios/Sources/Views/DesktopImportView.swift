import SwiftUI

/// "Continue from desktop" — lists recent resumable Claude Code / Codex sessions found on
/// the computer. Importing one creates a harness thread bound to that session id; your
/// next message resumes it with the CLI's full context.
struct DesktopImportView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [DesktopSession] = []
    @State private var loading = true
    @State private var importing: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
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
                    .listRowBackground(Color.appBG)
                    .listRowSeparatorTint(Color.appBorder)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBG)
            .navigationTitle("Continue from desktop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBG, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
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
    }

    private func load() async {
        loading = true
        sessions = (try? await app.api.desktopSessions()) ?? []
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

    private func shortPath(_ p: String) -> String {
        let home = ("~" as NSString).expandingTildeInPath
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
