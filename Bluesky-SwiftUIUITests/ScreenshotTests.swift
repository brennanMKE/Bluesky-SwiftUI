// ScreenshotTests.swift
//
// Automated screenshot runner (#0175). One test per screen, each driving the
// app to a known state via `BlueskyUITestHarness` and capturing a PNG to
// `screenshots/`. Running the suite produces a full set with no human in the
// loop:
//
//   xcodebuild test -workspace Bluesky.xcworkspace -scheme "Bluesky (Beta)" \
//     -testPlan Screenshots \
//     -destination 'platform=iOS Simulator,name=iPhone 17' \
//     TEST_RUNNER_BLUESKY_TEST_HANDLE='…' TEST_RUNNER_BLUESKY_TEST_PASSWORD='…'
//
// Each test skips (rather than fails) when credentials are absent, so the suite
// stays green in environments without a test account.

import XCTest

final class ScreenshotTests: XCTestCase {

    private var harness: BlueskyUITestHarness!
    private var credentials: (handle: String, password: String)!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let creds = BlueskyUITestHarness.credentialsFromEnvironment() else {
            throw XCTSkip("BLUESKY_TEST_HANDLE / BLUESKY_TEST_PASSWORD not set — skipping screenshot capture.")
        }
        credentials = creds
        harness = BlueskyUITestHarness(testCase: self)
    }

    // MARK: - Per-screen captures

    @MainActor
    func testCapture_home() {
        harness.launch(
            script: [.home, .waitForFeedLoad(minPosts: 1)],
            handle: credentials.handle, password: credentials.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        harness.screenshot(screen: "home")
    }

    @MainActor
    func testCapture_notifications() {
        harness.launch(
            script: [.notifications],
            handle: credentials.handle, password: credentials.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        harness.screenshot(screen: "notifications")
    }

    @MainActor
    func testCapture_search() {
        harness.launch(
            script: [.search],
            handle: credentials.handle, password: credentials.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        harness.screenshot(screen: "search")
    }

    @MainActor
    func testCapture_messages() {
        harness.launch(
            script: [.messages],
            handle: credentials.handle, password: credentials.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        harness.screenshot(screen: "messages")
    }

    @MainActor
    func testCapture_profile() {
        harness.launch(
            script: [.profile],
            handle: credentials.handle, password: credentials.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        harness.screenshot(screen: "profile")
    }
}
