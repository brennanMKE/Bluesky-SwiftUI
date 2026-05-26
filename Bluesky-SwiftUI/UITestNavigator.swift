import Foundation
import OSLog
import Observation
import BlueskyCore
import BlueskyFeed

// MARK: - UITestIntent

/// A single scripted navigation step.
///
/// The driver decodes an array of these from the `BLUESKY_UI_TEST_SCRIPT`
/// launch-environment variable and replays them in order once the app has a
/// live session and `MainTabView` is on screen. The JSON shape is:
///
/// ```jsonc
/// [
///   { "intent": "selectTab", "tab": "notifications" },
///   { "intent": "waitForFeedLoad", "minPosts": 1 },
///   { "intent": "tapFirstPost" }
/// ]
/// ```
///
/// Decoding is keyed off the `intent` string discriminator. New intents are
/// added as additional cases here and dispatched in `UITestNavigator.run`.
enum UITestIntent: Equatable, Codable {
    /// Select one of the primary tabs (`home`, `search`, `messages`,
    /// `notifications`, `saved`, `profile`).
    case selectTab(AppTab)
    /// Spin until the injected `FeedStore.posts.count >= minPosts` or the
    /// 10-second timeout elapses (the latter records a `scriptError`).
    case waitForFeedLoad(minPosts: Int)
    /// Push `ThreadView` for `posts[0]` by setting `MainTabView.threadURI`.
    case tapFirstPost
    /// Push `SettingsScreen` from the Profile tab.
    case openSettings
    /// Present the `ComposerSheet`.
    case openComposer
    /// Push `ModerationScreen`.
    case openModeration
    /// Push `BookmarksScreen`.
    case openBookmarks
    /// Tap the first row in `ConversationListScreen`. No state shortcut —
    /// the harness performs the actual `XCUIElement` tap; this intent only
    /// guarantees the Messages tab is selected first.
    case openFirstConversation
    /// Unconditional delay, capped at 10 seconds.
    case wait(seconds: Double)

    private enum CodingKeys: String, CodingKey {
        case intent, tab, minPosts, seconds
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let intent = try c.decode(String.self, forKey: .intent)
        switch intent {
        case "selectTab":
            let raw = try c.decode(String.self, forKey: .tab)
            guard let tab = AppTab(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .tab, in: c,
                    debugDescription: "Unknown tab '\(raw)'"
                )
            }
            self = .selectTab(tab)
        case "waitForFeedLoad":
            let minPosts = try c.decodeIfPresent(Int.self, forKey: .minPosts) ?? 1
            self = .waitForFeedLoad(minPosts: minPosts)
        case "tapFirstPost":
            self = .tapFirstPost
        case "openSettings":
            self = .openSettings
        case "openComposer":
            self = .openComposer
        case "openModeration":
            self = .openModeration
        case "openBookmarks":
            self = .openBookmarks
        case "openFirstConversation":
            self = .openFirstConversation
        case "wait":
            let seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 1
            self = .wait(seconds: seconds)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .intent, in: c,
                debugDescription: "Unknown intent '\(intent)'"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selectTab(let tab):
            try c.encode("selectTab", forKey: .intent)
            try c.encode(tab.rawValue, forKey: .tab)
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

// MARK: - UITestNavigator

/// Launch-environment scripted navigation driver.
///
/// Created *only* when `BLUESKY_UI_TEST_SCRIPT` is present in the process
/// environment (`UITestNavigator.fromEnvironment()` returns `nil` otherwise),
/// so production launches never allocate it and incur zero overhead.
///
/// `MainTabView` reads it via `@Environment(UITestNavigator?.self)` and mirrors
/// the published state into its own `@State` navigation bindings as each
/// intent fires. The navigator owns no UI; it is a small observable state
/// machine the test harness drives through the app's normal navigation paths.
@Observable
final class UITestNavigator {

    // MARK: Published navigation state (mirrored by MainTabView)

    /// Tab the app should switch to. `nil` until a `selectTab` intent fires.
    var selectedTab: AppTab? = nil
    /// AT-URI of the post whose thread should be pushed (set by `tapFirstPost`).
    var threadURI: ATURI? = nil
    var shouldOpenSettings = false
    var shouldOpenComposer = false
    var shouldOpenModeration = false
    var shouldOpenBookmarks = false
    /// Set when `tapFirstPost` runs before the feed has loaded a post; the
    /// `run` loop resolves it against the `FeedStore` once one is available.
    var shouldTapFirstPost = false
    /// First decode / dispatch failure message. Surfaced by `MainTabView` as a
    /// hidden `Text` with accessibility label `ui-test-driver-error` so the
    /// test process can read it via `XCUIApplication().staticTexts[...]`.
    var scriptError: String? = nil

    // MARK: Inputs

    /// The decoded script. Empty when decoding failed (see `scriptError`).
    let script: [UITestIntent]

    /// Feed store used by `waitForFeedLoad` / `tapFirstPost`. Injected by the
    /// app at boot so the navigator polls the same instance the UI renders.
    @ObservationIgnored private weak var feedStore: FeedStore?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "co.sstools.Bluesky",
        category: "UITestNavigator"
    )

    /// Maximum time any single blocking intent will wait before it records a
    /// `scriptError` and the run aborts.
    private let intentTimeout: TimeInterval = 10

    // MARK: Construction

    /// Builds a navigator from `BLUESKY_UI_TEST_SCRIPT`, or returns `nil` when
    /// the variable is absent. This is the single runtime gate that keeps the
    /// type out of production launches.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UITestNavigator? {
        guard let json = environment["BLUESKY_UI_TEST_SCRIPT"] else { return nil }
        return UITestNavigator(json: json)
    }

    init(json: String) {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "co.sstools.Bluesky",
            category: "UITestNavigator"
        )
        guard let data = json.data(using: .utf8) else {
            self.script = []
            self.scriptError = "ui-test: script is not valid UTF-8"
            logger.error("ui-test: script is not valid UTF-8")
            return
        }
        do {
            self.script = try JSONDecoder().decode([UITestIntent].self, from: data)
            logger.info("ui-test: decoded \(self.script.count, privacy: .public) intents")
        } catch {
            self.script = []
            self.scriptError = "ui-test: script decode failed: \(error)"
            logger.error("ui-test: script decode failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Test-only entry point that takes already-decoded intents.
    init(intents: [UITestIntent]) {
        self.script = intents
    }

    // MARK: Wiring

    /// Hands the live `FeedStore` to the navigator so the polling intents read
    /// the same instance the UI renders. Called once from the app at boot.
    func attach(feedStore: FeedStore) {
        self.feedStore = feedStore
    }

    // MARK: Run loop

    /// Replays the decoded script in order. Called by `MainTabView` once it is
    /// on screen (i.e. a live session exists). Each intent logs a `ui-test:`
    /// line before and after dispatch so a stuck script is inspectable in
    /// Console.app. Stops at the first timeout, recording `scriptError`.
    @MainActor
    func run() async {
        // A decode failure already populated `scriptError`; nothing to replay.
        guard scriptError == nil else { return }
        for (index, intent) in script.enumerated() {
            logger.info("ui-test: [\(index, privacy: .public)] dispatch \(String(describing: intent), privacy: .public)")
            let ok = await dispatch(intent)
            logger.info("ui-test: [\(index, privacy: .public)] done ok=\(ok, privacy: .public)")
            if !ok { return }
        }
    }

    /// Performs a single intent. Returns `false` (and sets `scriptError`) if a
    /// blocking intent times out.
    @MainActor
    private func dispatch(_ intent: UITestIntent) async -> Bool {
        switch intent {
        case .selectTab(let tab):
            selectedTab = tab
            return true

        case .waitForFeedLoad(let minPosts):
            return await waitForFeedLoad(minPosts: minPosts)

        case .tapFirstPost:
            if let uri = feedStore?.posts.first?.post.uri {
                threadURI = uri
                return true
            }
            // Feed not loaded yet — block briefly for a post to appear.
            guard await waitForFeedLoad(minPosts: 1) else { return false }
            if let uri = feedStore?.posts.first?.post.uri {
                threadURI = uri
                return true
            }
            shouldTapFirstPost = true
            scriptError = "ui-test: tapFirstPost found no posts after feed load"
            return false

        case .openSettings:
            // Switch to Profile first, then let the tab change settle before
            // raising the push flag. The Profile tab hosts the
            // `navigationDestination(isPresented: $showSettings)`, but it (and
            // its NavigationStack) is only mounted after the tab switch, and
            // the tab change fires `resetTransientNavState()` which clears the
            // flag. Setting both in the same synchronous block races that
            // reset and can set the flag before the destination exists. By
            // yielding here we let SwiftUI process the tab switch + reset and
            // mount the Profile content, then raise the flag — mirroring how
            // `tapFirstPost` waits for the feed before setting `threadURI`.
            selectedTab = .profile
            await settleAfterTabSwitch()
            shouldOpenSettings = true
            return true

        case .openComposer:
            shouldOpenComposer = true
            return true

        case .openModeration:
            // Same ordering as `openSettings`: settle the Profile tab switch
            // before raising the flag so the destination is mounted and the
            // tab-change reset has already run.
            selectedTab = .profile
            await settleAfterTabSwitch()
            shouldOpenModeration = true
            return true

        case .openBookmarks:
            shouldOpenBookmarks = true
            return true

        case .openFirstConversation:
            // No state shortcut: just ensure the Messages tab is showing; the
            // harness performs the actual row tap via XCUIElement.
            selectedTab = .messages
            return true

        case .wait(let seconds):
            let clamped = min(max(seconds, 0), intentTimeout)
            try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
            return true
        }
    }

    /// Lets a `selectedTab` change propagate through SwiftUI before the next
    /// mutation. A tab switch recreates the destination's NavigationStack (the
    /// content is keyed on `.id(selectedTab)`) and fires the
    /// `resetTransientNavState()` `onChange`, which clears the `shouldOpen*`
    /// mirrors. Yielding for a couple of run-loop turns ensures the freshly
    /// mounted Profile content — and its `navigationDestination` — exists, and
    /// that the reset has already run, before we raise the push flag. Without
    /// this the flag races the reset and is sometimes cleared on iOS.
    @MainActor
    private func settleAfterTabSwitch() async {
        // Two short sleeps span the tab-switch view update and the subsequent
        // reset/mount cycle; 0.3s total is well under any single intent's 10s
        // budget and imperceptible to the test run.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Polls the injected `FeedStore` until it has at least `minPosts` posts or
    /// the 10-second timeout elapses. Records a `scriptError` on timeout.
    @MainActor
    private func waitForFeedLoad(minPosts: Int) async -> Bool {
        guard let feedStore else {
            scriptError = "ui-test: waitForFeedLoad has no FeedStore attached"
            return false
        }
        let deadline = Date().addingTimeInterval(intentTimeout)
        while Date() < deadline {
            if feedStore.posts.count >= minPosts { return true }
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        }
        if feedStore.posts.count >= minPosts { return true }
        scriptError = "ui-test: waitForFeedLoad timed out after \(intentTimeout)s (have \(feedStore.posts.count), want \(minPosts))"
        return false
    }
}
