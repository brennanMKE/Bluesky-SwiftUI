import SwiftUI
import BlueskyAuth
import BlueskyDataStore
import BlueskyNetworking
import BlueskyKit

@main
struct Bluesky_SwiftUIApp: App {
    @State private var session: SessionManager?
    @State private var environment: BlueskyEnvironment?

    var body: some Scene {
        WindowGroup {
            Group {
                if let session, let environment {
                    RootView()
                        .environment(session)
                        .environment(environment)
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
        let prefs = UserDefaultsPreferencesStore(suiteName: "group.co.sstools.bluesky")
        let cache = (try? SwiftDataCacheStore(appGroupIdentifier: "group.co.sstools.bluesky"))
            ?? (try! SwiftDataCacheStore.inMemory())
        let env = BlueskyEnvironment(
            session: sm,
            accounts: accounts,
            preferences: prefs,
            network: network,
            cache: cache
        )
        await sm.restoreLastSession()
        session = sm
        environment = env
    }
}
