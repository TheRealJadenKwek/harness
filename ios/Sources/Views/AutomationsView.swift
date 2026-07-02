import SwiftUI

/// Scheduled agent jobs. "Agent automations" are phone-managed — created, edited,
/// toggled, and run from here; the harness daemon is the scheduler and each job's
/// results land in its own ⚡ thread (with the usual completion push). The System
/// section is the read-only view of LLM-touching launchd/cron jobs on the Mac.
struct AutomationsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var loading = false
    @State private var editing: ManagedAutomation?
    @State private var showNew = false
    @State private var runError: String?

    var body: some View {
        NavigationStack {
            List {
                managedSection
                if !app.automations.isEmpty {
                    systemSection
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
                ToolbarItem(placement: .primaryAction) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay {
                if app.managedAutomations.isEmpty && app.automations.isEmpty {
                    ContentUnavailableView(loading ? "Loading…" : "No automations",
                                           systemImage: "bolt.slash",
                                           description: Text("Tap + to schedule an agent job — it runs on your Mac and pings you when done."))
                }
            }
            .task { loading = true; await app.loadAutomations(); loading = false }
            .refreshable { await app.loadAutomations() }
            .sheet(isPresented: $showNew) {
                AutomationEditor(existing: nil).environmentObject(app)
            }
            .sheet(item: $editing) { a in
                AutomationEditor(existing: a).environmentObject(app)
            }
            .alert("Couldn't run", isPresented: .init(get: { runError != nil },
                                                      set: { if !$0 { runError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(runError ?? "") }
        }
    }

    private var managedSection: some View {
        Section {
            ForEach(app.managedAutomations) { a in
                HStack(spacing: 10) {
                    Button { editing = a } label: {
                        ManagedAutomationRow(a: a)
                    }
                    .buttonStyle(.plain)
                    Toggle("", isOn: .init(get: { a.enabled }, set: { setEnabled(a, $0) }))
                        .labelsHidden().controlSize(.mini)
                }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(a) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { run(a) } label: {
                            Label("Run now", systemImage: "play.fill")
                        }.tint(.green)
                    }
                    .listRowBackground(Color.appBG)
                    .listRowSeparatorTint(Color.appBorder)
            }
        } header: {
            Text("Agent automations").font(.caption).foregroundStyle(Color.appSecondary)
        } footer: {
            if app.managedAutomations.isEmpty {
                Text("None yet — tap + to schedule a recurring agent job.")
                    .font(.caption2).foregroundStyle(Color.appSecondary)
            }
        }
    }

    private var systemSection: some View {
        Section {
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
        } header: {
            Text("System (read-only)").font(.caption).foregroundStyle(Color.appSecondary)
        }
    }

    private func run(_ a: ManagedAutomation) {
        Task {
            do {
                let tid = try await app.api.runAutomation(a.id)
                app.pendingOpenThread = tid          // jump straight into the run
                dismiss()
            } catch {
                runError = error.localizedDescription
            }
        }
    }

    private func setEnabled(_ a: ManagedAutomation, _ on: Bool) {
        Task {
            _ = try? await app.api.updateAutomation(a.id, ["enabled": on])
            await app.loadAutomations()
        }
    }

    private func delete(_ a: ManagedAutomation) {
        Task {
            try? await app.api.deleteAutomation(a.id)
            await app.loadAutomations()
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

private struct ManagedAutomationRow: View {
    let a: ManagedAutomation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(a.enabled ? .orange : Color.appSecondary.opacity(0.4))
                Text(a.name).font(.body).lineLimit(1).foregroundStyle(Color.appText)
                Spacer(minLength: 6)
                Text(a.schedule_text ?? "").font(.caption2).foregroundStyle(Color.appSecondary)
            }
            Text(a.prompt)
                .font(.caption).foregroundStyle(Color.appSecondary).lineLimit(2)
            HStack(spacing: 6) {
                Image(systemName: engineIcon(a.provider))
                    .font(.system(size: 9)).foregroundStyle(Color.appSecondary)
                if let m = a.model, !m.isEmpty {
                    Text(m).font(.caption2).foregroundStyle(Color.appSecondary)
                }
                if let lr = a.last_run, lr > 0 {
                    Text("last run \(relativeTime(lr))")
                        .font(.caption2).foregroundStyle(Color.appSecondary)
                }
                if let st = a.last_status, st.hasPrefix("skipped") {
                    Text(st).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Create/edit sheet for a managed automation.
struct AutomationEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let existing: ManagedAutomation?

    @State private var name = ""
    @State private var prompt = ""
    @State private var provider = "claude"
    @State private var effort = "default"
    @State private var cwd = ""
    @State private var scheduleType = "daily"
    @State private var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var intervalMinutes = 60
    @State private var dailyCap = 0
    @State private var saving = false
    @State private var errorText: String?

    private static let intervals: [(String, Int)] = [
        ("15 min", 15), ("30 min", 30), ("1 hour", 60), ("2 hours", 120),
        ("4 hours", 240), ("6 hours", 360), ("12 hours", 720), ("24 hours", 1440),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("What should the agent do?") {
                    TextField("Name (e.g. Morning brief)", text: $name)
                    TextEditor(text: $prompt)
                        .frame(minHeight: 110)
                        .font(.body)
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text("The prompt to run, e.g. \u{201C}Summarize overnight lines moves and flag anything unusual.\u{201D}")
                                    .foregroundStyle(Color.appSecondary.opacity(0.6))
                                    .padding(.top, 8).padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                Section {
                    Picker("Repeats", selection: $scheduleType) {
                        Text("Daily at a time").tag("daily")
                        Text("Every interval").tag("interval")
                    }
                    if scheduleType == "daily" {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    } else {
                        Picker("Every", selection: $intervalMinutes) {
                            ForEach(Self.intervals, id: \.1) { label, mins in
                                Text(label).tag(mins)
                            }
                        }
                    }
                    Picker("Daily run limit", selection: $dailyCap) {
                        Text("Unlimited").tag(0)
                        ForEach([2, 4, 8, 12, 24], id: \.self) { n in
                            Text("\(n) runs").tag(n)
                        }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("Scheduled runs also pause automatically while your Claude 5-hour usage window is maxed out. Run-now always works.")
                        .font(.caption2)
                }
                Section("Engine") {
                    Picker("Engine", selection: $provider) {
                        ForEach(app.enabledProviders) { p in
                            Text(p.label).tag(p.id)
                        }
                    }
                    Picker("Effort", selection: $effort) {
                        ForEach(EffortCatalog.options(for: provider == "codex" ? "codex" : "claude"), id: \.value) { o in
                            Text(o.label).tag(o.value)
                        }
                    }
                    TextField("Working directory (optional, e.g. ~/repo)", text: $cwd)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if let errorText {
                    Section { Text(errorText).font(.callout).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "New automation" : "Edit automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { load() }
        }
    }

    private func load() {
        guard let a = existing else { return }
        name = a.name
        prompt = a.prompt
        provider = a.provider ?? "claude"
        effort = a.effort ?? "default"
        cwd = a.cwd ?? ""
        dailyCap = a.max_runs_per_day ?? 0
        if a.schedule.type == "interval" {
            scheduleType = "interval"
            intervalMinutes = a.schedule.minutes ?? 60
        } else {
            scheduleType = "daily"
            time = Calendar.current.date(from: DateComponents(hour: a.schedule.hour ?? 9,
                                                              minute: a.schedule.minute ?? 0)) ?? time
        }
    }

    private func save() {
        saving = true
        errorText = nil
        var schedule: [String: Any] = ["type": scheduleType]
        if scheduleType == "daily" {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            schedule["hour"] = c.hour ?? 9
            schedule["minute"] = c.minute ?? 0
        } else {
            schedule["minutes"] = intervalMinutes
        }
        var body: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "prompt": prompt.trimmingCharacters(in: .whitespaces),
            "provider": provider,
            "effort": effort,
            "schedule": schedule,
            "max_runs_per_day": dailyCap,
        ]
        if !cwd.trimmingCharacters(in: .whitespaces).isEmpty {
            body["cwd"] = cwd.trimmingCharacters(in: .whitespaces)
        }
        Task {
            do {
                if let a = existing {
                    _ = try await app.api.updateAutomation(a.id, body)
                } else {
                    _ = try await app.api.createAutomation(body)
                }
                await app.loadAutomations()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}
