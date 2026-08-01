import SwiftUI

/// Five tabs, and five is a ceiling rather than a preference: a sixth makes iOS
/// collapse the bar to four plus a "More" list, and the two that fall in are the
/// last two — which put sign-in behind an extra tap on an app that does nothing
/// until you sign in. Batch files moved under Settings when Insights arrived.
///
/// Selection is bound to `AppServices` rather than held locally so a tap on the
/// morning notification can switch tabs. That arrives at the app delegate before
/// any view exists to receive it.
struct RootView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var authorization: HealthAuthorization

    var body: some View {
        TabView(selection: $services.selectedTab) {
            StatusView()
                .tabItem { Label("Status", systemImage: "waveform.path.ecg") }
                .tag(AppServices.Tab.status)
            InsightsView()
                .tabItem { Label("Insights", systemImage: "sparkles") }
                .tag(AppServices.Tab.insights)
            MetricsView()
                .tabItem { Label("Metrics", systemImage: "list.bullet") }
                .tag(AppServices.Tab.metrics)
            ServerView()
                .tabItem { Label("Server", systemImage: "server.rack") }
                .tag(AppServices.Tab.server)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppServices.Tab.settings)
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
