import SwiftUI

struct SettingsView: View {
    @AppStorage("imageModel") private var imageModel = "google/gemini-3.1-flash-image"
    @AppStorage("videoModel") private var videoModel = ""
    @State private var imageModels: [Backend.MediaModel] = []
    @State private var videoModels: [Backend.MediaModel] = []
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var key = ""
    @State private var keyError: String?
    @State private var saving = false
    @State private var memories: [MemoryFact] = []
    @State private var loadedMem = false

    var body: some View {
        NavigationStack {
            Form {
                if store.guest && !store.authed {
                    Section("Account") {
                        Text("Using without an account — chats stay on this phone.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Sign in with Apple") {
                            AppleSignIn.shared.start { ok in if ok { store.signedIn(); dismiss() } }
                        }
                        Button("Sign in with Google") {
                            GoogleSignIn.shared.start { ok in Task { @MainActor in if ok { store.signedIn(); dismiss() } } }
                        }
                    }
                    Section("OpenRouter key (stored on this phone)") {
                        SecureField(store.localKey.isEmpty ? "sk-or-…" : "Replace key (…\(String(store.localKey.suffix(4))))", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Save") {
                            store.localKey = key.trimmingCharacters(in: .whitespaces)
                            key = ""
                        }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        Link("Get a key at openrouter.ai/settings/keys", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                            .font(.caption)
                        Text("On-device models are free and need no key.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                Section("Account") {
                    LabeledContent("Signed in as", value: store.profile?.email ?? "…")
                    if let s = store.profile?.spend, let u = s.usage {
                        LabeledContent("Total API spend",
                                       value: String(format: "$%.2f", u) + (s.limit.map { String(format: " of $%.0f", $0) } ?? ""))
                    }
                    Button("Sign out", role: .destructive) { store.signOut(); dismiss() }
                }
                Section("OpenRouter key") {
                    if store.profile?.hasKey == true {
                        LabeledContent("Saved key", value: store.profile?.keyTail ?? "•••")
                    } else {
                        Text("One-time setup — takes two minutes:").font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Sign in at openrouter.ai (Google works)")
                            Text("2. Keys → Create Key → copy it (sk-or-…)")
                            Text("3. Credits → add $5 — months of chatting")
                            Text("4. Paste it below")
                        }.font(.caption).foregroundStyle(.secondary)
                        Link("Open openrouter.ai/settings/keys", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                            .font(.caption)
                    }
                    SecureField(store.profile?.hasKey == true ? "Replace key (sk-or-…)" : "sk-or-…", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(saving ? "Checking…" : "Save") {
                        saving = true; keyError = nil
                        Task {
                            keyError = await store.saveKey(key.trimmingCharacters(in: .whitespaces))
                            saving = false
                            if keyError == nil { key = "" }
                        }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    if let e = keyError { Text(e).font(.caption).foregroundStyle(.red) }
                }
                Section("Media generation") {
                    Picker("Image model", selection: $imageModel) {
                        if !imageModels.isEmpty && !imageModels.contains(where: { $0.id == imageModel }) {
                            Text(imageModel).tag(imageModel)
                        }
                        ForEach(imageModels) { m in Text(m.name).tag(m.id) }
                    }
                    Picker("Video model", selection: $videoModel) {
                        Text("Off — never generate video").tag("")
                        ForEach(videoModels) { m in Text(m.name).tag(m.id) }
                    }
                    Text("Used when you ask the chat for an image or a video. Billed to your OpenRouter key; video runs $0.20–$1 per clip.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .task {
                    if imageModels.isEmpty {
                        imageModels = await Backend.mediaModels(kind: "image")
                        videoModels = await Backend.mediaModels(kind: "video")
                    }
                }
                Section("✨ Memory") {
                    if !loadedMem {
                        Button("Show what it remembers") {
                            Task { memories = await store.memories(); loadedMem = true }
                        }
                    } else if memories.isEmpty {
                        Text("Nothing yet — memories appear as you chat.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(memories) { m in
                            Text(m.fact).font(.callout)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        Task { await store.deleteMemory(m.id); memories.removeAll { $0.id == m.id } }
                                    } label: { Label("Forget", systemImage: "trash") }
                                }
                        }
                    }
                }
                Section {
                    Text("Chats, memory, and your key are shared with the web app — sign in with the same Google account anywhere.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await store.loadProfile() }
        }
    }
}
