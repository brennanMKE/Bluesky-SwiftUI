#if os(iOS)
import SwiftUI
import BlueskyAuth
import BlueskyCore
import BlueskyKit
import BlueskySettings
import BlueskyUI

/// Slide-in left drawer shown on iOS compact (iPhone) layouts.
///
/// RN parity: matches `Bluesky-ReactNative/src/view/shell/Drawer.tsx`. Three
/// zones top-to-bottom — profile header (avatar / name / handle / stats),
/// nine navigation rows in RN's order (Explore, Home, Chat, Notifications,
/// Feeds, Lists, Saved, Profile, Settings), and a footer with legal links
/// plus Feedback / Help pills.
///
/// The drawer is rendered as a `ZStack` overlay by the host (`MainTabView`),
/// not a system sheet — RN uses a custom slide-in animation and a tap-anywhere
/// scrim that the system `presentationDetents` API can't reproduce. This view
/// only renders the *panel* itself; the host is responsible for the scrim,
/// the move transition, and toggling visibility.
///
/// Navigation is driven through bindings rather than direct mutation so
/// `MainTabView` can keep ownership of every navigation flag it already
/// uses (`showMyFeeds`, `showLists`, `showBookmarks`, `showSettings`). Each
/// row callback first dismisses the drawer, then flips the appropriate flag
/// after a 220ms delay so the slide-out animation doesn't fight the
/// `navigationDestination` push — the same delay the original drawer used.
struct DrawerView: View {
    @Environment(\.blueskyTheme) private var theme
    @Environment(\.openURL) private var openURL

    /// Active tab. Tapping a row that maps to a top-level tab updates this
    /// binding so the host re-renders into that tab. The currently-selected
    /// tab also drives the row highlight (bold + filled icon).
    @Binding var selectedTab: AppTab?

    /// Currently signed-in account. Drives the header (handle, fallback
    /// display name) and the stats row.
    let currentAccount: Account?

    /// Avatar URL for the signed-in viewer. Hydrated by `MainTabView` via the
    /// existing per-session `getProfile` fetch and shared with the tab bar
    /// to avoid duplicate requests.
    let viewerAvatarURL: URL?

    /// Display name, hydrated alongside the avatar URL.
    let viewerDisplayName: String?

    /// Followers count for the viewer. Hydrated from `getProfile` when the
    /// drawer first opens. `nil` until the call completes — the stats row
    /// hides itself in that state rather than flashing zeros.
    let viewerFollowersCount: Int?

    /// `getProfile`'s `followsCount` for the viewer.
    let viewerFollowingCount: Int?

    /// Notification badge count, mirrored from `MainTabView`. Drives the
    /// trailing red bubble on the Notifications row, matching RN's
    /// `useUnreadNotifications`-driven badge.
    let notificationBadge: Int

    /// Called once the first time the drawer becomes visible so the host
    /// can refresh the viewer profile / stats.
    let onAppearOnce: () -> Void

    /// Dismiss the drawer. The host owns the `showDrawer` flag so dismissal
    /// also handles the slide-out animation.
    let onDismiss: () -> Void

    /// After a row that maps to a non-tab destination switches tabs, fire
    /// these to push the destination on the right NavigationStack.
    let onPushMyFeeds: () -> Void
    let onPushLists: () -> Void
    let onPushBookmarks: () -> Void
    let onPushSettings: () -> Void

    var body: some View {
        let panelWidth = min(UIScreen.main.bounds.width * 0.82, 340)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    profileHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    Divider()
                        .padding(.bottom, 4)
                    navRows
                    Divider()
                        .padding(.top, 4)
                    extraLinks
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                }
            }
            footerPills
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
        }
        .frame(width: panelWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.colors.background)
        .ignoresSafeArea(edges: .bottom)
        .onAppear { onAppearOnce() }
    }

    // MARK: - Header

    private var profileHeader: some View {
        let handle = currentAccount?.handle.rawValue ?? ""
        let displayName = viewerDisplayName ?? currentAccount?.displayName ?? handle
        return Button {
            selectTab(.profile)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                AvatarView(
                    url: viewerAvatarURL,
                    handle: handle.isEmpty ? "?" : handle,
                    size: 64
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    if !handle.isEmpty {
                        Text("@\(handle)")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                if let followers = viewerFollowersCount, let following = viewerFollowingCount {
                    statsRow(followers: followers, following: following)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
        .accessibilityHint("Navigates to your profile")
    }

    private func statsRow(followers: Int, following: Int) -> some View {
        let secondary = theme.colors.textSecondary
        let primary = theme.colors.textPrimary
        let followersStr = CompactNumberFormatter.string(from: followers)
        let followingStr = CompactNumberFormatter.string(from: following)
        let followersLabel = followers == 1 ? "follower" : "followers"
        return (
            Text(followersStr).font(.system(size: 15, weight: .semibold)).foregroundColor(primary)
            + Text(" \(followersLabel)  ").font(.system(size: 15)).foregroundColor(secondary)
            + Text("·").font(.system(size: 15)).foregroundColor(secondary)
            + Text("  \(followingStr)").font(.system(size: 15, weight: .semibold)).foregroundColor(primary)
            + Text(" following").font(.system(size: 15)).foregroundColor(secondary)
        )
        .lineLimit(1)
        .accessibilityLabel("\(followers) \(followersLabel), \(following) following")
    }

    // MARK: - Nav rows

    /// RN order from `Drawer.tsx`: Explore (Search), Home, Chat (Messages),
    /// Notifications, Feeds, Lists, Saved (Bookmarks), Profile, Settings.
    private var navRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            navRow(
                title: "Explore",
                icon: "magnifyingglass",
                iconActive: "magnifyingglass.circle.fill",
                isActive: selectedTab == .search
            ) {
                selectTab(.search)
            }
            navRow(
                title: "Home",
                icon: "house",
                iconActive: "house.fill",
                isActive: selectedTab == .home
            ) {
                selectTab(.home)
            }
            navRow(
                title: "Chat",
                icon: "bubble.left.and.bubble.right",
                iconActive: "bubble.left.and.bubble.right.fill",
                isActive: selectedTab == .messages
            ) {
                selectTab(.messages)
            }
            navRow(
                title: "Notifications",
                icon: "bell",
                iconActive: "bell.fill",
                isActive: selectedTab == .notifications,
                badge: notificationBadge
            ) {
                selectTab(.notifications)
            }
            navRow(
                title: "Feeds",
                icon: "number",
                iconActive: "number",
                isActive: false
            ) {
                pushAfterTabSwitch(tab: .home, push: onPushMyFeeds)
            }
            navRow(
                title: "Lists",
                icon: "list.bullet.indent",
                iconActive: "list.bullet.indent",
                isActive: false
            ) {
                pushAfterTabSwitch(tab: .profile, push: onPushLists)
            }
            navRow(
                title: "Saved",
                icon: "bookmark",
                iconActive: "bookmark.fill",
                isActive: selectedTab == .saved
            ) {
                pushAfterTabSwitch(tab: .profile, push: onPushBookmarks)
            }
            navRow(
                title: "Profile",
                icon: "person.circle",
                iconActive: "person.circle.fill",
                isActive: selectedTab == .profile
            ) {
                selectTab(.profile)
            }
            navRow(
                title: "Settings",
                icon: "gearshape",
                iconActive: "gearshape",
                isActive: false
            ) {
                pushAfterTabSwitch(tab: .profile, push: onPushSettings)
            }
        }
    }

    @ViewBuilder
    private func navRow(
        title: String,
        icon: String,
        iconActive: String,
        isActive: Bool,
        badge: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: isActive ? iconActive : icon)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(theme.colors.textPrimary)
                        .frame(width: 28, height: 28, alignment: .center)
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.colors.link))
                            .offset(x: 12, y: -4)
                    }
                }
                Text(title)
                    .font(.system(size: 19, weight: isActive ? .bold : .regular))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - Footer (legal links + pills)

    private var extraLinks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                openURL(BlueskyHelpURLs.termsOfService)
            } label: {
                Text("Terms of Service")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.colors.link)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Terms of Service")
            Button {
                openURL(BlueskyHelpURLs.privacyPolicy)
            } label: {
                Text("Privacy Policy")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.colors.link)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Privacy Policy")
        }
    }

    private var footerPills: some View {
        HStack(spacing: 8) {
            // Solid Feedback pill — RN: `variant="solid" color="secondary"`
            // with a leading message icon. Until a real feedback flow is
            // built, opens the GitHub Issues page in the browser.
            Button {
                openURL(URL(string: "https://github.com/bluesky-social/social-app/issues")!)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "message")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Feedback")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(theme.colors.textPrimary)
                .background(
                    Capsule().fill(theme.colors.backgroundSecondary)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send feedback")

            // Outline Help pill — RN: `variant="outline" color="secondary"`
            // with no icon. Opens the same Zendesk URL Settings → Help uses.
            Button {
                openURL(BlueskyHelpURLs.helpDesk)
            } label: {
                Text("Help")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(theme.colors.textPrimary)
                    .background(
                        Capsule().stroke(theme.colors.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Get help")

            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    /// Switch the active tab and dismiss the drawer. Used for rows that
    /// map directly to a top-level tab (no extra navigation push).
    private func selectTab(_ tab: AppTab) {
        onDismiss()
        selectedTab = tab
    }

    /// Switch tab first, dismiss the drawer, then push the destination after
    /// the slide-out animation completes — same 220ms delay used by the
    /// original drawer to avoid fighting the `navigationDestination` push.
    private func pushAfterTabSwitch(tab: AppTab, push: @escaping () -> Void) {
        onDismiss()
        selectedTab = tab
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            push()
        }
    }
}

#Preview("DrawerView — Light") {
    DrawerView(
        selectedTab: .constant(.home),
        currentAccount: nil,
        viewerAvatarURL: nil,
        viewerDisplayName: "Brennan",
        viewerFollowersCount: 286,
        viewerFollowingCount: 359,
        notificationBadge: 3,
        onAppearOnce: {},
        onDismiss: {},
        onPushMyFeeds: {},
        onPushLists: {},
        onPushBookmarks: {},
        onPushSettings: {}
    )
    .environment(\.colorScheme, .light)
}

#Preview("DrawerView — Dark") {
    DrawerView(
        selectedTab: .constant(.home),
        currentAccount: nil,
        viewerAvatarURL: nil,
        viewerDisplayName: "Brennan",
        viewerFollowersCount: 286,
        viewerFollowingCount: 359,
        notificationBadge: 3,
        onAppearOnce: {},
        onDismiss: {},
        onPushMyFeeds: {},
        onPushLists: {},
        onPushBookmarks: {},
        onPushSettings: {}
    )
    .environment(\.colorScheme, .dark)
}
#endif
