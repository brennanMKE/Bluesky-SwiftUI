import SwiftUI
import UserNotifications
import BlueskyAuth
import BlueskyDataStore
import BlueskyFeed
import BlueskyNetworking
import BlueskyKit
import BlueskyUI

@main
struct Bluesky_SwiftUIApp: App {
    /// Stored as a property so ARC keeps it alive for the lifetime of the app.
    private let pushDelegate = PushNotificationDelegate()

    @State private var session: SessionManager?
    @State private var environment: BlueskyEnvironment?
    /// Timeline feed store created in boot() and pre-loading before views appear.
    @State private var timelineFeedStore: FeedStore?

    init() {
        UNUserNotificationCenter.current().delegate = pushDelegate
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let session, let environment, let feedStore = timelineFeedStore {
                    RootView()
                        .environment(session)
                        .environment(environment)
                        .environment(feedStore)
                        .adaptiveBlueskyTheme()
                } else {
                    ProgressView("Starting…")
                        .task { await boot() }
                }
            }
            // The View-level modifier marks the existing window instance as the
            // preferred handler for incoming URLs/activities so macOS routes them
            // here instead of creating a new window.
            .handlesExternalEvents(preferring: Set(arrayLiteral: "*"), allowing: Set(arrayLiteral: "*"))
        }
        // The Scene-level modifier declares which external events this WindowGroup
        // accepts. Without it, macOS treats every incoming URL as needing a fresh
        // window because no existing scene has claimed the URL pattern. Both
        // modifiers are required: Scene-level chooses the WindowGroup, View-level
        // picks the existing window inside it.
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private func boot() async {
        let accounts = KeychainAccountStore()
        let network = ATProtoClient(accountStore: accounts)
        let sm = SessionManager(accountStore: accounts, network: network)
        let prefs = UserDefaultsPreferencesStore(suiteName: "group.co.sstools.bluesky")
        // Use App Group store when available (shared with extensions), otherwise fall
        // back to the app-local persistent store. Never use in-memory — if we cannot
        // write to disk the problem must be diagnosed and fixed, not silently hidden.
        let cache: any CacheStore
        do {
            if let appGroupCache = try? SwiftDataCacheStore(appGroupIdentifier: "group.co.sstools.bluesky") {
                print("[Boot] cache: App Group store")
                cache = appGroupCache
            } else {
                print("[Boot] cache: local persistent store")
                cache = try SwiftDataCacheStore()
            }
        } catch {
            // Persistent store failed to initialise — this is a real error.
            // Crash in debug builds so the problem is immediately visible.
            fatalError("Failed to create persistent cache store: \(error)")
        }
        let bookmarkStore: BookmarkStore
        do {
            bookmarkStore = try BookmarkStore()
        } catch {
            fatalError("Failed to create persistent bookmark store: \(error)")
        }
        let env = BlueskyEnvironment(
            session: sm,
            accounts: accounts,
            preferences: prefs,
            network: network,
            cache: cache,
            bookmarks: bookmarkStore
        )
        await sm.restoreLastSession()

        // Create the timeline FeedStore and kick off its initial load as a plain Task —
        // not tied to any SwiftUI view lifecycle, so it cannot be cancelled by view
        // recreation. The store is @Observable so FeedView will update automatically
        // as posts arrive.
        let feedStore = FeedStore(network: network, accountStore: accounts, cache: cache)
        Task { await feedStore.loadInitial(selection: .timeline) }
        timelineFeedStore = feedStore

        session = sm
        environment = env
    }
}
