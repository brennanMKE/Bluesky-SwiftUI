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

    #if os(iOS)
    /// Receives the APNs device token (#0030). UIKit only delivers
    /// `didRegisterForRemoteNotificationsWithDeviceToken` to the app
    /// delegate, so a minimal adaptor is required even under the SwiftUI
    /// lifecycle. See `PushAppDelegate` in `PushRouter.swift`.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    #endif

    @State private var session: SessionManager?
    @State private var environment: BlueskyEnvironment?
    /// Timeline feed store created in boot() and pre-loading before views appear.
    @State private var timelineFeedStore: FeedStore?
    /// UI-test navigation driver. Non-nil only when `BLUESKY_UI_TEST_SCRIPT` is
    /// present in the launch environment — production launches never allocate
    /// it (see `UITestNavigator.fromEnvironment`).
    @State private var uiTestNavigator: UITestNavigator?
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
                        // Injects the optional UI-test navigator. In production
                        // `uiTestNavigator` is `nil`, so `MainTabView`'s
                        // `@Environment(UITestNavigator?.self)` resolves to `nil`
                        // and the driver code path is never entered.
                        .environment(uiTestNavigator)
                        .modifier(AppearanceShellModifier(appearance: appearance))
                } else {
                    ProgressView("Starting…")
                        .task { await boot() }
                }
            }
            // Root-level UI-test error surface. Renders the `ui-test-driver-error`
            // accessibility label whenever the navigator records a decode /
            // dispatch failure — even before login — so the XCUITest process can
            // read it via `app.staticTexts["ui-test-driver-error"]`. Hidden and
            // zero-size in all other cases (and absent entirely in production,
            // where `uiTestNavigator` is `nil`).
            .overlay(alignment: .top) {
                if let message = uiTestNavigator?.scriptError {
                    // Diagnostic surface for the XCUITest process, read via the
                    // `ui-test-driver-error` identifier. Only ever rendered when
                    // a script error exists — i.e. a UI-test failure path, never
                    // in production (where `uiTestNavigator` is nil) and never in
                    // passing screenshots. Rendered as a real, laid-out, visible
                    // element rather than a 0×0 / transparent one: AppKit prunes
                    // zero-size or fully-clear elements from the macOS
                    // accessibility tree, which made the label unreadable there
                    // (iOS/UIKit kept it, so only macOS failed). A small visible
                    // banner is the most reliable cross-platform way to keep the
                    // element queryable.
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Color.red)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("ui-test-driver-error")
                        .accessibilityLabel("ui-test-driver-error")
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

        // UI-test auto-login: when the launch environment carries test
        // credentials AND no live session was restored, sign in programmatically
        // via `createSession` so the scripted navigator can drive a logged-in
        // app. Gated on `BLUESKY_UI_TEST_SCRIPT` so this never runs outside a
        // UI-test launch. Credentials come from the harness's launch
        // environment — never from a committed file.
        let environmentVars = ProcessInfo.processInfo.environment
        if environmentVars["BLUESKY_UI_TEST_SCRIPT"] != nil,
           sm.currentAccount == nil,
           let handle = environmentVars["BLUESKY_TEST_HANDLE"], !handle.isEmpty,
           let password = environmentVars["BLUESKY_TEST_PASSWORD"], !password.isEmpty {
            do {
                _ = try await sm.login(identifier: handle, password: password, authFactorToken: nil)
                bootLogger.info("ui-test: programmatic sign-in succeeded for \(handle, privacy: .public)")
            } catch {
                bootLogger.error("ui-test: programmatic sign-in failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Create the timeline FeedStore and kick off its initial load as a plain Task —
        // not tied to any SwiftUI view lifecycle, so it cannot be cancelled by view
        // recreation. The store is @Observable so FeedView will update automatically
        // as posts arrive.
        let feedStore = FeedStore(network: network, accountStore: accounts, cache: cache)
        Task { await feedStore.loadInitial(selection: .timeline) }
        timelineFeedStore = feedStore

        // Build the scripted navigator only when a script is present, and hand
        // it the live FeedStore so its `waitForFeedLoad` / `tapFirstPost`
        // intents poll the same instance the UI renders.
        let navigator = UITestNavigator.fromEnvironment()
        navigator?.attach(feedStore: feedStore)
        // Cleanup intents (#0064 `deleteTestPosts`) need the authenticated
        // network client and the account store to resolve the signed-in DID.
        navigator?.attach(network: network, accounts: accounts)
        uiTestNavigator = navigator

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
