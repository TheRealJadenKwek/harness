import SwiftUI

/// One field for choosing a model: shows the current selection, taps into a searchable
/// list of every model the provider offers (fetched live — e.g. all of OpenRouter), and
/// lets you type ANY model id even if it isn't in the list. Replaces the old
/// Picker + "Custom model…" pair.
struct ModelField: View {
    @EnvironmentObject var app: AppState
    let providerId: String
    let defaultLabel: String        // e.g. "Default (z-ai/glm-4.6)"
    @Binding var model: String      // "" = provider default

    var body: some View {
        NavigationLink {
            ModelSearchView(providerId: providerId, defaultLabel: defaultLabel, model: $model)
                .environmentObject(app)
        } label: {
            HStack {
                Text("Model")
                Spacer()
                Text(model.isEmpty ? defaultLabel : model)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

struct ModelSearchView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let providerId: String
    let defaultLabel: String
    @Binding var model: String

    @State private var all: [ModelOption] = []
    @State private var query = ""
    @State private var loading = true

    private var filtered: [ModelOption] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.value.lowercased().contains(q) || $0.label.lowercased().contains(q) }
    }

    private var typed: String { query.trimmingCharacters(in: .whitespaces) }
    private var exactMatch: Bool { all.contains { $0.value == typed } }

    var body: some View {
        List {
            Section {
                Button {
                    model = ""; dismiss()
                } label: {
                    HStack {
                        Text(defaultLabel)
                        Spacer()
                        if model.isEmpty { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                // Use exactly what was typed, even if it's not in the catalog.
                if !typed.isEmpty && !exactMatch {
                    Button {
                        model = typed; dismiss()
                    } label: {
                        Label("Use \u{201C}\(typed)\u{201D}", systemImage: "keyboard")
                    }
                }
            }
            Section {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("Loading models…").foregroundStyle(.secondary) }
                }
                ForEach(filtered, id: \.value) { m in
                    Button {
                        model = m.value; dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.label).foregroundStyle(.primary)
                                if m.label != m.value {
                                    Text(m.value).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model == m.value { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            } header: {
                if !all.isEmpty { Text("\(filtered.count) of \(all.count) models") }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search or type a model id")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        all = (try? await app.api.providerModels(providerId)) ?? []
        loading = false
    }
}
