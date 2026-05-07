import SwiftUI
import OSLog
import UserNotifications
import BlueskyAuth
import BlueskyDataStore
import BlueskyFeed
import BlueskyNetworking
import BlueskyKit
import BlueskyUI

private let bootLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "co.sstools.Bluesky", category: "Boot")

@main
struct Bluesky_SwiftUIApp: App {
    /// Stored as a property so ARC keeps it alive for the lifetime of the app.
    private let pushDelegate = PushNotificationDelegate()

    @State private var session: SessionManager?
    @State private var environment: BlueskyEnvironment?
    /// Timeline feed store created in boot() and pre-loading before views appear.
    @State private var timelineFeedStore: FeedStore?
    /// Appearance preferences (color mode, dark variant, font family, font
    /// size). Created during boot() so the value is available before any view
    /// renders, and shared with the Settings screen via the SwiftUI
    /// environment so both write to the same persisted source of truth.
    @State private var appearance: AppearanceStore?

    init() {
        UNUserNotificationCenter.current().delegate = pushDelegate
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let session, let environment, let feedStore = timelineFeedStore, let appearance {
                    RootView()
                        .environment(session)
                        .environment(environment)
                        .environment(feedStore)
                        .environment(appearance)
                        .modifier(AppearanceShellModifier(appearance: appearance))
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
        let pathMonitor = NWPathMonitorAdapter()
        pathMonitor.start()
        let network = ATProtoClient(accountStore: accounts, pathMonitor: pathMonitor)
        let sm = SessionManager(accountStore: accounts, network: network)
        let prefs = UserDefaultsPreferencesStore(suiteName: "group.co.sstools.bluesky")
        let appearanceStore = AppearanceStore(preferences: prefs)
        // Use App Group store when available (shared with extensions), otherwise fall
        // back to the app-local persistent store. Never use in-memory — if we cannot
        // write to disk the problem must be diagnosed and fixed, not silently hidden.
        let cache: any CacheStore
        do {
            // App Group store is preferred (shared with extensions). If it fails
            // (e.g. App Group entitlement missing or container not provisioned),
            // log the underlying error and fall back to a local store. The outer
            // catch still handles a total failure of both stores.
            let appGroupCache: SwiftDataCacheStore?
            do {
                appGroupCache = try SwiftDataCacheStore(appGroupIdentifier: "group.co.sstools.bluesky")
            } catch {
                bootLogger.debug("App Group cache unavailable, falling back to local store: \(error.localizedDescription, privacy: .public)")
                appGroupCache = nil
            }
            if let appGroupCache {
                bootLogger.info("cache: App Group store")
                cache = appGroupCache
            } else {
                bootLogger.info("cache: local persistent store")
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
            bookmarks: bookmarkStore,
            pathMonitor: pathMonitor
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
        appearance = appearanceStore
    }
}

// MARK: - Appearance shell modifier

/// Applies the user's appearance preferences to the SwiftUI shell:
///
/// 1. `colorMode` → `.preferredColorScheme(_:)` (or no override when set to
///    `.system`, so the host trait collection wins).
/// 2. The active color scheme + `darkVariant` → which `BlueskyTheme` palette
///    is injected via `.blueskyTheme(_:)`. In light mode the variant is
///    irrelevant; in dark mode the user picks between the standard `.dark`
///    palette and the lower-contrast `.dim` palette.
private struct AppearanceShellModifier: ViewModifier {
    @Bindable var appearance: AppearanceStore
    /// Resolved color scheme — reflects the host trait collection when
    /// `preferredColorScheme` is unset (`.system`), or the forced value when
    /// `.light` / `.dark` is in effect.
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preferredScheme)
            .blueskyTheme(activeTheme)
    }

    private var preferredScheme: ColorScheme? {
        switch appearance.colorMode {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// `.light` palette in light mode; in dark mode pick between `.dim` and
    /// `.dark` based on the user's variant preference.
    private var activeTheme: BlueskyTheme {
        guard colorScheme == .dark else { return .light }
        switch appearance.darkVariant {
        case .dim:  return .dim
        case .dark: return .dark
        }
    }
}
