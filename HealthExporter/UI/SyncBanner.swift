import SwiftUI

/// Speaks up only when something needs attention.
///
/// This replaces a 132pt status ring that was on screen permanently. The ring
/// was honest but always-on, and a healthy state rendered at that size is just
/// furniture — which is the problem, because furniture is not read, and this app
/// exists to make a *silent* failure visible.
///
/// So: nothing at all on a good day, a single line of prose when there is
/// something worth knowing, and a full card only for the states someone has to
/// act on. `state(...)` returning nil is the common case by design.
struct SyncBanner: View {
    enum State {
        case failed(String)
        case locked
        case uploadingOff(pending: Int)
        case stale(since: Date)
        case running(String)

        var symbol: String {
            switch self {
            case .failed: return "exclamationmark.triangle.fill"
            case .locked: return "lock.fill"
            case .uploadingOff: return "icloud.slash.fill"
            case .stale: return "clock.badge.exclamationmark.fill"
            case .running: return "arrow.triangle.2.circlepath"
            }
        }

        var tint: Color {
            switch self {
            case .failed: return .red
            case .locked, .running: return .secondary
            case .uploadingOff, .stale: return .orange
            }
        }

        var title: String {
            switch self {
            case .failed: return "Sync problem"
            case .locked: return "Waiting for unlock"
            case .uploadingOff: return "Uploading is off"
            case .stale: return "Nothing has synced recently"
            case .running: return "Syncing"
            }
        }

        var detail: String {
            switch self {
            case .failed(let message):
                return message
            case .locked:
                return "Health data is encrypted while the phone is locked. This resumes on unlock."
            case .uploadingOff(let pending):
                return "\(pending) batch\(pending == 1 ? "" : "es") queued on this phone."
            case .stale(let since):
                return "Last sync \(since.formatted(.relative(presentation: .named)))."
            case .running(let detail):
                return detail
            }
        }
    }

    let state: State

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: state.symbol)
                .font(.callout)
                .foregroundStyle(state.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.subheadline.weight(.semibold))
                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(state.tint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    /// The states worth interrupting for. Everything else — an ordinary idle
    /// app that synced an hour ago — returns nil and the screen stays quiet.
    static func state(
        phase: SyncEngine.Phase,
        lastSyncedAt: Date?,
        pendingBatches: Int,
        uploadEnabled: Bool
    ) -> State? {
        switch phase {
        case .failed(let message):
            return .failed(message)
        case .waitingForUnlock:
            return .locked
        case .syncing(let metric, let progress, let total):
            return .running("\(metric.replacingOccurrences(of: "_", with: " ")) · \(progress) of \(total)")
        case .delivering(let remaining):
            return .running("\(remaining) batch\(remaining == 1 ? "" : "es") to upload")
        case .idle:
            break
        }

        // A queue with uploading switched off never drains on its own, so it is
        // worth saying — a growing pile of batches on the phone looks like
        // nothing at all until the disk fills.
        if pendingBatches > 0 && !uploadEnabled {
            return .uploadingOff(pending: pendingBatches)
        }
        // Two days is the same window the Server tab calls stale, so the two
        // screens cannot disagree about whether something is wrong.
        if let lastSyncedAt, Date().timeIntervalSince(lastSyncedAt) > 48 * 3600 {
            return .stale(since: lastSyncedAt)
        }
        return nil
    }
}
