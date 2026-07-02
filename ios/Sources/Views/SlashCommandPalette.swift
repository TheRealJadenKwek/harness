import SwiftUI

struct SlashCommand: Identifiable {
    let name: String
    let desc: String
    var id: String { name }
}

// Slash commands are a Claude Code feature (claude CLI). `codex exec` does NOT
// process them (verified — it just treats "/x" as a prompt), so Codex/OpenRouter
// threads get no command palette.
enum CommandCatalog {
    static func commands(for engine: String) -> [SlashCommand] {
        switch engine {
        case "claude": return claude
        default: return []
        }
    }

    static let claude: [SlashCommand] = [
        .init(name: "/cost", desc: "Token / cost usage"),
        .init(name: "/context", desc: "Context window usage"),
        .init(name: "/compact", desc: "Compact the conversation"),
        .init(name: "/review", desc: "Review a PR / branch"),
        .init(name: "/code-review", desc: "Review the diff"),
        .init(name: "/security-review", desc: "Security review"),
        .init(name: "/simplify", desc: "Simplify changed code"),
        .init(name: "/verify", desc: "Verify a change works"),
        .init(name: "/daily-brief", desc: "Your daily brief"),
        .init(name: "/deep-research", desc: "Deep research report"),
        .init(name: "/commit", desc: "Create a git commit"),
        .init(name: "/commit-push-pr", desc: "Commit, push, open a PR"),
        .init(name: "/feature-dev", desc: "Guided feature development"),
        .init(name: "/review-pr", desc: "Comprehensive PR review"),
        .init(name: "/init", desc: "Write / refresh CLAUDE.md"),
        .init(name: "/modernize-assess", desc: "Assess a legacy system"),
    ]
}

struct SlashCommandPalette: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    let engine: String
    let onPick: (String) -> Void

    private var all: [SlashCommand] { CommandCatalog.commands(for: engine) }
    private var filtered: [SlashCommand] {
        search.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.desc.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { c in
                Button {
                    onPick(c.name)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.system(.body, design: .monospaced))
                        Text(c.desc).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
