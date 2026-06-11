import Foundation
import OSLog
import UserNotifications
import BlueskyCore
import BlueskyKit
import BlueskyNotifications
#if os(iOS)
import UIKit
#endif

private let pushLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "co.sstools.Bluesky", category: "Push")

// MARK: - Notification names

extension Notification.Name {
    /// Posted by `PushRouteDispatcher` whenever a push-notification route is
    /// ready to apply. Carries no payload — `MainTabView` consumes the buffered
    /// route via `PushRouteDispatcher.consumePendingRoute()`.
    static let pushRouteReceived = Notification.Name("co.sstools.bluesky.pushRouteReceived")

    /// Posted by `MainTabView` whenever the device's network path transitions
    /// from not-viable to viable. Feature view models can observe this to
    /// trigger a refresh when connectivity is restored. `object` is `nil`.
    static let networkBecameViable = Notification.Name("co.sstools.bluesky.networkBecameViable")

    /// Posted when the user taps the active Home tab on the iOS custom tab
    /// bar (RN parity for "tap-to-scroll-to-top"). `FeedView` listens for
    /// this and scrolls its feed back to the first post. `object` is `nil`.
    static let scrollFeedToTop = Notification.Name("co.sstools.bluesky.scrollFeedToTop")
}

// MARK: - PushRouteDispatcher

/// Hands parsed push routes from the notification-center delegate to the UI.
///
/// The tap callback can fire before `MainTabView` is mounted (cold start from
/// a notification tap), so the route is buffered here rather than passed in
/// the `NSNotification` itself: `MainTabView` consumes it both from `.task`
/// on first appearance (cold start) and on `.pushRouteReceived` (warm).
@MainActor
enum PushRouteDispatcher {
    private(set) static var pendingRoute: PushNotificationRoute?

    static func dispatch(_ route: PushNotificationRoute) {
        pendingRoute = route
        NotificationCenter.default.post(name: .pushRouteReceived, object: nil)
    }

    static func consumePendingRoute() -> PushNotificationRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    /// Verification hook for #0030: `simctl push` can deliver a payload to the
    /// simulator but cannot synthesize the banner *tap*, so a launch
    /// environment variable `BLUESKY_SIMULATE_PUSH_TAP` carrying the APNs JSON
    /// payload routes through the exact same parse → dispatch path
    /// `userNotificationCenter(_:didReceive:…)` uses. Production launches never
    /// set the variable, making this a no-op.
    static func simulateTapFromEnvironmentIfRequested() async {
        guard let json = ProcessInfo.processInfo.environment["BLUESKY_SIMULATE_PUSH_TAP"],
              !json.isEmpty else { return }
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                pushLogger.error("simulated push tap: payload is not a JSON object")
                return
            }
            guard let payload = PushNotificationPayload(userInfo: object) else {
                pushLogger.error("simulated push tap: payload has no reason — not routable")
                return
            }
            // Give the UI a beat to finish mounting so the dispatch exercises
            // the same warm path a real tap would.
            try await Task.sleep(for: .seconds(2))
            pushLogger.info("simulated push tap: reason=\(payload.reason, privacy: .public) route=\(String(describing: payload.route), privacy: .public)")
            dispatch(payload.route)
        } catch {
            pushLogger.error("simulated push tap failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - PushNotificationDelegate

/// Handles foreground presentation and user-tap responses for APNs pushes.
///
/// Bluesky's notification gateway attaches RN's `NotificationPayload` keys to
/// the APNs payload (see `useNotificationHandler.ts` in the RN reference):
/// ```json
/// {
///   "aps": { "alert": { "title": "Alice liked your post" } },
///   "reason": "like",
///   "uri": "at://did:plc:…/app.bsky.feed.like/…",
///   "subject": "at://did:plc:…/app.bsky.feed.post/…",
///   "recipientDid": "did:plc:…"
/// }
/// ```
/// Parsing and routing rules live in `BlueskyNotifications`
/// (`PushNotificationPayload` / `PushNotificationRoute`) so they are
/// unit-testable; this delegate is a thin parse-and-forward shim.
final class PushNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    // MARK: Tap response

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let payload = PushNotificationPayload(userInfo: userInfo) {
            pushLogger.info("push tap: reason=\(payload.reason, privacy: .public) route=\(String(describing: payload.route), privacy: .public)")
            PushRouteDispatcher.dispatch(payload.route)
        } else {
            pushLogger.info("push tap: no reason key — not a routable Bluesky payload")
        }
        completionHandler()
    }

    // MARK: Foreground presentation

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Log the parsed route so simulator verification (`simctl push` with
        // the app foregrounded) can confirm receipt + parsing end-to-end.
        if let payload = PushNotificationPayload(userInfo: notification.request.content.userInfo) {
            pushLogger.info("push received in foreground: reason=\(payload.reason, privacy: .public) route=\(String(describing: payload.route), privacy: .public)")
        }
        // Show banner, badge, and play sound even while the app is in the foreground.
        completionHandler([.banner, .badge, .sound])
    }
}

// MARK: - Push registration (iOS)

#if os(iOS)
/// Minimal `UIApplicationDelegate` adaptor: UIKit only delivers the APNs
/// device token via `didRegisterForRemoteNotificationsWithDeviceToken`, so a
/// SwiftUI-lifecycle app still needs this shim (#0030). Everything else stays
/// in the SwiftUI app struct.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        pushLogger.info("APNs device token received (\(deviceToken.count) bytes)")
        PushRegistrationCoordinator.shared.deviceTokenReceived(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        pushLogger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// Obtains the APNs device token and registers it with Bluesky's notification
/// gateway (`app.bsky.notification.registerPush`) once a session is active —
/// RN parity: `getAndRegisterPushToken` in
/// `src/lib/notifications/notifications.ts`.
///
/// `MainTabView` calls `activate(network:)` whenever the signed-in account
/// changes; the token callback may arrive before or after activation, so the
/// coordinator buffers whichever side shows up first.
@MainActor
final class PushRegistrationCoordinator {
    static let shared = PushRegistrationCoordinator()

    private var network: (any NetworkClient)?
    /// Token that arrived before a session was active.
    private var pendingToken: Data?
    /// Hex of the last token successfully registered, to avoid re-posting the
    /// same registration on every account-change observation.
    private var registeredTokenHex: String?

    func activate(network: any NetworkClient) {
        self.network = network
        if let token = pendingToken {
            pendingToken = nil
            deviceTokenReceived(token)
        }
        Task { await requestAuthorizationAndRegister() }
    }

    func deviceTokenReceived(_ deviceToken: Data) {
        guard let network else {
            pendingToken = deviceToken
            return
        }
        let hex = PushRegistrationService.tokenHexString(deviceToken)
        guard hex != registeredTokenHex else { return }
        Task {
            do {
                try await PushRegistrationService.register(
                    deviceToken: deviceToken,
                    appID: Bundle.main.bundleIdentifier ?? "co.sstools.Bluesky",
                    network: network
                )
                registeredTokenHex = hex
                pushLogger.info("registerPush succeeded (appId=\(Bundle.main.bundleIdentifier ?? "?", privacy: .public))")
            } catch {
                pushLogger.error("registerPush failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func requestAuthorizationAndRegister() async {
        // Token acquisition does not require user authorization — always ask
        // UIKit for the APNs token so `registerPush` can run.
        UIApplication.shared.registerForRemoteNotifications()

        // Prompt for alert permission only while undetermined. Suppressed
        // under test launches (`BLUESKY_UI_TEST_SCRIPT` / simulated-tap hook)
        // because nothing can answer the system alert in automated simulator
        // runs and it would otherwise block every screenshot.
        let env = ProcessInfo.processInfo.environment
        guard env["BLUESKY_UI_TEST_SCRIPT"] == nil, env["BLUESKY_SIMULATE_PUSH_TAP"] == nil else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            pushLogger.info("notification authorization granted=\(granted)")
        } catch {
            pushLogger.error("notification authorization request failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
