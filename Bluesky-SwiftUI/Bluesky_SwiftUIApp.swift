import SwiftUI
import BlueskyAuth
import BlueskyDataStore
import BlueskyNetworking

@main
struct Bluesky_SwiftUIApp: App {
    @State private var session: SessionManager?

    var body: some Scene {
        WindowGroup {
            Group {
                if let session {
                    RootView()
                        .environment(session)
                } else {
                    ProgressView("Starting…")
                        .task { await boot() }
                }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private func boot() async {
        let accounts = KeychainAccountStore()
        let network = ATProtoClient(accountStore: accounts)
        let sm = SessionManager(accountStore: accounts, network: network)
        await sm.restoreLastSession()
        session = sm
    }
}
