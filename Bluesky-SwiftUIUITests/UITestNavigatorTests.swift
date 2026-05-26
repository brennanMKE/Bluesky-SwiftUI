// UITestNavigatorTests.swift
//
// Behavioral verification of the #0175 acceptance criteria for the scripted
// navigation driver. Session-dependent tests skip when no credentials are
// injected; the error-surface test runs without credentials because a malformed
// script is rejected before sign-in matters.

import XCTest

final class UITestNavigatorTests: XCTestCase {

    private var harness: BlueskyUITestHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        harness = BlueskyUITestHarness(testCase: self)
    }

    // MARK: - Session-dependent

    /// AC: `[{"intent":"selectTab","tab":"notifications"}]` routes the app to
    /// the Notifications tab before the first assertion. The Notifications top
    /// bar / header is the proof the tab is active.
    @MainActor
    func testSelectTabRoutesToNotifications() throws {
        let creds = try requireCredentials()
        harness.launch(
            script: [.notifications],
            handle: creds.handle, password: creds.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        // The Notifications header text is present once the tab is selected.
        let header = harness.app.staticTexts["Notifications"]
        XCTAssertTrue(
            header.waitForExistence(timeout: 10),
            "Notifications screen was not routed to before the first assertion"
        )
    }

    /// AC: `waitForFeedLoad` blocks until posts arrive (no script error), then
    /// the Home feed is on screen. A timeout would surface as a script error.
    @MainActor
    func testWaitForFeedLoadBlocksUntilPosts() throws {
        let creds = try requireCredentials()
        harness.launch(
            script: [.home, .waitForFeedLoad(minPosts: 1)],
            handle: creds.handle, password: creds.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        // If the feed loaded a post the script completes with no error; if it
        // timed out at 10s the driver sets `ui-test-driver-error`.
        XCTAssertFalse(
            harness.app.staticTexts["ui-test-driver-error"].waitForExistence(timeout: 12),
            "waitForFeedLoad reported an error: \(harness.app.staticTexts["ui-test-driver-error"].label)"
        )
    }

    /// AC (#0185): `[{"intent":"selectTab","tab":"profile"},{"intent":"openSettings"}]`
    /// reliably pushes `SettingsScreen` on iOS via the driver intent — no
    /// own-profile-menu workaround. This is the regression guard for the
    /// timing/ordering fix so other suites can rely on the intent.
    @MainActor
    func testOpenSettingsIntentPushesSettingsScreen() throws {
        let creds = try requireCredentials()
        harness.launch(
            script: [.profile, .openSettings],
            handle: creds.handle, password: creds.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        XCTAssertTrue(
            element("settings-screen").waitForExistence(timeout: 15),
            "settings-screen did not push after the openSettings driver intent (#0185)"
        )
    }

    /// AC (#0185): `[{"intent":"selectTab","tab":"profile"},{"intent":"openModeration"}]`
    /// reliably pushes `ModerationScreen` on iOS via the driver intent.
    @MainActor
    func testOpenModerationIntentPushesModerationScreen() throws {
        let creds = try requireCredentials()
        harness.launch(
            script: [.profile, .openModeration],
            handle: creds.handle, password: creds.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        XCTAssertTrue(
            element("moderation-screen").waitForExistence(timeout: 15),
            "moderation-screen did not push after the openModeration driver intent (#0185)"
        )
    }

    // MARK: - Credential-independent

    /// AC: the `ui-test-driver-error` accessibility label is readable from the
    /// test process when a script fails to decode. A malformed script is
    /// rejected during app boot, before any sign-in, so this needs no creds.
    @MainActor
    func testMalformedScriptSurfacesError() {
        let app = harness.app
        app.launchEnvironment["BLUESKY_UI_TEST_SCRIPT"] = "{ this is not valid json"
        app.launch()
        XCTAssertTrue(
            app.staticTexts["ui-test-driver-error"].waitForExistence(timeout: 20),
            "ui-test-driver-error label was not readable after a decode failure"
        )
    }

    // MARK: - Helpers

    /// First element of any type carrying `identifier`. SwiftUI renders an
    /// `.accessibilityIdentifier` container as a generic element rather than a
    /// concrete UIKit type, so we match any descendant — same pattern as
    /// `SettingsModerationUITests`.
    private func element(_ identifier: String) -> XCUIElement {
        harness.app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func requireCredentials() throws -> (handle: String, password: String) {
        guard let creds = BlueskyUITestHarness.credentialsFromEnvironment() else {
            throw XCTSkip("BLUESKY_TEST_HANDLE / BLUESKY_TEST_PASSWORD not set — skipping session-dependent test.")
        }
        return creds
    }
}
