import SwiftUI
import UIKit

@main
struct HealthExporterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .environmentObject(services.authorization)
                .environmentObject(services.syncEngine)
                .task {
                    await services.onLaunch()
                }
        }
    }
}

/// `BGTaskScheduler.register` has to happen before the app finishes launching,
/// which is earlier than any SwiftUI `.task` runs. The delegate exists purely to
/// own that moment.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Log.shared.info("app", "Launched")
        // Background task handlers must be registered here, not later.
        AppServices.shared.bootstrap()
        return true
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        // HealthKit was unreadable while locked. Now that it isn't, drain
        // whatever the observers flagged in the meantime.
        Log.shared.info("app", "Protected data available; draining flagged types")
        Task { @MainActor in
            await AppServices.shared.syncEngine.syncDirtyTypes()
        }
    }
}
