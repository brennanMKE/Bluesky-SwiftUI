import SwiftUI
import OSLog
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
import BlueskyUI

private let mainTabViewLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "co.sstools.Bluesky", category: "MainTabView")

struct MainTabView: View {
    @Environment(SessionManager.self) private var session
    @Environment(BlueskyEnvironment.self) private var env
    @Environment(\.blueskyTheme) private var theme
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
    @State private var offlineBannerState = OfflineBannerState()
    /// Single shared `BookmarksStore` so the sidebar Saved tab and the
    /// per-screen instance share state (avoids duplicate fetches whenever
    /// the user re-enters the tab).
    @State private var savedStore: BookmarksStore?
    /// Avatar URL for the signed-in viewer, used by the iOS Profile tab icon.
    /// Populated lazily on first appearance and refreshed when the active
    /// account changes; falls back to a placeholder while loading or when
    /// the network call fails.
    @State private var viewerAvatarURL: URL?
    /// Display name for the signed-in viewer, used by the iOS drawer profile card.
    @State private var viewerDisplayName: String?
    /// iOS-only: whether the slide-in drawer is currently visible.
    @State private var showDrawer = false
    /// iOS-only: navigation flag to push the My Feeds destination from the
    /// `#` button on the top bar (#0073).
    @State private var showMyFeeds = false
    /// iOS-only: AT-URI of a custom feed opened from the My Feeds screen,
    /// used to push a `CustomFeedTimelineView` for that feed.
    @State private var openCustomFeedURI: ATURI?
    /// iOS-only: navigation flag to push a notification-settings placeholder
    /// from the gear button on the Notifications top bar (#0077). The real
    /// destination — a public entry point into `BlueskySettings`'
    /// `NotificationSettingsScreen` — is tracked as a follow-up.
    @State private var showNotificationSettings = false

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
            .overlay(alignment: .top) {
                OfflineBanner(state: offlineBannerState)
            }
            .task { await observePathStatus() }
        #else
        adaptiveLayout
            .onOpenURL { handleDeepLink($0) }
            .onReceive(NotificationCenter.default.publisher(for: .openPostThread)) { note in
                handlePushPostThread(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openProfile)) { note in
                handlePushProfile(note)
            }
            .overlay(alignment: .top) {
                OfflineBanner(state: offlineBannerState)
            }
            .task { await observePathStatus() }
        #endif
    }

    /// Subscribes to the shared `NetworkPathMonitoring` and mirrors viability into
    /// `offlineBannerState` for the SwiftUI banner. Also broadcasts a notification
    /// when connectivity is restored so feature view models can refresh.
    private func observePathStatus() async {
        // Seed initial state from the synchronous snapshot before awaiting the stream.
        withAnimation { offlineBannerState.isOffline = !env.pathMonitor.isViable }
        for await status in env.pathMonitor.statusStream {
            let offline = (status != .viable)
            withAnimation { offlineBannerState.isOffline = offline }
            if status == .viable {
                NotificationCenter.default.post(name: .networkBecameViable, object: nil)
            }
        }
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

    /// Clears per-tab navigation state when the user switches tabs so stale
    /// destinations (thread, profile, settings, bookmarks, etc.) don't push
    /// themselves back onto the freshly-recreated NavigationStack.
    private func resetTransientNavState() {
        threadURI = nil
        feedProfileDID = nil
        showSavedFeeds = false
        showModeration = false
        showSettings = false
        showBookmarks = false
        showLists = false
        showMyFeeds = false
        openCustomFeedURI = nil
        showNotificationSettings = false
    }

    // MARK: - macOS sidebar (NavigationSplitView)

    #if os(macOS)
    private var macOSSidebar: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(AppTab.sidebarTabs) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .badge(badge(for: tab))
                        .tag(tab)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Bluesky")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { selectedTab = .home } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }
            .toolbarBackground(theme.colors.background, for: .automatic)
        } detail: {
            NavigationStack {
                // ZStack floods the detail column with the theme background from
                // inside the NavigationStack, overriding the system near-black
                // material that ignores any .background() applied from outside.
                ZStack(alignment: .top) {
                    theme.colors.background.ignoresSafeArea()
                    tabContent(selectedTab ?? .home)
                }
            }
            // Keying the NavigationStack on the selected tab forces SwiftUI to
            // create a fresh stack instance whenever the tab changes, which
            // immediately clears any pushed views (e.g. ThreadView) and shows
            // the new tab's root screen. Without this, macOS keeps the existing
            // stack alive even though the root content has changed.
            .id(selectedTab ?? AppTab.home)
            .onChange(of: selectedTab) { _, _ in
                resetTransientNavState()
            }
        }
        .background(theme.colors.background)
        .toolbarBackground(theme.colors.background, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
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
                        ForEach(AppTab.sidebarTabs) { tab in
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
                    .id(selectedTab ?? AppTab.home)
                    .onChange(of: selectedTab) { _, _ in
                        resetTransientNavState()
                    }
                }
            } else {
                iosCompactLayout
            }
        }
    }

    /// iOS compact (iPhone) layout: a custom icon-only tab bar with the
    /// signed-in user's avatar on the Profile tab and a floating blue
    /// compose button (FAB) hovering above the bar on every screen except
    /// Messages. Selection is mirrored into `selectedTab`; tapping the
    /// active Home tab broadcasts a scroll-to-top notification that
    /// `FeedView` listens for (RN parity, since the system `TabView`'s
    /// implicit scroll-to-top isn't available on a custom bar).
    private var iosCompactLayout: some View {
        let activeTab = selectedTab ?? .home
        return NavigationStack {
            // Fix #0088: mount the slim top bar via `.safeAreaInset(edge: .top)`
            // rather than as the first child of a `VStack` that respects the
            // top safe area. The bar's *background* ignores the top safe area
            // (see `BlueskyTopBar`) so it bleeds behind the status bar while
            // its *content* stays inside the safe area. Profile owns its own
            // banner-bleed (see `ProfileScreen`'s `.ignoresSafeArea(.top)`),
            // so its inset slot resolves to `EmptyView` and the screen
            // handles the status-bar zone itself.
            tabContent(activeTab)
                .safeAreaInset(edge: .top, spacing: 0) {
                    // Slim top bar on tabs that have adopted the RN parity
                    // chrome. Home (#0072) and Notifications (#0077) both
                    // mount a `BlueskyTopBar` here to share the drawer and
                    // suppress the giant system headline. Other tabs
                    // (Search, Profile, Messages) still draw their own
                    // chrome — see their dedicated parity issues.
                    switch activeTab {
                    case .home:
                        iosHomeTopBar
                    case .notifications:
                        iosNotificationsTopBar
                    case .search:
                        iosSearchTopBar
                    default:
                        EmptyView()
                    }
                }
        }
        // Re-create the navigation stack when the active tab changes so
        // pushed destinations (thread, profile, settings, etc.) belonging
        // to the previous tab don't survive into the new one. This matches
        // the existing iPad regular and macOS sidebar behavior.
        .id(activeTab)
        .onChange(of: selectedTab) { _, _ in
            resetTransientNavState()
        }
        // The FAB overlay is added BEFORE safeAreaInset so its alignment
        // bounds end at the top of the tab bar — the bar pushes the
        // overlay up when it inserts itself into the safe area. This
        // keeps the FAB visually 16pt above the bar without manual
        // height math.
        .overlay(alignment: .bottomTrailing) {
            if activeTab != .messages && !showDrawer {
                composeFAB
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            iosCustomTabBar(activeTab: activeTab)
        }
        // Drawer overlay sits above tab content + bottom bar so the slide-in
        // panel can cover the full screen including the safe-area inset.
        .overlay(alignment: .leading) {
            iosDrawerOverlay
        }
        .task(id: session.currentAccount?.did) {
            await refreshViewerAvatar()
        }
        .sheet(isPresented: $showComposer) {
            ComposerSheet(network: env.network, accountStore: env.accounts, preferences: env.preferences)
        }
    }

    /// Slim top bar shown on the iOS Home tab. Hosts the hamburger drawer
    /// trigger on the leading edge, the Bluesky wordmark in the centre, and
    /// the My Feeds (`#`) shortcut on the trailing edge — matching the RN
    /// reference layout for #0072.
    private var iosHomeTopBar: some View {
        BlueskyTopBar(
            leading: {
                BlueskyTopBarIconButton(
                    systemImage: "line.3.horizontal",
                    accessibilityLabel: "Open menu",
                    action: { withAnimation(.easeOut(duration: 0.22)) { showDrawer = true } }
                )
            },
            trailing: {
                BlueskyTopBarIconButton(
                    systemImage: "number",
                    accessibilityLabel: "My feeds",
                    action: { showMyFeeds = true }
                )
            }
        )
    }

    /// Slim top bar shown on the iOS Notifications tab. Reuses the same
    /// shared drawer state as Home (the hamburger triggers `showDrawer`),
    /// renders a single-line "Notifications" title in the centre, and a
    /// gear button on the trailing edge that pushes a placeholder
    /// notification-settings destination — see #0077 for the follow-up to
    /// route into `BlueskySettings.NotificationSettingsScreen` directly.
    private var iosNotificationsTopBar: some View {
        BlueskyTopBar(
            leading: {
                BlueskyTopBarIconButton(
                    systemImage: "line.3.horizontal",
                    accessibilityLabel: "Open menu",
                    action: { withAnimation(.easeOut(duration: 0.22)) { showDrawer = true } }
                )
            },
            center: {
                // Plain title (regular weight, primary text colour) — the
                // brand-blue heavy `BlueskyWordmark` is reserved for Home.
                // Sizing matches the wordmark so the visual weight of the
                // bar is consistent across tabs.
                Text("Notifications")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            },
            trailing: {
                BlueskyTopBarIconButton(
                    systemImage: "gearshape",
                    accessibilityLabel: "Notification settings",
                    action: { showNotificationSettings = true }
                )
            }
        )
    }

    /// Slim top bar shown on the iOS Search tab. Reuses the same shared
    /// drawer state as Home and Notifications (the hamburger triggers
    /// `showDrawer`), renders a single-line "Search" title in the centre,
    /// and leaves the trailing slot empty — the RN reference's Search
    /// shell (`src/screens/Search/Shell.tsx`) puts a `Layout.Header.Slot`
    /// (an empty placeholder) on the trailing edge for the base Search
    /// screen; the language-filter dropdown only appears on the
    /// SearchResults sub-screen, not the discovery view this top bar
    /// covers. The search field itself stays directly below this bar
    /// inside `SearchScreen`.
    private var iosSearchTopBar: some View {
        BlueskyTopBar(
            leading: {
                BlueskyTopBarIconButton(
                    systemImage: "line.3.horizontal",
                    accessibilityLabel: "Open menu",
                    action: { withAnimation(.easeOut(duration: 0.22)) { showDrawer = true } }
                )
            },
            center: {
                // Plain title (regular weight, primary text colour) — matches
                // the Notifications top bar's per-screen title treatment.
                // Sizing matches `BlueskyWordmark` so the visual weight of
                // the bar is consistent across tabs.
                Text("Search")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            },
            trailing: {
                // RN's base Search screen has no trailing action — the
                // search field below handles all the discovery affordances.
                EmptyView()
            }
        )
    }

    /// Custom icon-only tab bar shown on iOS compact widths.
    /// Selected tabs render with the filled SF Symbol variant; the Profile
    /// tab swaps the icon for a circular avatar that gains a brand-blue
    /// ring when active.
    private func iosCustomTabBar(activeTab: AppTab) -> some View {
        HStack(spacing: 0) {
            ForEach(AppTab.compactTabs) { tab in
                Button {
                    if tab == activeTab && tab == .home {
                        // RN parity: tapping Home while already on Home
                        // scrolls the feed back to the top.
                        NotificationCenter.default.post(name: .scrollFeedToTop, object: nil)
                    }
                    selectedTab = tab
                } label: {
                    iosTabBarLabel(for: tab, isActive: tab == activeTab)
                        .frame(maxWidth: .infinity, minHeight: 49)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .frame(height: 49)
        .background(
            theme.colors.background
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.colors.border)
                        .frame(height: 0.5)
                }
        )
    }

    @ViewBuilder
    private func iosTabBarLabel(for tab: AppTab, isActive: Bool) -> some View {
        let tint = isActive ? theme.colors.link : theme.colors.textSecondary
        switch tab {
        case .profile:
            ZStack {
                AvatarView(
                    url: viewerAvatarURL,
                    handle: session.currentAccount?.handle.rawValue ?? "?",
                    size: 28
                )
                if isActive {
                    Circle()
                        .strokeBorder(theme.colors.link, lineWidth: 2)
                        .frame(width: 30, height: 30)
                }
            }
            .frame(width: 30, height: 30)
        default:
            Image(systemName: iosTabIcon(for: tab, isActive: isActive))
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(tint)
                .symbolRenderingMode(.monochrome)
                .overlay(alignment: .topTrailing) {
                    let count = badge(for: tab)
                    if count > 0 {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.red))
                            .offset(x: 10, y: -6)
                    }
                }
        }
    }

    private func iosTabIcon(for tab: AppTab, isActive: Bool) -> String {
        switch tab {
        case .home:          return isActive ? "house.fill" : "house"
        case .search:        return isActive ? "magnifyingglass.circle.fill" : "magnifyingglass"
        case .messages:      return isActive ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
        case .notifications: return isActive ? "bell.fill" : "bell"
        case .saved:         return isActive ? "bookmark.fill" : "bookmark"
        case .profile:       return isActive ? "person.circle.fill" : "person.circle"
        }
    }

    /// Floating compose button (FAB) shown at bottom-right above the
    /// iOS tab bar. Brand-blue circle with a pencil glyph; opens the
    /// shared `ComposerSheet`.
    private var composeFAB: some View {
        Button {
            showComposer = true
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    Circle().fill(theme.colors.link)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New post")
    }

    // MARK: - iOS drawer

    /// Slide-in left drawer shown on iPhone. Mirrors the RN reference's
    /// shell drawer: profile card on top, navigation rows for the major
    /// destinations, sign-out at the bottom. Implemented as a hand-rolled
    /// `ZStack` overlay (rather than a system sheet) so the slide animation
    /// and dim-scrim match the React Native parity target.
    @ViewBuilder
    private var iosDrawerOverlay: some View {
        if showDrawer {
            ZStack(alignment: .leading) {
                // Tap-anywhere-to-dismiss scrim.
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.22)) { showDrawer = false }
                    }
                    .transition(.opacity)
                drawerPanel
                    .transition(.move(edge: .leading))
            }
            .zIndex(10)
        }
    }

    /// The opaque drawer panel itself. Profile card at top, nav rows in the
    /// middle, sign-out at the bottom. Width is ~80% of the screen — matches
    /// the RN drawer width.
    private var drawerPanel: some View {
        let panelWidth = min(UIScreen.main.bounds.width * 0.82, 340)
        return VStack(spacing: 0) {
            drawerProfileCard
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    drawerRow("Profile", systemImage: "person.circle") {
                        dismissDrawer()
                        selectedTab = .profile
                    }
                    drawerRow("Search", systemImage: "magnifyingglass") {
                        dismissDrawer()
                        selectedTab = .search
                    }
                    drawerRow("Feeds", systemImage: "number") {
                        dismissDrawer()
                        selectedTab = .home
                        // Push the My Feeds destination after the drawer
                        // has had time to dismiss so the navigation animation
                        // doesn't fight the drawer slide-out.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 220_000_000)
                            showMyFeeds = true
                        }
                    }
                    drawerRow("Lists", systemImage: "list.bullet") {
                        dismissDrawer()
                        selectedTab = .profile
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 220_000_000)
                            showLists = true
                        }
                    }
                    drawerRow("Bookmarks", systemImage: "bookmark") {
                        dismissDrawer()
                        selectedTab = .profile
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 220_000_000)
                            showBookmarks = true
                        }
                    }
                    drawerRow("Settings", systemImage: "gearshape") {
                        dismissDrawer()
                        selectedTab = .profile
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 220_000_000)
                            showSettings = true
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            Divider()
            drawerRow("Sign out", systemImage: "rectangle.portrait.and.arrow.right", isDestructive: true) {
                dismissDrawer()
                if let did = session.currentAccount?.did {
                    Task {
                        do {
                            try await session.logout(did: did)
                        } catch {
                            mainTabViewLogger.error("logout failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .frame(width: panelWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.colors.background)
        .ignoresSafeArea(edges: .bottom)
    }

    private var drawerProfileCard: some View {
        let account = session.currentAccount
        let handle = account?.handle.rawValue ?? ""
        let displayName = viewerDisplayName ?? account?.displayName ?? handle
        return HStack(spacing: 12) {
            AvatarView(
                url: viewerAvatarURL,
                handle: handle.isEmpty ? "?" : handle,
                size: 52
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                if !handle.isEmpty {
                    Text("@\(handle)")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func drawerRow(
        _ title: String,
        systemImage: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isDestructive ? theme.colors.error : theme.colors.textPrimary)
                    .frame(width: 28, height: 28, alignment: .center)
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isDestructive ? theme.colors.error : theme.colors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func dismissDrawer() {
        withAnimation(.easeOut(duration: 0.22)) { showDrawer = false }
    }

    /// Hydrates `viewerAvatarURL` from the AT Protocol `getProfile`
    /// endpoint. Failures are swallowed silently — the avatar simply
    /// falls back to the initials placeholder rendered by `AvatarView`.
    private func refreshViewerAvatar() async {
        guard let did = session.currentAccount?.did else {
            viewerAvatarURL = nil
            viewerDisplayName = nil
            return
        }
        do {
            let profile: ProfileDetailed = try await env.network.get(
                lexicon: "app.bsky.actor.getProfile",
                params: ["actor": did.rawValue]
            )
            viewerAvatarURL = profile.avatar
            viewerDisplayName = profile.displayName
        } catch {
            mainTabViewLogger.debug("viewer avatar fetch failed: \(error.localizedDescription, privacy: .public)")
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
                bookmarks: env.bookmarks,
                onPostTap: { post in threadURI = post.uri },
                onAuthorTap: { profile in feedProfileDID = profile.did }
            )
            .navigationDestination(item: $threadURI) { uri in
                ThreadView(
                    uri: uri,
                    network: env.network,
                    accountStore: env.accounts,
                    bookmarks: env.bookmarks,
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
                #if os(iOS)
                // On iOS compact the floating FAB owns post composition and
                // replaces this toolbar entry; the iPad regular split view
                // still benefits from a toolbar shortcut, so show the
                // compose button only at .regular width on iOS.
                if horizontalSizeClass == .regular {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showComposer = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showComposer = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
                #endif
                #if os(iOS)
                // The Saved Feeds shortcut moves into the iPhone drawer (#0072);
                // keep it as a toolbar item only at iPad regular width.
                if horizontalSizeClass == .regular {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showSavedFeeds = true
                        } label: {
                            Image(systemName: "list.star")
                        }
                    }
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSavedFeeds = true
                    } label: {
                        Image(systemName: "list.star")
                    }
                }
                #endif
            }
            .navigationDestination(isPresented: $showSavedFeeds) {
                SavedFeedsScreen(network: env.network, cache: env.cache)
            }
            #if os(iOS)
            // Destination for the Home top bar's `#` button (#0072 / #0073).
            // The screen lets the user manage their pinned/saved feeds, search
            // for new ones, and discover curated suggestions.
            .navigationDestination(isPresented: $showMyFeeds) {
                MyFeedsScreen(
                    network: env.network,
                    cache: env.cache,
                    onFeedTap: { saved, resolved in
                        // "following" maps back to the timeline — close the
                        // My Feeds screen and let the user fall through to
                        // the existing Home feed.
                        if saved.type == "timeline" {
                            showMyFeeds = false
                            return
                        }
                        openCustomFeedURI = ATURI(rawValue: saved.value)
                    },
                    onSuggestedTap: { feed in
                        openCustomFeedURI = feed.uri
                    }
                )
            }
            .navigationDestination(item: $openCustomFeedURI) { uri in
                CustomFeedTimelineView(
                    feedURI: uri,
                    title: uri.rkey ?? "Feed",
                    network: env.network,
                    accountStore: env.accounts,
                    cache: env.cache,
                    onPostTap: { post in threadURI = post.uri },
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            #endif
            // The composer sheet is attached at the layout root on iOS
            // compact (so the floating FAB can drive it from outside any
            // tab); on macOS and iPad regular the per-tab toolbar compose
            // button presents from this binding.
            #if os(macOS)
            .sheet(isPresented: $showComposer) {
                ComposerSheet(network: env.network, accountStore: env.accounts, preferences: env.preferences)
            }
            #else
            .sheet(isPresented: Binding(
                get: { showComposer && horizontalSizeClass == .regular },
                set: { if !$0 { showComposer = false } }
            )) {
                ComposerSheet(network: env.network, accountStore: env.accounts, preferences: env.preferences)
            }
            #endif
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
                onUnreadCountChange: { count in notificationBadge = count },
                onAuthorTap: { profile in feedProfileDID = profile.did }
            )
            // Destination for actor-avatar / expanded-actor taps on the
            // notifications list (#0080). Same shared `feedProfileDID`
            // state used by Home / Saved / Search so back-navigation
            // behaves consistently.
            .navigationDestination(item: $feedProfileDID) { did in
                ProfileScreen(
                    actorDID: did,
                    network: env.network,
                    accountStore: env.accounts,
                    viewerDID: session.currentAccount?.did
                )
            }
            #if os(iOS)
            // Destination for the gear button on the iOS Notifications top
            // bar (#0077). Routes to a placeholder until the existing
            // internal `NotificationSettingsScreen` in BlueskySettings is
            // exposed publicly — tracked as a follow-up.
            .navigationDestination(isPresented: $showNotificationSettings) {
                placeholderScreen("Notification Settings", systemImage: "bell.badge")
            }
            #endif
        case .saved:
            BookmarksScreen(
                store: savedStoreOrCreate(),
                onPostTap: { post in threadURI = post.uri },
                onAuthorTap: { profile in feedProfileDID = profile.did }
            )
            .navigationDestination(item: $threadURI) { uri in
                ThreadView(
                    uri: uri,
                    network: env.network,
                    accountStore: env.accounts,
                    bookmarks: env.bookmarks,
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
        case .profile:
            if let account = session.currentAccount {
                ProfileScreen(
                    actorDID: account.did,
                    network: env.network,
                    accountStore: env.accounts,
                    viewerDID: account.did,
                    // #0083: on iOS the own-profile menu lives in the
                    // banner-row ellipsis (with blue dot). macOS keeps the
                    // toolbar Menu below.
                    onSettings:   { showSettings = true },
                    onSaved:      { showBookmarks = true },
                    onMyLists:    { showLists = true },
                    onModeration: { showModeration = true }
                )
                #if os(macOS)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Settings", systemImage: "gear") { showSettings = true }
                            Button("Saved", systemImage: "bookmark") { showBookmarks = true }
                            Button("My Lists", systemImage: "list.bullet") { showLists = true }
                            Button("Moderation", systemImage: "shield") { showModeration = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                #endif
                .navigationDestination(isPresented: $showModeration) {
                    ModerationScreen(network: env.network, accountStore: env.accounts)
                }
                .navigationDestination(isPresented: $showSettings) {
                    SettingsScreen(
                        preferences: env.preferences,
                        accountStore: env.accounts,
                        network: env.network,
                        cache: env.cache,
                        currentAccount: session.currentAccount,
                        onModerationTap: { showModeration = true },
                        onSignOut: {
                            Task {
                                do {
                                    try await session.logout(did: account.did)
                                } catch {
                                    mainTabViewLogger.error("logout failed: \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        },
                        onAccountDeactivated: {
                            // Mirror RN's `logoutCurrentAccount('Deactivated')`:
                            // after the server flips the account to deactivated,
                            // sign out so the RootView gate routes to
                            // `DeactivatedView` on the next sign-in.
                            Task {
                                do {
                                    try await session.logout(did: account.did)
                                } catch {
                                    mainTabViewLogger.error("post-deactivate logout failed: \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        }
                    )
                }
                .navigationDestination(isPresented: $showBookmarks) {
                    BookmarksScreen(
                        store: savedStoreOrCreate(),
                        onPostTap: { post in threadURI = post.uri },
                        onAuthorTap: { profile in feedProfileDID = profile.did }
                    )
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

    /// Lazily creates the shared `BookmarksStore` on first access. Reusing the
    /// same instance across the sidebar Saved tab and any other entry point
    /// (e.g. Profile menu) avoids re-fetching the bookmark list every time the
    /// user navigates away and back.
    private func savedStoreOrCreate() -> BookmarksStore {
        if let existing = savedStore { return existing }
        let store = BookmarksStore(network: env.network)
        savedStore = store
        return store
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
    case home, search, messages, notifications, saved, profile

    var id: String { rawValue }

    /// Tabs shown in compact iPhone-style tab bars. The system caps useful tab
    /// bars at five items, so `Saved` is hidden in compact and remains
    /// accessible from the Profile menu (matching the bsky.app mobile drawer).
    static var compactTabs: [AppTab] {
        [.home, .search, .messages, .notifications, .profile]
    }

    /// Tabs shown in regular sidebar layouts (macOS, iPadOS regular width).
    /// `Saved` sits alongside the other primary destinations to mirror the
    /// bsky.app web LeftNav.
    static var sidebarTabs: [AppTab] { allCases }

    var title: String {
        switch self {
        case .home:          "Home"
        case .search:        "Search"
        case .messages:      "Messages"
        case .notifications: "Notifications"
        case .saved:         "Saved"
        case .profile:       "Profile"
        }
    }

    var icon: String {
        switch self {
        case .home:          "house"
        case .search:        "magnifyingglass"
        case .messages:      "bubble.left.and.bubble.right"
        case .notifications: "bell"
        case .saved:         "bookmark"
        case .profile:       "person.circle"
        }
    }
}

