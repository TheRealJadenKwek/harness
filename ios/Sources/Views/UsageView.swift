import SwiftUI

struct UsageView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var usage: UsageInfo?
    @State private var loaded = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let fh = usage?.claude?.five_hour {
                        limitRow("5-hour limit", fh)
                    } else {
                        Text(loaded ? "No reading yet — send a Claude message to populate."
                                    : "Loading…")
                            .font(.caption).foregroundStyle(Color.appSecondary)
                    }
                    if let wk = usage?.claude?.seven_day {
                        limitRow("Weekly limit", wk)
                    } else if usage?.claude?.five_hour != nil {
                        Text("Your weekly limit shows here once you're near it — Claude only reports the limit that's currently binding.")
                            .font(.caption2).foregroundStyle(Color.appSecondary)
                    }
                } header: {
                    Text("Claude")
                } footer: {
                    if let u = usage?.claude?.updated {
                        Text("Updated \(relativeTime(u)) · reflects your last Claude turn")
                    }
                }
                Section("Codex") {
                    Label {
                        Text("The Codex CLI doesn't report plan limits — only per-turn tokens. Track usage from the cost estimate on each Codex message.")
                            .font(.caption).foregroundStyle(Color.appSecondary)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(Color.appSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBG)
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
        }
        .task { await load() }
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    private func limitRow(_ title: String, _ r: RateLimit) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body).foregroundStyle(Color.appText)
                if let reset = r.resetsAt {
                    Text(resetText(reset)).font(.caption).foregroundStyle(Color.appSecondary)
                }
                if r.isUsingOverage == true {
                    Text("Using overage").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            statusBadge(r.status)
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ s: String?) -> some View {
        let (label, color): (String, Color)
        switch s {
        case "allowed":                       (label, color) = ("OK", .green)
        case "warning", "approaching":        (label, color) = ("Warning", .orange)
        case "rejected", "limited", "blocked": (label, color) = ("Limited", .red)
        default:                              (label, color) = (s ?? "—", Color.appSecondary)
        }
        return Text(label).font(.caption).bold()
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(color.opacity(0.15)).foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func resetText(_ ts: Double) -> String {
        let secs = ts - now.timeIntervalSince1970
        if secs <= 0 { return "Resetting…" }
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
    }

    private func load() async {
        usage = try? await app.api.usage()
        loaded = true
    }
}
