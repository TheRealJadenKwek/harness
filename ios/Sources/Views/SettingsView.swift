import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac harness") {
                    TextField("http://100.x.x.x:8787", text: $url)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Bearer token", text: $token)
                }
                Section {
                    Button {
                        save()
                    } label: {
                        Text(testing ? "Testing…" : "Save & Test connection")
                    }
                    .disabled(testing)
                    if let result {
                        Text(result).font(.callout)
                    }
                } footer: {
                    Text("The harness runs on your Mac and is reachable over Tailscale. Find the token in ~/.claude-harness/config.env.")
                }
                Section {
                    Toggle("Push notifications", isOn: Binding(
                        get: { app.pushEnabled },
                        set: { app.setPushEnabled($0) }
                    ))
                    Button("Open iOS notification settings") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    .font(.callout)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Get pinged when a task finishes, even with the app closed. Turning this on shows the iOS permission prompt the first time — if you tapped \u{201C}Don\u{2019}t Allow\u{201D} before, enable it from iOS notification settings.")
                }
                if app.providers.contains(where: { $0.requires_key == true }) {
                    Section {
                        ForEach(app.providers.filter { $0.requires_key == true }) { p in
                            ProviderKeyRow(provider: p)
                        }
                    } header: {
                        Text("Model providers (bring your own key)")
                    } footer: {
                        Text("Paste a key and Save to enable. GLM uses your Z.ai coding plan; OpenRouter unlocks many models with one key.")
                    }
                }
                Section {
                    Label {
                        Text("The ~$ amounts are just estimates of what each request *would* cost on the pay-per-use API. You run Claude & Codex on your subscriptions — nothing is charged per token. (Codex figures are estimated from token counts.)")
                            .font(.footnote).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About costs")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { url = app.baseURL; token = app.token }
        }
    }

    func save() {
        app.baseURL = url.trimmingCharacters(in: .whitespaces)
        app.token = token.trimmingCharacters(in: .whitespaces)
        testing = true
        result = nil
        Task {
            let ok = await app.testConnection()
            result = ok ? "✅ Connected" : "❌ Could not reach the harness"
            testing = false
            if ok { await app.refresh() }
        }
    }
}

struct ProviderKeyRow: View {
    @EnvironmentObject var app: AppState
    let provider: Provider
    @State private var key = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.label).fontWeight(.medium)
                if provider.has_key == true {
                    Label("key set", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { provider.enabled },
                    set: { v in Task { busy = true; await app.setProvider(provider.id, apiKey: nil, enabled: v); busy = false } }
                ))
                .labelsHidden()
                .disabled(busy)
            }
            HStack {
                SecureField(provider.has_key == true ? "Replace API key…" : "Paste API key", text: $key)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save") {
                    Task { busy = true; await app.setProvider(provider.id, apiKey: key, enabled: true); key = ""; busy = false }
                }
                .disabled(key.isEmpty || busy)
            }
        }
        .padding(.vertical, 4)
    }
}
