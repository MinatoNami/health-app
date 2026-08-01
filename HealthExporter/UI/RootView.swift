import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authorization: HealthAuthorization

    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("Status", systemImage: "waveform.path.ecg") }
            MetricsView()
                .tabItem { Label("Metrics", systemImage: "list.bullet") }
            ExportsView()
                .tabItem { Label("Exports", systemImage: "square.and.arrow.up") }
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
