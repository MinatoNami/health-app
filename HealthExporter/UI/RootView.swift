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
                .tabItem { Label("Summary", systemImage: "heart.text.square") }
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
        // Layered over the tabs rather than replacing them, so the five tab
        // roots are being built underneath while this is up. Gating their
        // construction on boot would only move that cost to the moment this
        // disappears, which is the moment it is most visible.
        .overlay { BootGate(progress: services.boot) }
    }
}

/// Owns the decision to show the boot screen, and exists only so that decision
/// is made by a view that observes `BootProgress`.
///
/// Putting `if !services.boot.isFinished` directly in `RootView` looks
/// equivalent and is not: `BootProgress` is a nested `ObservableObject`, and its
/// changes do not propagate through the `AppServices` that publishes it. The
/// boot screen rendered, updated its own label and bar — and then stayed up for
/// ever, because the view holding the condition never re-evaluated.
private struct BootGate: View {
    @ObservedObject var progress: BootProgress

    var body: some View {
        ZStack {
            // `isVisible` and not merely "unfinished": for the quarter-second
            // that a cached launch takes, showing nothing is the better screen.
            if progress.isVisible, !progress.isFinished {
                BootView(progress: progress)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: progress.isFinished)
        .animation(.easeOut(duration: 0.2), value: progress.isVisible)
    }
}

/// What fills the gap between the first frame and a usable interface.
///
/// It deliberately matches the launch screen underneath it — same background,
/// same mark in the same place — so the handover from the static launch image to
/// live SwiftUI is not a visible jump. The progress bar is the only thing that
/// arrives, and it arrives into a layout that has not moved.
private struct BootView: View {
    @ObservedObject var progress: BootProgress

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Text("Health Exporter")
                    .font(.title3.weight(.semibold))

                VStack(spacing: 8) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                        .frame(maxWidth: 220)
                        .animation(.easeInOut(duration: 0.3), value: progress.fraction)

                    Text(progress.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        // Reserves the line so a longer label does not shift the
                        // bar upward as the steps advance.
                        .frame(height: 18)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: progress.label)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting up. \(progress.label).")
    }
}
