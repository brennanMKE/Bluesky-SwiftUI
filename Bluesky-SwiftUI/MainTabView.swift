import SwiftUI
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

struct MainTabView: View {
    @Environment(SessionManager.self) private var session
    @Environment(BlueskyEnvironment.self) private var env
    @State private var selectedTab: AppTab? = .home
    @State private var messageBadge = 0
    @State private var notificationBadge = 0
    @State private var threadURI: ATURI?
    @State private var showComposer = false
    @State private var showModeration = false

    var body: some View {
        #if os(macOS)
        macOSSidebar
            .onOpenURL { handleDeepLink($0) }
        #else
        adaptiveLayout
            .onOpenURL { handleDeepLink($0) }
        #endif
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
                onPostTap: { post in threadURI = post.uri }
            )
            .navigationDestination(isPresented: Binding(
                get: { threadURI != nil },
                set: { if !$0 { threadURI = nil } }
            )) {
                if let uri = threadURI {
                    ThreadView(uri: uri, network: env.network)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showComposer = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
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
                        Button {
                            showModeration = true
                        } label: {
                            Image(systemName: "shield")
                        }
                    }
                }
                .navigationDestination(isPresented: $showModeration) {
                    ModerationScreen(network: env.network, accountStore: env.accounts)
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
