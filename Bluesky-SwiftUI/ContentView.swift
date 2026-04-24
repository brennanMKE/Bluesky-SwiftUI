import SwiftUI
import BlueskyAuth

struct RootView: View {
    @Environment(SessionManager.self) private var session

    var body: some View {
        if session.currentAccount != nil {
            MainTabView()
        } else {
            LoginView(session: session, onSuccess: {})
        }
    }
}
