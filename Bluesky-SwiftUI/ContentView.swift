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
            } else if session.currentAccount?.status == .deactivated {
                // RN parity: a deactivated session must not enter MainTabView —
                // API calls fail and the user has no path to reactivate. Mirror
                // `view/shell/index.tsx`'s `currentAccount?.status ===
                // 'deactivated'` branch with a dedicated holding screen. The
                // takendown / suspended branches will live alongside this one
                // (issue #0095).
                DeactivatedView(
                    session: session,
                    onReactivated: {
                        // SessionManager has already mutated `currentAccount`
                        // to `.active`; the Group re-evaluates and routes to
                        // MainTabView (or onboarding) on the next render.
                    },
                    onSignedOut: {
                        // SessionManager cleared `currentAccount`; the gate
                        // falls back to LoginView.
                    },
                    onAddAccount: {
                        // No other accounts: drop to login. SessionManager
                        // already has `currentAccount = nil` only if logout
                        // ran; if not, force a re-route by clearing it.
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
