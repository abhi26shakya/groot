import SwiftUI
import GrootKit

/// One row in the Recovery Center: selection toggle, kind icon, filename,
/// source → destination, agent + relative time, status badge, and a
/// Restore/Undo action when the entry is currently reversible.
struct RecoveryRow: View {
    let entry: JournalEntry
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text(pathSummary)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(entry.agentID.raw.capitalized) · \(relativeTime)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Spacer()

            statusBadge

            if status == .applied {
                Button(entry.kind == .trash ? "Restore" : "Undo") { onRestore() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch entry.kind {
        case .move: return "arrow.right.doc.on.clipboard"
        case .rename: return "pencil"
        case .trash: return "trash"
        case .permanentDelete: return "trash.slash"
        }
    }

    private var displayName: String {
        ((entry.destinationPath ?? entry.sourcePath) as NSString).lastPathComponent
    }

    private var pathSummary: String {
        if entry.kind == .trash {
            return entry.sourcePath
        }
        if let destination = entry.destinationPath {
            return "\(entry.sourcePath) → \(destination)"
        }
        return entry.sourcePath
    }

    private var relativeTime: String {
        entry.timestamp.formatted(.relative(presentation: .named))
    }

    /// Shared with the Dashboard's activity list (`ActivityRow`) via
    /// `JournalEntry.recoveryStatus(fileManager:)` — a pure, GrootKit-level
    /// computation rather than a View reaching into the filesystem itself.
    private var status: RecoveryStatus { entry.recoveryStatus() }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .reverted: badge("Reverted", .secondary)
        case .unavailable: badge("Unavailable", .orange)
        case .applied: badge("Applied", .green)
        }
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
