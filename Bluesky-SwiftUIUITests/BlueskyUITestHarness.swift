// BlueskyUITestHarness.swift
//
// Foundation for the Bluesky UI test suites (#0175, blocking #0176–#0183).
//
// The harness owns an `XCUIApplication`, encodes a scripted navigation plan
// into the app's launch environment, forwards test credentials, drives the app
// to a known screen before assertions, and captures screenshots to a
// `screenshots/` directory shared with `screenshot.sh`.

import XCTest

// MARK: - UITestIntent

/// A scripted navigation step, encoded into `BLUESKY_UI_TEST_SCRIPT` and
/// replayed in-process by the app's `UITestNavigator`. This is a test-target
/// mirror of the app-side intent vocabulary: UI tests run out-of-process and
/// cannot import the app target's types, so the JSON shape is the contract.
enum UITestIntent: Encodable {
    /// Select `home`, `search`, `messages`, `notifications`, `saved`, or `profile`.
    case selectTab(String)
    /// Block until `FeedStore.posts.count >= minPosts` or the 10s timeout.
    case waitForFeedLoad(minPosts: Int)
    /// Push the thread for the first feed post.
    case tapFirstPost
    /// Push Settings from the Profile tab.
    case openSettings
    /// Present the composer sheet.
    case openComposer
    /// Push the moderation screen.
    case openModeration
    /// Push the bookmarks screen.
    case openBookmarks
    /// Select the Messages tab (the harness taps the first row separately).
    case openFirstConversation
    /// Unconditional delay (seconds, capped at 10 by the app).
    case wait(seconds: Double)

    /// Convenience for the common tab cases, matching the spec's `.selectTab(.home)`.
    static let home = UITestIntent.selectTab("home")
    static let search = UITestIntent.selectTab("search")
    static let messages = UITestIntent.selectTab("messages")
    static let notifications = UITestIntent.selectTab("notifications")
    static let saved = UITestIntent.selectTab("saved")
    static let profile = UITestIntent.selectTab("profile")

    private enum CodingKeys: String, CodingKey {
        case intent, tab, minPosts, seconds
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selectTab(let tab):
            try c.encode("selectTab", forKey: .intent)
            try c.encode(tab, forKey: .tab)
        case .waitForFeedLoad(let minPosts):
            try c.encode("waitForFeedLoad", forKey: .intent)
            try c.encode(minPosts, forKey: .minPosts)
        case .tapFirstPost:
            try c.encode("tapFirstPost", forKey: .intent)
        case .openSettings:
            try c.encode("openSettings", forKey: .intent)
        case .openComposer:
            try c.encode("openComposer", forKey: .intent)
        case .openModeration:
            try c.encode("openModeration", forKey: .intent)
        case .openBookmarks:
            try c.encode("openBookmarks", forKey: .intent)
        case .openFirstConversation:
            try c.encode("openFirstConversation", forKey: .intent)
        case .wait(let seconds):
            try c.encode("wait", forKey: .intent)
            try c.encode(seconds, forKey: .seconds)
        }
    }
}

// MARK: - BlueskyUITestHarness

/// Per-test convenience wrapper around `XCUIApplication`.
///
/// Construct one per `XCTestCase`, then call `launch(script:handle:password:)`
/// to start the app routed to a known screen.
final class BlueskyUITestHarness {

    let app: XCUIApplication

    /// Owning test case, used to attach screenshots so they appear in the
    /// `.xcresult` bundle. Held weakly to avoid a retain cycle.
    private weak var testCase: XCTestCase?

    init(app: XCUIApplication? = nil, testCase: XCTestCase) {
        self.app = app ?? XCUIApplication()
        self.testCase = testCase
    }

    // MARK: Credentials

    /// Test credentials read from the *test process* environment. Verification
    /// runs inject these via the `TEST_RUNNER_` prefix on the `xcodebuild`
    /// command line (xcodebuild strips the prefix when launching the runner),
    /// so the secret never lives in a committed scheme, test plan, or source
    /// file. Returns `nil` when either var is absent — callers then `XCTSkip`.
    static func credentialsFromEnvironment() -> (handle: String, password: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let handle = env["BLUESKY_TEST_HANDLE"], !handle.isEmpty,
              let password = env["BLUESKY_TEST_PASSWORD"], !password.isEmpty else {
            return nil
        }
        return (handle, password)
    }

    // MARK: Launch

    /// JSON-encodes `script` into `BLUESKY_UI_TEST_SCRIPT`, forwards the test
    /// credentials into `BLUESKY_TEST_HANDLE` / `BLUESKY_TEST_PASSWORD`, and
    /// launches the app. The app performs a programmatic `createSession`
    /// sign-in when it sees these vars and has no live session, then the
    /// in-process `UITestNavigator` replays the script.
    func launch(script: [UITestIntent] = [], handle: String, password: String) {
        app.launchEnvironment["BLUESKY_TEST_HANDLE"] = handle
        app.launchEnvironment["BLUESKY_TEST_PASSWORD"] = password
        app.launchEnvironment["BLUESKY_UI_TEST_SCRIPT"] = Self.encode(script)
        app.launch()
    }

    /// Encodes a script to a JSON string. Always produces a value (defaults to
    /// `[]`) so the app's env-var gate (presence, not content) is satisfied
    /// even for an empty script.
    static func encode(_ script: [UITestIntent]) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(script),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    // MARK: Waiting

    /// Blocks until `MainTabView` is on screen. The tab bar's accessibility
    /// elements (or, on macOS, the sidebar) are present once the app is past
    /// login. We key off the Home tab label, which both layouts expose.
    @discardableResult
    func waitForMainTabView(timeout: TimeInterval = 15) -> Bool {
        // Either the custom iOS tab bar button or the macOS sidebar row carries
        // the "Home" label; the regular-width split view does too.
        let home = app.buttons["Home"]
        let homeCell = app.cells["Home"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if home.exists || homeCell.exists { return true }
            if app.staticTexts["ui-test-driver-error"].exists { return false }
            usleep(200_000)
        }
        return home.exists || homeCell.exists
    }

    /// Fails the test if the app surfaced a script decode / dispatch error.
    func assertNoScriptError(file: StaticString = #filePath, line: UInt = #line) {
        let errorLabel = app.staticTexts["ui-test-driver-error"]
        XCTAssertFalse(
            errorLabel.exists,
            "UI test driver reported a script error: \(errorLabel.label)",
            file: file, line: line
        )
    }

    // MARK: Screenshots

    /// Captures the full physical screen, attaches it to the running test, and
    /// writes a PNG to `screenshots/<screen>_<timestamp>.png` (same naming as
    /// `screenshot.sh`). The directory is resolved relative to the repo root so
    /// captures land in the tracked `screenshots/` folder, and falls back to a
    /// temp directory if that path is unavailable.
    @discardableResult
    func screenshot(screen: String) -> URL? {
        let shot = XCUIScreen.main.screenshot()

        // Attach to the test result bundle so it surfaces in Xcode / xcresult.
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = screen
        attachment.lifetime = .keepAlways
        testCase?.add(attachment)

        // Also write a PNG to the shared screenshots/ directory.
        let timestamp = Self.timestampFormatter.string(from: Date())
        let filename = "\(screen)_\(timestamp).png"
        let directory = Self.screenshotsDirectory()
        let fileURL = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try shot.pngRepresentation.write(to: fileURL)
            return fileURL
        } catch {
            XCTFail("Failed to write screenshot \(filename): \(error)")
            return nil
        }
    }

    /// `screenshots/` under the repo root (`BLUESKY_SCREENSHOTS_DIR` override
    /// wins), falling back to the temp directory. The repo root is derived from
    /// this source file's path so it works regardless of the test runner's
    /// working directory.
    private static func screenshotsDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["BLUESKY_SCREENSHOTS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // This file lives at <repoRoot>/Bluesky-SwiftUIUITests/BlueskyUITestHarness.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let candidate = repoRoot.appendingPathComponent("screenshots", isDirectory: true)
        // Verify the parent is writable; otherwise fall back to a temp dir.
        if FileManager.default.isWritableFile(atPath: repoRoot.path) {
            return candidate
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("screenshots", isDirectory: true)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
