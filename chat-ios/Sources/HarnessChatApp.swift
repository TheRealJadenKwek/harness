import SwiftUI

@main
struct HarnessChatApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup {
            Group {
                if store.authed {
                    ChatListView()
                } else {
                    SignInView()
                }
            }
            .environmentObject(store)
            .onOpenURL { url in
                if url.scheme == "harnesschat", Backend.handleCallback(url) { store.signedIn() }
            }
        }
    }
}

struct SignInView: View {
    @EnvironmentObject var store: Store
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color(red: 0.79, green: 0.39, blue: 0.26))
            Text("Harness Chat").font(.title2.bold())
            Text("Your chats, memory, and history —\nsynced with the web app.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button {
                busy = true; error = nil
                GoogleSignIn.shared.start { ok in
                    Task { @MainActor in
                        busy = false
                        if ok { store.signedIn() } else { error = "Sign-in didn't complete — try again." }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "g.circle.fill")
                    Text("Continue with Google").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40).padding(.top, 10)
            .disabled(busy)
            Button {
                busy = true; error = nil
                AppleSignIn.shared.start { ok in
                    busy = false
                    if ok { store.signedIn() } else { error = "Apple sign-in didn't complete — try again." }
                }
            } label: {
                HStack {
                    Image(systemName: "apple.logo")
                    Text("Continue with Apple").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            .disabled(busy)
            if busy { ProgressView() }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
            Spacer(); Spacer()
        }
    }
}
