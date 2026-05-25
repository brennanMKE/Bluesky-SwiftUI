// ComposerUITests.swift
//
// UI test suite for the post composer — sheet, character count, Post-button
// enable/disable transitions, cancel, and post submission (#0182). Built on the
// #0175 harness and mirroring HomeFeedUITests (#0176), ThreadViewUITests
// (#0177), ProfileUITests (#0178), SearchUITests (#0179), NotificationsUITests
// (#0180), and MessagesUITests (#0181).
//
// Covers what the issue asks for:
//   • Composer opens clean — `openComposer` presents `composer-sheet`; the
//     `composer-text-editor` is empty on a fresh open (#0151 regression guard);
//     the `composer-char-count` reads "0/300".
//   • Text input + Post-button state — Post is disabled when empty, enables
//     after typing, and goes disabled again when over the 300-character cap
//     (over-limit). The `composer-char-count` value tracks the typed length.
//   • Cancel — tapping `composer-cancel-button` on an empty composer dismisses
//     `composer-sheet` and leaves the feed visible.
//   • Submission — see the note below; gated off by default.
//   • Screenshots — composer empty + composer with text.
//
// Run via the Screenshots test plan, which forwards credentials from the
// xcodebuild command line:
//
//   xcodebuild test -workspace Bluesky.xcworkspace -scheme "Bluesky (Beta)" \
//     -testPlan Screenshots \
//     -destination 'platform=iOS Simulator,name=iPhone 17' \
//     -only-testing:Bluesky-SwiftUIUITests/ComposerUITests \
//     BLUESKY_TEST_HANDLE='…' BLUESKY_TEST_PASSWORD='…'
//
// Every session-dependent test skips (rather than fails) when credentials are
// absent, mirroring the sibling suites.
//
// SIDE-EFFECT NOTE (per #0182): submitting a post writes to the live test
// account's feed. To keep that feed clean, the default flow verifies the
// composer WITHOUT a network submit — it asserts the sheet, the character
// counter, and the Post-button enable/disable transitions only. The actual
// end-to-end submit is in `testPostSubmissionEndToEnd`, which SKIPS unless
// `BLUESKY_ENABLE_POST_SUBMIT=1` is set. When enabled, it posts a single
// timestamped marker ("UITest <ISO8601>") so a human can identify and delete
// it; it never posts more than one marker per run.

import XCTest

final class ComposerUITests: XCTestCase {

    private var harness: BlueskyUITestHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        harness = BlueskyUITestHarness(testCase: self)
    }

    // MARK: - Helpers

    private func requireCredentials() throws -> (handle: String, password: String) {
        guard let creds = BlueskyUITestHarness.credentialsFromEnvironment() else {
            throw XCTSkip("BLUESKY_TEST_HANDLE / BLUESKY_TEST_PASSWORD not set — skipping session-dependent composer test.")
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

    /// The composer sheet root (`composer-sheet`).
    private var composerSheet: XCUIElement { element("composer-sheet") }
    /// The primary text editor (`composer-text-editor`).
    private var textEditor: XCUIElement { element("composer-text-editor") }
    /// The character counter (`composer-char-count`). Its accessibility value is
    /// `"<used>/300"`.
    private var charCount: XCUIElement { element("composer-char-count") }
    /// The submit button (`composer-post-button`).
    private var postButton: XCUIElement { element("composer-post-button") }
    /// The cancel button (`composer-cancel-button`).
    private var cancelButton: XCUIElement { element("composer-cancel-button") }

    /// Launches onto the Home tab and fires `openComposer`, then waits for the
    /// composer sheet to mount. Asserts the main tab view appeared and no
    /// script error surfaced. Returns once `composer-sheet` is on screen.
    @discardableResult
    private func launchComposer(
        creds: (handle: String, password: String),
        dark: Bool = false
    ) -> XCUIElement {
        if dark {
            // The app reads this argument at boot to force the dark color
            // scheme for screenshot parity (matches the sibling suites).
            harness.app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        }
        harness.launch(
            script: [.home, .openComposer],
            handle: creds.handle, password: creds.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()

        let sheet = composerSheet
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 15),
            "composer-sheet did not appear after the openComposer intent"
        )
        return sheet
    }

    /// Focuses the text editor and types `text`. The composer's TextEditor is
    /// reachable via the `composer-text-editor` identifier; we tap to focus
    /// before typing so the keystrokes land in the editor.
    private func type(_ text: String, into editor: XCUIElement) {
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "composer-text-editor not present")
        if editor.isHittable { editor.tap() }
        editor.typeText(text)
    }

    /// Parses the "<used>/300" value off the `composer-char-count` element.
    /// Returns `nil` when the value isn't yet in that shape.
    private func parsedCharCount() -> Int? {
        let value = (charCount.value as? String) ?? ""
        guard let slash = value.firstIndex(of: "/") else { return nil }
        return Int(value[value.startIndex..<slash])
    }

    /// Polls until `composer-char-count` reports `expected` (or times out).
    @discardableResult
    private func waitForCharCount(_ expected: Int, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if parsedCharCount() == expected { return true }
            usleep(150_000)
        }
        return parsedCharCount() == expected
    }

    /// Polls until `postButton.isEnabled == enabled` (or times out). The Post
    /// button enable state is driven by `viewModel.canPost`, which updates
    /// asynchronously as text changes, so we wait rather than read once.
    @discardableResult
    private func waitForPostButton(enabled: Bool, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if postButton.exists && postButton.isEnabled == enabled { return true }
            usleep(150_000)
        }
        return postButton.exists && postButton.isEnabled == enabled
    }

    // MARK: - Composer opens clean

    /// The composer sheet appears after `openComposer`. (#0034 / #0035)
    @MainActor
    func testComposerSheetOpens() throws {
        let creds = try requireCredentials()
        let sheet = launchComposer(creds: creds)
        XCTAssertTrue(sheet.exists, "composer-sheet not present after openComposer")
    }

    /// The text editor is empty on a fresh open — the direct regression guard
    /// for #0151 (composer opened pre-filled with stale text).
    @MainActor
    func testTextEditorEmptyOnFreshOpen() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        XCTAssertTrue(textEditor.waitForExistence(timeout: 8), "composer-text-editor did not appear")
        let value = (textEditor.value as? String) ?? ""
        XCTAssertTrue(
            value.isEmpty,
            "composer-text-editor should be empty on a fresh open (#0151), got: \"\(value)\""
        )
    }

    /// The character counter starts at 0 (rendered as "0/300"). (#0182)
    @MainActor
    func testCharacterCountStartsAtZero() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        XCTAssertTrue(charCount.waitForExistence(timeout: 8), "composer-char-count did not appear")
        XCTAssertTrue(
            waitForCharCount(0),
            "composer-char-count should read 0 on a fresh open, got: \"\((charCount.value as? String) ?? "nil")\""
        )
    }

    // MARK: - Text input and Post-button state

    /// The Post button is disabled while the editor is empty. (#0182)
    @MainActor
    func testPostButtonDisabledWhenEmpty() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        XCTAssertTrue(postButton.waitForExistence(timeout: 8), "composer-post-button did not appear")
        XCTAssertTrue(
            waitForPostButton(enabled: false),
            "composer-post-button should be disabled when the composer is empty"
        )
    }

    /// Typing text enables the Post button and advances the character counter.
    /// (#0182)
    @MainActor
    func testPostButtonEnablesAfterTypingAndCountUpdates() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        // Disabled before any input.
        XCTAssertTrue(waitForPostButton(enabled: false), "Post button not disabled on empty composer")

        type("Hello", into: textEditor)

        XCTAssertTrue(
            waitForCharCount(5),
            "composer-char-count should read 5 after typing \"Hello\", got: \"\((charCount.value as? String) ?? "nil")\""
        )
        XCTAssertTrue(
            waitForPostButton(enabled: true),
            "composer-post-button should be enabled after typing non-empty text"
        )
    }

    /// Typing past the 300-character cap disables the Post button again, and the
    /// counter reflects the over-limit length. (#0182)
    @MainActor
    func testPostButtonDisabledWhenOverLimit() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        // 305 characters — just over the 300 cap. Built from a repeated short
        // token so XCUIElement.typeText stays reliable.
        let overLimit = String(repeating: "a", count: 305)
        type(overLimit, into: textEditor)

        XCTAssertTrue(
            waitForCharCount(305),
            "composer-char-count should read 305 after typing past the cap, got: \"\((charCount.value as? String) ?? "nil")\""
        )
        XCTAssertTrue(
            waitForPostButton(enabled: false),
            "composer-post-button should be disabled when the text is over the 300-character limit"
        )
    }

    // MARK: - Cancel

    /// Tapping Cancel on an empty composer dismisses the sheet without posting,
    /// and the underlying feed remains visible. An empty composer has no
    /// draftable content, so Cancel dismisses directly (no save prompt). (#0182)
    @MainActor
    func testCancelDismissesEmptyComposer() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        XCTAssertTrue(cancelButton.waitForExistence(timeout: 8), "composer-cancel-button did not appear")
        XCTAssertTrue(cancelButton.isHittable, "composer-cancel-button is not hittable")
        cancelButton.tap()

        // The sheet should disappear.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: composerSheet)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(composerSheet.exists, "composer-sheet still present after Cancel")

        // The Home tab / main tab view is still on screen behind the dismissed
        // sheet — nothing navigated.
        XCTAssertTrue(harness.waitForMainTabView(timeout: 5), "MainTabView not visible after cancelling the composer")
    }

    // MARK: - Post submission (gated)

    /// End-to-end post submission. SKIPPED by default to keep the live test
    /// account's feed clean. Enable with `BLUESKY_ENABLE_POST_SUBMIT=1` to
    /// actually submit. When enabled, it posts a single timestamped marker so
    /// the entry is easy to identify and delete afterward; it submits at most
    /// one post per run. (#0182)
    @MainActor
    func testPostSubmissionEndToEnd() throws {
        let creds = try requireCredentials()
        guard ProcessInfo.processInfo.environment["BLUESKY_ENABLE_POST_SUBMIT"] == "1" else {
            throw XCTSkip("BLUESKY_ENABLE_POST_SUBMIT not set to 1 — skipping the live post-submission test to avoid writing to the test account's feed. Set BLUESKY_ENABLE_POST_SUBMIT=1 to enable; it posts one timestamped 'UITest <ISO8601>' marker you can then delete.")
        }

        launchComposer(creds: creds)

        let marker = "UITest \(ISO8601DateFormatter().string(from: Date()))"
        type(marker, into: textEditor)

        XCTAssertTrue(waitForPostButton(enabled: true), "Post button not enabled before submit")
        postButton.tap()

        // After a successful post the view model dismisses the sheet.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: composerSheet)
        waitForExpectations(timeout: 20)
        XCTAssertFalse(composerSheet.exists, "composer-sheet still present after submitting a post")
    }

    // MARK: - Screenshots

    @MainActor
    func testScreenshotComposerEmpty() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)
        _ = composerSheet.waitForExistence(timeout: 8)
        harness.screenshot(screen: "composer-empty")
    }

    @MainActor
    func testScreenshotComposerWithText() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)
        type("Hello from the UI test suite", into: textEditor)
        _ = waitForCharCount(28)
        harness.screenshot(screen: "composer-with-text")
    }

    @MainActor
    func testScreenshotComposerEmptyDark() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds, dark: true)
        _ = composerSheet.waitForExistence(timeout: 8)
        harness.screenshot(screen: "composer-empty-dark")
    }
}
