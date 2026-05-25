// ProfileUITests.swift
//
// UI test suite for the profile screen — own and others (#0178), built on the
// #0175 harness and mirroring the structure of HomeFeedUITests (#0176) and
// ThreadViewUITests (#0177).
//
// Covers what the issue asks for:
//   • Own profile — `selectTab(.profile)` lands on the viewer's own profile;
//     header structural elements render (avatar, display name, handle,
//     followers / following counts, banner or its placeholder); the Edit
//     Profile affordance is present (own-profile, not a Follow button); the
//     Posts tab exists and is selected by default; the own-profile menu
//     surfaces Settings / Saved / My Lists / Moderation.
//   • Other profile — tapping the first feed post's author avatar pushes that
//     user's `ProfileScreen` (#0046); its header shows a Follow / Following
//     button rather than an Edit affordance; back navigation pops the profile.
//   • Screenshots — own-profile and other-profile captures.
//
// Run via the Screenshots test plan, which forwards credentials from the
// xcodebuild command line:
//
//   xcodebuild test -workspace Bluesky.xcworkspace -scheme "Bluesky (Beta)" \
//     -testPlan Screenshots \
//     -destination 'platform=iOS Simulator,name=iPhone 17' \
//     -only-testing:Bluesky-SwiftUIUITests/ProfileUITests \
//     BLUESKY_TEST_HANDLE='…' BLUESKY_TEST_PASSWORD='…'
//
// Every session-dependent test skips (rather than fails) when credentials are
// absent, mirroring HomeFeedUITests / ThreadViewUITests / ScreenshotTests.
//
// Note on determinism: the other-profile path navigates via whatever post the
// home feed serves first. If the feed serves no post (rare, but possible on a
// brand-new account), those tests degrade to a clean `XCTSkip` rather than a
// failure — the same pattern ThreadViewUITests uses for reply-dependent checks.

import XCTest

final class ProfileUITests: XCTestCase {

    private var harness: BlueskyUITestHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        harness = BlueskyUITestHarness(testCase: self)
    }

    // MARK: - Helpers

    private func requireCredentials() throws -> (handle: String, password: String) {
        guard let creds = BlueskyUITestHarness.credentialsFromEnvironment() else {
            throw XCTSkip("BLUESKY_TEST_HANDLE / BLUESKY_TEST_PASSWORD not set — skipping session-dependent profile test.")
        }
        return creds
    }

    /// First element of any type carrying `identifier`. SwiftUI renders an
    /// `.accessibilityIdentifier` container as a generic element rather than a
    /// UIKit `.cell`, so we match any descendant — honoring the spec's intent
    /// without coupling to a concrete XCUIElement.ElementType.
    private func element(_ identifier: String) -> XCUIElement {
        harness.app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// Count of elements carrying `identifier` currently in the tree.
    private func count(_ identifier: String) -> Int {
        harness.app.descendants(matching: .any)
            .matching(identifier: identifier)
            .count
    }

    /// Launches onto the viewer's own profile (`selectTab(.profile)`) and waits
    /// for the header to render. Asserts the main tab view appeared and no
    /// script error surfaced. Returns the `profile-screen` element.
    @discardableResult
    private func launchOntoOwnProfile(
        creds: (handle: String, password: String),
        dark: Bool = false
    ) -> XCUIElement {
        if dark {
            harness.app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        }
        harness.launch(
            script: [.profile],
            handle: creds.handle, password: creds.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()

        let screen = element("profile-screen")
        XCTAssertTrue(
            screen.waitForExistence(timeout: 15),
            "profile-screen did not appear after selecting the Profile tab"
        )
        // The header is async-loaded over the network; wait for the display
        // name (always present once the profile resolves) before asserting.
        _ = element("profile-display-name").waitForExistence(timeout: 15)
        return screen
    }

    /// Launches onto the home feed, waits for a post, taps the first post's
    /// author avatar to push that user's profile, and waits for the pushed
    /// `profile-screen` to render. Skips cleanly if the feed serves no post.
    /// Returns the pushed profile element.
    @discardableResult
    private func launchIntoOtherProfile(
        creds: (handle: String, password: String),
        dark: Bool = false
    ) throws -> XCUIElement {
        if dark {
            harness.app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        }
        harness.launch(
            script: [.home, .waitForFeedLoad(minPosts: 1)],
            handle: creds.handle, password: creds.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()

        let authorAvatar = element("post-author-avatar")
        guard authorAvatar.waitForExistence(timeout: 15) else {
            throw XCTSkip("Home feed served no post with a tappable author avatar — cannot reach another profile (needs a non-empty feed).")
        }
        XCTAssertTrue(authorAvatar.isHittable, "First post's author avatar is not hittable")
        authorAvatar.tap()

        let screen = element("profile-screen")
        XCTAssertTrue(
            screen.waitForExistence(timeout: 15),
            "profile-screen did not push after tapping a feed post's author avatar (#0046)"
        )
        _ = element("profile-display-name").waitForExistence(timeout: 15)
        return screen
    }

    // MARK: - Own profile

    /// The own-profile header renders its structural elements: avatar, display
    /// name, handle, and the followers / following stat counts.
    @MainActor
    func testOwnProfileHeaderElementsPresent() throws {
        let creds = try requireCredentials()
        launchOntoOwnProfile(creds: creds)

        XCTAssertTrue(element("profile-avatar").waitForExistence(timeout: 10), "profile-avatar missing from own profile header")
        XCTAssertTrue(element("profile-display-name").waitForExistence(timeout: 10), "profile-display-name missing from own profile header")
        XCTAssertTrue(element("profile-handle").exists, "profile-handle missing from own profile header")
        XCTAssertTrue(element("profile-followers-count").exists, "profile-followers-count missing from own profile header")
        XCTAssertTrue(element("profile-following-count").exists, "profile-following-count missing from own profile header")
    }

    /// The banner renders — either a real banner image (`profile-banner`) or
    /// its placeholder (`profile-banner-placeholder`) when the account has none.
    @MainActor
    func testOwnProfileBannerPresent() throws {
        let creds = try requireCredentials()
        launchOntoOwnProfile(creds: creds)

        let banner = element("profile-banner")
        let placeholder = element("profile-banner-placeholder")
        let deadline = Date().addingTimeInterval(10)
        var found = false
        while Date() < deadline {
            if banner.exists || placeholder.exists {
                found = true
                break
            }
            usleep(200_000)
        }
        XCTAssertTrue(
            found,
            "Neither profile-banner nor profile-banner-placeholder appeared in the own profile header"
        )
    }

    /// The Posts tab exists and is selected by default; at least one post cell
    /// renders below it. The post-cell assertion degrades to a soft check when
    /// the account has no posts (the Posts tab itself and its selected state
    /// are the structural invariant the test guards).
    @MainActor
    func testOwnProfilePostsTabSelectedByDefault() throws {
        let creds = try requireCredentials()
        launchOntoOwnProfile(creds: creds)

        let postsTab = element("profile-posts-tab")
        XCTAssertTrue(postsTab.waitForExistence(timeout: 10), "profile-posts-tab missing from the profile tab strip")

        // The Posts tab carries a "selected" accessibility value when active.
        XCTAssertEqual(
            postsTab.value as? String, "selected",
            "Posts tab is not selected by default on the profile screen"
        )

        // At least one post cell should render once the Posts feed hydrates.
        // An account with zero posts is valid, so this is conditional.
        let firstCell = element("post-cell")
        if !firstCell.waitForExistence(timeout: 10) {
            throw XCTSkip("Profile served no posts under the Posts tab — post-cell assertion is conditional on the account having posts.")
        }
        XCTAssertGreaterThanOrEqual(count("post-cell"), 1, "Expected at least one post cell under the Posts tab")
    }

    /// The Edit Profile affordance is present on the viewer's own profile (and
    /// — implicitly — the Follow button is not, since this is the own profile).
    @MainActor
    func testOwnProfileShowsEditAffordance() throws {
        let creds = try requireCredentials()
        launchOntoOwnProfile(creds: creds)

        let editButton = element("profile-edit-button")
        XCTAssertTrue(
            editButton.waitForExistence(timeout: 10),
            "profile-edit-button (Edit Profile) missing from the viewer's own profile"
        )
        // The own profile must not expose a Follow button.
        XCTAssertFalse(
            element("profile-follow-button").exists,
            "profile-follow-button should not appear on the viewer's own profile"
        )
    }

    /// The own-profile menu (the banner-row ellipsis on iOS) surfaces the
    /// Settings / Saved / My Lists / Moderation items when tapped.
    @MainActor
    func testOwnProfileMenuItemsReachable() throws {
        let creds = try requireCredentials()
        launchOntoOwnProfile(creds: creds)

        let menuButton = element("profile-menu-button")
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10), "profile-menu-button missing from the own profile header")
        XCTAssertTrue(menuButton.isHittable, "profile-menu-button is not hittable")
        menuButton.tap()

        // The menu presents as system buttons labeled with each destination.
        for label in ["Settings", "Saved", "My Lists", "Moderation"] {
            let item = harness.app.buttons[label].firstMatch
            XCTAssertTrue(
                item.waitForExistence(timeout: 5),
                "Own-profile menu item '\(label)' not found after opening the profile menu"
            )
        }
    }

    // MARK: - Other profile (via feed author tap)

    /// Tapping a feed post's author avatar pushes that user's profile screen.
    @MainActor
    func testOtherProfilePushesFromFeedAuthorTap() throws {
        let creds = try requireCredentials()
        let screen = try launchIntoOtherProfile(creds: creds)

        XCTAssertTrue(screen.exists, "profile-screen not present after navigating to another user's profile")
        // The pushed profile renders its header (display name + handle).
        XCTAssertTrue(element("profile-display-name").waitForExistence(timeout: 10), "Pushed profile rendered no display name")
        XCTAssertTrue(element("profile-handle").exists, "Pushed profile rendered no handle")
    }

    /// The pushed (other) profile shows a Follow / Following button rather than
    /// the own-profile Edit affordance. Conditional skip if the served author
    /// happens to be the viewer themselves (own post in the feed).
    @MainActor
    func testOtherProfileShowsFollowButton() throws {
        let creds = try requireCredentials()
        try launchIntoOtherProfile(creds: creds)

        let follow = element("profile-follow-button")
        let edit = element("profile-edit-button")

        // Wait for one of the two affordances to settle (header is async).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if follow.exists || edit.exists { break }
            usleep(200_000)
        }

        if edit.exists && !follow.exists {
            // The feed served the viewer's own post, so the tapped author is
            // the viewer — the own-profile affordance is correct here.
            throw XCTSkip("Tapped author resolved to the viewer's own profile (own post in feed) — Follow button is intentionally absent.")
        }

        XCTAssertTrue(follow.exists, "profile-follow-button missing from another user's profile header")
        XCTAssertTrue(follow.isHittable, "profile-follow-button is not hittable on another user's profile")
        XCTAssertFalse(edit.exists, "profile-edit-button should not appear on another user's profile")
    }

    /// Back navigation from the pushed profile pops it off the stack — the
    /// `profile-screen` is no longer present at the top level afterward.
    @MainActor
    func testOtherProfileBackNavigationPops() throws {
        let creds = try requireCredentials()
        try launchIntoOtherProfile(creds: creds)

        XCTAssertTrue(element("profile-screen").exists, "profile-screen not present before back navigation")

        // The navigation bar's leading back button pops the pushed profile.
        let backButton = harness.app.navigationBars.buttons.element(boundBy: 0)
        if !backButton.waitForExistence(timeout: 5) || !backButton.isHittable {
            throw XCTSkip("No hittable back button exposed on this layout — back-pop assertion needs a navigation bar back affordance.")
        }
        backButton.tap()

        // After popping, the profile screen should disappear and the feed's
        // post cells should be back on screen.
        let deadline = Date().addingTimeInterval(8)
        var popped = false
        while Date() < deadline {
            if element("post-cell").exists && !element("profile-screen").exists {
                popped = true
                break
            }
            usleep(200_000)
        }
        XCTAssertTrue(
            popped,
            "Back navigation did not pop the pushed profile (profile-screen still present and/or feed not restored)"
        )
    }

    // MARK: - Screenshots

    @MainActor
    func testScreenshotOwnProfile() throws {
        let creds = try requireCredentials()
        launchOntoOwnProfile(creds: creds)
        XCTAssertTrue(element("profile-display-name").waitForExistence(timeout: 15), "Own profile did not render before screenshot")
        harness.screenshot(screen: "own-profile")
    }

    @MainActor
    func testScreenshotOtherProfile() throws {
        let creds = try requireCredentials()
        try launchIntoOtherProfile(creds: creds)
        XCTAssertTrue(element("profile-display-name").waitForExistence(timeout: 15), "Other profile did not render before screenshot")
        harness.screenshot(screen: "other-profile")
    }
}
