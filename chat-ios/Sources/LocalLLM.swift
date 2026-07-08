import Foundation
import MLXLMCommon
import MLXLLM

/// On-device models (Apple MLX). Weights download once from Hugging Face into
/// Documents/huggingface and run fully offline after that.
struct LocalModelSpec: Identifiable {
    let id: String          // model id used in Chat.model, "ondevice/…"
    let name: String
    let repo: String        // HF repo with MLX weights
    let size: String
}

enum LocalModels {
    static let specs: [LocalModelSpec] = [
        LocalModelSpec(id: "ondevice/minicpm5-1b", name: "MiniCPM5 1B", repo: "openbmb/MiniCPM5-1B-MLX", size: "~0.7 GB"),
        // Qwen3.5's hybrid linear-attention arch isn't in MLX Swift yet; Qwen3 is
        // the newest Qwen the runtime supports (same Think/No-think toggle).
        LocalModelSpec(id: "ondevice/qwen3-0.6b", name: "Qwen3 0.6B", repo: "mlx-community/Qwen3-0.6B-4bit", size: "~0.4 GB"),
        LocalModelSpec(id: "ondevice/qwen3-1.7b", name: "Qwen3 1.7B", repo: "mlx-community/Qwen3-1.7B-4bit", size: "~1.0 GB"),
    ]
    static func spec(for modelId: String) -> LocalModelSpec? { specs.first { $0.id == modelId } }
    static func isLocal(_ modelId: String) -> Bool { modelId.hasPrefix("ondevice/") }
}

@MainActor
final class LocalLLM: ObservableObject {
    static let shared = LocalLLM()
    @Published var progress: [String: Double] = [:]      // repo → 0…1 while downloading
    @Published var loading: Set<String> = []
    @Published var ready: Set<String> = []               // repos with weights on disk
    private var containers: [String: ModelContainer] = [:]

    init() { refresh() }

    func refresh() {
        for s in LocalModels.specs where LocalLLM.onDisk(s.repo) { ready.insert(s.repo) }
    }

    static func weightsDir(_ repo: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/" + repo)
    }
    static func onDisk(_ repo: String) -> Bool {
        FileManager.default.fileExists(atPath: weightsDir(repo).appendingPathComponent("config.json").path)
    }

    func remove(_ repo: String) {
        containers[repo] = nil
        ready.remove(repo)
        try? FileManager.default.removeItem(at: LocalLLM.weightsDir(repo))
    }

    func container(for repo: String) async throws -> ModelContainer {
        if let c = containers[repo] { return c }
        // HF transformers-v5 class name; map it to the generic fast tokenizer
        replacementTokenizers["TokenizersBackend"] = "PreTrainedTokenizer"
        loading.insert(repo)
        defer { loading.remove(repo); progress[repo] = nil }
        let c = try await LLMModelFactory.shared.loadContainer(
            // the repo's tokenizer_config only declares </s>, but the model's real
            // stop set (generation_config eos_token_id) also includes <|im_end|>
            configuration: ModelConfiguration(id: repo, extraEOSTokens: ["<|im_end|>"])
        ) { [weak self] p in
            Task { @MainActor in self?.progress[repo] = p.fractionCompleted }
        }
        containers[repo] = c
        ready.insert(repo)
        return c
    }

    /// Stream a reply for the chat history. `think` flips MiniCPM5's hybrid
    /// reasoning template (enable_thinking); reasoning arrives inline as a
    /// <think>…</think> block, which the UI renders separately.
    func stream(modelId: String, messages: [Msg], think: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let spec = LocalModels.spec(for: modelId) else {
                        throw NSError(domain: "local", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown on-device model"])
                    }
                    let container = try await self.container(for: spec.repo)
                    var chat: [MLXLMCommon.Chat.Message] = []
                    for m in messages where !m.content.isEmpty {
                        chat.append(m.role == "user" ? .user(m.content) : .assistant(stripThink(m.content)))
                    }
                    let input = UserInput(chat: chat, additionalContext: ["enable_thinking": think])
                    // model-card sampling: think 0.9/0.95, no-think 0.7/0.95
                    var params = GenerateParameters(temperature: think ? 0.9 : 0.7, topP: 0.95)
                    params.maxTokens = 4096
                    try await container.perform { context in
                        let prepared = try await context.processor.prepare(input: input)
                        let cache = context.model.newCache(parameters: params)
                        for await item in try MLXLMCommon.generate(
                            input: prepared, cache: cache, parameters: params, context: context)
                        {
                            if Task.isCancelled { break }
                            if let chunk = item.chunk { continuation.yield(chunk) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// "<think>…</think>Answer" → (reasoning, answer). Handles a still-open block mid-stream.
func splitThink(_ text: String) -> (think: String?, answer: String) {
    guard let open = text.range(of: "<think>") else { return (nil, text) }
    let rest = text[open.upperBound...]
    if let close = rest.range(of: "</think>") {
        let t = String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let a = String(rest[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.isEmpty ? nil : t, a)
    }
    return (String(rest).trimmingCharacters(in: .whitespacesAndNewlines), "")
}
func stripThink(_ text: String) -> String {
    let (_, a) = splitThink(text)
    return a.isEmpty ? text : a
}
