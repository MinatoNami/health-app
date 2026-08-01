import SwiftUI
import UserNotifications

/// Controls for the morning alert.
///
/// The two things worth being honest about are both here: iOS decides when the
/// text is refreshed, and iOS only ever asks for notification permission once.
struct DailyBriefSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var engine: SyncEngine

    private var scheduler: DailyBriefScheduler { services.dailyBrief }

    var body: some View {
        List {
            Section {
                Toggle("Daily brief", isOn: Binding(
                    get: { scheduler.settings.enabled },
                    set: { newValue in
                        scheduler.settings.enabled = newValue
                        if newValue {
                            Task {
                                await scheduler.requestAuthorization()
                                await scheduler.refresh()
                            }
                        }
                    }
                ))

                DatePicker(
                    "Time",
                    selection: Binding(
                        get: {
                            Calendar.current.date(
                                from: DateComponents(hour: scheduler.settings.hour,
                                                     minute: scheduler.settings.minute)
                            ) ?? Date()
                        },
                        set: { date in
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                            scheduler.settings.hour = parts.hour ?? 8
                            scheduler.settings.minute = parts.minute ?? 0
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .disabled(!scheduler.settings.enabled)

                Toggle("Only when something changed", isOn: Binding(
                    get: { scheduler.settings.onlyWhenNotable },
                    set: { scheduler.settings.onlyWhenNotable = $0 }
                ))
                .disabled(!scheduler.settings.enabled)
            } footer: {
                Text("An alert that says \"nothing changed\" every morning is one you turn "
                     + "off, and then you miss the day it matters.")
            }

            if scheduler.authorizationStatus == .denied {
                Section {
                    Label("Notifications are turned off for this app", systemImage: "bell.slash")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Open Settings") { scheduler.openSystemSettings() }
                } footer: {
                    Text("iOS only asks once, so this can only be changed in Settings.")
                }
            }

            Section("Preview") {
                if let brief = scheduler.lastBrief {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Morning brief").font(.subheadline.weight(.semibold))
                        Text("Through \(brief.asOf)").font(.caption).foregroundStyle(.secondary)
                        Text(brief.notificationBody).font(.callout)
                    }
                    .padding(.vertical, 4)

                    if !brief.worthNotifying && scheduler.settings.onlyWhenNotable {
                        Text("Nothing notable today, so no alert would be sent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !engine.isSignedIn {
                    Text("Sign in to see your brief.").foregroundStyle(.secondary)
                } else {
                    Text("Not fetched yet.").foregroundStyle(.secondary)
                }

                Button("Refresh now") {
                    Task { await scheduler.refresh() }
                }
                .disabled(!engine.isSignedIn)
            }

            Section {
                if let next = scheduler.lastScheduledFor {
                    LabeledContent("Next alert",
                                   value: next.formatted(date: .abbreviated, time: .shortened))
                } else if scheduler.settings.enabled {
                    Text("Nothing scheduled yet.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("The text is written in advance — iOS will not run this app at 8am just "
                     + "to compose it. It is refreshed whenever the app syncs, and a background "
                     + "run is requested for the small hours. When that does not happen the "
                     + "alert still arrives, saying which day it describes. Opening it always "
                     + "fetches the current numbers.")
            }
        }
        .navigationTitle("Morning brief")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await scheduler.refreshAuthorizationStatus()
            if scheduler.lastBrief == nil { await scheduler.refresh() }
        }
    }
}
