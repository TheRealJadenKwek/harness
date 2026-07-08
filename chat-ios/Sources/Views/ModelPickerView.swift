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

    @StateObject private var local = LocalLLM.shared

    private static let curated: [(id: String, desc: String)] = [
        ("minimax/minimax-m3", "default 🖼"),
        ("x-ai/grok-4.5", "new + sharp 🖼"),
        ("deepseek/deepseek-v4-pro", "smart"),
        ("deepseek/deepseek-v4-flash", "cheapest + fastest"),
        ("nvidia/nemotron-3-ultra-550b-a55b:free", "free!"),
    ]

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section("Defaults") {
                        ForEach(Self.curated, id: \.id) { c in
                            if let m = store.models.first(where: { $0.id == c.id }) ?? fallback(c.id) {
                                Button { selected = m.id; dismiss() } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 4) {
                                                Text(m.name).foregroundStyle(.primary).lineLimit(1)
                                                if m.vision { Text("🖼").font(.caption2) }
                                            }
                                            Text(c.desc + " · " + priceLabel(m))
                                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if selected == m.id { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                    }
                    Section("On-device (free, offline)") {
                        ForEach(LocalModels.specs) { spec in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(spec.name).foregroundStyle(.primary)
                                        Text("📱").font(.caption2)
                                    }
                                    Text(local.ready.contains(spec.repo)
                                         ? "downloaded · hybrid reasoning · $0"
                                         : spec.size + " download · runs on this iPhone")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let p = local.progress[spec.repo], p < 1 {
                                    ProgressView(value: p).frame(width: 70)
                                } else if local.ready.contains(spec.repo) {
                                    if selected == spec.id { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                                    Button(role: .destructive) { local.remove(spec.repo) } label: {
                                        Image(systemName: "trash").font(.caption)
                                    }.buttonStyle(.borderless).foregroundStyle(.secondary)
                                } else if local.loading.contains(spec.repo) {
                                    ProgressView()
                                } else {
                                    Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if local.ready.contains(spec.repo) { selected = spec.id; dismiss() }
                                else { Task { _ = try? await local.container(for: spec.repo); selected = spec.id } }
                            }
                        }
                    }
                }
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
                                HStack(spacing: 4) {
                                    Text(m.name).foregroundStyle(.primary).lineLimit(1)
                                    if m.vision { Text("🖼").font(.caption2) }
                                }
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
            .task { local.refresh(); if store.models.isEmpty { await store.loadModels() } }
        }
    }

    private func fallback(_ id: String) -> ORModel? {
        ORModel(id: id, name: shortModel(id), context: 0, promptPrice: 0, completionPrice: 0, vision: false, reasoning: true)
    }
    private func priceLabel(_ m: ORModel) -> String {
        if m.promptPrice == 0 && m.completionPrice == 0 { return "free" }
        return String(format: "$%.2f/$%.2f per M", m.promptPrice * 1e6, m.completionPrice * 1e6)
    }
}
