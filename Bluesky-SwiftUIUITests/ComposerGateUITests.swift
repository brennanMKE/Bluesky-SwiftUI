// ComposerGateUITests.swift
//
// Module 12 gate live validation on iPhone (#0064). Unlike ComposerUITests
// (#0182), which deliberately avoids network submits, this suite performs the
// live checks the gate issue calls for, with a strict mutation budget:
//
//   • test01: ONE plain-text post (also carries the @mention check and the
//     link-card *preview* check),
//   • test02: ONE image post (also carries the alt-text check),
//   • test03: ONE video post,
//   • test04: ONE two-post thread whose root carries the link-card embed
//     (so the link-card *submit* check and the thread check share a single
//     two-post mutation).
//
// Every live post starts with the marker `UITest-0064 ` so the companion
// cleanup intent (`deleteTestPosts`, see UITestNavigator) can delete exactly
// these posts afterwards — run `ComposerGateCleanupTests` after this suite.
// (`listRecords` returns newest-first, so the cleanup deletes thread replies
// before their root.)
//
// The draft flow is validated against the current design (#0151: explicit
// Drafts list; the legacy per-context auto-restore described in older issue
// text was removed deliberately).
//
// Run (placeholder credentials are fine when the simulator already has a
// signed-in keychain session — the app only uses them when no session
// restores):
//
//   xcodebuild test -workspace Bluesky.xcworkspace -scheme "Bluesky (Beta)" \
//     -destination 'id=<sim-udid>' \
//     -only-testing:Bluesky-SwiftUIUITests/ComposerGateUITests \
//     TEST_RUNNER_BLUESKY_TEST_HANDLE='…' TEST_RUNNER_BLUESKY_TEST_PASSWORD='…'

import XCTest

/// Marker prefix carried by every live post this suite creates, and matched
/// by the cleanup intent. Must stay ≥ 8 characters (the app refuses shorter
/// prefixes as a guard against broad deletes).
private let marker = "UITest-0064"

/// The signed-in test account's handle, used for the @mention autocomplete
/// check (mentioning the account itself avoids notifying anyone else).
private let ownHandle = "rnmigration.bsky.social"

final class ComposerGateUITests: XCTestCase {

    private var harness: BlueskyUITestHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        harness = BlueskyUITestHarness(testCase: self)
    }

    // MARK: - Helpers (mirroring ComposerUITests)

    private func requireCredentials() throws -> (handle: String, password: String) {
        guard let creds = BlueskyUITestHarness.credentialsFromEnvironment() else {
            throw XCTSkip("BLUESKY_TEST_HANDLE / BLUESKY_TEST_PASSWORD not set — skipping live composer gate test.")
        }
        return creds
    }

    private func element(_ identifier: String) -> XCUIElement {
        harness.app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private var composerSheet: XCUIElement { element("composer-sheet") }
    private var textEditor: XCUIElement { element("composer-text-editor") }
    private var charCount: XCUIElement { element("composer-char-count") }
    private var postButton: XCUIElement { element("composer-post-button") }
    private var cancelButton: XCUIElement { element("composer-cancel-button") }

    @discardableResult
    private func launchComposer(creds: (handle: String, password: String)) -> XCUIElement {
        harness.launch(script: [.home, .openComposer], handle: creds.handle, password: creds.password)
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        let sheet = composerSheet
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "composer-sheet did not appear")
        return sheet
    }

    private func type(_ text: String, into editor: XCUIElement) {
        XCTAssertTrue(editor.waitForExistence(timeout: 8), "composer-text-editor not present")
        if editor.isHittable { editor.tap() }
        editor.typeText(text)
    }

    private func waitGone(_ el: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        let exp = XCTNSPredicateExpectation(predicate: gone, object: el)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    @discardableResult
    private func waitForPostButton(enabled: Bool, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if postButton.exists && postButton.isEnabled == enabled { return true }
            usleep(150_000)
        }
        return postButton.exists && postButton.isEnabled == enabled
    }

    /// First static text anywhere in the app whose label contains `fragment`.
    private func staticTextContaining(_ fragment: String) -> XCUIElement {
        harness.app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", fragment))
            .firstMatch
    }

    /// Taps the first photo-library grid cell the picker exposes. PHPicker
    /// cells surface as images labelled "Photo, …" / "Video, …"; fall back to
    /// the first image at all if the label shape differs on this OS.
    private func tapPickerItem(kind: String) -> Bool {
        let labelled = harness.app.images
            .matching(NSPredicate(format: "label BEGINSWITH %@", kind))
            .firstMatch
        if labelled.waitForExistence(timeout: 12) {
            tapViaCoordinate(labelled)
            return true
        }
        let anyImage = harness.app.scrollViews.images.firstMatch
        if anyImage.waitForExistence(timeout: 5) {
            tapViaCoordinate(anyImage)
            return true
        }
        return false
    }

    /// Picker grid cells live in a remote view controller and often report
    /// `isHittable == false` even when fully visible; a coordinate tap lands
    /// regardless.
    private func tapViaCoordinate(_ el: XCUIElement) {
        if el.isHittable {
            el.tap()
        } else {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Taps Post and waits for either a clean dismissal (success) or the
    /// "Post failed" alert (failure — screenshot + XCTFail with the server
    /// message, so defects like the blob-encoding rejection are captured).
    @discardableResult
    private func submitAndExpectDismiss(timeout: TimeInterval, failureScreenshot: String) -> Bool {
        postButton.tap()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !composerSheet.exists { return true }
            let alert = harness.app.alerts.firstMatch
            if alert.exists {
                harness.screenshot(screen: failureScreenshot)
                let message = alert.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
                XCTFail("Post failed with alert: \(message)")
                return false
            }
            usleep(300_000)
        }
        XCTFail("composer-sheet still present after posting (no alert either)")
        return false
    }

    /// Verifies a marker post is visible on the own-profile screen.
    private func assertPostVisibleOnOwnProfile(_ fragment: String, screenshot name: String) {
        XCTAssertTrue(harness.tapTab("Profile"), "could not switch to the Profile tab")
        let post = staticTextContaining(fragment)
        XCTAssertTrue(post.waitForExistence(timeout: 20), "post containing \"\(fragment)\" not visible on own profile")
        harness.screenshot(screen: name)
    }

    // MARK: - 01 · Plain-text post + @mention autocomplete + link card

    /// The single text post of the run. Covers three gate checks at once:
    /// plain-text post, @mention autocomplete, link card preview.
    @MainActor
    func test01TextPostWithMentionAndLinkCard() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        // -- Mention autocomplete --
        type("\(marker) test post via @rnmigr", into: textEditor)
        let suggestion = composerSheet.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", ownHandle))
            .firstMatch
        let suggestionAppeared = suggestion.waitForExistence(timeout: 12)
        harness.screenshot(screen: "0064-mention-suggestions")
        XCTAssertTrue(suggestionAppeared, "mention suggestion overlay did not appear for @rnmigr")
        suggestion.tap()

        // The tapped suggestion replaces the @prefix with the full handle.
        let valueAfterMention = (textEditor.value as? String) ?? ""
        XCTAssertTrue(
            valueAfterMention.contains("@\(ownHandle)"),
            "editor text does not contain the selected mention, got: \"\(valueAfterMention)\""
        )

        // -- Link card --
        type("will be deleted shortly https://github.com", into: textEditor)
        // Host line renders as soon as the URL is detected.
        XCTAssertTrue(
            staticTextContaining("github.com").waitForExistence(timeout: 10),
            "link card (host line) did not appear after typing a URL"
        )
        // OpenGraph metadata title resolves asynchronously.
        let resolvedTitle = staticTextContaining("GitHub").waitForExistence(timeout: 20)
        harness.screenshot(screen: "0064-link-card")
        XCTAssertTrue(resolvedTitle, "link card metadata (title containing 'GitHub') did not resolve")

        // Remove the URL again before submitting so this test's single post
        // stays embed-free: the link-card *submit* check is covered by
        // test04's thread root (one mutation covers both gate checks).
        // The editor still has keyboard focus (don't re-tap: a tap would move
        // the caret away from the end of the text).
        textEditor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: " https://github.com".count))
        let cardGone = NSPredicate(format: "exists == false")
        let cardExp = XCTNSPredicateExpectation(predicate: cardGone, object: staticTextContaining("github.com"))
        XCTAssertEqual(XCTWaiter().wait(for: [cardExp], timeout: 10), .completed, "link card did not disappear after deleting the URL")

        // -- Submit (text + mention only) --
        XCTAssertTrue(waitForPostButton(enabled: true), "Post button not enabled before submit")
        guard submitAndExpectDismiss(timeout: 30, failureScreenshot: "0064-text-post-failed") else { return }

        // -- Draft clears after a successful post --
        let fab = harness.app.buttons["New post"]
        XCTAssertTrue(fab.waitForExistence(timeout: 10), "compose FAB not found after posting")
        fab.tap()
        XCTAssertTrue(composerSheet.waitForExistence(timeout: 10), "composer did not reopen")
        let reopenedValue = (textEditor.value as? String) ?? ""
        XCTAssertTrue(reopenedValue.isEmpty, "composer not empty after a successful post, got: \"\(reopenedValue)\"")
        harness.screenshot(screen: "0064-empty-after-post")
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()
        XCTAssertTrue(waitGone(composerSheet, timeout: 10))

        // -- Verify in profile feed --
        assertPostVisibleOnOwnProfile("\(marker) test post", screenshot: "0064-text-post-in-profile")
    }

    // MARK: - 02 · Image post via PHPicker + alt text

    /// The single image post of the run. Covers the PHPicker image-post check
    /// and the alt-text check.
    @MainActor
    func test02ImagePostWithAltText() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        type("\(marker) image post, deleted shortly", into: textEditor)

        // -- Attach one image through PHPicker --
        let addImage = harness.app.buttons["Add image"]
        XCTAssertTrue(addImage.waitForExistence(timeout: 8), "Add image button not present")
        addImage.tap()
        XCTAssertTrue(tapPickerItem(kind: "Photo"), "could not tap a photo in the PHPicker grid")

        // The attached thumbnail appears in the composer's image grid once
        // the picker dismisses and the data loads.
        let thumbnail = composerSheet.images.firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 15), "attached image thumbnail did not appear")
        harness.screenshot(screen: "0064-image-attached")

        // -- Alt text via the cell's context menu --
        thumbnail.press(forDuration: 1.2)
        let editAlt = harness.app.buttons["Edit Alt Text"]
        XCTAssertTrue(editAlt.waitForExistence(timeout: 8), "Edit Alt Text context action not found")
        editAlt.tap()
        let altField = harness.app.textFields["Describe this image…"]
        XCTAssertTrue(altField.waitForExistence(timeout: 8), "alt text field did not appear")
        altField.tap()
        altField.typeText("Gradient test image uploaded by an automated UI test")
        harness.screenshot(screen: "0064-image-alt-editor")
        let done = harness.app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()

        // -- Submit (image upload can take a while) --
        XCTAssertTrue(waitForPostButton(enabled: true, timeout: 10), "Post button not enabled before submit")
        guard submitAndExpectDismiss(timeout: 45, failureScreenshot: "0064-image-post-failed") else { return }

        // -- Verify in profile feed --
        assertPostVisibleOnOwnProfile("\(marker) image post", screenshot: "0064-image-post-in-profile")
    }

    // MARK: - 03 · Video post

    /// The single video post of the run. Validates the iOS PhotosPicker video
    /// flow (`loadTransferable` → `VideoAttachment`), the preview affordances,
    /// and a live submit carrying an `app.bsky.embed.video` blob (#0197 fix).
    @MainActor
    func test03VideoPost() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        type("\(marker) video post, deleted shortly", into: textEditor)

        let addVideo = harness.app.buttons["Add video"]
        XCTAssertTrue(addVideo.waitForExistence(timeout: 8), "Add video button not present")
        addVideo.tap()
        XCTAssertTrue(tapPickerItem(kind: "Video"), "could not tap a video in the picker grid")

        let attached = staticTextContaining("Video attached")
        XCTAssertTrue(attached.waitForExistence(timeout: 20), "'Video attached' preview did not appear")
        harness.screenshot(screen: "0064-video-attached")

        // Alt text + captions affordances should be present on the preview.
        XCTAssertTrue(harness.app.buttons["Alt text"].firstMatch.exists, "video alt-text affordance missing")
        XCTAssertTrue(harness.app.buttons["Captions"].firstMatch.exists, "video captions affordance missing")

        // -- Submit (video blob upload) --
        XCTAssertTrue(waitForPostButton(enabled: true, timeout: 10), "Post button not enabled before submit")
        guard submitAndExpectDismiss(timeout: 60, failureScreenshot: "0064-video-post-failed") else { return }

        // -- Verify in profile feed --
        assertPostVisibleOnOwnProfile("\(marker) video post", screenshot: "0064-video-post-in-profile")
    }

    // MARK: - 04 · Thread post (2 posts) with link-card root

    /// The single two-post mutation of the run: the root post carries the
    /// resolved link-card embed (`app.bsky.embed.external` with thumb — the
    /// submit half of the link-card check, unblocked by #0197), and the second
    /// editor's text is posted as a reply to the root (the thread check).
    @MainActor
    func test04ThreadPostWithLinkCard() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        // Root post: marker text + a URL with stable OpenGraph data.
        type("\(marker) thread root with link card https://github.com", into: textEditor)
        XCTAssertTrue(
            staticTextContaining("github.com").waitForExistence(timeout: 10),
            "link card (host line) did not appear after typing a URL"
        )
        XCTAssertTrue(
            staticTextContaining("GitHub").waitForExistence(timeout: 20),
            "link card metadata (title containing 'GitHub') did not resolve"
        )

        let editorsBefore = harness.app.textViews.count
        let addToThread = harness.app.buttons["Add to thread"]
        XCTAssertTrue(addToThread.waitForExistence(timeout: 8), "Add to thread button not present")
        addToThread.tap()

        // A second TextEditor mounts for the thread post.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && harness.app.textViews.count <= editorsBefore { usleep(200_000) }
        XCTAssertGreaterThan(harness.app.textViews.count, editorsBefore, "second thread editor did not appear")

        // The reply text must also start with the marker so the cleanup
        // intent matches (and deletes) it.
        let secondEditor = harness.app.textViews.element(boundBy: harness.app.textViews.count - 1)
        secondEditor.tap()
        secondEditor.typeText("\(marker) thread reply, deleted shortly")
        harness.screenshot(screen: "0064-thread-composer")

        // -- Submit (root + reply; root uploads the card thumbnail blob) --
        XCTAssertTrue(waitForPostButton(enabled: true, timeout: 10), "Post button not enabled before submit")
        guard submitAndExpectDismiss(timeout: 60, failureScreenshot: "0064-thread-post-failed") else { return }

        // -- Verify the root in the profile feed (the reply's reply-ref is
        //    verified server-side via the public AppView) --
        assertPostVisibleOnOwnProfile("\(marker) thread root", screenshot: "0064-thread-post-in-profile")
    }

    // MARK: - 05 · Drafts: save on cancel, fresh-open empty, restore, delete

    /// Validates the current draft design (#0151): cancel-with-content offers
    /// "Save Draft"; a fresh composer open is empty; the Drafts sheet restores
    /// the saved draft. (The legacy per-`replyTo.uri` auto-restore described
    /// in the original gate text was removed by design in #0151.)
    @MainActor
    func test05DraftSaveAndRestore() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        let draftText = "\(marker) draft persistence check"
        type(draftText, into: textEditor)

        // Cancel → Save Draft.
        cancelButton.tap()
        let saveDraft = harness.app.buttons["Save Draft"]
        XCTAssertTrue(saveDraft.waitForExistence(timeout: 8), "Save Draft option did not appear on cancel")
        saveDraft.tap()
        XCTAssertTrue(waitGone(composerSheet, timeout: 10), "composer still present after saving draft")

        // Reopen: must be empty on a fresh open (#0151).
        let fab = harness.app.buttons["New post"]
        XCTAssertTrue(fab.waitForExistence(timeout: 10), "compose FAB not found")
        fab.tap()
        XCTAssertTrue(composerSheet.waitForExistence(timeout: 10), "composer did not reopen")
        let freshValue = (textEditor.value as? String) ?? ""
        XCTAssertTrue(freshValue.isEmpty, "fresh composer open should be empty, got: \"\(freshValue)\"")

        // Drafts sheet → tap the saved draft → text restores.
        let draftsButton = harness.app.buttons["Drafts"]
        XCTAssertTrue(draftsButton.waitForExistence(timeout: 8), "Drafts button not present")
        draftsButton.tap()
        let draftRow = staticTextContaining(draftText)
        XCTAssertTrue(draftRow.waitForExistence(timeout: 10), "saved draft not listed in the Drafts sheet")
        harness.screenshot(screen: "0064-drafts-sheet")
        draftRow.tap()

        let restored = (textEditor.value as? String) ?? ""
        XCTAssertTrue(restored.contains("draft persistence check"), "draft text did not restore, got: \"\(restored)\"")
        harness.screenshot(screen: "0064-draft-restored")

        // Clean up: discard the loaded content, then delete the draft row.
        cancelButton.tap()
        let discard = harness.app.buttons["Discard"]
        if discard.waitForExistence(timeout: 5) { discard.tap() }
        XCTAssertTrue(waitGone(composerSheet, timeout: 10))

        fab.tap()
        XCTAssertTrue(composerSheet.waitForExistence(timeout: 10))
        draftsButton.tap()
        let rowAgain = staticTextContaining(draftText)
        if rowAgain.waitForExistence(timeout: 8) {
            rowAgain.swipeLeft()
            let delete = harness.app.buttons["Delete"]
            if delete.waitForExistence(timeout: 5) {
                delete.tap()
                _ = waitGone(rowAgain, timeout: 5)
            }
        }
        XCTAssertFalse(staticTextContaining(draftText).exists, "draft row still present after delete")
        let doneButton = harness.app.buttons["Done"].firstMatch
        if doneButton.waitForExistence(timeout: 5) { doneButton.tap() }
        if cancelButton.waitForExistence(timeout: 5) { cancelButton.tap() }
    }

    // MARK: - 06 · Keyboard / safe area

    /// With the keyboard up, the character counter and the Post button must
    /// remain visible/hittable, per the gate's keyboard & safe-area check.
    @MainActor
    func test06KeyboardSafeArea() throws {
        let creds = try requireCredentials()
        launchComposer(creds: creds)

        type("Keyboard safe area check", into: textEditor)
        XCTAssertGreaterThan(harness.app.keyboards.count, 0, "soft keyboard not on screen after typing")
        harness.screenshot(screen: "0064-keyboard-up")

        XCTAssertTrue(postButton.exists && postButton.isHittable, "Post button not visible/hittable with keyboard up")
        XCTAssertTrue(charCount.exists, "character counter missing from hierarchy with keyboard up")
        XCTAssertTrue(charCount.isHittable, "character counter not visible (hittable) with the keyboard up")
    }
}

// MARK: - Cleanup

/// Deletes the marker posts created by `ComposerGateUITests` via the app's
/// authenticated session (UITestNavigator `deleteTestPosts` intent). Run this
/// AFTER the gate suite and verify the account is clean (e.g. via the public
/// AppView `getAuthorFeed`).
final class ComposerGateCleanupTests: XCTestCase {

    private var harness: BlueskyUITestHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        harness = BlueskyUITestHarness(testCase: self)
    }

    @MainActor
    func testDeleteMarkerPosts() throws {
        guard let creds = BlueskyUITestHarness.credentialsFromEnvironment() else {
            throw XCTSkip("BLUESKY_TEST_HANDLE / BLUESKY_TEST_PASSWORD not set — skipping cleanup.")
        }
        harness.launch(
            script: [.home, .deleteTestPosts(markerPrefix: marker), .wait(seconds: 2)],
            handle: creds.handle, password: creds.password
        )
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")

        // The delete intent runs asynchronously after the tab view mounts;
        // poll the error surface for a while — it must stay absent.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if harness.scriptErrorElement.exists {
                XCTFail("cleanup script error: \(harness.scriptErrorElement.label)")
                return
            }
            usleep(500_000)
        }
        harness.assertNoScriptError()

        // Visual confirmation: own profile no longer shows marker posts.
        XCTAssertTrue(harness.tapTab("Profile"), "could not switch to the Profile tab")
        sleep(5)
        harness.app.swipeDown() // refresh
        sleep(3)
        harness.screenshot(screen: "0064-after-cleanup")
    }
}
