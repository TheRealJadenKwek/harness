import SwiftUI

struct AutomationsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.automations) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle().fill(statusColor(a.status)).frame(width: 8, height: 8)
                            Text(a.name).font(.body).lineLimit(1).foregroundStyle(Color.appText)
                            Spacer(minLength: 6)
                            Text(a.schedule).font(.caption2).foregroundStyle(Color.appSecondary)
                        }
                        HStack(spacing: 6) {
                            Image(systemName: a.kind == "cron" ? "clock" : "bolt")
                                .font(.system(size: 9)).foregroundStyle(Color.appSecondary)
                            Text(a.detail)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.appSecondary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(Color.appBG)
                    .listRowSeparatorTint(Color.appBorder)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBG)
            .navigationTitle("Automations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBG, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay {
                if app.automations.isEmpty {
                    ContentUnavailableView(loading ? "Loading…" : "No automations",
                                           systemImage: "bolt.slash",
                                           description: Text("launchd agents and cron jobs on your Mac."))
                }
            }
            .task { loading = true; await app.loadAutomations(); loading = false }
            .refreshable { await app.loadAutomations() }
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "running", "active": return .green
        case "loaded": return Color.appSecondary
        default: return Color.appSecondary.opacity(0.35)
        }
    }
}
