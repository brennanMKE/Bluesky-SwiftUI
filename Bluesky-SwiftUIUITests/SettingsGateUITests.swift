// SettingsGateUITests.swift
//
// Module 14 gate live validation on iPhone (#0065). Unlike
// SettingsModerationUITests (#0183), which only asserts reachability, this
// suite performs the live persistence checks the gate issue calls for: each
// setting must take immediate effect and survive a force-quit + relaunch
// (`app.terminate()` + fresh `launch()` is a true cold start).
//
// Covered settings:
//   • Theme — Color Mode (System / Light / Dark) and Dark Theme variant
//     (Dim / Dark). Immediate effect is evidenced by Home-feed screenshots
//     (pixel-sampled against the #0040 ALF palettes after the run: light bg
//     #FFFFFF, dark bg #000000, dim bg #151D28); persistence by the segmented
//     pickers' selection after relaunch.
//   • Font size — XS/S/M/L/XL tier picker. Immediate effect via the preview
//     text's measured frame; persistence via the picker selection after
//     relaunch.
//   • Content & Media — Autoplay Videos toggle.
//   • Accessibility — Reduce Motion + Disable haptic feedback toggles.
//   • Notifications — Likes → Push notifications channel toggle
//     (local-only persistence, see NotificationPreferencesStore).
//   • Languages — Primary post language (server-backed via putPreferences;
//     the test REVERTS it to English before finishing).
//
// MUTATION BUDGET: every change is restored to its original (default) value
// before the test ends, including the server-side primary post language.
// Restores run inside the test body (not tearDown) so a restore failure is a
// loud test failure rather than silent drift.
//
// Run (placeholder credentials are fine when the simulator already has a
// signed-in keychain session — the app only uses them when no session
// restores):
//
//   xcodebuild test -workspace Bluesky.xcworkspace -scheme "Bluesky (Beta)" \
//     -destination 'id=<sim-udid>' \
//     -only-testing:Bluesky-SwiftUIUITests/SettingsGateUITests \
//     TEST_RUNNER_BLUESKY_TEST_HANDLE='…' TEST_RUNNER_BLUESKY_TEST_PASSWORD='…'

import XCTest

final class SettingsGateUITests: XCTestCase {

    private var harness: BlueskyUITestHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        harness = BlueskyUITestHarness(testCase: self)
    }

    // MARK: - Helpers

    private func requireCredentials() throws -> (handle: String, password: String) {
        guard let creds = BlueskyUITestHarness.credentialsFromEnvironment() else {
            throw XCTSkip("BLUESKY_TEST_HANDLE / BLUESKY_TEST_PASSWORD not set — skipping live settings gate test.")
        }
        return creds
    }

    private func element(_ identifier: String) -> XCUIElement {
        harness.app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// Launches the app routed to the Profile tab and opens Settings through
    /// the own-profile overflow menu — the same deterministic path
    /// SettingsModerationUITests (#0183) uses (the `openSettings` driver intent
    /// does not reliably push on iOS, see #0185).
    private func launchToSettings(creds: (handle: String, password: String)) {
        harness.launch(script: [.profile], handle: creds.handle, password: creds.password)
        XCTAssertTrue(harness.waitForMainTabView(), "MainTabView did not appear")
        harness.assertNoScriptError()

        let menu = element("profile-menu-button")
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "profile-menu-button did not appear on the own profile")
        menu.tap()

        let item = harness.app.buttons["Settings"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8), "Settings item missing from the profile menu")
        item.tap()

        XCTAssertTrue(
            element("settings-screen").waitForExistence(timeout: 15),
            "settings-screen did not appear after opening Settings from the profile menu"
        )
    }

    /// Force-quits the app and walks back to the Settings root — the gate's
    /// relaunch cycle. `terminate()` + `launch()` is a cold start: the app
    /// re-reads every preference from `UserDefaultsPreferencesStore`.
    private func relaunchToSettings(creds: (handle: String, password: String)) {
        harness.app.terminate()
        launchToSettings(creds: creds)
    }

    /// Scrolls the settings list (or the whole app) until `identifier` exists.
    @discardableResult
    private func scrollDownTo(_ identifier: String, swipes: Int = 6) -> XCUIElement {
        let target = element(identifier)
        if target.waitForExistence(timeout: 3) { return target }
        let container = element("settings-screen").exists ? element("settings-screen") : harness.app
        for _ in 0..<swipes {
            if target.exists { break }
            container.swipeUp()
        }
        return target
    }

    /// Taps a settings row and waits for the pushed screen's navigation title.
    private func openSettingsRow(_ rowIdentifier: String, waitForTitle title: String) {
        let row = scrollDownTo(rowIdentifier)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(rowIdentifier) missing from the settings list")
        row.tap()
        XCTAssertTrue(
            waitForScreenTitled(title),
            "Tapping \(rowIdentifier) did not push a screen titled \"\(title)\""
        )
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
    private func popBack(to parentIdentifier: String, timeout: TimeInterval = 8) -> Bool {
        let back = harness.app.navigationBars.buttons.element(boundBy: 0)
        guard back.waitForExistence(timeout: 5), back.isHittable else { return false }
        back.tap()
        return element(parentIdentifier).waitForExistence(timeout: timeout)
    }

    /// Switches to the Home tab (popping pushed screens first if the tab bar
    /// is covered) and waits for at least one feed post card to render so a
    /// screenshot captures the themed feed surface.
    private func goHomeAndWaitForFeed() {
        if !harness.tapTab("Home", timeout: 3) {
            // Tab bar not reachable — pop pushed screens until it is.
            for _ in 0..<4 {
                let back = harness.app.navigationBars.buttons.element(boundBy: 0)
                guard back.exists, back.isHittable else { break }
                back.tap()
                if harness.tab("Home").waitForExistence(timeout: 2) { break }
            }
            XCTAssertTrue(harness.tapTab("Home"), "Could not switch to the Home tab")
        }
        // Post cards carry the feed-post identifier prefix; fall back to a
        // settle delay so the screenshot is of a rendered feed either way.
        let post = harness.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'feed-post'"))
            .firstMatch
        _ = post.waitForExistence(timeout: 10)
        sleep(1)
    }

    // MARK: Segmented pickers (Appearance screen)

    /// Resolves one of the Appearance screen's segmented pickers by a segment
    /// label unique to it: Color Mode → "Light", Dark Theme → "Dim",
    /// Font → "Theme", Font Size → "XS". ("System" and "Dark" both appear in
    /// two pickers, so they cannot anchor the lookup.)
    private func segmentedControl(uniqueSegment: String, timeout: TimeInterval = 8) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let controls = harness.app.segmentedControls
            for index in 0..<controls.count {
                let control = controls.element(boundBy: index)
                if control.buttons[uniqueSegment].exists { return control }
            }
            usleep(200_000)
        }
        return nil
    }

    /// Taps `segment` inside `control` and asserts it becomes selected.
    private func select(segment: String, in control: XCUIElement,
                        file: StaticString = #filePath, line: UInt = #line) {
        let button = control.buttons[segment]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Segment \(segment) not found", file: file, line: line)
        button.tap()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if button.isSelected { break }
            usleep(150_000)
        }
        XCTAssertTrue(button.isSelected, "Segment \(segment) did not become selected after tapping", file: file, line: line)
    }

    private func assertSelected(segment: String, in control: XCUIElement, context: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let button = control.buttons[segment]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Segment \(segment) not found (\(context))", file: file, line: line)
        XCTAssertTrue(button.isSelected, "Segment \(segment) is not selected (\(context))", file: file, line: line)
    }

    // MARK: Switch toggles

    /// Reads a SwiftUI Toggle's on/off state ("1"/"0").
    private func switchValue(_ label: String) -> String? {
        let toggle = harness.app.switches[label].firstMatch
        guard toggle.waitForExistence(timeout: 8) else { return nil }
        return toggle.value as? String
    }

    /// Taps a labeled Toggle and asserts its value flips to `expected`.
    ///
    /// SwiftUI renders a labeled `Toggle` as an outer switch element wrapping
    /// an inner switch control; tapping the outer element's center hits the
    /// label text, which does nothing. Tap the inner switch when the runtime
    /// exposes one, otherwise tap near the trailing edge where the knob sits.
    private func setSwitch(_ label: String, to expected: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        let toggle = harness.app.switches[label].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "Toggle '\(label)' not found", file: file, line: line)
        if (toggle.value as? String) == expected { return }

        func currentValue() -> String? { toggle.value as? String }
        func poll(_ seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if currentValue() == expected { return true }
                usleep(150_000)
            }
            return currentValue() == expected
        }

        let inner = toggle.switches.firstMatch
        if inner.exists {
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        if !poll(3) {
            // Alternate tap style in case the first one missed the knob.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            _ = poll(3)
        }
        XCTAssertEqual(
            currentValue(), expected,
            "Toggle '\(label)' did not switch to \(expected) after tapping",
            file: file, line: line
        )
    }

    // MARK: - Theme (Color Mode + Dark Theme variant)

    /// Dark (Dim) → relaunch → Dark (Dark) → relaunch → Light → relaunch →
    /// restore System. Home-feed screenshots at each stop are pixel-sampled
    /// after the run against the #0040 palettes.
    @MainActor
    func testThemeImmediateEffectAndPersistence() throws {
        let creds = try requireCredentials()

        // Step 1 — Dark mode, default Dim variant.
        launchToSettings(creds: creds)
        openSettingsRow("settings-appearance-row", waitForTitle: "Appearance")

        guard let colorMode = segmentedControl(uniqueSegment: "Light") else {
            XCTFail("Color Mode segmented picker not found"); return
        }
        select(segment: "Dark", in: colorMode)

        // Dark Theme variant picker must appear once Dark is active, with Dim
        // selected by default (AppearanceStore default).
        guard let darkVariant = segmentedControl(uniqueSegment: "Dim") else {
            XCTFail("Dark Theme variant picker did not appear after selecting Dark color mode"); return
        }
        assertSelected(segment: "Dim", in: darkVariant, context: "default variant after enabling Dark")
        harness.screenshot(screen: "0065-appearance-dark-dim")

        // Immediate effect on the themed feed surface.
        goHomeAndWaitForFeed()
        harness.screenshot(screen: "0065-home-dark-dim")

        // Step 2 — relaunch: Dark + Dim must survive.
        relaunchToSettings(creds: creds)
        openSettingsRow("settings-appearance-row", waitForTitle: "Appearance")
        guard let colorMode2 = segmentedControl(uniqueSegment: "Light"),
              let darkVariant2 = segmentedControl(uniqueSegment: "Dim") else {
            XCTFail("Appearance pickers not found after relaunch (dark/dim)"); return
        }
        assertSelected(segment: "Dark", in: colorMode2, context: "color mode after relaunch")
        assertSelected(segment: "Dim", in: darkVariant2, context: "dark variant after relaunch")
        harness.screenshot(screen: "0065-appearance-dark-dim-relaunch")
        goHomeAndWaitForFeed()
        harness.screenshot(screen: "0065-home-dark-dim-relaunch")

        // Step 3 — switch the variant to Dark (full black) and verify it
        // takes immediate effect and survives a relaunch.
        XCTAssertTrue(harness.tapTab("Profile"), "Could not return to the Profile tab")
        let menu = element("profile-menu-button")
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "profile-menu-button missing on return to profile")
        menu.tap()
        let settingsItem = harness.app.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 8), "Settings item missing from the profile menu")
        settingsItem.tap()
        XCTAssertTrue(element("settings-screen").waitForExistence(timeout: 15), "settings-screen did not reappear")
        openSettingsRow("settings-appearance-row", waitForTitle: "Appearance")
        guard let darkVariant3 = segmentedControl(uniqueSegment: "Dim") else {
            XCTFail("Dark Theme variant picker not found (step 3)"); return
        }
        select(segment: "Dark", in: darkVariant3)
        goHomeAndWaitForFeed()
        harness.screenshot(screen: "0065-home-dark-dark")

        relaunchToSettings(creds: creds)
        openSettingsRow("settings-appearance-row", waitForTitle: "Appearance")
        guard let darkVariant4 = segmentedControl(uniqueSegment: "Dim") else {
            XCTFail("Dark Theme variant picker not found after relaunch (dark/dark)"); return
        }
        assertSelected(segment: "Dark", in: darkVariant4, context: "dark variant after relaunch (dark)")

        // Restore the variant default (Dim) while the picker is still visible.
        select(segment: "Dim", in: darkVariant4)

        // Step 4 — Light mode: immediate effect + persistence.
        guard let colorMode4 = segmentedControl(uniqueSegment: "Light") else {
            XCTFail("Color Mode picker not found (step 4)"); return
        }
        select(segment: "Light", in: colorMode4)
        goHomeAndWaitForFeed()
        harness.screenshot(screen: "0065-home-light")

        relaunchToSettings(creds: creds)
        openSettingsRow("settings-appearance-row", waitForTitle: "Appearance")
        guard let colorMode5 = segmentedControl(uniqueSegment: "Light") else {
            XCTFail("Color Mode picker not found after relaunch (light)"); return
        }
        assertSelected(segment: "Light", in: colorMode5, context: "color mode after relaunch (light)")
        harness.screenshot(screen: "0065-appearance-light-relaunch")

        // Step 5 — restore the System default.
        select(segment: "System", in: colorMode5)
    }

    // MARK: - Font size

    /// XL tier: the in-screen preview text grows immediately; the selection
    /// survives a relaunch; a Home screenshot at XL is captured for the
    /// app-wide font-scaling comparison. Restores M.
    @MainActor
    func testFontSizeImmediateEffectAndPersistence() throws {
        let creds = try requireCredentials()

        launchToSettings(creds: creds)
        openSettingsRow("settings-appearance-row", waitForTitle: "Appearance")

        guard let fontSize = segmentedControl(uniqueSegment: "XS") else {
            XCTFail("Font Size segmented picker not found"); return
        }
        assertSelected(segment: "M", in: fontSize, context: "default font size tier")

        // Preview sentence rendered at the selected tier's body point size.
        let preview = harness.app.staticTexts["The quick brown fox jumps over the lazy dog."]
        // The preview may be below the fold on smaller devices.
        if !preview.waitForExistence(timeout: 3) {
            harness.app.swipeUp()
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Font-size preview text not found")
        let heightAtM = preview.frame.height

        guard let fontSizeAgain = segmentedControl(uniqueSegment: "XS") else {
            XCTFail("Font Size picker disappeared after scrolling"); return
        }
        select(segment: "XL", in: fontSizeAgain)

        // Immediate effect: the preview text re-renders at 18pt (vs 16pt at M),
        // so its frame must grow.
        let deadline = Date().addingTimeInterval(5)
        var heightAtXL = preview.frame.height
        while Date() < deadline {
            heightAtXL = preview.frame.height
            if heightAtXL > heightAtM + 0.5 { break }
            usleep(200_000)
        }
        XCTAssertGreaterThan(
            heightAtXL, heightAtM + 0.5,
            "Font-size preview text did not grow after selecting XL (M: \(heightAtM), XL: \(heightAtXL))"
        )
        harness.screenshot(screen: "0065-appearance-fontsize-xl")

        // Evidence for the app-wide scaling check: Home feed at XL.
        goHomeAndWaitForFeed()
        harness.screenshot(screen: "0065-home-fontsize-xl")

        // Persistence: relaunch and confirm XL is still selected.
        relaunchToSettings(creds: creds)
        openSettingsRow("settings-appearance-row", waitForTitle: "Appearance")
        guard let fontSize2 = segmentedControl(uniqueSegment: "XS") else {
            XCTFail("Font Size picker not found after relaunch"); return
        }
        assertSelected(segment: "XL", in: fontSize2, context: "font size tier after relaunch")
        harness.screenshot(screen: "0065-appearance-fontsize-xl-relaunch")

        // Restore the default tier.
        select(segment: "M", in: fontSize2)
    }

    // MARK: - Content & Media + Accessibility toggles

    /// Autoplay Videos off, Reduce Motion on, Disable haptic feedback on →
    /// relaunch → all three persisted → restore defaults.
    @MainActor
    func testContentAndAccessibilityTogglesPersist() throws {
        let creds = try requireCredentials()

        launchToSettings(creds: creds)

        // Content & Media: Autoplay Videos defaults to on — switch it off.
        openSettingsRow("settings-content-row", waitForTitle: "Content & Media")
        XCTAssertEqual(switchValue("Autoplay Videos"), "1", "Autoplay Videos expected to start at its default (on)")
        setSwitch("Autoplay Videos", to: "0")
        harness.screenshot(screen: "0065-content-autoplay-off")
        XCTAssertTrue(popBack(to: "settings-screen"), "Could not pop back to settings from Content & Media")

        // Accessibility: Reduce Motion + Disable haptic feedback default off —
        // switch both on. (Disable haptic feedback is the iOS-only control the
        // issue calls out.)
        openSettingsRow("settings-accessibility-row", waitForTitle: "Accessibility")
        XCTAssertEqual(switchValue("Reduce Motion"), "0", "Reduce Motion expected to start at its default (off)")
        setSwitch("Reduce Motion", to: "1")
        XCTAssertEqual(switchValue("Disable haptic feedback"), "0", "Disable haptic feedback expected to start at its default (off)")
        setSwitch("Disable haptic feedback", to: "1")
        harness.screenshot(screen: "0065-accessibility-toggles-on")

        // Relaunch: all three values must survive the cold start.
        relaunchToSettings(creds: creds)
        openSettingsRow("settings-content-row", waitForTitle: "Content & Media")
        XCTAssertEqual(switchValue("Autoplay Videos"), "0", "Autoplay Videos did not persist (off) across relaunch")
        harness.screenshot(screen: "0065-content-autoplay-off-relaunch")
        // Restore while we're here.
        setSwitch("Autoplay Videos", to: "1")
        XCTAssertTrue(popBack(to: "settings-screen"), "Could not pop back to settings from Content & Media (relaunch)")

        openSettingsRow("settings-accessibility-row", waitForTitle: "Accessibility")
        XCTAssertEqual(switchValue("Reduce Motion"), "1", "Reduce Motion did not persist (on) across relaunch")
        XCTAssertEqual(switchValue("Disable haptic feedback"), "1", "Disable haptic feedback did not persist (on) across relaunch")
        harness.screenshot(screen: "0065-accessibility-toggles-on-relaunch")

        // Restore defaults.
        setSwitch("Reduce Motion", to: "0")
        setSwitch("Disable haptic feedback", to: "0")
    }

    // MARK: - Notification toggles

    /// Likes → Push notifications off → relaunch → still off → restore on.
    /// Persistence is local (NotificationPreferencesStore); no network writes.
    @MainActor
    func testNotificationToggleSurvivesRelaunch() throws {
        let creds = try requireCredentials()

        launchToSettings(creds: creds)
        openSettingsRow("settings-notifications-row", waitForTitle: "Notifications")

        // Push the Likes per-type screen.
        let likesRow = harness.app.buttons["Likes"].firstMatch.exists
            ? harness.app.buttons["Likes"].firstMatch
            : harness.app.staticTexts["Likes"].firstMatch
        XCTAssertTrue(likesRow.waitForExistence(timeout: 10), "Likes row missing from the notifications hub")
        likesRow.tap()
        XCTAssertTrue(waitForScreenTitled("Likes"), "Likes notification settings screen did not push")

        XCTAssertEqual(switchValue("Push notifications"), "1", "Likes push toggle expected to start at its default (on)")
        setSwitch("Push notifications", to: "0")
        harness.screenshot(screen: "0065-notifications-likes-push-off")

        // Relaunch and walk back to the same screen.
        relaunchToSettings(creds: creds)
        openSettingsRow("settings-notifications-row", waitForTitle: "Notifications")
        let likesRow2 = harness.app.buttons["Likes"].firstMatch.exists
            ? harness.app.buttons["Likes"].firstMatch
            : harness.app.staticTexts["Likes"].firstMatch
        XCTAssertTrue(likesRow2.waitForExistence(timeout: 10), "Likes row missing after relaunch")
        likesRow2.tap()
        XCTAssertTrue(waitForScreenTitled("Likes"), "Likes screen did not push after relaunch")

        XCTAssertEqual(switchValue("Push notifications"), "0", "Likes push toggle did not persist (off) across relaunch")
        harness.screenshot(screen: "0065-notifications-likes-push-off-relaunch")

        // Restore the default.
        setSwitch("Push notifications", to: "1")
    }

    // MARK: - Post languages

    /// Primary post language: English → Spanish (server-backed via
    /// putPreferences) → relaunch → still Spanish → REVERT to English.
    @MainActor
    func testPrimaryPostLanguagePersists() throws {
        let creds = try requireCredentials()

        launchToSettings(creds: creds)
        openSettingsRow("settings-languages-row", waitForTitle: "Languages")
        // Let the screen's `load()` settle so the pickers show server truth.
        sleep(2)

        XCTAssertTrue(
            setPrimaryPostLanguage(to: "Spanish", expectedCurrent: "English"),
            "Could not change the primary post language to Spanish"
        )
        // Allow the putPreferences write to complete; a failure surfaces as a
        // "Could not save" alert, which must not be present.
        sleep(2)
        XCTAssertFalse(
            harness.app.alerts["Could not save"].exists,
            "putPreferences(postLanguages) failed — 'Could not save' alert shown"
        )
        harness.screenshot(screen: "0065-languages-primary-spanish")

        // Relaunch: the picker must come back showing Spanish (seeded from the
        // local mirror, then confirmed against the server by `load()`).
        relaunchToSettings(creds: creds)
        openSettingsRow("settings-languages-row", waitForTitle: "Languages")
        sleep(2)
        XCTAssertTrue(
            primaryPostLanguageShows("Spanish"),
            "Primary post language did not persist (Spanish) across relaunch"
        )
        harness.screenshot(screen: "0065-languages-primary-spanish-relaunch")

        // REVERT the server-side preference to English.
        XCTAssertTrue(
            setPrimaryPostLanguage(to: "English", expectedCurrent: "Spanish"),
            "Could not revert the primary post language to English"
        )
        sleep(2)
        XCTAssertFalse(
            harness.app.alerts["Could not save"].exists,
            "putPreferences revert failed — 'Could not save' alert shown"
        )
        XCTAssertTrue(
            primaryPostLanguageShows("English"),
            "Primary post language did not revert to English"
        )
    }

    /// The Languages form has two menu pickers labeled "Language" (App
    /// language first, Primary post language second). Resolves the primary
    /// picker as the second matching element, with a fallback to elements
    /// whose label carries the current selection.
    private func primaryLanguagePicker(currentSelection: String) -> XCUIElement? {
        let labeled = harness.app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Language"))
        if labeled.count >= 2 { return labeled.element(boundBy: 1) }
        let bySelection = harness.app.buttons.matching(NSPredicate(format: "label CONTAINS %@", currentSelection))
        if bySelection.count >= 2 { return bySelection.element(boundBy: 1) }
        if bySelection.count == 1 { return bySelection.element(boundBy: 0) }
        return nil
    }

    private func primaryPostLanguageShows(_ name: String, timeout: TimeInterval = 10) -> Bool {
        // The menu picker's button label carries the selected option's name.
        let match = harness.app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        return match.waitForExistence(timeout: timeout)
    }

    /// Opens the primary post language menu picker and selects `name`.
    ///
    /// The menu opens scrolled to the current selection, so the target option
    /// may be above or below the visible window — scroll toward the top
    /// (swipe down) first, then toward the bottom (swipe up).
    private func setPrimaryPostLanguage(to name: String, expectedCurrent: String) -> Bool {
        guard let picker = primaryLanguagePicker(currentSelection: expectedCurrent),
              picker.waitForExistence(timeout: 8) else { return false }
        picker.tap()

        let option = harness.app.buttons[name].firstMatch
        if !option.waitForExistence(timeout: 5) {
            // The open menu is the scrollable surface; prefer its collection
            // view when the runtime exposes one. The content-language list has
            // ~200 alphabetical entries and the menu opens scrolled to the
            // current selection, so a generous one-direction budget is needed
            // (e.g. Spanish → English is ~125 rows up the list).
            let menu = harness.app.collectionViews.firstMatch.exists
                ? harness.app.collectionViews.firstMatch
                : harness.app
            for _ in 0..<18 {          // toward the top of the list first
                if option.exists { break }
                menu.swipeDown()
            }
            if !option.exists {
                for _ in 0..<36 {      // then sweep down the full list
                    if option.exists { break }
                    menu.swipeUp()
                }
            }
        }
        guard option.waitForExistence(timeout: 3) else { return false }
        option.tap()

        // The picker button should now reflect the new selection.
        return primaryPostLanguageShows(name)
    }
}
