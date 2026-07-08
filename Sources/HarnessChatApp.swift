import SwiftUI

@main
struct HarnessChatApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup {
            ChatListView().environmentObject(store)
        }
    }
}
