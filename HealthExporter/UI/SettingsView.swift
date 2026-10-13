import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var authorization: HealthAuthorization
    @EnvironmentObject private var engine: SyncEngine
    @State private var showResetConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var username = ""
    /// Never persisted: it exists only for the request that exchanges it for a
    /// token, and is cleared as soon as that returns.
    @State private var password = ""

    /// No `NavigationStack` of its own: this is pushed from `DataView`, which
    /// owns the stack. A nested one here would give the pushed screen a second
    /// navigation bar and swallow the back button.
    var body: some View {
            Form {
                Section(header: Text("History").sectionLabelStyle()) {
                    DatePicker("Backfill from",
                               selection: Binding(
                                   get: { engine.settings.backfillStartDate },
                                   set: { engine.settings.backfillStartDate = $0 }
                               ),
                               displayedComponents: .date)
                    Text("Samples older than this are read — so the sync cursor still "
                         + "advances past them — but not exported. Reaching back years "
                         + "mostly buys you per-second heart rate data.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                    // One literal, not three joined with `+`. `Text` only parses
                    // markdown through its `LocalizedStringKey` overload, and
                    // that overload is chosen for a string *literal*; a runtime
                    // concatenation picks the plain `String` one instead. The
                    // asterisks were being drawn on screen.
                    Text("""
                        Moving this date **earlier does not fetch older data on its own**. \
                        The cursor has already advanced past those samples, so you also have \
                        to reset it below.
                        """)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                }
                .listRowBackground(Ink.surface)

                Section(header: Text("Daily rollups").sectionLabelStyle()) {
                    Stepper(
                        "Re-emit last \(engine.settings.statisticsLookbackDays) days",
                        value: Binding(
                            get: { engine.settings.statisticsLookbackDays },
                            set: { engine.settings.statisticsLookbackDays = $0 }
                        ),
                        in: 1...90
                    )
                    Text("Rollup IDs are deterministic per metric and day, so re-sending "
                         + "recent days is an upsert, not a duplicate. Covers samples that "
                         + "arrive late and change a past day's total.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                    Button("Rebuild All Daily Totals") { engine.rebuildDailyTotals() }
                    Text(engine.settings.rollupsRebuiltAt.map {
                        "Re-sends one rollup per metric per day back to the backfill date, "
                            + "once. Last done \($0.formatted(date: .abbreviated, time: .shortened))."
                    } ?? "Re-sends one rollup per metric per day back to the backfill date, "
                        + "once. Runs on the next sync.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                }
                .listRowBackground(Ink.surface)

                Section(header: Text("HTTP destination").sectionLabelStyle()) {
                    Toggle("Upload automatically", isOn: Binding(
                        get: { engine.settings.sink.enabled },
                        set: { engine.settings.sink.enabled = $0 }
                    ))
                    TextField("https://your-server", text: Binding(
                        get: { engine.settings.sink.baseURL },
                        set: { engine.settings.sink.baseURL = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    if engine.settings.sink.enabled && engine.settings.sink.endpoint == nil {
                        Label("Needs a valid https:// URL", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Ink.absent)
                    }
                    Text("HTTPS only. Batches that fail to upload stay in the outbox and "
                         + "are retried; permanent failures are parked rather than looped.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                }
                .listRowBackground(Ink.surface)

                Section(header: Text("Certificate pin").sectionLabelStyle()) {
                    TextField("SHA-256 of the server certificate", text: Binding(
                        get: { engine.settings.sink.pinnedCertificateSHA256 },
                        set: { engine.settings.sink.pinnedCertificateSHA256 = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                    Text("A Tailscale hostname can't get a publicly trusted certificate, so "
                         + "the app trusts this one certificate and nothing else — narrower "
                         + "than installing a CA profile, which would trust that CA for every "
                         + "site. Get the value from ./deploy.sh pin. Leave empty to validate "
                         + "normally against system roots instead.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                }
                .listRowBackground(Ink.surface)

                Section(header: Text("Account").sectionLabelStyle()) {
                    if engine.isSignedIn {
                        Label("Signed in", systemImage: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(.green)
                        Button("Sign Out", role: .destructive) {
                            Task { await engine.signOut() }
                        }
                        .foregroundStyle(Ink.danger)
                        Text("Signing out revokes this device's token on the server, so a "
                             + "copy of it left anywhere else stops working too.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Ink.faint)
                            .lineSpacing(2)
                    } else {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        Button {
                            Task {
                                await engine.signIn(username: username, password: password)
                                // Held only for the one request that exchanges
                                // it for a token.
                                password = ""
                            }
                        } label: {
                            HStack {
                                Text("Sign In")
                                if engine.connectionTest == .running {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(username.isEmpty || password.isEmpty
                                  || engine.connectionTest == .running
                                  || engine.settings.sink.endpoint == nil)
                        Text("The server returns a token, which is kept in the Keychain. Your "
                             + "password is never stored on the device.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Ink.faint)
                            .lineSpacing(2)
                    }
                }
                .listRowBackground(Ink.surface)

                Section(header: Text("Connection").sectionLabelStyle()) {
                    Button {
                        Task { await engine.testConnection() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            if engine.connectionTest == .running {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(engine.connectionTest == .running
                              || engine.settings.sink.endpoint == nil
                              || !engine.isSignedIn)

                    switch engine.connectionTest {
                    case .untested:
                        Text("Checks the URL, the certificate pin, and the token in one "
                             + "request. Sends no health data.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Ink.faint)
                            .lineSpacing(2)
                    case .running:
                        EmptyView()
                    case .succeeded(let message):
                        Label(message, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "xmark.octagon")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .listRowBackground(Ink.surface)

                Section(header: Text("Permissions").sectionLabelStyle()) {
                    Button("Open Settings") { authorization.openHealthSettings() }
                    Text("iOS will not re-prompt for a data type once you've decided on "
                         + "it. Settings is the only way to change your mind.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                }
                .listRowBackground(Ink.surface)

                Section(header: Text("Insights").sectionLabelStyle()) {
                    NavigationLink("Morning brief") { DailyBriefSettingsView() }
                    NavigationLink("How insights work") { InsightsAboutView() }
                    if let status = engine.insightStatus {
                        LabeledContent("Processed") {
                            Text(status.isReady
                                 ? (status.destination?.description ?? "locally")
                                 : "unavailable")
                                .foregroundStyle(status.isReady ? Ink.muted : Ink.absent)
                                .multilineTextAlignment(.trailing)
                        }
                        if status.isReady, let model = status.model {
                            LabeledContent("Model", value: model)
                        }
                        LabeledContent("Questions kept",
                                       value: "\(status.retentionDays ?? 30) days")
                    }
                }
                .listRowBackground(Ink.surface)

                Section(header: Text("Diagnostics").sectionLabelStyle()) {
                    NavigationLink("Batch Files & Log") { ExportsView() }
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                    if engine.rejectedBatches > 0 {
                        Button("Retry \(engine.rejectedBatches) Rejected Batch"
                               + (engine.rejectedBatches == 1 ? "" : "es")) {
                            engine.retryRejectedBatches()
                        }
                        Text("The server refused these for their content — too large, "
                             + "malformed, or a newer format than it understands. They "
                             + "are kept on this phone. Retry once the server is updated.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Ink.faint)
                            .lineSpacing(2)
                    }
                    Button("Reset Sync Cursors", role: .destructive) {
                        showResetConfirmation = true
                    }
                    .foregroundStyle(Ink.danger)
                    Text("Clears every anchor. The next sync re-reads all history from "
                         + "the backfill date and re-uploads it — hundreds of megabytes, "
                         + "and hours of background time.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                    Text("It does not duplicate anything: every record carries a stable "
                         + "id, so the server updates in place rather than inserting again. "
                         + "Deletions also survive — a re-sent record cannot resurrect one "
                         + "you removed from Health.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                    Button("Delete Pending Batches", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .foregroundStyle(Ink.danger)
                    Text("Empties the outbox. Use after a failed run leaves duplicate "
                         + "batches behind.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                }
                .listRowBackground(Ink.surface)
            }
            // Surfaces only. The `Form` itself is left alone deliberately:
            // it carries sign-in, a date picker, a stepper and two destructive
            // confirmations, and rebuilding that as custom cards to match the
            // artboard would risk the app's critical path for a visual change.
            .scrollContentBackground(.hidden)
            .background(Ink.ground)
            // Toggles, the date picker's selection, the stepper and every
            // NavigationLink chevron take their colour from here. Set once on
            // the Form rather than per control, which is how the old screen
            // ended up with a system-blue toggle over a warm near-black ground.
            .tint(Ink.accent)
            .navigationTitle("Settings")
            .confirmationDialog("Reset all sync cursors?",
                                isPresented: $showResetConfirmation,
                                titleVisibility: .visible) {
                Button("Reset", role: .destructive) { engine.resetSyncState() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete all pending batches?",
                                isPresented: $showDeleteConfirmation,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Outbox.shared.deleteAllPending()
                    engine.refreshCounts()
                }
                Button("Cancel", role: .cancel) {}
        }
    }
}

struct DiagnosticsView: View {
    var body: some View {
        List {
            Section(header: Text("Unresolved identifiers").sectionLabelStyle()) {
                if MetricCatalog.unresolved.isEmpty {
                    Text("All catalog identifiers resolved on this OS.")
                        .foregroundStyle(Ink.faint)
                } else {
                    Text("These are in the catalog but unknown to this iOS version, so "
                         + "they're skipped rather than crashing. Listed here so a typo "
                         + "or version gap never silently loses a metric.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.faint)
                        .lineSpacing(2)
                    ForEach(MetricCatalog.unresolved, id: \.self) { name in
                        Text(name).font(.caption.monospaced())
                    }
                }
            }
            .listRowBackground(Ink.surface)

            Section(header: Text("Not yet supported").sectionLabelStyle()) {
                Text("Each needs a bespoke reader rather than the generic sample path.")
                    .font(.caption)
                    .foregroundStyle(Ink.faint)
                ForEach(MetricCatalog.deferredTypes, id: \.self) { item in
                    Text(item).font(.caption)
                }
            }
            .listRowBackground(Ink.surface)

            Section(header: Text("Storage").sectionLabelStyle()) {
                LabeledContent("Pending", value: "\(Outbox.shared.pendingBatches().count) batches")
                LabeledContent("Archived", value: "\(Outbox.shared.archivedBatches().count) batches")
                LabeledContent("Tracked types", value: "\(AnchorStore.shared.all.count)")
            }
            .listRowBackground(Ink.surface)
        }
        .navigationTitle("Diagnostics")
    }
}
