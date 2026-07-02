import SwiftUI

struct NewThreadSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var provider = "claude"
    @State private var title = ""
    @State private var cwd = ""
    @State private var permissionMode = "bypass"
    @State private var effort = "default"
    @State private var model = ""
    @State private var showModelCustom = false
    @State private var modelCustomText = ""
    @State private var creating = false
    @State private var error: String?

    private var engine: String {
        app.providers.first { $0.id == provider }?.engine ?? "claude"
    }
    private func providerModels() -> [ModelOption] {
        if let p = app.providers.first(where: { $0.id == provider }) {
            if let m = p.models, !m.isEmpty { return m }
            return ModelCatalog.options(for: p.engine)
        }
        return ModelCatalog.options(for: engine)
    }
    private var defaultModelText: String {
        if let dm = app.providers.first(where: { $0.id == provider })?.default_model, !dm.isEmpty { return "Default (\(dm))" }
        return "Default"
    }
    private var defaultEffortText: String {
        if let de = app.providers.first(where: { $0.id == provider })?.default_effort, !de.isEmpty { return "Default (\(de))" }
        return "Default"
    }
    private var providerDefaultEffort: String? {
        app.providers.first { $0.id == provider }?.default_effort
    }
    private func coerceEffort() {
        if providerDefaultEffort == nil && effort == "default" { effort = "high" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Engine") {
                    Picker("Engine", selection: $provider) {
                        ForEach(app.enabledProviders) { p in
                            Text(p.label).tag(p.id)
                        }
                    }
                }
                Section("Model") {
                    Picker("Model", selection: $model) {
                        Text(defaultModelText).tag("")
                        ForEach(providerModels(), id: \.value) { o in
                            Text(o.label).tag(o.value)
                        }
                        if !model.isEmpty && !providerModels().contains(where: { $0.value == model }) {
                            Text(model).tag(model)
                        }
                    }
                    Button("Custom model…") {
                        modelCustomText = model
                        showModelCustom = true
                    }
                }
                Section("Permissions") {
                    Picker("Mode", selection: $permissionMode) {
                        Text("Full access").tag("bypass")
                        Text("Plan only").tag("plan")
                        Text("Accept edits").tag("acceptEdits")
                        Text("Ask (read-only)").tag("default")
                    }
                }
                Section("Reasoning effort") {
                    Picker("Effort", selection: $effort) {
                        if providerDefaultEffort != nil {
                            Text(defaultEffortText).tag("default")
                        }
                        ForEach(EffortCatalog.options(for: engine).filter { $0.value != "default" }, id: \.value) { o in
                            Text(o.label).tag(o.value)
                        }
                    }
                }
                Section("Optional") {
                    TextField("Title", text: $title)
                    TextField("Working dir (e.g. ~/myrepo)", text: $cwd)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(creating)
                }
            }
            .onAppear {
                let ids = app.enabledProviders.map { $0.id }
                provider = ids.contains(app.defaultProvider) ? app.defaultProvider : (ids.first ?? "claude")
                permissionMode = app.defaultPermission
                effort = app.defaultEffort
                coerceEffort()
            }
            .onChange(of: provider) { _, _ in coerceEffort() }
            .alert("Custom model", isPresented: $showModelCustom) {
                TextField("model id", text: $modelCustomText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Set") { model = modelCustomText.trimmingCharacters(in: .whitespaces) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Type any model id the CLI supports — including new releases.")
            }
        }
    }

    func create() {
        creating = true
        error = nil
        app.defaultProvider = provider
        app.defaultPermission = permissionMode
        app.defaultEffort = effort
        Task { @MainActor in
            do {
                let t = try await app.createThread(provider: provider, cwd: cwd, title: title, permissionMode: permissionMode, effort: effort, model: model)
                app.pendingOpenThread = t.id     // jump straight into the new thread
                dismiss()
            } catch {
                self.error = error.localizedDescription
                creating = false
            }
        }
    }
}
