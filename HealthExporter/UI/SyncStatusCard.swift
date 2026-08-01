import SwiftUI

/// The one thing the Status tab should answer at a glance: is this working?
///
/// Deliberately not a numbers panel. "Synced 4 minutes ago" answers the actual
/// question; "1,284,551 records / 712 batches / 2,031 pending" makes the reader
/// do the work. Counts still exist on the Server tab for when they are wanted.
struct SyncStatusCard: View {
    let phase: SyncEngine.Phase
    let lastSyncedAt: Date?
    let pendingBatches: Int
    let uploadEnabled: Bool

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 10)

                if case .syncing(_, let progress, let total) = phase, total > 0 {
                    Circle()
                        .trim(from: 0, to: min(1, Double(progress) / Double(total)))
                        .stroke(tint.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: progress)
                } else if phase.isRunning {
                    // Delivering has no meaningful denominator — an indeterminate
                    // sweep is honest where a filled ring would be invented.
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(tint.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(pulse ? 360 : 0))
                        .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
                } else {
                    Circle()
                        .trim(from: 0, to: 1)
                        .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }

                VStack(spacing: 3) {
                    Image(systemName: symbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                    Text(headline)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)
            .onAppear { pulse = true }

            VStack(spacing: 4) {
                Text(relativeLastSync)
                    .font(.title3.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if pendingBatches > 0 {
                QueueBar(pending: pendingBatches, uploadEnabled: uploadEnabled)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Presentation

    private var symbol: String {
        switch phase {
        case .idle: return lastSyncedAt == nil ? "circle.dotted" : "checkmark"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .delivering: return "arrow.up.to.line"
        case .waitingForUnlock: return "lock"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch phase {
        case .failed: return .orange
        case .waitingForUnlock: return .secondary
        case .idle: return lastSyncedAt == nil ? .secondary : .green
        default: return .accentColor
        }
    }

    private var headline: String {
        switch phase {
        case .idle: return lastSyncedAt == nil ? "Not yet" : "Up to date"
        case .syncing: return "Reading"
        case .delivering: return "Uploading"
        case .waitingForUnlock: return "Locked"
        case .failed: return "Attention"
        }
    }

    /// The headline fact. A relative time is what people actually check for;
    /// an absolute timestamp makes them do the subtraction.
    private var relativeLastSync: String {
        guard let lastSyncedAt else { return "Never synced" }
        let elapsed = Date().timeIntervalSince(lastSyncedAt)
        if elapsed < 90 { return "Synced just now" }
        return "Synced \(lastSyncedAt.formatted(.relative(presentation: .named)))"
    }

    private var detail: String? {
        switch phase {
        case .syncing(let metric, let progress, let total):
            return "\(metric.replacingOccurrences(of: "_", with: " ")) · \(progress) of \(total)"
        case .delivering(let remaining):
            return "\(remaining) batch\(remaining == 1 ? "" : "es") to upload"
        case .waitingForUnlock:
            return "Health data is encrypted while the phone is locked. This resumes on unlock."
        case .failed(let message):
            return message
        case .idle:
            guard let lastSyncedAt, Date().timeIntervalSince(lastSyncedAt) > 48 * 3600 else { return nil }
            return "Nothing has synced in over two days."
        }
    }
}

/// Queue depth as a proportion rather than a count. "How much is left" is the
/// question; the exact number of files is not.
private struct QueueBar: View {
    let pending: Int
    let uploadEnabled: Bool

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(uploadEnabled ? Color.accentColor.gradient : Color.orange.gradient)
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 8)

            Text(uploadEnabled
                 ? "Queued to upload"
                 : "Queued — uploading is off")
                .font(.caption2)
                .foregroundStyle(uploadEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
        }
        .padding(.horizontal, 24)
    }

    /// Against a soft ceiling so the bar reads as "a lot" rather than tracking
    /// an exact backlog the reader can't act on.
    private var fraction: Double {
        min(1, Double(pending) / 200)
    }
}
