import Foundation
import UserNotifications
import BlueskyCore

// MARK: - Notification names

extension Notification.Name {
    /// Posted when a push notification payload contains a post URI to open.
    /// `object` is the raw AT-URI `String` of the target post.
    static let openPostThread = Notification.Name("co.sstools.bluesky.openPostThread")

    /// Posted when a push notification payload identifies a profile to open.
    /// `object` is the DID `String` of the target user.
    static let openProfile = Notification.Name("co.sstools.bluesky.openProfile")

    /// Posted by `MainTabView` whenever the device's network path transitions
    /// from not-viable to viable. Feature view models can observe this to
    /// trigger a refresh when connectivity is restored. `object` is `nil`.
    static let networkBecameViable = Notification.Name("co.sstools.bluesky.networkBecameViable")

    /// Posted when the user taps the active Home tab on the iOS custom tab
    /// bar (RN parity for "tap-to-scroll-to-top"). `FeedView` listens for
    /// this and scrolls its feed back to the first post. `object` is `nil`.
    static let scrollFeedToTop = Notification.Name("co.sstools.bluesky.scrollFeedToTop")
}

// MARK: - PushNotificationDelegate

/// Handles foreground presentation and user-tap responses for APNs push notifications.
///
/// Bluesky's APNs payload typically looks like:
/// ```json
/// {
///   "reason": "like",
///   "subject": "at://did:plc:.../app.bsky.feed.post/abc",
///   "author": "did:plc:..."
/// }
/// ```
/// On tap the delegate inspects `reason` to decide whether to route to a thread or a profile,
/// then posts an `NSNotification` that `MainTabView` observes.
final class PushNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {

    // MARK: Tap response

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let reason = userInfo["reason"] as? String ?? ""

        switch reason {
        case "follow":
            // Navigate to the follower's profile.
            if let authorDID = userInfo["author"] as? String {
                NotificationCenter.default.post(name: .openProfile, object: authorDID)
            }

        default:
            // For like, repost, mention, reply, quote — navigate to the subject post.
            if let subject = userInfo["subject"] as? String {
                NotificationCenter.default.post(name: .openPostThread, object: subject)
            } else if let subject = userInfo["uri"] as? String {
                // Fallback: some payloads use "uri" instead of "subject".
                NotificationCenter.default.post(name: .openPostThread, object: subject)
            }
        }

        completionHandler()
    }

    // MARK: Foreground presentation

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner, badge, and play sound even while the app is in the foreground.
        completionHandler([.banner, .badge, .sound])
    }
}
