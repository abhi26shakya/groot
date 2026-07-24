import SwiftUI
import GrootKit

/// A single KPI tile in the dashboard's top row.
struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
            Text(value).font(.title.bold()).contentTransition(.numericText())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }
}

/// A live card for one agent: color dot, state, current task, progress.
struct AgentCard: View {
    let summary: AgentManager.AgentSummary

    private var color: Color { Color(hex: summary.descriptor.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(color.opacity(0.22)).frame(width: 34, height: 34)
                    Image(systemName: summary.descriptor.symbol)
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.descriptor.name).font(.headline)
                    Text(stateLabel).font(.caption).foregroundStyle(stateColor)
                }
                Spacer()
                StatusDot(state: summary.report.state)
            }

            if let task = summary.report.currentTask {
                Text(task).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let progress = summary.report.progress {
                ProgressView(value: progress).tint(color)
            }
            if let last = summary.report.lastAction {
                Text(last).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.18)))
    }

    private var stateLabel: String { summary.report.state.rawValue.capitalized }
    private var stateColor: Color {
        switch summary.report.state {
        case .running: return .green
        case .paused: return .orange
        case .error: return .red
        default: return .secondary
        }
    }
}

struct StatusDot: View {
    let state: AgentState
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.7), radius: 4)
    }
    private var color: Color {
        switch state {
        case .running: return .green
        case .paused: return .orange
        case .error: return .red
        case .stopped: return .gray
        case .idle: return .blue
        }
    }
}

/// An approval prompt card, with Approve / Skip actions.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let request: ApprovalRequest

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: request.isDestructive ? "exclamationmark.triangle.fill" : "wand.and.stars")
                .font(.title2)
                .foregroundStyle(request.isDestructive ? .red : .yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.summary).font(.headline)
                if let detail = request.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button("Skip") { Task { await model.reject(request) } }
                .buttonStyle(.bordered)
            Button("Approve") { Task { await model.approve(request) } }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.yellow.opacity(0.25)))
    }
}

/// Recent journaled operations with per-move Undo (the Recovery Center seed).
struct ActivityList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.activity.isEmpty {
            Text("No activity yet. Take a screenshot or drop a file on your Desktop.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else {
            VStack(spacing: 0) {
                ForEach(model.activity.prefix(20)) { entry in
                    ActivityRow(entry: entry)
                    if entry.id != model.activity.prefix(20).last?.id { Divider().opacity(0.3) }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let entry: JournalEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text((entry.destinationPath ?? entry.sourcePath as String).asFilename)
                    .font(.callout).lineLimit(1)
                Text("\(entry.kind.rawValue.capitalized) · \(entry.agentID.raw)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            // Shared with the Recovery Center (`RecoveryRow`) via
            // `JournalEntry.recoveryStatus(fileManager:)`, so the two never
            // diverge on what counts as currently restorable.
            switch entry.recoveryStatus() {
            case .reverted:
                Text("Reverted").font(.caption2).foregroundStyle(.tertiary)
            case .applied:
                Button(entry.kind == .trash ? "Restore" : "Undo") {
                    Task { await model.undo(entry) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .unavailable:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var icon: String {
        switch entry.kind {
        case .move: return "arrow.right.doc.on.clipboard"
        case .rename: return "pencil"
        case .trash: return "trash"
        }
    }
}

private extension String {
    var asFilename: String { (self as NSString).lastPathComponent }
}
