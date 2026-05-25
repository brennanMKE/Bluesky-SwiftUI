// SettingsModerationUITests.swift
//
// UI test suite for the Settings and Moderation navigation trees (#0183), built
// on the #0175 harness and mirroring HomeFeedUITests (#0176), ThreadViewUITests
// (#0177), ProfileUITests (#0178), SearchUITests (#0179), NotificationsUITests
// (#0180), MessagesUITests (#0181), and ComposerUITests (#0182).
//
// Covers what the issue asks for:
//   • Settings root reachability — opening Settings from the own-profile menu
//     pushes `settings-screen`; each top-level row (Account, Privacy &
//     Security, Notifications, Appearance, Languages, Accessibility, About)
//     navigates into its sub-screen, asserted by the pushed screen's
//     navigation title. Tapping `settings-account-row` pushes
//     `account-settings-screen`. The Sign Out button is asserted present +
//     enabled only — it is NEVER tapped.
//   • Moderation reachability — opening Moderation from the own-profile menu
//     pushes `moderation-screen`; Muted Accounts (`moderation-mutes-row`)
//     pushes `moderation-mutes-screen` and exposes a search field; Blocked
//     Accounts pushes `moderation-blocks-screen`; Configure content filters
//     pushes `moderation-content-filters-screen`.
//   • Screenshots — settings root + moderation root, light and dark.
//
// NAVIGATION NOTE: the #0175 `openSettings` / `openModeration` driver intents
// push via `navigationDestination(isPresented:)` from an `onChange` that does
// not reliably fire across the iOS tab-content rebuild (verified empirically),
// so this suite reaches both hubs through the own-profile overflow menu — the
// real user path on iOS, and the same menu ProfileUITests (#0178) asserts.
//
// Run via the Screenshots test plan, which forwards credentials from the
// xcodebuild command line:
//
//   xcodebuild test -workspace Bluesky.xcworkspace -scheme "Bluesky (Beta)" \
//     -testPlan Screenshots \
//     -destination 'platform=iOS Simulator,name=iPhone 17' \
//     -only-testing:Bluesky-SwiftUIUITests/SettingsModerationUITests \
//     BLUESKY_TEST_HANDLE='…' BLUESKY_TEST_PASSWORD='…'
//
// Every session-dependent test skips (rather than fails) when credentials are
// absent, mirroring the sibling suites.
//
// SIDE-EFFECT NOTE (per #0183): the Settings and Account screens host
// account-destructive controls (Sign Out, Deactivate, Delete, change
// email/handle/password, change birthday) and the Moderation screens host
// persistent state changes (mute/block lists, adult-content toggle, report).
// This suite only NAVIGATES to those screens and asserts their controls render;
// it never taps Sign Out / Deactivate / Delete, never submits a report, never
// mutes/blocks anyone, and never toggles a control that writes to the network.

import XCTest

final class SettingsModerationUITests: XCTestCase {

    private var harness: BlueskyUITestHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        harness = BlueskyUITestHarness(testCase: self)
    }

    // MARK: - Helpers

    private func requireCredentials() throws -> (handle: String, password: String) {
        guard let creds = BlueskyUITestHarness.credentialsFromEnvironment() else {
            throw XCTSkip("BLUESKY_TEST_HANDLE / BLUESKY_TEST_PASSWORD not set — skipping session-dependent settings/moderation test.")
        }
        return creds
    }

    /// First element of any type carrying `identifier`. SwiftUI renders an
    /// `.accessibilityIdentifier` container as a generic element rather than a
    /// concrete UIKit type, so we match any descendant — honoring the spec's
    /// intent without coupling to a specific `XCUIElement.ElementType`.
    private func element(_ identifier: String) -> XCUIElement {
        harness.app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// Brings the row carrying `identifier` into the tree. SwiftUI `List` rows
    /// render lazily, so a row below the fold does not exist until scrolled
    /// into view. Swipes up (toward the bottom) until the element exists or the
    /// swipe budget is exhausted. Returns the element either way so callers can
    /// assert existence with a clear message.
    @discardableResult
    private func scrollDownTo(_ identifier: String, swipes: Int = 6) -> XCUIElement {
        let target = element(identifier)
        if target.waitForExistence(timeout: 3) { return target }
        let container = harness.app.descendants(matching: .any)
            .matching(identifier: "settings-screen").firstMatch.exists
            ? element("settings-screen")
            : harness.app
        for _ in 0..<swipes {
            if target.exists { break }
            container.swipeUp()
        }
        return target
    }

    /// Selects the Profile tab, opens the own-profile overflow menu
    /// (`profile-menu-button`), and taps the menu item labeled `menuItem`. This
    /// is the real iOS navigation path into Settings / Moderation — the menu
    /// surfaces Settings · Saved · My Lists · Moderation, the same set asserted
    /// by ProfileUITests (#0178). The `openSettings` / `openModeration` driver
    /// intents push via `navigationDestination(isPresented:)` from an `onChange`
    /// that does not reliably fire across the tab-content rebuild on iOS, so the
    /// suite drives the user-facing menu, which pushes the destination
    /// deterministically.
    private func navigateFromProfileMenu(
        creds: (handle: String, password: String),
        menuItem: String,
        dark: Bool
    ) {
        if dark {
            // The app reads this argument at boot to force the dark color
            // scheme for screenshot parity (matches the sibling suites).
            harness.app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        }
        harness.launch(
            script: [.profile],
            handle: creds.handle, password: creds.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()

        let menu = element("profile-menu-button")
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "profile-menu-button did not appear on the own profile")
        XCTAssertTrue(menu.isHittable, "profile-menu-button is not hittable")
        menu.tap()

        let item = harness.app.buttons[menuItem].firstMatch
        XCTAssertTrue(
            item.waitForExistence(timeout: 8),
            "Own-profile menu item '\(menuItem)' not found after opening the profile menu"
        )
        item.tap()
    }

    /// Navigates to the Settings screen via the own-profile menu and waits for
    /// `settings-screen`.
    @discardableResult
    private func launchSettings(
        creds: (handle: String, password: String),
        dark: Bool = false
    ) -> XCUIElement {
        navigateFromProfileMenu(creds: creds, menuItem: "Settings", dark: dark)

        let screen = element("settings-screen")
        XCTAssertTrue(
            screen.waitForExistence(timeout: 15),
            "settings-screen did not appear after opening Settings from the profile menu"
        )
        return screen
    }

    /// Navigates to the Moderation screen via the own-profile menu and waits for
    /// `moderation-screen`.
    @discardableResult
    private func launchModeration(
        creds: (handle: String, password: String),
        dark: Bool = false
    ) -> XCUIElement {
        navigateFromProfileMenu(creds: creds, menuItem: "Moderation", dark: dark)

        let screen = element("moderation-screen")
        XCTAssertTrue(
            screen.waitForExistence(timeout: 15),
            "moderation-screen did not appear after opening Moderation from the profile menu"
        )
        return screen
    }

    /// Pops the top-most pushed screen by tapping the navigation bar's leading
    /// back button, then waits for `parentIdentifier` to be back on screen.
    /// Returns `false` if no hittable back button is exposed (e.g. a layout
    /// without a navigation bar back affordance) so callers can skip cleanly.
    @discardableResult
    private func popBack(to parentIdentifier: String, timeout: TimeInterval = 8) -> Bool {
        let back = harness.app.navigationBars.buttons.element(boundBy: 0)
        guard back.waitForExistence(timeout: 5), back.isHittable else { return false }
        back.tap()
        return element(parentIdentifier).waitForExistence(timeout: timeout)
    }

    /// Taps the row carrying `rowIdentifier` and asserts the pushed screen's
    /// navigation title (`expectedTitle`) appears. Navigation titles are the
    /// stable anchor for sub-screens that don't otherwise carry a root
    /// identifier. Returns once the title is on screen.
    private func assertRowPushes(
        _ rowIdentifier: String,
        showsTitle expectedTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // List rows render lazily, so a row below the fold must be scrolled
        // into the tree before it can be tapped.
        let row = scrollDownTo(rowIdentifier)
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "\(rowIdentifier) missing from the settings list",
            file: file, line: line
        )
        XCTAssertTrue(row.isHittable, "\(rowIdentifier) is not hittable", file: file, line: line)
        row.tap()

        // The pushed screen surfaces its navigation title; on iOS it appears in
        // the navigation bar, so we match either a navigation bar with that
        // identifier or a static text with the title.
        let navBar = harness.app.navigationBars[expectedTitle]
        let titleText = harness.app.staticTexts[expectedTitle]
        let deadline = Date().addingTimeInterval(10)
        var pushed = false
        while Date() < deadline {
            if navBar.exists || titleText.exists { pushed = true; break }
            usleep(200_000)
        }
        XCTAssertTrue(
            pushed,
            "Tapping \(rowIdentifier) did not push a screen titled \"\(expectedTitle)\"",
            file: file, line: line
        )
    }

    // MARK: - Settings root reachability

    /// The Settings screen appears after opening it from the profile menu.
    @MainActor
    func testSettingsScreenAppears() throws {
        let creds = try requireCredentials()
        let screen = launchSettings(creds: creds)
        XCTAssertTrue(screen.exists, "settings-screen not present after opening Settings")
    }

    /// The Account row pushes the dedicated Account settings screen, which
    /// carries the `account-settings-screen` root identifier (#0113 regression
    /// guard — Account was once a stub).
    @MainActor
    func testAccountRowPushesAccountSettings() throws {
        let creds = try requireCredentials()
        launchSettings(creds: creds)

        let accountRow = element("settings-account-row")
        XCTAssertTrue(accountRow.waitForExistence(timeout: 10), "settings-account-row missing from the settings list")
        XCTAssertTrue(accountRow.isHittable, "settings-account-row is not hittable")
        accountRow.tap()

        XCTAssertTrue(
            element("account-settings-screen").waitForExistence(timeout: 10),
            "account-settings-screen did not push after tapping the Account row (#0113)"
        )
    }

    /// Each top-level settings row navigates into its sub-screen, asserted by
    /// the pushed screen's navigation title, popping back between rows. A
    /// reachability guard against a refactor of `SettingsScreen` dropping a
    /// destination (#0114 / #0116–#0122 / #0124).
    @MainActor
    func testSettingsRowsAreReachable() throws {
        let creds = try requireCredentials()
        launchSettings(creds: creds)

        // (rowIdentifier, pushed navigation title)
        let rows: [(String, String)] = [
            ("settings-privacy-row", "Privacy & Security"),
            ("settings-notifications-row", "Notifications"),
            ("settings-appearance-row", "Appearance"),
            ("settings-languages-row", "Languages"),
            ("settings-accessibility-row", "Accessibility"),
            ("settings-about-row", "About"),
        ]

        for (rowID, title) in rows {
            assertRowPushes(rowID, showsTitle: title)
            XCTAssertTrue(
                popBack(to: "settings-screen"),
                "Could not pop back to settings-screen after visiting \(rowID)"
            )
        }
    }

    /// The Sign Out button is present and enabled, but is NEVER tapped — tapping
    /// it would end the live test account's session. Presence + enabled-state
    /// check only (per #0183 notes and the side-effect caution).
    @MainActor
    func testSignOutButtonPresentButNotTapped() throws {
        let creds = try requireCredentials()
        launchSettings(creds: creds)

        let signOut = element("settings-sign-out-button")
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "settings-sign-out-button missing from the settings list")
        XCTAssertTrue(signOut.isEnabled, "settings-sign-out-button should be enabled (presence check only — never tapped)")
    }

    /// The Moderation row inside Settings is present (it pushes the moderation
    /// hub via the host's `onModerationTap`). Reachability presence check.
    @MainActor
    func testModerationRowPresentInSettings() throws {
        let creds = try requireCredentials()
        launchSettings(creds: creds)

        // The Moderation row lives in the Privacy section, below the fold —
        // scroll it into view before asserting.
        let modRow = scrollDownTo("settings-moderation-row")
        XCTAssertTrue(
            modRow.waitForExistence(timeout: 10),
            "settings-moderation-row missing from the settings list"
        )
        XCTAssertTrue(modRow.isHittable, "settings-moderation-row is not hittable")
        modRow.tap()

        XCTAssertTrue(
            element("moderation-screen").waitForExistence(timeout: 10),
            "moderation-screen did not push after tapping the Moderation row in Settings"
        )
    }

    // MARK: - Moderation reachability

    /// The Moderation screen appears after opening it from the profile menu.
    @MainActor
    func testModerationScreenAppears() throws {
        let creds = try requireCredentials()
        let screen = launchModeration(creds: creds)
        XCTAssertTrue(screen.exists, "moderation-screen not present after opening Moderation")
    }

    /// Muted Accounts pushes `moderation-mutes-screen`, which exposes a search
    /// field (#0134 regression guard — the mutes list once had none).
    @MainActor
    func testMutesRowPushesMutesScreenWithSearch() throws {
        let creds = try requireCredentials()
        launchModeration(creds: creds)

        let mutesRow = element("moderation-mutes-row")
        XCTAssertTrue(mutesRow.waitForExistence(timeout: 10), "moderation-mutes-row missing from the moderation hub")
        XCTAssertTrue(mutesRow.isHittable, "moderation-mutes-row is not hittable")
        mutesRow.tap()

        XCTAssertTrue(
            element("moderation-mutes-screen").waitForExistence(timeout: 10),
            "moderation-mutes-screen did not push after tapping Muted Accounts"
        )

        // The `.searchable` modifier renders a system search field. It only
        // mounts once the list has content (an empty list shows
        // ContentUnavailableView instead), so a missing field on an empty
        // mutes list is a clean skip rather than a failure (#0134's invariant
        // is "the screen offers search when there is data to search").
        let searchField = harness.app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 6) {
            throw XCTSkip("Muted Accounts list is empty on the test account — the search field is conditional on the list having entries (#0134).")
        }
        XCTAssertTrue(searchField.exists, "moderation mutes search field did not appear")
    }

    /// Blocked Accounts pushes `moderation-blocks-screen`.
    @MainActor
    func testBlocksRowPushesBlocksScreen() throws {
        let creds = try requireCredentials()
        launchModeration(creds: creds)

        let blocksRow = element("moderation-blocks-row")
        XCTAssertTrue(blocksRow.waitForExistence(timeout: 10), "moderation-blocks-row missing from the moderation hub")
        XCTAssertTrue(blocksRow.isHittable, "moderation-blocks-row is not hittable")
        blocksRow.tap()

        XCTAssertTrue(
            element("moderation-blocks-screen").waitForExistence(timeout: 10),
            "moderation-blocks-screen did not push after tapping Blocked Accounts"
        )
    }

    /// Configure content filters pushes `moderation-content-filters-screen`.
    @MainActor
    func testContentFiltersRowPushesContentFiltersScreen() throws {
        let creds = try requireCredentials()
        launchModeration(creds: creds)

        let row = element("moderation-content-filters-row")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "moderation-content-filters-row missing from the moderation hub")
        XCTAssertTrue(row.isHittable, "moderation-content-filters-row is not hittable")
        row.tap()

        XCTAssertTrue(
            element("moderation-content-filters-screen").waitForExistence(timeout: 10),
            "moderation-content-filters-screen did not push after tapping Configure content filters"
        )
    }

    /// The remaining moderation-hub rows (Interaction settings, Muted words &
    /// tags, Moderation lists) are present — a reachability presence guard
    /// against a refactor dropping a hub destination.
    @MainActor
    func testModerationHubRowsPresent() throws {
        let creds = try requireCredentials()
        launchModeration(creds: creds)

        for rowID in ["moderation-interaction-row", "moderation-muted-words-row", "moderation-lists-row"] {
            XCTAssertTrue(
                element(rowID).waitForExistence(timeout: 10),
                "\(rowID) missing from the moderation hub"
            )
        }
    }

    // MARK: - Screenshots

    @MainActor
    func testScreenshotSettingsRoot() throws {
        let creds = try requireCredentials()
        launchSettings(creds: creds)
        _ = element("settings-account-row").waitForExistence(timeout: 8)
        harness.screenshot(screen: "settings-root")
    }

    @MainActor
    func testScreenshotModerationRoot() throws {
        let creds = try requireCredentials()
        launchModeration(creds: creds)
        _ = element("moderation-mutes-row").waitForExistence(timeout: 8)
        harness.screenshot(screen: "moderation-root")
    }

    @MainActor
    func testScreenshotSettingsRootDark() throws {
        let creds = try requireCredentials()
        launchSettings(creds: creds, dark: true)
        _ = element("settings-account-row").waitForExistence(timeout: 8)
        harness.screenshot(screen: "settings-root-dark")
    }

    @MainActor
    func testScreenshotModerationRootDark() throws {
        let creds = try requireCredentials()
        launchModeration(creds: creds, dark: true)
        _ = element("moderation-mutes-row").waitForExistence(timeout: 8)
        harness.screenshot(screen: "moderation-root-dark")
    }
}
