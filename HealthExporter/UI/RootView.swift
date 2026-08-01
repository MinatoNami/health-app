import SwiftUI

/// Five tabs, and five is a ceiling rather than a preference: a sixth makes iOS
/// collapse the bar to four plus a "More" list, and the two that fall in are the
/// last two — which put sign-in behind an extra tap on an app that does nothing
/// until you sign in. Batch files moved under Settings when Insights arrived.
struct RootView: View {
    @EnvironmentObject private var authorization: HealthAuthorization

    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("Status", systemImage: "waveform.path.ecg") }
            InsightsView()
                .tabItem { Label("Insights", systemImage: "sparkles") }
            MetricsView()
                .tabItem { Label("Metrics", systemImage: "list.bullet") }
            ServerView()
                .tabItem { Label("Server", systemImage: "server.rack") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .overlay {
            if !authorization.isAvailable {
                ContentUnavailableView(
                    "HealthKit Unavailable",
                    systemImage: "heart.slash",
                    description: Text("This device does not provide Health data.")
                )
                .background(.background)
            }
        }
    }
}
