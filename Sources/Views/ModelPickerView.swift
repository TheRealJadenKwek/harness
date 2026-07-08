import SwiftUI

struct ModelPickerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @Binding var selected: String
    @State private var query = ""

    private var filtered: [ORModel] {
        let base = query.isEmpty ? store.models
            : store.models.filter { $0.id.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        return base.sorted {
            let fa = store.favorites.contains($0.id), fb = store.favorites.contains($1.id)
            return fa == fb ? $0.id < $1.id : fa
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty && !store.models.contains(where: { $0.id == query }) {
                    Button { selected = query; dismiss() } label: {
                        Label("Use \"\(query)\"", systemImage: "keyboard")
                    }
                }
                ForEach(filtered) { m in
                    Button {
                        selected = m.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).foregroundStyle(.primary).lineLimit(1)
                                Text("\(m.id) · \(m.context / 1000)k ctx · $\(String(format: "%.2f", m.promptPrice * 1e6))/$\(String(format: "%.2f", m.completionPrice * 1e6)) per M")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if selected == m.id { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                            Button {
                                store.toggleFavorite(m.id)
                            } label: {
                                Image(systemName: store.favorites.contains(m.id) ? "star.fill" : "star")
                                    .foregroundStyle(store.favorites.contains(m.id) ? .orange : .secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search or type a model id")
            .navigationTitle("\(store.models.count) models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if store.models.isEmpty { await store.loadModels() } }
        }
    }
}
