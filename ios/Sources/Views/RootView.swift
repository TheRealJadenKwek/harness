import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
    @State private var showSettings = false
    @State private var showAutomations = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if app.isConfigured || app.demoMode {
                    ThreadListView()
                } else {
                    ContentUnavailableView {
                        Label("Not connected", systemImage: "antenna.radiowaves.left.and.right.slash")
                    } description: {
                        Text("Connect to your Mac's harness to use Claude & Codex — or take a look around in demo mode first.")
                    } actions: {
                        Button("Open Settings") { showSettings = true }
                            .buttonStyle(.borderedProminent)
                        Button("Explore the demo") { app.enterDemo() }
                    }
                }
            }
            .background(Color.appBG)
            .navigationTitle("Threads")
            .toolbarBackground(Color.appBG, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        if app.demoMode {
                            Button { app.exitDemo() } label: {
                                Text("DEMO · Exit").font(.caption2).bold()
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.18)).foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                        } else {
                            Circle()
                                .fill(app.connected ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                        }
                        Button { showAutomations = true } label: { Image(systemName: "bolt") }
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(app)
            }
            .sheet(isPresented: $showAutomations) {
                AutomationsView().environmentObject(app)
            }
            .onAppear { PushManager.processAlive = true }
            .task {
                await app.refresh()
                if app.connected { app.enablePush() }       // ask + register for push once reachable
                consumePendingOpen()                         // cold-launch deep link from a tapped push
            }
            .onChange(of: app.pendingOpenThread) { _, _ in consumePendingOpen() }
        }
    }

    /// Navigate straight to a thread requested by a push tap (or a fresh thread create),
    /// resetting the stack so we land directly on it regardless of current nav state.
    private func openThread(_ id: String) {
        var p = NavigationPath()
        p.append(id)
        path = p
    }

    private func consumePendingOpen() {
        if let id = app.pendingOpenThread {
            app.pendingOpenThread = nil
            openThread(id)
        } else if let open = UserDefaults.standard.string(forKey: "openThreadID"), !open.isEmpty {
            UserDefaults.standard.removeObject(forKey: "openThreadID")
            openThread(open)
        }
    }
}
