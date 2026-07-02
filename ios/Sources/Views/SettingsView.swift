import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var testing = false
    @State private var result: String?
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            Form {
                if app.servers.count > 1 {
                    Section("Servers") {
                        ForEach(app.servers) { s in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).fontWeight(.medium)
                                    Text(s.url).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if s.id == app.activeServerID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                app.switchTo(s.id)
                                url = s.url; token = s.token; result = nil
                            }
                        }
                        .onDelete { idx in
                            for i in idx { app.removeServer(app.servers[i].id) }
                            url = app.baseURL; token = app.token
                        }
                    }
                }
                Section(app.servers.count > 1 ? "Active server" : "Harness server") {
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
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add another server", systemImage: "plus.circle")
                    }
                    if let result {
                        Text(result).font(.callout)
                    }
                } footer: {
                    Text("The harness runs on your Mac or Windows PC, reachable over Tailscale. Open http://127.0.0.1:8787/pair on that computer for a scannable QR, or find the token in its config.env.")
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
            .sheet(isPresented: $showAdd) {
                AddServerSheet().environmentObject(app)
                    .onDisappear { url = app.baseURL; token = app.token }
            }
        }
    }

    func save() {
        app.updateActiveServer(url: url.trimmingCharacters(in: .whitespaces),
                               token: token.trimmingCharacters(in: .whitespaces))
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

struct AddServerSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var showScanner = false
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                if PairScannerView.isSupported {
                    Section {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
                        }
                    } footer: {
                        Text("On the computer running the harness, open http://127.0.0.1:8787/pair and scan the code.")
                    }
                }
                Section("Or enter manually") {
                    TextField("Name (e.g. Gaming PC)", text: $name)
                    TextField("http://100.x.x.x:8787", text: $url)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Bearer token", text: $token)
                }
                Section {
                    Button(testing ? "Testing…" : "Add & Connect") { add() }
                        .disabled(testing || url.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let result { Text(result).font(.callout) }
                }
            }
            .navigationTitle("Add server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showScanner) {
                PairScannerView { payload in
                    showScanner = false
                    if let u = URL(string: payload), u.scheme == "harness" {
                        app.handlePair(u)
                        dismiss()
                    } else {
                        result = "❌ Not a Harness pairing code"
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    func add() {
        let id = app.addServer(name: name.trimmingCharacters(in: .whitespaces),
                               url: url.trimmingCharacters(in: .whitespaces),
                               token: token.trimmingCharacters(in: .whitespaces))
        app.switchTo(id)
        testing = true
        result = nil
        Task {
            let ok = await app.testConnection()
            testing = false
            result = ok ? "✅ Connected" : "❌ Could not reach it — saved anyway"
            if ok {
                await app.refresh()
                dismiss()
            }
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
