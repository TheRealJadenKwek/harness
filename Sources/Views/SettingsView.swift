import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenRouter API key") {
                    SecureField("sk-or-…", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save") {
                        store.saveKey(key)
                        dismiss()
                    }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !store.apiKey.isEmpty {
                        Label("Key saved in Keychain", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                        .font(.caption)
                }
                Section {
                    Text("Chats stay on this phone. Messages go directly to OpenRouter — no server in between.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
