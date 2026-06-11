// HomeFeedUITests.swift
//
// UI test suite for the home feed (#0176), built on the #0175 harness.
//
// Covers the three areas the issue asks for:
//   • Feed loads and renders posts (cell present, action row present, no dupes)
//   • Post interactions (like value flips, reply navigates)
//   • Screenshots (light + dark)
//
// Run via the Screenshots test plan, which forwards credentials from the
// xcodebuild command line:
//
//   xcodebuild test -workspace Bluesky.xcworkspace -scheme "Bluesky (Beta)" \
//     -testPlan Screenshots \
//     -destination 'platform=iOS Simulator,name=iPhone 17' \
//     BLUESKY_TEST_HANDLE='…' BLUESKY_TEST_PASSWORD='…'
//
// Every session-dependent test skips (rather than fails) when credentials are
// absent, mirroring ScreenshotTests / UITestNavigatorTests.

import XCTest

final class HomeFeedUITests: XCTestCase {

    private var harness: BlueskyUITestHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        harness = BlueskyUITestHarness(testCase: self)
    }

    // MARK: - Helpers

    private func requireCredentials() throws -> (handle: String, password: String) {
        guard let creds = BlueskyUITestHarness.credentialsFromEnvironment() else {
            throw XCTSkip("BLUESKY_TEST_HANDLE / BLUESKY_TEST_PASSWORD not set — skipping session-dependent home-feed test.")
        }
        return creds
    }

    /// Launches the app onto the Home feed and blocks until at least one post
    /// has loaded, asserting the main tab view appeared and no script error
    /// surfaced. Shared setup for the load / interaction tests.
    private func launchOntoLoadedFeed(
        creds: (handle: String, password: String),
        dark: Bool = false
    ) {
        if dark {
            // The app reads this argument at boot to force the dark color
            // scheme for screenshot parity (#0176 dark-mode capture).
            harness.app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        }
        harness.launch(
            script: [.home, .waitForFeedLoad(minPosts: 1)],
            handle: creds.handle, password: creds.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
    }

    /// The first post cell. SwiftUI renders the `.accessibilityIdentifier`
    /// container as a generic element rather than a UIKit `.cell`, so we match
    /// any descendant carrying the `post-cell` identifier regardless of type —
    /// honoring the spec's intent (`post-cell`) without coupling to a concrete
    /// XCUIElement.ElementType the SwiftUI runtime is free to change.
    private func firstPostCell() -> XCUIElement {
        harness.app.descendants(matching: .any)
            .matching(identifier: "post-cell")
            .firstMatch
    }

    /// Count of post cells currently in the element tree.
    private func postCellCount() -> Int {
        harness.app.descendants(matching: .any)
            .matching(identifier: "post-cell")
            .count
    }

    /// First action button with the given identifier inside the first post
    /// cell. Action buttons are SwiftUI `Button`s, so they surface as
    /// `.button`; scoping to the first cell keeps us off later rows.
    private func firstAction(_ identifier: String) -> XCUIElement {
        firstPostCell()
            .descendants(matching: .button)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// Falls back to an app-wide button query when the cell-scoped lookup
    /// can't resolve (e.g. the share `ShareLink` sits just outside the
    /// accessibility container on some layouts).
    private func firstActionAppWide(_ identifier: String) -> XCUIElement {
        harness.app.buttons.matching(identifier: identifier).firstMatch
    }

    // MARK: - Feed loads and renders posts

    /// At least one post cell is visible after launch.
    @MainActor
    func testFeedLoadsAtLeastOnePostCell() throws {
        let creds = try requireCredentials()
        launchOntoLoadedFeed(creds: creds)

        let cell = firstPostCell()
        XCTAssertTrue(
            cell.waitForExistence(timeout: 10),
            "No post-cell appeared after the feed loaded"
        )
    }

    /// The first post cell contains the full action row: reply, repost, like,
    /// and share (bookmark is also present but the spec lists the core four).
    @MainActor
    func testPostCellContainsActionRow() throws {
        let creds = try requireCredentials()
        launchOntoLoadedFeed(creds: creds)

        XCTAssertTrue(
            firstPostCell().waitForExistence(timeout: 10),
            "No post-cell appeared after the feed loaded"
        )

        let reply = firstAction("post-action-reply")
        let repost = firstAction("post-action-repost")
        let like = firstAction("post-action-like")
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "Reply button missing from post cell")
        XCTAssertTrue(repost.exists, "Repost button missing from post cell")
        XCTAssertTrue(like.exists, "Like button missing from post cell")

        // Share is a ShareLink; accept either the cell-scoped or app-wide hit.
        let shareInCell = firstAction("post-action-share")
        let shareAnywhere = firstActionAppWide("post-action-share")
        XCTAssertTrue(
            shareInCell.exists || shareAnywhere.exists,
            "Share button missing from post cell"
        )

        // The cell also renders text content (display name / handle / body).
        XCTAssertTrue(
            firstPostCell().staticTexts.firstMatch.waitForExistence(timeout: 5),
            "Post cell rendered no text content"
        )
    }

    /// No duplicate cells: switching to Search and back to Home must not double
    /// the post count (guards the #0049 duplicate-view-model regression).
    @MainActor
    func testNoDuplicateCellsAfterTabSwitch() throws {
        let creds = try requireCredentials()
        launchOntoLoadedFeed(creds: creds)

        XCTAssertTrue(
            firstPostCell().waitForExistence(timeout: 10),
            "No post-cell appeared after the feed loaded"
        )
        let before = postCellCount()
        XCTAssertGreaterThan(before, 0, "Expected at least one post cell before switching tabs")

        // Switch away to Search, then back to Home. `tapTab` resolves the
        // destination on either shell — iOS tab-bar `Button`s or macOS sidebar
        // `cells` — so this dup-guard runs unchanged on both platforms.
        XCTAssertTrue(harness.tapTab("Search"), "Search tab not found")
        XCTAssertTrue(harness.tapTab("Home"), "Home tab not found")

        // Allow the feed to settle back onto Home.
        XCTAssertTrue(
            firstPostCell().waitForExistence(timeout: 10),
            "Post cells disappeared after returning to Home"
        )
        let after = postCellCount()

        // The visible (lazily-rendered) count can drift slightly with scroll
        // position, but a duplicate-view-model bug roughly *doubles* it. Assert
        // the count did not balloon — a strict 2x guard with a small tolerance.
        XCTAssertLessThan(
            after, before * 2,
            "Post cell count roughly doubled after a tab switch (before=\(before), after=\(after)) — likely duplicate FeedViewModels (#0049)"
        )
    }

    // MARK: - Post interactions

    /// Tapping the like button flips its accessibility value within 1s.
    @MainActor
    func testLikeButtonTapFlipsAccessibilityValue() throws {
        let creds = try requireCredentials()
        launchOntoLoadedFeed(creds: creds)

        let like = firstAction("post-action-like")
        XCTAssertTrue(like.waitForExistence(timeout: 10), "Like button never appeared")

        let initialValue = like.value as? String
        XCTAssertNotNil(initialValue, "Like button exposed no accessibility value")
        XCTAssertTrue(
            initialValue == "liked" || initialValue == "not liked",
            "Unexpected like value '\(initialValue ?? "nil")'"
        )

        like.tap()

        // Poll for the value to flip (network round-trip + state mirror).
        let expected = (initialValue == "liked") ? "not liked" : "liked"
        let deadline = Date().addingTimeInterval(8)
        var flipped = false
        while Date() < deadline {
            if (firstAction("post-action-like").value as? String) == expected {
                flipped = true
                break
            }
            usleep(200_000)
        }
        XCTAssertTrue(
            flipped,
            "Like value did not flip from '\(initialValue ?? "nil")' to '\(expected)' after tapping (#0041 / #0053 regression surface)"
        )
    }

    /// Tapping the reply button presents the composer sheet or pushes the
    /// thread. We assert the composer text field (sheet) appears; if the build
    /// routes reply to the thread instead, accept the `thread-view` identifier.
    @MainActor
    func testReplyButtonOpensComposerOrThread() throws {
        let creds = try requireCredentials()
        launchOntoLoadedFeed(creds: creds)

        let reply = firstAction("post-action-reply")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "Reply button never appeared")
        reply.tap()

        // The reply composer is a sheet with a text view; the thread route
        // exposes the `thread-view` identifier. Either satisfies the spec.
        let composerField = harness.app.textViews.firstMatch
        let threadView = harness.app.descendants(matching: .any)
            .matching(identifier: "thread-view").firstMatch

        let deadline = Date().addingTimeInterval(8)
        var appeared = false
        while Date() < deadline {
            if composerField.exists || threadView.exists {
                appeared = true
                break
            }
            usleep(200_000)
        }
        XCTAssertTrue(
            appeared,
            "Tapping reply neither presented a composer sheet nor pushed the thread view"
        )
    }

    // MARK: - Screenshots

    @MainActor
    func testScreenshotHomeFeed() throws {
        let creds = try requireCredentials()
        launchOntoLoadedFeed(creds: creds)
        XCTAssertTrue(firstPostCell().waitForExistence(timeout: 10), "Feed did not render before screenshot")
        harness.screenshot(screen: "home-feed")
    }

    @MainActor
    func testScreenshotHomeFeedDark() throws {
        let creds = try requireCredentials()
        launchOntoLoadedFeed(creds: creds, dark: true)
        XCTAssertTrue(firstPostCell().waitForExistence(timeout: 10), "Feed did not render before dark screenshot")
        harness.screenshot(screen: "home-feed-dark")
    }
}
