import SwiftUI
import UserNotifications
import BlueskyAuth
import BlueskyDataStore
import BlueskyNetworking
import BlueskyKit

@main
struct Bluesky_SwiftUIApp: App {
    /// Stored as a property so ARC keeps it alive for the lifetime of the app.
    private let pushDelegate = PushNotificationDelegate()

    @State private var session: SessionManager?
    @State private var environment: BlueskyEnvironment?

    init() {
        UNUserNotificationCenter.current().delegate = pushDelegate
    }

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
            // Route deep links to the existing window on macOS rather than spawning a new one.
            .handlesExternalEvents(preferring: Set(arrayLiteral: "*"), allowing: Set(arrayLiteral: "*"))
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
        let bookmarkStore = (try? BookmarkStore())
            ?? (try! BookmarkStore.inMemory())
        let env = BlueskyEnvironment(
            session: sm,
            accounts: accounts,
            preferences: prefs,
            network: network,
            cache: cache,
            bookmarks: bookmarkStore
        )
        await sm.restoreLastSession()
        session = sm
        environment = env
    }
}
