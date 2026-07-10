import SwiftUI

struct ModelOption: Codable, Hashable {
    let label: String   // shown to the user, e.g. "Opus 4.8"
    let value: String   // sent to the CLI, e.g. "claude-opus-4-8"
}

// Quick-pick models per engine (friendly name -> CLI id). "Custom…" covers anything new.
enum ModelCatalog {
    static func options(for engine: String) -> [ModelOption] {
        switch engine {
        case "claude":
            return [
                .init(label: "Opus 4.8", value: "claude-opus-4-8"),
                .init(label: "Sonnet 4.6", value: "claude-sonnet-4-6"),
                .init(label: "Haiku 4.5", value: "claude-haiku-4-5"),
                .init(label: "Opus 4.7", value: "claude-opus-4-7"),
                .init(label: "Opus 4.6", value: "claude-opus-4-6"),
            ]
        case "codex":
            return [
                .init(label: "GPT-5.5", value: "gpt-5.5"),
                .init(label: "GPT-5.4", value: "gpt-5.4"),
                .init(label: "GPT-5.4-Mini", value: "gpt-5.4-mini"),
                .init(label: "GPT-5.3-Codex-Spark", value: "gpt-5.3-codex-spark"),
            ]
        default:
            return []
        }
    }

    // Friendly label for a stored model value ("" = Default; unknown = the raw id).
    static func label(for value: String, engine: String) -> String {
        if value.isEmpty { return "Default" }
        return options(for: engine).first { $0.value == value }?.label ?? value
    }

    static func isPreset(_ value: String, engine: String) -> Bool {
        options(for: engine).contains { $0.value == value }
    }
}

struct EffortOption: Hashable {
    let label: String
    let value: String
}

// Reasoning effort per engine — Codex tops out at "Extra High"; Claude also has "Max".
enum EffortCatalog {
    static func options(for engine: String) -> [EffortOption] {
        var opts: [EffortOption] = [
            .init(label: "Default", value: "default"),
            .init(label: "Low", value: "low"),
            .init(label: "Medium", value: "medium"),
            .init(label: "High", value: "high"),
            .init(label: "Extra High", value: "xhigh"),
        ]
        if engine == "claude" {
            opts.append(.init(label: "Max", value: "max"))
        }
        return opts
    }

    static func label(for value: String, engine: String) -> String {
        options(for: engine).first { $0.value == value }?.label ?? value
    }
}

func engineIcon(_ engine: String?) -> String {
    let e = engine ?? ""
    if e.contains("harness") { return "terminal" }
    switch e {
    case "codex": return "chevron.left.forwardslash.chevron.right"
    case "gemini": return "diamond"
    default: return "sparkles"
    }
}

/// Human engine name for a thread — provider beats engine (Harness Code
/// threads ride the codex wire protocol but are their own engine).
func engineName(_ t: ThreadSummary) -> String {
    let p = t.provider.isEmpty ? t.engine : t.provider
    if p.contains("harness") { return "Harness Code" }
    switch p {
    case "codex": return "Codex"
    case "claude": return "Claude Code"
    case "gemini": return "Gemini"
    default: return p.isEmpty ? t.engine : p
    }
}
