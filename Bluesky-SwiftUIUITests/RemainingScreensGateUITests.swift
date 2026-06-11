// RemainingScreensGateUITests.swift
//
// Module 15 gate live validation on iPhone (#0066): Lists, Starter Packs,
// Saved Feeds, Video Feed, Labeler Profile, App Passwords, Bookmarks.
//
// Two of the seven screens (Video Feed, Starter Packs hub/create) have no
// entry point in the iOS shell, so they are validated by code analysis in the
// gate issue rather than here. The remaining five are covered by:
//
//   • testSavedFeedsServerStateRecon  — READ-ONLY: My Feeds screen state
//     (server savedFeedsPrefV2 truth) + screenshots. No putPreferences writes
//     are performed by this suite at all until the wipe-semantics question
//     around single-pref `putPreferences` bodies is resolved.
//   • testLabelerSubscriptionStateRecon — READ-ONLY: Moderation → first
//     subscribed labeler → LabelerProfileScreen subscribe-button state.
//     (LabelerProfileStore reads `savedFeeds` instead of `labelersPref`, so
//     the expected defect evidence is an "Unsubscribe-able" labeler showing
//     "Subscribe".) Deliberately does NOT tap Subscribe — that would write a
//     malformed `savedFeeds` item (type: "labeler") to the live account.
//   • testListsCreateOpenDelete — MUTATION (reversed): create a list named
//     "UITest-0066 List", open its detail (tabs, header), swipe-to-delete it
//     from the hub, verify it is gone.
//   • testAppPasswordsCreateRevoke — MUTATION (reversed): create app password
//     "UITest-0066", copy the token from the alert, revoke via swipe, verify
//     the list refreshes empty of it.
//   • testBookmarksAddViewRemove — MUTATION (reversed): bookmark the first
//     home-feed post, verify it appears under Saved, remove it there, verify
//     the empty state, pull-to-refresh to confirm server truth.
//
// Run (placeholder credentials are fine when the simulator already has a
// signed-in keychain session):
//
//   xcodebuild test -workspace Bluesky.xcworkspace -scheme "Bluesky (Beta)" \
//     -destination 'id=<sim-udid>' \
//     -only-testing:Bluesky-SwiftUIUITests/RemainingScreensGateUITests/<test> \
//     TEST_RUNNER_BLUESKY_TEST_HANDLE='…' TEST_RUNNER_BLUESKY_TEST_PASSWORD='…'

import XCTest

/// Marker carried by every record this suite creates (list name, app-password
/// name) so any orphaned test data is identifiable and removable by hand.
private let marker = "UITest-0066"

final class RemainingScreensGateUITests: XCTestCase {

    private var harness: BlueskyUITestHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        harness = BlueskyUITestHarness(testCase: self)
    }

    // MARK: - Helpers

    private func requireCredentials() throws -> (handle: String, password: String) {
        guard let creds = BlueskyUITestHarness.credentialsFromEnvironment() else {
            throw XCTSkip("BLUESKY_TEST_HANDLE / BLUESKY_TEST_PASSWORD not set — skipping live gate test.")
        }
        return creds
    }

    private func element(_ identifier: String) -> XCUIElement {
        harness.app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// Launches routed to the Profile tab and opens `item` from the
    /// own-profile overflow menu (same deterministic path as the other gate
    /// suites — the `openSettings` driver intent is unreliable on iOS, #0185).
    private func launchToProfileMenuItem(
        _ item: String,
        creds: (handle: String, password: String)
    ) {
        harness.launch(script: [.profile], handle: creds.handle, password: creds.password)
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        openProfileMenuItem(item)
    }

    /// Opens `item` from the own-profile overflow menu, assuming the Profile
    /// tab is already showing.
    private func openProfileMenuItem(_ item: String) {
        let menu = element("profile-menu-button")
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "profile-menu-button did not appear on the own profile")
        menu.tap()
        let entry = harness.app.buttons[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "\(item) item missing from the profile menu")
        entry.tap()
    }

    private func waitForScreenTitled(_ title: String, timeout: TimeInterval = 10) -> Bool {
        let navBar = harness.app.navigationBars[title]
        let titleText = harness.app.staticTexts[title]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if navBar.exists || titleText.exists { return true }
            usleep(200_000)
        }
        return navBar.exists || titleText.exists
    }

    /// Pops the top-most pushed screen via the navigation bar back button.
    @discardableResult
    private func popBack(timeout: TimeInterval = 8) -> Bool {
        let back = harness.app.navigationBars.buttons.element(boundBy: 0)
        guard back.waitForExistence(timeout: 5), back.isHittable else { return false }
        back.tap()
        return true
    }

    /// First cell (List row) containing a static text equal to `text`.
    private func cellContaining(_ text: String) -> XCUIElement {
        harness.app.cells.containing(.staticText, identifier: text).firstMatch
    }

    // MARK: - Saved Feeds (read-only recon)

    /// READ-ONLY sweep of the My Feeds screen — the canonical iPhone home for
    /// pinned/saved feed management (the iPad/macOS `SavedFeedsScreen` is not
    /// reachable on compact width). Captures the server `savedFeedsPrefV2`
    /// state for the gate record. Performs NO pin/unpin/reorder writes: every
    /// `putPreferences` body in BlueskyKit carries a single preference object,
    /// and until the replace-vs-merge semantics of the endpoint are confirmed
    /// safe, mutating saved feeds from a live test risks clobbering the
    /// account's other preferences.
    @MainActor
    func testSavedFeedsServerStateRecon() throws {
        let creds = try requireCredentials()
        harness.launch(script: [.home, .waitForFeedLoad(minPosts: 1)], handle: creds.handle, password: creds.password)
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()

        let myFeeds = harness.app.buttons["My feeds"].firstMatch
        XCTAssertTrue(myFeeds.waitForExistence(timeout: 10), "My feeds (#) button missing from the Home top bar")
        myFeeds.tap()
        XCTAssertTrue(waitForScreenTitled("My Feeds"), "My Feeds screen did not push")

        // Let the saved-feeds + suggested-feeds loads settle.
        sleep(4)
        harness.screenshot(screen: "0066-myfeeds-recon")

        // Record the pinned/unpinned composition for the gate notes: pinned
        // rows expose an "Unpin" toggle, saved-but-unpinned rows expose "Pin".
        let unpinButtons = harness.app.buttons.matching(NSPredicate(format: "label == 'Unpin'")).count
        let pinButtons = harness.app.buttons.matching(NSPredicate(format: "label == 'Pin'")).count
        let summary = XCTAttachment(string: "pinned rows: \(unpinButtons), saved-unpinned rows: \(pinButtons)")
        summary.name = "saved-feeds-composition"
        summary.lifetime = .keepAlways
        add(summary)

        // The screen itself must at least render the section scaffolding.
        XCTAssertTrue(
            harness.app.staticTexts["My Feeds"].firstMatch.exists,
            "My Feeds section header missing"
        )
        // Empty-state marker, if present, is the wipe-evidence smoking gun.
        if harness.app.staticTexts["Feeds you save will appear here."].exists {
            let note = XCTAttachment(string: "SAVED FEEDS EMPTY — server savedFeedsPrefV2 has no items")
            note.name = "saved-feeds-empty"
            note.lifetime = .keepAlways
            add(note)
        }

        // Scroll once for the Discover section evidence.
        harness.app.swipeUp()
        harness.screenshot(screen: "0066-myfeeds-recon-discover")
    }

    // MARK: - Labeler Profile (read-only recon)

    /// READ-ONLY: walks Moderation → Advanced → first subscribed labeler →
    /// LabelerProfileScreen, and records the subscribe button's title. For a
    /// labeler listed under "subscribed labelers" (sourced from
    /// `labelersPref`) the button must read "Unsubscribe"; it reading
    /// "Subscribe" is live evidence that `LabelerProfileStore` derives
    /// subscription state from the wrong preference (`savedFeeds`).
    /// Does NOT tap the button — subscribing would write a malformed
    /// `savedFeeds` item (`type: "labeler"`) to the live account.
    @MainActor
    func testLabelerSubscriptionStateRecon() throws {
        let creds = try requireCredentials()
        launchToProfileMenuItem("Moderation", creds: creds)
        XCTAssertTrue(
            element("moderation-screen").waitForExistence(timeout: 15),
            "moderation-screen did not appear"
        )
        // Let the labelers load resolve.
        sleep(3)

        // The Advanced section is below the fold.
        for _ in 0..<4 where !harness.app.staticTexts["Advanced"].exists {
            harness.app.swipeUp()
        }
        harness.screenshot(screen: "0066-moderation-advanced")

        if harness.app.staticTexts["No subscribed labelers"].exists {
            let note = XCTAttachment(string: "NO SUBSCRIBED LABELERS — labelersPref empty; LabelerProfileScreen unreachable on this account")
            note.name = "labelers-empty"
            note.lifetime = .keepAlways
            add(note)
            return
        }

        // Tap the first labeler row (a NavigationLink cell inside Advanced).
        // Labeler rows are the only NavigationLinks after the "Advanced"
        // header; identify by the pushed "Content Labeler" title.
        let advancedHeader = harness.app.staticTexts["Advanced"]
        XCTAssertTrue(advancedHeader.exists, "Advanced section not found after scrolling")
        // Heuristic: the first cell below the Advanced header.
        let cells = harness.app.cells
        var tapped = false
        for index in 0..<cells.count {
            let cell = cells.element(boundBy: index)
            guard cell.frame.minY > advancedHeader.frame.minY, cell.isHittable else { continue }
            cell.tap()
            if waitForScreenTitled("Content Labeler", timeout: 6) {
                tapped = true
                break
            }
        }
        XCTAssertTrue(tapped, "Could not open a labeler row from the Advanced section")

        // Wait for the labeler load (getServices + getPreferences).
        sleep(3)
        harness.screenshot(screen: "0066-labeler-profile")

        let subscribe = harness.app.buttons["Subscribe"].firstMatch
        let unsubscribe = harness.app.buttons["Unsubscribe"].firstMatch
        XCTAssertTrue(
            subscribe.exists || unsubscribe.exists,
            "Neither Subscribe nor Unsubscribe button present on the labeler profile"
        )
        let state = XCTAttachment(string: "labeler button shows: \(unsubscribe.exists ? "Unsubscribe (correct)" : "Subscribe (WRONG for a subscribed labeler)")")
        state.name = "labeler-subscription-state"
        state.lifetime = .keepAlways
        add(state)
    }

    // MARK: - Lists (create → open → delete, fully reversed)

    @MainActor
    func testListsCreateOpenDelete() throws {
        let creds = try requireCredentials()
        let listName = "\(marker) List"

        launchToProfileMenuItem("My Lists", creds: creds)
        XCTAssertTrue(waitForScreenTitled("Lists"), "Lists screen did not push from the profile menu")
        sleep(2)
        harness.screenshot(screen: "0066-lists-initial")

        // Create. The toolbar plus button surfaces as "Add".
        let add = harness.app.navigationBars.buttons["Add"].firstMatch.exists
            ? harness.app.navigationBars.buttons["Add"].firstMatch
            : harness.app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8), "Create (+) button missing from the Lists toolbar")
        add.tap()
        XCTAssertTrue(waitForScreenTitled("New List"), "New List sheet did not present")

        let nameField = harness.app.textFields["Name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 8), "Name field missing on the New List sheet")
        nameField.tap()
        nameField.typeText(listName)
        harness.screenshot(screen: "0066-lists-create-sheet")

        let create = harness.app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5), "Create button missing on the New List sheet")
        create.tap()

        // The new list must appear in the hub (createList re-syncs the store).
        let row = harness.app.staticTexts[listName].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Created list did not appear in the Lists hub")
        harness.screenshot(screen: "0066-lists-created")

        // Open the detail screen: header + Posts/People/About tabs.
        row.tap()
        XCTAssertTrue(waitForScreenTitled(listName), "List detail did not push")
        sleep(2)
        XCTAssertTrue(
            harness.app.buttons["People"].exists || harness.app.staticTexts["People"].exists,
            "People tab missing on the curate list detail"
        )
        harness.screenshot(screen: "0066-list-detail")

        // People tab: a fresh list has no members. This is also where RN
        // offers member management; the SwiftUI port has no add/remove UI
        // (gate finding) so only the empty state is asserted.
        let peopleTab = harness.app.buttons["People"].firstMatch
        if peopleTab.exists { peopleTab.tap() }
        _ = harness.app.staticTexts["No Members"].waitForExistence(timeout: 8)
        harness.screenshot(screen: "0066-list-detail-people")

        // About tab renders the metadata block.
        let aboutTab = harness.app.buttons["About"].firstMatch
        if aboutTab.exists {
            aboutTab.tap()
            _ = harness.app.staticTexts["CREATOR"].waitForExistence(timeout: 6)
            harness.screenshot(screen: "0066-list-detail-about")
        }

        // Back to the hub, delete via the iOS swipe action (ListsScreen
        // ownedSection `.onDelete`).
        XCTAssertTrue(popBack(), "Could not pop back to the Lists hub")
        XCTAssertTrue(row.waitForExistence(timeout: 8), "List row missing after popping back")
        let cell = cellContaining(listName)
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "List cell not found for swipe-to-delete")
        cell.swipeLeft()
        let delete = harness.app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Swipe Delete action did not appear on the list row")
        delete.tap()

        // Reversal check: the row disappears (optimistic) and stays gone
        // after a pull-to-refresh round-trips the server.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, harness.app.staticTexts[listName].exists {
            usleep(250_000)
        }
        XCTAssertFalse(harness.app.staticTexts[listName].exists, "List row still present after delete")
        harness.app.swipeDown()
        sleep(3)
        XCTAssertFalse(harness.app.staticTexts[listName].exists, "List reappeared after refresh — server delete failed")
        harness.screenshot(screen: "0066-lists-after-delete")
    }

    /// Continuation / cleanup for `testListsCreateOpenDelete`: that test's
    /// create step succeeds server-side, but the hub re-fetches `getLists`
    /// once, immediately, racing AppView indexing — so the new row never
    /// appears in-session and the test fails before its delete step. This
    /// test runs on a fresh launch (the list is indexed by now), validates
    /// the detail screen, then swipe-deletes the marker list — completing
    /// the gate's open/delete checks and removing the orphaned record.
    @MainActor
    func testListsOpenDeleteAfterIndexing() throws {
        let creds = try requireCredentials()
        let listName = "\(marker) List"

        launchToProfileMenuItem("My Lists", creds: creds)
        XCTAssertTrue(waitForScreenTitled("Lists"), "Lists screen did not push from the profile menu")

        let row = harness.app.staticTexts[listName].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Marker list not in the hub — nothing to validate or clean up")
        harness.screenshot(screen: "0066-lists-hub-with-list")

        // Open the detail screen: header + Posts/People/About tabs.
        row.tap()
        XCTAssertTrue(waitForScreenTitled(listName), "List detail did not push")
        sleep(2)
        XCTAssertTrue(
            harness.app.buttons["People"].exists || harness.app.staticTexts["People"].exists,
            "People tab missing on the curate list detail"
        )
        harness.screenshot(screen: "0066-list-detail")

        let peopleTab = harness.app.buttons["People"].firstMatch
        if peopleTab.exists { peopleTab.tap() }
        _ = harness.app.staticTexts["No Members"].waitForExistence(timeout: 8)
        harness.screenshot(screen: "0066-list-detail-people")

        let aboutTab = harness.app.buttons["About"].firstMatch
        if aboutTab.exists {
            aboutTab.tap()
            sleep(1)
            harness.screenshot(screen: "0066-list-detail-about")
        }

        // Back to the hub, delete via the iOS swipe action.
        XCTAssertTrue(popBack(), "Could not pop back to the Lists hub")
        XCTAssertTrue(row.waitForExistence(timeout: 8), "List row missing after popping back")
        let cell = cellContaining(listName)
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "List cell not found for swipe-to-delete")
        cell.swipeLeft()
        let delete = harness.app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Swipe Delete action did not appear on the list row")
        delete.tap()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, harness.app.staticTexts[listName].exists {
            usleep(250_000)
        }
        XCTAssertFalse(harness.app.staticTexts[listName].exists, "List row still present after delete")
        harness.screenshot(screen: "0066-lists-after-delete")
    }

    // MARK: - App Passwords (create → copy → revoke, fully reversed)

    @MainActor
    func testAppPasswordsCreateRevoke() throws {
        let creds = try requireCredentials()

        launchToProfileMenuItem("Settings", creds: creds)
        XCTAssertTrue(element("settings-screen").waitForExistence(timeout: 15), "settings-screen did not appear")

        let row = element("settings-app-passwords-row")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "settings-app-passwords-row missing")
        row.tap()
        XCTAssertTrue(waitForScreenTitled("App Passwords"), "App Passwords screen did not push")
        sleep(2)
        harness.screenshot(screen: "0066-apppasswords-initial")

        // Create.
        let add = harness.app.navigationBars.buttons["Add"].firstMatch.exists
            ? harness.app.navigationBars.buttons["Add"].firstMatch
            : harness.app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8), "Create (+) button missing from App Passwords toolbar")
        add.tap()
        XCTAssertTrue(waitForScreenTitled("Add App Password"), "Add App Password sheet did not present")

        let nameField = harness.app.textFields["e.g. My RSS Reader"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 8), "Name field missing on Add App Password sheet")
        nameField.tap()
        nameField.typeText(marker)
        harness.app.buttons["Create"].firstMatch.tap()

        // Token alert: copy (iOS clipboard semantics), which dismisses it.
        let alert = harness.app.alerts["App Password Created"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "App Password Created alert did not appear")
        harness.screenshot(screen: "0066-apppasswords-created-alert")
        alert.buttons["Copy"].tap()

        // List refresh: the new row appears.
        let pwRow = harness.app.staticTexts[marker].firstMatch
        XCTAssertTrue(pwRow.waitForExistence(timeout: 10), "New app password row did not appear in the list")
        harness.screenshot(screen: "0066-apppasswords-row")

        // Revoke via the trailing swipe action — full reversal.
        let cell = cellContaining(marker)
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "App password cell not found for swipe-to-revoke")
        cell.swipeLeft()
        let revoke = harness.app.buttons["Revoke"].firstMatch
        XCTAssertTrue(revoke.waitForExistence(timeout: 5), "Revoke swipe action did not appear")
        revoke.tap()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, harness.app.staticTexts[marker].exists {
            usleep(250_000)
        }
        XCTAssertFalse(harness.app.staticTexts[marker].exists, "App password row still present after revoke")
        harness.screenshot(screen: "0066-apppasswords-after-revoke")
    }

    // MARK: - Bookmarks (add → view → remove, fully reversed)

    @MainActor
    func testBookmarksAddViewRemove() throws {
        let creds = try requireCredentials()

        // Pre-flight: the account's Saved list must start empty so the
        // appears/disappears assertions are unambiguous. If it isn't, skip
        // rather than mutate someone's pre-existing bookmarks.
        harness.launch(script: [.profile], handle: creds.handle, password: creds.password)
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()
        openProfileMenuItem("Saved")
        XCTAssertTrue(waitForScreenTitled("Saved"), "Saved (Bookmarks) screen did not push")
        if !harness.app.staticTexts["Nothing saved yet"].waitForExistence(timeout: 15) {
            harness.screenshot(screen: "0066-bookmarks-preexisting")
            throw XCTSkip("Saved screen is not empty — refusing to mutate pre-existing bookmarks.")
        }
        harness.screenshot(screen: "0066-bookmarks-empty-initial")

        // Home: bookmark the first feed post. The action button's
        // accessibility label flips Bookmark ↔ Remove Bookmark with state.
        XCTAssertTrue(harness.tapTab("Home"), "Could not switch to the Home tab")
        let bookmark = harness.app.descendants(matching: .any)
            .matching(identifier: "post-action-bookmark").firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 20), "post-action-bookmark missing on the home feed")
        XCTAssertEqual(bookmark.label, "Bookmark", "First post is already bookmarked — expected a clean slate")
        bookmark.tap()

        // Optimistic flip is the immediate-effect evidence.
        let flipDeadline = Date().addingTimeInterval(8)
        while Date() < flipDeadline, bookmark.label != "Remove Bookmark" {
            usleep(200_000)
        }
        XCTAssertEqual(bookmark.label, "Remove Bookmark", "Bookmark button did not flip after tapping")
        harness.screenshot(screen: "0066-bookmark-added-feed")

        // Open Saved from the profile overflow menu.
        XCTAssertTrue(harness.tapTab("Profile"), "Could not switch to the Profile tab")
        openProfileMenuItem("Saved")
        XCTAssertTrue(waitForScreenTitled("Saved"), "Saved (Bookmarks) screen did not push")

        let savedPost = harness.app.descendants(matching: .any)
            .matching(identifier: "post-cell").firstMatch
        XCTAssertTrue(savedPost.waitForExistence(timeout: 15), "Bookmarked post did not appear on the Saved screen")
        harness.screenshot(screen: "0066-bookmarks-with-post")

        // Remove it via the post card's bookmark toggle (parity with the
        // bsky.app Saved view; the screen has no swipe-to-delete rows).
        let removeButton = harness.app.descendants(matching: .any)
            .matching(identifier: "post-action-bookmark").firstMatch
        XCTAssertTrue(removeButton.waitForExistence(timeout: 8), "Bookmark toggle missing on the saved post card")
        XCTAssertEqual(removeButton.label, "Remove Bookmark", "Saved row's bookmark toggle should show the bookmarked state")
        removeButton.tap()

        // Optimistic removal → empty state.
        let emptyState = harness.app.staticTexts["Nothing saved yet"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10), "Saved screen did not empty after removing the bookmark")
        harness.screenshot(screen: "0066-bookmarks-after-remove")

        // Server truth: relaunch cold and confirm Saved is still empty.
        harness.app.terminate()
        harness.launch(script: [.profile], handle: creds.handle, password: creds.password)
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear after relaunch")
        openProfileMenuItem("Saved")
        XCTAssertTrue(waitForScreenTitled("Saved"), "Saved screen did not push after relaunch")
        XCTAssertTrue(
            harness.app.staticTexts["Nothing saved yet"].waitForExistence(timeout: 15),
            "Bookmark reappeared after relaunch — server delete failed (or pre-existing bookmarks present)"
        )
        harness.screenshot(screen: "0066-bookmarks-empty-relaunch")
    }
}
