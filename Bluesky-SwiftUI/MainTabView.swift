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
    /// Optional UI-test navigation driver. `nil` in production (the app injects
    /// `nil` when `BLUESKY_UI_TEST_SCRIPT` is absent), so the driver code path
    /// is dead weight only under UI test. See `UITestNavigator`.
    @Environment(UITestNavigator.self) private var uiTestNavigator: UITestNavigator?
    /// Drives the unread-badge refetch when the app returns to the
    /// foreground (#0196). RN parity: `checkUnread` in
    /// `state/queries/notifications/unread.tsx` early-returns while the app
    /// isn't active, so the count re-syncs on the first tick after
    /// foregrounding — we refetch explicitly on the `.active` transition.
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab? = .home
    @State private var messageBadge = 0
    @State private var notificationBadge = 0
    @State private var threadURI: ATURI?
    /// DID of a profile to navigate to from feed/thread author taps.
    @State private var feedProfileDID: DID?
    /// Push-notification destinations parked while a tab switch is in flight
    /// (#0030). `resetTransientNavState` — which runs on every tab change and
    /// would otherwise wipe the destination — consumes these after the reset.
    @State private var pendingPushThreadURI: ATURI?
    @State private var pendingPushProfileDID: DID?
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
    /// Single shared `NotificationsViewModel` (#0196) so the app-shell
    /// unread-count poll and the Notifications tab screen observe one
    /// `NotificationsStore`. Without sharing, the screen's `markSeen()`
    /// would zero a *different* store's count and the badge could never
    /// clear; with it, the screen's `.onChange(of: unreadCount)` →
    /// `onUnreadCountChange` fires on the N → 0 transition.
    @State private var notificationsViewModel: NotificationsViewModel?
    /// Avatar URL for the signed-in viewer, used by the iOS Profile tab icon.
    /// Populated lazily on first appearance and refreshed when the active
    /// account changes; falls back to a placeholder while loading or when
    /// the network call fails.
    @State private var viewerAvatarURL: URL?
    /// Display name for the signed-in viewer, used by the iOS drawer profile card.
    @State private var viewerDisplayName: String?
    /// Followers count for the signed-in viewer. Used by the drawer profile
    /// header's stats row (#0150). `nil` until the first `getProfile` call
    /// completes — the row hides itself in that state rather than flashing
    /// zeros.
    @State private var viewerFollowersCount: Int?
    /// Following count for the signed-in viewer. Same lifecycle as
    /// `viewerFollowersCount`.
    @State private var viewerFollowingCount: Int?
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

    /// AT-URI of the post whose `LikedByScreen` should push, fired by the
    /// focal-post stat row in `ThreadView` (#0146 + #0139).
    @State private var likedByPostURI: ATURI?
    /// AT-URI of the post whose `RepostedByScreen` should push.
    @State private var repostedByPostURI: ATURI?
    /// AT-URI of the post whose `QuotesOfScreen` should push.
    @State private var quotesPostURI: ATURI?
    /// AT-URI of a feed (`app.bsky.feed.generator`) opened from a
    /// `feedgen-like` notification row (#0062). Reused as the navigation
    /// item for a `CustomFeedTimelineView` push from the Notifications
    /// tab. Distinct from `openCustomFeedURI` because that slot is iOS-only
    /// and tied to the My Feeds entry point — keeping these separate avoids
    /// cross-tab destination leaks.
    @State private var notificationFeedURI: ATURI?
    /// AT-URI of a starter pack (`app.bsky.graph.starterpack`) opened from
    /// a `starterpack-joined` notification row (#0062). Drives a
    /// `StarterPackScreen` push from the Notifications tab.
    @State private var notificationStarterPackURI: ATURI?
    /// AT-URI of a starter pack opened from a profile's Starter Packs tab
    /// (#0206) — own profile or a pushed profile on the Home / Search /
    /// Saved / Profile stacks. Drives a `StarterPackScreen` push.
    @State private var starterPackURI: ATURI?
    /// Presents the Starter Pack create wizard (#0206), entered from the
    /// own profile's Starter Packs tab (RN: `ProfileStarterPacks` → the
    /// `StarterPackWizard` route).
    @State private var showStarterPackCreate = false
    /// URI of a pack the wizard just created, parked until the sheet's
    /// `onDismiss` so the `StarterPackScreen` push isn't swallowed by the
    /// dismissal transition (#0206; RN replaces the route directly).
    @State private var pendingCreatedStarterPackURI: ATURI?
    /// Entry into the immersive video feed (#0205). Set by a tap on a card
    /// in the Discover tab's "Trending Videos" interstitial (RN: the
    /// `VideoFeed` route, navigated to from `CompactVideoPostCard`), or by
    /// the `openVideoFeed` UI-test intent. Drives a `VideoFeedView` push on
    /// the Home tab.
    @State private var videoFeedEntry: VideoFeedEntry?

    var body: some View {
        #if os(macOS)
        macOSSidebar
            .onOpenURL { handleDeepLink($0) }
            .onReceive(NotificationCenter.default.publisher(for: .pushRouteReceived)) { _ in
                applyPendingPushRoute()
            }
            .task {
                // Cold start from a notification tap: the delegate may have
                // buffered a route before this view mounted.
                applyPendingPushRoute()
                await PushRouteDispatcher.simulateTapFromEnvironmentIfRequested()
                applyPendingPushRoute()
            }
            .overlay(alignment: .top) {
                OfflineBanner(state: offlineBannerState)
            }
            .task { await observePathStatus() }
            // #0196: app-shell unread-count poll — restarts when the
            // signed-in account changes so the badge never carries over
            // across account switches.
            .task(id: session.currentAccount?.did) {
                await pollUnreadNotifications()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshUnreadBadge() }
            }
            .modifier(UITestDriverModifier(
                navigator: uiTestNavigator,
                selectedTab: $selectedTab,
                threadURI: $threadURI,
                showSettings: $showSettings,
                showComposer: $showComposer,
                showModeration: $showModeration,
                showBookmarks: $showBookmarks,
                videoFeedEntry: $videoFeedEntry
            ))
        #else
        adaptiveLayout
            .onOpenURL { handleDeepLink($0) }
            .onReceive(NotificationCenter.default.publisher(for: .pushRouteReceived)) { _ in
                applyPendingPushRoute()
            }
            .task {
                // Cold start from a notification tap: the delegate may have
                // buffered a route before this view mounted.
                applyPendingPushRoute()
                await PushRouteDispatcher.simulateTapFromEnvironmentIfRequested()
                applyPendingPushRoute()
            }
            // #0030: once a session is active, obtain the APNs token and
            // register it with Bluesky's notification gateway. Re-runs when
            // the signed-in account changes.
            .task(id: session.currentAccount?.did) {
                guard session.currentAccount != nil else { return }
                PushRegistrationCoordinator.shared.activate(network: env.network)
            }
            // #0196: app-shell unread-count poll — restarts when the
            // signed-in account changes so the badge never carries over
            // across account switches.
            .task(id: session.currentAccount?.did) {
                await pollUnreadNotifications()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshUnreadBadge() }
            }
            .overlay(alignment: .top) {
                OfflineBanner(state: offlineBannerState)
            }
            .task { await observePathStatus() }
            .modifier(UITestDriverModifier(
                navigator: uiTestNavigator,
                selectedTab: $selectedTab,
                threadURI: $threadURI,
                showSettings: $showSettings,
                showComposer: $showComposer,
                showModeration: $showModeration,
                showBookmarks: $showBookmarks,
                videoFeedEntry: $videoFeedEntry
            ))
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

    /// Consumes the route buffered by `PushRouteDispatcher` (#0030) and maps
    /// it onto the app's navigation state. Threads and profiles land on the
    /// Home tab's stack — RN parity: `useNotificationHandler` navigates
    /// `HomeTab` for post/profile URLs and `resetToTab` for the
    /// notifications fallback.
    private func applyPendingPushRoute() {
        guard let route = PushRouteDispatcher.consumePendingRoute() else { return }
        switch route {
        case .postThread(let uri):
            routePushDestination(thread: uri, profile: nil)
        case .profile(let did):
            routePushDestination(thread: nil, profile: did)
        case .conversation, .messagesInbox:
            // ConversationListScreen has no external "open this convo" entry
            // point yet, so both chat routes land on the Messages inbox.
            selectedTab = .messages
        case .notificationsTab:
            selectedTab = .notifications
        }
    }

    /// Routes a push destination onto the Home tab. When a tab switch is
    /// needed, the destination is parked in `pendingPushThreadURI` /
    /// `pendingPushProfileDID` because the switch triggers
    /// `resetTransientNavState`, which would clear a directly-set value.
    private func routePushDestination(thread: ATURI?, profile: DID?) {
        if selectedTab == .home {
            if let thread { threadURI = thread }
            if let profile { feedProfileDID = profile }
        } else {
            pendingPushThreadURI = thread
            pendingPushProfileDID = profile
            selectedTab = .home
        }
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
        notificationFeedURI = nil
        notificationStarterPackURI = nil
        starterPackURI = nil
        showStarterPackCreate = false
        pendingCreatedStarterPackURI = nil
        videoFeedEntry = nil

        // #0030: a push-notification route that required a tab switch parked
        // its destination above; apply it after the reset, deferred one tick
        // so the freshly-recreated NavigationStack (`.id(selectedTab)`)
        // exists before its destination binding fires.
        if pendingPushThreadURI != nil || pendingPushProfileDID != nil {
            let thread = pendingPushThreadURI
            let profile = pendingPushProfileDID
            pendingPushThreadURI = nil
            pendingPushProfileDID = nil
            Task { @MainActor in
                if let thread { threadURI = thread }
                if let profile { feedProfileDID = profile }
            }
        }
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
        .padding(.horizontal, 8) // RN: BottomBarStyles `bottomBar` paddingLeft/Right = tokens.space.sm (8)
        .frame(height: 49)
        .background(
            theme.colors.background
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.colors.border)
                        .frame(height: 0.5)
                }
                // RN's bar is opaque through the home-indicator region
                // (paddingBottom: clamp(insets.bottom, 15, 60)); without
                // this, feed content shows through below the bar.
                .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private func iosTabBarLabel(for tab: AppTab, isActive: Bool) -> some View {
        // RN parity (BottomBar.tsx): every glyph renders in the primary text
        // color in both states — selection is conveyed by the filled icon
        // variant (and, for Profile, the hairline ring), not by a tint change.
        let tint = theme.colors.textPrimary
        switch tab {
        case .profile:
            // RN draws the avatar at `iconWidth - 2` (26pt) normally and
            // `iconWidth - 3` (25pt) when selected, inside a circular wrapper
            // with a 1px border (transparent when inactive, text-colored when
            // active), so the slot's footprint stays at the shared 28pt icon
            // size in both states.
            ZStack {
                AvatarView(
                    url: viewerAvatarURL,
                    handle: session.currentAccount?.handle.rawValue ?? "?",
                    size: isActive ? 25 : 26
                )
                if isActive {
                    Circle()
                        .strokeBorder(theme.colors.textPrimary, lineWidth: 1)
                        .frame(width: 27, height: 27)
                }
            }
            .frame(width: 28, height: 28)
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

    /// Slide-in left drawer shown on iPhone. Mirrors RN's
    /// `Bluesky-ReactNative/src/view/shell/Drawer.tsx`: profile header at
    /// the top with avatar / name / handle / followers · following stats,
    /// nine navigation rows in RN order (Explore, Home, Chat,
    /// Notifications, Feeds, Lists, Saved, Profile, Settings), and a footer
    /// with Terms of Service / Privacy Policy links plus Feedback / Help
    /// pill buttons. Implemented as a hand-rolled `ZStack` overlay (rather
    /// than a system sheet) so the slide animation and dim-scrim match the
    /// React Native parity target. The panel itself lives in `DrawerView`
    /// (#0150) so the body of `MainTabView` doesn't balloon.
    @ViewBuilder
    private var iosDrawerOverlay: some View {
        if showDrawer {
            ZStack(alignment: .leading) {
                // Tap-anywhere-to-dismiss scrim.
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { dismissDrawer() }
                    .transition(.opacity)
                DrawerView(
                    selectedTab: $selectedTab,
                    currentAccount: session.currentAccount,
                    viewerAvatarURL: viewerAvatarURL,
                    viewerDisplayName: viewerDisplayName,
                    viewerFollowersCount: viewerFollowersCount,
                    viewerFollowingCount: viewerFollowingCount,
                    notificationBadge: notificationBadge,
                    onAppearOnce: {
                        // Refresh stats when the drawer first opens so the
                        // followers/following row is populated even if the
                        // initial `task(id:)` fired before the drawer was
                        // ever visible.
                        Task { await refreshViewerAvatar() }
                    },
                    onDismiss: { dismissDrawer() },
                    onPushMyFeeds:   { showMyFeeds = true },
                    onPushLists:     { showLists = true },
                    onPushBookmarks: { showBookmarks = true },
                    onPushSettings:  { showSettings = true }
                )
                .transition(.move(edge: .leading))
            }
            .zIndex(10)
        }
    }

    private func dismissDrawer() {
        withAnimation(.easeOut(duration: 0.22)) { showDrawer = false }
    }

    /// Hydrates `viewerAvatarURL`, `viewerDisplayName`, and the followers /
    /// following counts shown in the iOS sidebar drawer header (#0150) from
    /// the AT Protocol `getProfile` endpoint. Failures are swallowed
    /// silently — the avatar falls back to the `AvatarView` initials
    /// placeholder and the stats row hides itself.
    private func refreshViewerAvatar() async {
        guard let did = session.currentAccount?.did else {
            viewerAvatarURL = nil
            viewerDisplayName = nil
            viewerFollowersCount = nil
            viewerFollowingCount = nil
            return
        }
        do {
            let profile: ProfileDetailed = try await env.network.get(
                lexicon: "app.bsky.actor.getProfile",
                params: ["actor": did.rawValue]
            )
            viewerAvatarURL = profile.avatar
            viewerDisplayName = profile.displayName
            viewerFollowersCount = profile.followersCount
            viewerFollowingCount = profile.followsCount
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
                onAuthorTap: { profile in feedProfileDID = profile.did },
                // #0205: Trending Videos interstitial (Discover tab) →
                // immersive video feed, seeded at the tapped post (RN:
                // `CompactVideoPostCard` navigates to the `VideoFeed` route
                // with `initialPostUri`).
                onTrendingVideoTap: { post in
                    videoFeedEntry = VideoFeedEntry(initialPostURI: post.uri.rawValue)
                },
                // #0205: the interstitial's "View more" card opens the video
                // feed generator's timeline (RN: `makeCustomFeedLink`).
                onTrendingVideosViewMore: {
                    openCustomFeedURI = ATURI(rawValue: VideoFeedView.videoFeedURI)
                }
            )
            .navigationDestination(item: $threadURI) { uri in
                ThreadView(
                    uri: uri,
                    network: env.network,
                    accountStore: env.accounts,
                    bookmarks: env.bookmarks,
                    onAuthorTap: { profile in feedProfileDID = profile.did },
                    onPostTap: { post in threadURI = post.uri },
                    onLikedByTap: { postURI in likedByPostURI = postURI },
                    onRepostedByTap: { postURI in repostedByPostURI = postURI },
                    onQuotesTap: { postURI in quotesPostURI = postURI }
                )
            }
            .navigationDestination(item: $feedProfileDID) { did in
                ProfileScreen(
                    actorDID: did,
                    network: env.network,
                    accountStore: env.accounts,
                    viewerDID: session.currentAccount?.did,
                    // #0206: a pushed profile's Starter Packs tab opens the
                    // pack on the same stack. Creation is only offered on
                    // the Profile tab's own-profile mount.
                    onStarterPackTap: { uri in starterPackURI = uri }
                )
            }
            // #0206: starter pack opened from a profile's Starter Packs tab.
            .navigationDestination(item: $starterPackURI) { uri in
                StarterPackScreen(
                    starterPackURI: uri,
                    network: env.network,
                    accountStore: env.accounts
                )
            }
            .navigationDestination(item: $likedByPostURI) { postURI in
                LikedByScreen(
                    postURI: postURI,
                    network: env.network,
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            .navigationDestination(item: $repostedByPostURI) { postURI in
                RepostedByScreen(
                    postURI: postURI,
                    network: env.network,
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            .navigationDestination(item: $quotesPostURI) { postURI in
                QuotesOfScreen(
                    postURI: postURI,
                    network: env.network,
                    onPostTap: { post in threadURI = post.uri },
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            // #0205: immersive vertical video feed. Pushed from the Discover
            // tab's Trending Videos interstitial (and the `openVideoFeed`
            // UI-test intent); always backed by the `thevids` video
            // algorithm feed, mirroring RN's `VideoFeedSourceContext`
            // (`type: 'feedgen', uri: VIDEO_FEED_URI`).
            .navigationDestination(item: $videoFeedEntry) { entry in
                VideoFeedView(
                    network: env.network,
                    accountStore: env.accounts,
                    cache: env.cache,
                    feedURI: VideoFeedView.videoFeedURI,
                    initialPostURI: entry.initialPostURI,
                    onProfileTap: { did in feedProfileDID = did },
                    onPostTap: { post in threadURI = post.uri }
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
                // macOS: My Feeds (`#`) is the sole trailing toolbar button
                // (#0196). Compose was removed from the toolbar — it moves to
                // a floating bottom-right button in #0197. The `number` glyph
                // matches the iOS-RN trailing icon (BlueskyTopBar, #0072 / #0073).
                ToolbarItem(id: "bsky.myfeeds", placement: .primaryAction) {
                    Button {
                        showSavedFeeds = true
                    } label: {
                        Image(systemName: "number")
                    }
                    .help("My Feeds")
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
            #endif
            // Custom feed timeline destination. Historically iOS-only (the
            // My Feeds entry point), but the Trending Videos interstitial's
            // "View more" card (#0205) routes here on both platforms, so the
            // destination is registered unconditionally.
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
            // #0184: hoist the actor / post destinations up to the app shell so
            // tapping a People result pushes a real `ProfileScreen` and tapping
            // a Posts result pushes a real `ThreadView`. `BlueskySearch` cannot
            // import `BlueskyProfile`/`BlueskyFeed` without a cross-feature
            // cycle, so — exactly like the Notifications tab — the screen
            // exposes `onActorTap`/`onPostTap` closures and the app target
            // (which sits above both modules) maps them onto the shared
            // `feedProfileDID` / `threadURI` navigation state.
            SearchScreen(
                network: env.network,
                onActorTap: { profile in feedProfileDID = profile.did },
                onPostTap: { post in threadURI = post.uri }
            )
            .navigationDestination(item: $feedProfileDID) { did in
                ProfileScreen(
                    actorDID: did,
                    network: env.network,
                    accountStore: env.accounts,
                    viewerDID: session.currentAccount?.did,
                    // #0206: a pushed profile's Starter Packs tab opens the
                    // pack on the same stack. Creation is only offered on
                    // the Profile tab's own-profile mount.
                    onStarterPackTap: { uri in starterPackURI = uri }
                )
            }
            // #0206: starter pack opened from a profile's Starter Packs tab.
            .navigationDestination(item: $starterPackURI) { uri in
                StarterPackScreen(
                    starterPackURI: uri,
                    network: env.network,
                    accountStore: env.accounts
                )
            }
            .navigationDestination(item: $threadURI) { uri in
                ThreadView(
                    uri: uri,
                    network: env.network,
                    accountStore: env.accounts,
                    bookmarks: env.bookmarks,
                    onAuthorTap: { profile in feedProfileDID = profile.did },
                    onPostTap: { post in threadURI = post.uri },
                    onLikedByTap: { postURI in likedByPostURI = postURI },
                    onRepostedByTap: { postURI in repostedByPostURI = postURI },
                    onQuotesTap: { postURI in quotesPostURI = postURI }
                )
            }
            .navigationDestination(item: $likedByPostURI) { postURI in
                LikedByScreen(
                    postURI: postURI,
                    network: env.network,
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            .navigationDestination(item: $repostedByPostURI) { postURI in
                RepostedByScreen(
                    postURI: postURI,
                    network: env.network,
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            .navigationDestination(item: $quotesPostURI) { postURI in
                QuotesOfScreen(
                    postURI: postURI,
                    network: env.network,
                    onPostTap: { post in threadURI = post.uri },
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
        case .messages:
            ConversationListScreen(
                network: env.network,
                viewerDID: session.currentAccount?.did
            )
        case .notifications:
            // #0196: pass the *shared* view model (not `network:`) so the
            // screen's `markSeen()` zeroes the same store the shell-level
            // unread poll populates — that N → 0 transition is what fires
            // `onUnreadCountChange` and clears the tab badge.
            NotificationsScreen(
                viewModel: notificationsViewModelOrCreate(),
                onUnreadCountChange: { count in notificationBadge = count },
                onAuthorTap: { profile in feedProfileDID = profile.did },
                // #0160 / #0062: hoist the thread destination up to the app
                // shell so the real `ThreadView` from `BlueskyFeed` mounts
                // here. `BlueskyNotifications` cannot import `BlueskyFeed`
                // without forming a cross-feature cycle, so the screen's
                // internal `navigationDestination` is a placeholder that
                // only activates when no `onPostTap` is wired (used by
                // previews). The app target sits above both modules and
                // can wire the real destination via the shared
                // `threadURI` `@State`.
                onPostTap: { uri in threadURI = uri },
                // #0062: route `feedgen-like` rows to a real feed timeline
                // and `starterpack-joined` rows to the starter pack screen.
                // The screen dispatches by AT-URI collection segment so the
                // single tap handler picks the right destination based on
                // what `reasonSubject` actually points at.
                onFeedTap: { uri in notificationFeedURI = uri },
                onStarterPackTap: { uri in notificationStarterPackURI = uri }
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
                    viewerDID: session.currentAccount?.did,
                    // #0206: a pushed profile's Starter Packs tab opens the
                    // pack on the same stack. Creation is only offered on
                    // the Profile tab's own-profile mount.
                    onStarterPackTap: { uri in starterPackURI = uri }
                )
            }
            // #0206: starter pack opened from a profile's Starter Packs tab.
            .navigationDestination(item: $starterPackURI) { uri in
                StarterPackScreen(
                    starterPackURI: uri,
                    network: env.network,
                    accountStore: env.accounts
                )
            }
            // #0160 / #0062: real `ThreadView` destination for tapped
            // notifications (likes/replies/mentions/quotes/reposts). Mirrors
            // the Home/Saved tab wiring so an in-thread tap on a reply or
            // quote can keep navigating into deeper threads via the same
            // `threadURI` state, and so the focal-post stat row's
            // liked-by / reposted-by / quotes destinations work from the
            // notifications path too (#0146).
            .navigationDestination(item: $threadURI) { uri in
                ThreadView(
                    uri: uri,
                    network: env.network,
                    accountStore: env.accounts,
                    bookmarks: env.bookmarks,
                    onAuthorTap: { profile in feedProfileDID = profile.did },
                    onPostTap: { post in threadURI = post.uri },
                    onLikedByTap: { postURI in likedByPostURI = postURI },
                    onRepostedByTap: { postURI in repostedByPostURI = postURI },
                    onQuotesTap: { postURI in quotesPostURI = postURI }
                )
            }
            .navigationDestination(item: $likedByPostURI) { postURI in
                LikedByScreen(
                    postURI: postURI,
                    network: env.network,
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            .navigationDestination(item: $repostedByPostURI) { postURI in
                RepostedByScreen(
                    postURI: postURI,
                    network: env.network,
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            .navigationDestination(item: $quotesPostURI) { postURI in
                QuotesOfScreen(
                    postURI: postURI,
                    network: env.network,
                    onPostTap: { post in threadURI = post.uri },
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            // #0062: real feed timeline for `feedgen-like` notifications.
            // `reasonSubject` points at an `app.bsky.feed.generator` URI
            // — without this, taps fell through to `ThreadView` and
            // rendered an empty thread.
            .navigationDestination(item: $notificationFeedURI) { uri in
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
            // #0062: real starter pack screen for `starterpack-joined`
            // notifications. `reasonSubject` points at an
            // `app.bsky.graph.starterpack` URI.
            .navigationDestination(item: $notificationStarterPackURI) { uri in
                StarterPackScreen(
                    starterPackURI: uri,
                    network: env.network,
                    accountStore: env.accounts
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
                    onPostTap: { post in threadURI = post.uri },
                    onLikedByTap: { postURI in likedByPostURI = postURI },
                    onRepostedByTap: { postURI in repostedByPostURI = postURI },
                    onQuotesTap: { postURI in quotesPostURI = postURI }
                )
            }
            .navigationDestination(item: $feedProfileDID) { did in
                ProfileScreen(
                    actorDID: did,
                    network: env.network,
                    accountStore: env.accounts,
                    viewerDID: session.currentAccount?.did,
                    // #0206: a pushed profile's Starter Packs tab opens the
                    // pack on the same stack. Creation is only offered on
                    // the Profile tab's own-profile mount.
                    onStarterPackTap: { uri in starterPackURI = uri }
                )
            }
            // #0206: starter pack opened from a profile's Starter Packs tab.
            .navigationDestination(item: $starterPackURI) { uri in
                StarterPackScreen(
                    starterPackURI: uri,
                    network: env.network,
                    accountStore: env.accounts
                )
            }
            .navigationDestination(item: $likedByPostURI) { postURI in
                LikedByScreen(
                    postURI: postURI,
                    network: env.network,
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            .navigationDestination(item: $repostedByPostURI) { postURI in
                RepostedByScreen(
                    postURI: postURI,
                    network: env.network,
                    onAuthorTap: { profile in feedProfileDID = profile.did }
                )
            }
            .navigationDestination(item: $quotesPostURI) { postURI in
                QuotesOfScreen(
                    postURI: postURI,
                    network: env.network,
                    onPostTap: { post in threadURI = post.uri },
                    onAuthorTap: { profile in feedProfileDID = profile.did }
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
                    onModeration: { showModeration = true },
                    // #0206: Starter Packs tab — open a pack on this stack,
                    // and let the own profile launch the create wizard.
                    onStarterPackTap:    { uri in starterPackURI = uri },
                    onCreateStarterPack: { showStarterPackCreate = true }
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
                        .help("More")
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
                // #0206: starter pack opened from the own profile's Starter
                // Packs tab (or pushed right after the wizard creates one —
                // RN parity with `navigation.replace('StarterPack', …)`).
                .navigationDestination(item: $starterPackURI) { uri in
                    StarterPackScreen(
                        starterPackURI: uri,
                        network: env.network,
                        accountStore: env.accounts
                    )
                }
                // #0206: multi-step Starter Pack create wizard (#0128),
                // entered from the Starter Packs tab's Create button. A
                // successful create parks the new pack's URI and the push
                // fires once the sheet has fully dismissed (mirrors RN's
                // `navigation.replace('StarterPack', …)`).
                .sheet(isPresented: $showStarterPackCreate, onDismiss: {
                    if let uri = pendingCreatedStarterPackURI {
                        pendingCreatedStarterPackURI = nil
                        starterPackURI = uri
                    }
                }) {
                    StarterPackCreateSheet(
                        network: env.network,
                        accountStore: env.accounts,
                        onDismiss: {},
                        onCreated: { uri in pendingCreatedStarterPackURI = uri }
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

    // MARK: - Unread notifications poll (#0196)

    /// RN polls the unread count every 30 seconds while foregrounded —
    /// `UPDATE_INTERVAL = 30 * 1e3` in
    /// `src/state/queries/notifications/unread.tsx` — with an initial check
    /// as soon as a session exists. (RN additionally skips ~50% of poll
    /// ticks once the count is non-zero and stops entirely at 30+; we keep
    /// the fixed 30 s cadence — `getUnreadCount` is a single cheap query,
    /// unlike RN's full 40-item page fetch.)
    private static let unreadPollInterval: Duration = .seconds(30)

    /// Lazily creates the shared `NotificationsViewModel` on first access.
    /// Mirrors `savedStoreOrCreate()` — one instance backs both the
    /// shell-level poll and the Notifications tab screen.
    private func notificationsViewModelOrCreate() -> NotificationsViewModel {
        if let existing = notificationsViewModel { return existing }
        let vm = NotificationsViewModel(network: env.network)
        notificationsViewModel = vm
        return vm
    }

    /// App-shell unread-count poll loop (#0196). Runs for the lifetime of
    /// the signed-in account (`.task(id: session.currentAccount?.did)`):
    /// fetches once immediately — the badge populates right after session
    /// restore, before the Notifications tab is ever opened — then every
    /// `unreadPollInterval`, mirroring RN. On iOS the task is suspended
    /// with the app, so backgrounded ticks simply don't run; the
    /// `scenePhase == .active` handler covers the refetch-on-foreground.
    private func pollUnreadNotifications() async {
        let vm = notificationsViewModelOrCreate()
        guard session.currentAccount != nil else {
            notificationBadge = 0
            return
        }
        while !Task.isCancelled {
            await vm.fetchUnreadCount()
            notificationBadge = vm.unreadCount
            try? await Task.sleep(for: Self.unreadPollInterval)
        }
    }

    /// One-shot unread refetch, fired on return to the foreground (#0196).
    private func refreshUnreadBadge() {
        guard session.currentAccount != nil else { return }
        Task {
            let vm = notificationsViewModelOrCreate()
            await vm.fetchUnreadCount()
            notificationBadge = vm.unreadCount
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

// MARK: - VideoFeedEntry

/// Navigation payload for a push into the immersive `VideoFeedView` (#0205).
/// Mirrors the relevant slice of RN's `VideoFeedSourceContext`: the source is
/// always the `thevids` feedgen, and `initialPostURI` seeds the pager at the
/// tapped post (`initialPostUri` in RN). `nil` when entry comes from the
/// `openVideoFeed` UI-test intent, which has no tapped card.
struct VideoFeedEntry: Hashable {
    var initialPostURI: String?
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

// MARK: - UI test driver modifier

/// Bridges the optional `UITestNavigator` into `MainTabView`'s private
/// navigation `@State`. Only meaningful under UI test: when `navigator` is
/// `nil` (the production case) the `.task` returns immediately and no overlay
/// or observation runs.
///
/// On appear it kicks off the navigator's scripted `run()` loop. Because the
/// navigator is `@Observable`, mutating its `selectedTab` / `threadURI` /
/// `shouldOpen*` properties inside `run()` invalidates this view, and the
/// `.onChange` handlers below copy each value into the matching binding —
/// driving the app through its normal navigation paths exactly as a user tap
/// would. A hidden `Text` carrying the `ui-test-driver-error` accessibility
/// label exposes any decode / timeout failure to the XCUITest process.
private struct UITestDriverModifier: ViewModifier {
    let navigator: UITestNavigator?
    @Binding var selectedTab: AppTab?
    @Binding var threadURI: ATURI?
    @Binding var showSettings: Bool
    @Binding var showComposer: Bool
    @Binding var showModeration: Bool
    @Binding var showBookmarks: Bool
    @Binding var videoFeedEntry: VideoFeedEntry?

    func body(content: Content) -> some View {
        content
            .task {
                guard let navigator else { return }
                // Apply any state the script already produced before the first
                // observation fires, then replay the remaining intents.
                applyNavigatorState(navigator)
                await navigator.run()
                applyNavigatorState(navigator)
            }
            .onChange(of: navigator?.selectedTab) { _, newValue in
                if let newValue { selectedTab = newValue }
            }
            .onChange(of: navigator?.threadURI) { _, newValue in
                if let newValue { threadURI = newValue }
            }
            .onChange(of: navigator?.shouldOpenSettings) { _, newValue in
                if newValue == true { showSettings = true }
            }
            .onChange(of: navigator?.shouldOpenComposer) { _, newValue in
                if newValue == true { showComposer = true }
            }
            .onChange(of: navigator?.shouldOpenModeration) { _, newValue in
                if newValue == true { showModeration = true }
            }
            .onChange(of: navigator?.shouldOpenBookmarks) { _, newValue in
                if newValue == true { showBookmarks = true }
            }
            .onChange(of: navigator?.shouldOpenVideoFeed) { _, newValue in
                if newValue == true { videoFeedEntry = VideoFeedEntry(initialPostURI: nil) }
            }
            // The `ui-test-driver-error` surface lives at the app root (see
            // `Bluesky_SwiftUIApp`) so it is readable even before login, e.g. on
            // a script decode failure. No per-screen overlay is needed here.
    }

    /// Copies the navigator's current navigation state into the bindings.
    private func applyNavigatorState(_ navigator: UITestNavigator) {
        if let tab = navigator.selectedTab { selectedTab = tab }
        if let uri = navigator.threadURI { threadURI = uri }
        if navigator.shouldOpenSettings { showSettings = true }
        if navigator.shouldOpenComposer { showComposer = true }
        if navigator.shouldOpenModeration { showModeration = true }
        if navigator.shouldOpenBookmarks { showBookmarks = true }
        if navigator.shouldOpenVideoFeed { videoFeedEntry = VideoFeedEntry(initialPostURI: nil) }
    }
}

