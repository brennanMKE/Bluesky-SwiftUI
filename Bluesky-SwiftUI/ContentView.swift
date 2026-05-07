import SwiftUI
import BlueskyAuth
import BlueskyCore
import BlueskyKit
import BlueskyOnboarding

struct RootView: View {
    @Environment(SessionManager.self) private var session
    @Environment(BlueskyEnvironment.self) private var env

    /// Local-only flag mirroring the `hasOnboarded` preference. Seeded from
    /// `PreferencesStore` on first appear and flipped to `true` once the
    /// onboarding flow signals completion. We hold a separate `@State` so
    /// the view rerenders when the flow finishes without needing to round-
    /// trip back through the preferences store.
    @State private var hasOnboarded: Bool = true

    var body: some View {
        Group {
            if session.currentAccount == nil {
                LoginView(
                    session: session,
                    onSuccess: {},
                    onSignupSuccess: {
                        // Brand-new accounts go through the post-signup
                        // onboarding flow before MainTabView. Flip the local
                        // pref so the gate below picks them up on the next
                        // render (the flag defaults to `true` so existing
                        // sign-ins skip onboarding).
                        markOnboardingPending(env.preferences)
                        hasOnboarded = false
                    }
                )
            } else if !hasOnboarded {
                OnboardingFlowView(
                    session: session,
                    network: env.network,
                    accountStore: env.accounts,
                    preferences: env.preferences,
                    onComplete: { hasOnboarded = true }
                )
            } else {
                MainTabView()
            }
        }
        .task(id: session.currentAccount?.did) {
            // Re-check whenever the active account changes so logout/login
            // / account-switch cleanly re-evaluates the flow gate.
            hasOnboarded = onboardingHasCompleted(env.preferences)
        }
    }
}
