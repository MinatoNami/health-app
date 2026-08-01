import Foundation
import SwiftUI

/// Single owner of the long-lived objects.
///
/// A shared reference is needed because `BGTaskScheduler` handlers are static
/// entry points invoked by the system long after any view has gone away — they
/// need a way back to the live engine rather than constructing a second one with
/// its own anchors.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let authorization: HealthAuthorization
    let syncEngine: SyncEngine
    let backgroundSync: BackgroundSync

    init() {
        let auth = HealthAuthorization()
        let engine = SyncEngine(authorization: auth)
        self.authorization = auth
        self.syncEngine = engine
        self.backgroundSync = BackgroundSync(authorization: auth, engine: engine)
    }

    /// Must run inside `didFinishLaunchingWithOptions`. `BGTaskScheduler.register`
    /// throws if it happens after launch completes, which is earlier than any
    /// SwiftUI `.task` — hence the app delegate.
    func bootstrap() {
        backgroundSync.registerTaskHandlers()
    }

    /// Called when the app becomes active. Re-registering observers every launch
    /// is deliberate: if HealthKit previously stopped background delivery, this
    /// is the only thing that brings it back.
    func onLaunch() async {
        guard authorization.hasRequested else { return }
        await backgroundSync.startObserving()
        backgroundSync.scheduleNextRun()
        await syncEngine.syncAll(reason: "app launch")
    }
}
