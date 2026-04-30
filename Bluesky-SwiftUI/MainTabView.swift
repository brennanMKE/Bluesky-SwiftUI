import SwiftUI
import UserNotifications
import BlueskyAuth
import BlueskyCore
import BlueskyKit
import BlueskyFeed
import BlueskyProfile
import BlueskySearch
import BlueskyNotifications
import BlueskyMessages
import BlueskyComposer
import BlueskyModeration
import BlueskySettings
import BlueskyLists

struct MainTabView: View {
    @Environment(SessionManager.self) private var session
    @Environment(BlueskyEnvironment.self) private var env
    @State private var selectedTab: AppTab? = .home
    @State private var messageBadge = 0
    @State private var notificationBadge = 0
    @State private var threadURI: ATURI?
    /// DID of a profile opened via push notification routing.
    @State private var pushProfileDID: String?
    /// DID of a profile to navigate to from feed/thread author taps.
    @State private var feedProfileDID: DID?
    @State private var showComposer = false
    @State private var showModeration = false
    @State private var showSettings = false
    @State private var showBookmarks = false
    @State private var showSavedFeeds = false
    @State private var showLists = false

    var body: some View {
        #if os(macOS)
        macOSSidebar
            .onOpenURL { handleDeepLink($0) }
            .onReceive(NotificationCenter.default.publisher(for: .openPostThread)) { note in
                handlePushPostThread(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openProfile)) { note in
                handlePushProfile(note)
            }
        #else
        adaptiveLayout
            .onOpenURL { handleDeepLink($0) }
            .onReceive(NotificationCenter.default.publisher(for: .openPostThread)) { note in
                handlePushPostThread(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openProfile)) { note in
                handlePushProfile(note)
            }
        #endif
    }

    // MARK: - Push notification routing

    private func handlePushPostThread(_ note: Foundation.Notification) {
        guard let uriString = note.object as? String else { return }
        let uri = ATURI(rawValue: uriString)
        selectedTab = .home
        threadURI = uri
    }

    private func handlePushProfile(_ note: Foundation.Notification) {
        guard let did = note.object as? String, !did.isEmpty else { return }
        pushProfileDID = did
        selectedTab = .profile
    }

    // MARK: - macOS sidebar (NavigationSplitView)

    #if os(macOS)
    private var macOSSidebar: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(AppTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .badge(badge(for: tab))
                        .tag(tab)
                }
            }
            .navigationTitle("Bluesky")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { selectedTab = .home } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }
        } detail: {
            NavigationStack {
                tabContent(selectedTab ?? .home)
            }
            // Keying the NavigationStack on the selected tab forces SwiftUI to
            // create a fresh stack instance whenever the tab changes, which
            // immediately clears any pushed views (e.g. ThreadView) and shows
            // the new tab's root screen. Without this, macOS keeps the existing
            // stack alive even though the root content has changed.
            .id(selectedTab)
            .onChange(of: selectedTab) { _, _ in
                // Clear per-tab navigation state so stale destinations
                // (thread, profile) don't re-appear if the tab is revisited.
                threadURI = nil
                feedProfileDID = nil
            }
        }
    }
    #endif

    // MARK: - iOS/iPadOS adaptive layout

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var adaptiveLayout: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    List(selection: $selectedTab) {
                        ForEach(AppTab.allCases) { tab in
                            Label(tab.title, systemImage: tab.icon)
                                .badge(badge(for: tab))
                                .tag(tab)
                        }
                    }
                    .navigationTitle("Bluesky")
                } detail: {
                    NavigationStack {
                        tabContent(selectedTab ?? .home)
                    }
                    // Same fix as macOS: reset the stack when the tab changes
                    // so pushed views don't linger in the detail pane.
                    .id(selectedTab)
                    .onChange(of: selectedTab) { _, _ in
                        threadURI = nil
                        feedProfileDID = nil
                    }
                }
            } else {
                TabView(selection: Binding(
                    get: { selectedTab ?? .home },
                    set: { selectedTab = $0 }
                )) {
                    ForEach(AppTab.allCases) { tab in
                        NavigationStack {
                            tabContent(tab)
                        }
                        .tabItem { Label(tab.title, systemImage: tab.icon) }
                        .tag(tab)
                        .badge(badge(for: tab))
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Tab content (placeholder screens)

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .home:
            FeedView(
                network: env.network,
                accountStore: env.accounts,
                cache: env.cache,
                onPostTap: { post in threadURI = post.uri },
                onAuthorTap: { profile in feedProfileDID = profile.did }
            )
            .navigationDestination(item: $threadURI) { uri in
                ThreadView(
                    uri: uri,
                    network: env.network,
                    accountStore: env.accounts,
                    onAuthorTap: { profile in feedProfileDID = profile.did },
                    onPostTap: { post in threadURI = post.uri }
                )
            }
            .navigationDestination(item: $feedProfileDID) { did in
                ProfileScreen(
                    actorDID: did,
                    network: env.network,
                    accountStore: env.accounts,
                    viewerDID: session.currentAccount?.did
                )
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showComposer = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSavedFeeds = true
                    } label: {
                        Image(systemName: "list.star")
                    }
                }
            }
            .navigationDestination(isPresented: $showSavedFeeds) {
                SavedFeedsScreen(network: env.network, cache: env.cache)
            }
            .sheet(isPresented: $showComposer) {
                ComposerSheet(network: env.network, accountStore: env.accounts)
            }
        case .search:
            SearchScreen(network: env.network)
        case .messages:
            ConversationListScreen(
                network: env.network,
                viewerDID: session.currentAccount?.did
            )
        case .notifications:
            NotificationsScreen(
                network: env.network,
                onUnreadCountChange: { count in notificationBadge = count }
            )
        case .profile:
            if let account = session.currentAccount {
                ProfileScreen(
                    actorDID: account.did,
                    network: env.network,
                    accountStore: env.accounts,
                    viewerDID: account.did
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Settings", systemImage: "gear") { showSettings = true }
                            Button("Bookmarks", systemImage: "bookmark") { showBookmarks = true }
                            Button("My Lists", systemImage: "list.bullet") { showLists = true }
                            Button("Moderation", systemImage: "shield") { showModeration = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .navigationDestination(isPresented: $showModeration) {
                    ModerationScreen(network: env.network, accountStore: env.accounts)
                }
                .navigationDestination(isPresented: $showSettings) {
                    SettingsScreen(
                        preferences: env.preferences,
                        accountStore: env.accounts,
                        network: env.network,
                        onModerationTap: { showModeration = true },
                        onSignOut: {
                            Task { try? await session.logout(did: account.did) }
                        }
                    )
                }
                .navigationDestination(isPresented: $showBookmarks) {
                    BookmarksScreen(network: env.network)
                }
                .navigationDestination(isPresented: $showLists) {
                    ListsScreen(
                        actorDID: account.did.rawValue,
                        network: env.network,
                        accountStore: env.accounts
                    )
                }
            } else {
                placeholderScreen("Profile", systemImage: "person.circle")
            }
        }
    }

    private func placeholderScreen(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
    }

    // MARK: - Badges

    private func badge(for tab: AppTab) -> Int {
        switch tab {
        case .messages:      return messageBadge
        case .notifications: return notificationBadge
        default:             return 0
        }
    }

    // MARK: - Deep links

    private func handleDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return }
        let isBlueskyScheme = url.scheme == "bluesky"
        let isBskyApp = url.scheme == "https" && url.host == "bsky.app"
        guard isBlueskyScheme || isBskyApp else { return }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch path {
        case "notifications":        selectedTab = .notifications
        case "messages", "chat":     selectedTab = .messages
        default:
            if path.hasPrefix("profile") { selectedTab = .profile }
        }
    }
}

// MARK: - AppTab

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home, search, messages, notifications, profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:          "Home"
        case .search:        "Search"
        case .messages:      "Messages"
        case .notifications: "Notifications"
        case .profile:       "Profile"
        }
    }

    var icon: String {
        switch self {
        case .home:          "house"
        case .search:        "magnifyingglass"
        case .messages:      "bubble.left.and.bubble.right"
        case .notifications: "bell"
        case .profile:       "person.circle"
        }
    }
}
