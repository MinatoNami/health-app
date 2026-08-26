import SwiftUI

/// Four tabs: Today, Insights, Trends, Data.
///
/// It was five, and three of them — Metrics, Server, Settings — all answered
/// the same question: is the machine working. That is a lot of the app's
/// cheapest-to-reach real estate spent on plumbing, so they are one `DataView`
/// now, with Settings pushed from it. Five remains the ceiling whatever the
/// split: a sixth makes iOS collapse the bar to four plus a "More" list.
///
/// Selection is bound to `AppServices` rather than held locally so a tap on the
/// morning notification can switch tabs. That arrives at the app delegate before
/// any view exists to receive it.
struct RootView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var authorization: HealthAuthorization
    @EnvironmentObject private var engine: SyncEngine

    var body: some View {
        // The drawer wraps the tabs rather than living inside one of them. A
        // `TabView` draws its bar above the selected tab's content, so a drawer
        // owned by `InsightsView` slid *under* the tab bar — covering the
        // conversation while leaving the one bright control on screen sitting
        // over the top of it.
        SideDrawer(isOpen: $services.showingChatHistory) {
            ChatHistoryView {
                withAnimation(.snappy(duration: 0.28)) { services.showingChatHistory = false }
            }
        } content: {
            tabs
        }
        // Stated once, in front of everything, when the server the app is
        // configured to use did not answer at launch.
        //
        // Retry comes first and is the default: the common cause is a laptop
        // that has not woken up or a tailnet not yet connected, and both fix
        // themselves in seconds. Continue is what keeps the app's own rule
        // intact — the cached figures are still on screen behind this, and a
        // snapshot from yesterday says more than a blank page.
        .alert("Can't reach the server", isPresented: serverErrorBinding) {
            Button("Retry") {
                Task { await services.checkServerReachable() }
            }
            // `.cancel` and not merely a third button. Without a cancel role
            // SwiftUI synthesises its own "Cancel" — a fourth option, sitting
            // below Close App, that does exactly what this one does and says
            // nothing about what continuing means. Carrying the role here both
            // removes it and makes the swipe-to-dismiss gesture land on the
            // sensible choice.
            Button("Continue Offline", role: .cancel) { services.startupServerError = nil }
            Button("Close App", role: .destructive) { services.closeApp() }
        } message: {
            Text(services.startupServerError ?? "")
        }
        // `Ink` is a fixed dark palette, not an adaptive one — see
        // `DesignTokens`. Without this the system draws its own chrome in the
        // device's colour scheme: a near-black navigation title on a near-black
        // ground, and every pushed `List` in light grey. A light variant is a
        // deliberate piece of work, not a scheme flip.
        .preferredColorScheme(.dark)
        // Switching tabs is navigating away from the conversation the drawer
        // belongs to, so it should not still be hanging over the next screen.
        .onChange(of: services.selectedTab) { _, tab in
            services.showingChatHistory = false
            // Arriving at Insights is arriving with a question, so it opens a
            // new conversation rather than whatever was last on screen. Nothing
            // is lost: the previous chat is in the history drawer, which is
            // where a finished conversation belongs. Not while a question is in
            // flight — that would discard an answer already being written.
            if tab == .insights, !engine.isAsking { engine.newChat() }
        }
    }

    /// `alert(isPresented:)` wants a `Bool` binding, and the message is a
    /// `String?`. Writing `false` back clears the error, which is what
    /// dismissing this should mean.
    private var serverErrorBinding: Binding<Bool> {
        Binding(
            get: { services.startupServerError != nil },
            set: { if !$0 { services.startupServerError = nil } }
        )
    }

    private var tabs: some View {
        TabView(selection: $services.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "bolt.heart") }
                .tag(AppServices.Tab.today)
            InsightsView()
                .tabItem { Label("Insights", systemImage: "sparkles") }
                .tag(AppServices.Tab.insights)
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.bar") }
                .tag(AppServices.Tab.trends)
            DataView()
                .tabItem { Label("Data", systemImage: "gearshape") }
                .tag(AppServices.Tab.data)
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
