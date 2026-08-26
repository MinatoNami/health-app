import SwiftUI

/// First launch, and the only screen every user is guaranteed to see.
///
/// It exists because of one iOS constraint that the rest of the app can only
/// apologise for afterwards: **read access is granted once per data type,
/// ever**. Calling `requestAuthorization` a second time for a type already
/// decided returns immediately with no sheet, so a user who taps through the
/// permission prompt with three groups enabled has quietly closed the door on
/// the other five, and the only way back is Settings → Privacy → Health.
///
/// So the order here is deliberate and is the whole reason this is a flow
/// rather than a card: explain, **choose the groups**, and only then ask iOS.
/// The old first-run — a "Grant Health access to begin" card sitting on the
/// Summary tab next to a note telling you to visit a different tab first — got
/// that order exactly backwards.
struct OnboardingView: View {
    @EnvironmentObject private var authorization: HealthAuthorization
    @EnvironmentObject private var services: AppServices

    /// Set when the flow is finished or skipped, so this never reappears.
    let finish: () -> Void

    @State private var path: [Step] = Self.initialPath
    @State private var requesting = false

    enum Step: Hashable { case choose, connect }

    /// Where the flow opens. Always the intro, except under a DEBUG launch
    /// argument.
    ///
    /// The server step sits behind `requestAuthorization`, which presents a
    /// **system** Health sheet — and that sheet is not in this app's element
    /// tree, so XCUITest cannot dismiss it and cannot get past it. Without a
    /// way in, step three would be the one screen in the app nobody had ever
    /// looked at. This is that way in, and it cannot ship.
    private static var initialPath: [Step] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-onboardingStep=connect") { return [.connect] }
        if ProcessInfo.processInfo.arguments.contains("-onboardingStep=choose") { return [.choose] }
        #endif
        return []
    }

    var body: some View {
        NavigationStack(path: $path) {
            intro
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .choose: chooseTypes
                    case .connect: connectServer
                    }
                }
        }
        .tint(Ink.accent)
        .preferredColorScheme(.dark)
    }

    // MARK: - 1 · What this is

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "bolt.heart")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Ink.accent)
                            .padding(.bottom, 2)
                        Text("Your health data, on a server you own.")
                            .font(.system(size: 27, weight: .semibold))
                            .kerning(-0.5)
                            .foregroundStyle(Ink.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("This app reads Apple Health, sends it to your own machine, and asks a model you also own to explain what it finds. Nothing goes anywhere you have not configured.")
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .foregroundStyle(Ink.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 20)

                    Divider().overlay(Ink.divider)

                    VStack(alignment: .leading, spacing: 18) {
                        promise("Compared against you, not a population",
                                "Every figure is your last 7 days against your own preceding 28.")
                        promise("It tells you how much to trust it",
                                "Every number carries how many days it was measured from.")
                        promise("No score to fail",
                                "No streaks, no rings, no invented number out of ten.")
                    }

                    onceEverWarning
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            VStack(spacing: 12) {
                Button {
                    path.append(.choose)
                } label: {
                    Text("Choose what to share")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.ground)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Ink.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                Button("Not now", action: finish)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.faint)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
        .background(Ink.ground)
        .navigationBarHidden(true)
    }

    private func promise(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle().fill(Ink.measured.opacity(0.13))
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.measured)
            }
            .frame(width: 26, height: 26)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The one thing on this screen that is a warning rather than a promise.
    private var onceEverWarning: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 16))
                .foregroundStyle(Ink.absent)
                .padding(.top, 1)
            Text("iOS asks about each data type **once, ever**. Choose what to include on the next screen — changing your mind later means a trip to Settings.")
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Ink.absent.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Ink.absent.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - 2 · Choose the groups

    /// `MetricsView` unchanged, with the request button under it.
    ///
    /// Reused rather than reimplemented: it is the same decision the Data tab
    /// offers later, and two lists of the same groups would drift the moment
    /// one gained a category.
    private var chooseTypes: some View {
        MetricsView()
            // No `navigationTitle` here: `MetricsView` sets its own further
            // down the tree and the innermost one wins, so anything written
            // here would be dead code that looks like it works.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if let error = authorization.lastRequestError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.absentInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        request()
                    } label: {
                        HStack(spacing: 8) {
                            if requesting { ProgressView().controlSize(.small).tint(Ink.ground) }
                            Text(requesting ? "Asking Health…" : "Request Health Access")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Ink.ground)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(enabledCount == 0 ? Ink.hairline : Ink.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(enabledCount == 0 || requesting)

                    Text(enabledCount == 0
                         ? "Enable at least one group to continue."
                         : "\(enabledCount) group\(enabledCount == 1 ? "" : "s") — iOS will ask about each type once.")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.faint)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(.bar)
            }
    }

    private var enabledCount: Int { authorization.enabledGroupIDs.count }

    private func request() {
        requesting = true
        Task {
            await authorization.requestAuthorization()
            requesting = false
            // Onward whether or not anything was granted. Read authorization is
            // deliberately opaque — `authorizationStatus` reports sharing only,
            // and a denied read is indistinguishable from an empty store — so
            // there is nothing here to branch on, and pretending otherwise
            // would mean guessing at what the user chose.
            path.append(.connect)
        }
    }

    // MARK: - 3 · Point it at a server

    private var connectServer: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 13) {
                        Image(systemName: "externaldrive.badge.checkmark")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(Ink.measured)
                            .padding(.bottom, 2)
                        Text("Now point it somewhere.")
                            .font(.system(size: 25, weight: .semibold))
                            .kerning(-0.4)
                            .foregroundStyle(Ink.primary)
                        Text("Health data is being read on this phone, but nothing is analysed until it reaches a server you run. Until then the app collects and queues — nothing is lost.")
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .foregroundStyle(Ink.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("You will need").sectionLabelStyle()
                        need("The server's address, over HTTPS")
                        need("A username and password for it")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            VStack(spacing: 12) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Text("Connect a server")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.ground)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Ink.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                Button("Do this later", action: finish)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.faint)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
        .background(Ink.ground)
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        // No back button, and no "Done" in the bar. Back would return to the
        // group picker, which after the permission prompt is a decision iOS
        // will not let you retake — an affordance that looks like an undo and
        // is not. That leaves two exits, and they do different things.
        .navigationBarBackButtonHidden(true)
    }

    private func need(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Ink.faint)
                .frame(width: 4, height: 4)
                .padding(.top, 8)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(Ink.muted)
        }
    }
}
