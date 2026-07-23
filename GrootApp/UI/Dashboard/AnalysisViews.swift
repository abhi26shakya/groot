import SwiftUI
import GrootKit

/// A pill-style action button used in the dashboard's action row.
struct ActionButton: View {
    let title: String
    let systemImage: String
    var busy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// Storage analysis: recommendations first (the differentiator), then the
/// heaviest files.
struct StorageInsightsView: View {
    let report: StorageReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(report.insights) { insight in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title).font(.headline)
                        Text(insight.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteFormat.string(insight.reclaimableBytes))
                        .font(.callout.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if !report.largestFiles.isEmpty {
                Text("Largest files").font(.subheadline.bold()).padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(report.largestFiles.prefix(8)) { file in
                        HStack {
                            Image(systemName: "doc.fill").foregroundStyle(.secondary).frame(width: 18)
                            Text(file.name).lineLimit(1)
                            Spacer()
                            Text(ByteFormat.string(file.sizeBytes))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        if file.id != report.largestFiles.prefix(8).last?.id { Divider().opacity(0.3) }
                    }
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

/// Duplicate groups with recoverable-space summary. Deletion is gated by the
/// approval card, so this view is informational.
struct DuplicateReportView: View {
    let report: DuplicateReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(report.duplicateCount) duplicates in \(report.groups.count) groups",
                      systemImage: "square.on.square")
                    .font(.headline)
                Spacer()
                Text("\(ByteFormat.string(report.totalRecoverableBytes)) recoverable")
                    .font(.callout.bold()).foregroundStyle(.green)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            ForEach(report.groups.prefix(8)) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(group.original.map { ($0 as NSString).lastPathComponent } ?? "—")
                            .font(.callout.bold()).lineLimit(1)
                        Spacer()
                        Text("×\(group.paths.count) · \(ByteFormat.string(group.recoverableBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(group.duplicates, id: \.self) { dup in
                        Text((dup as NSString).lastPathComponent)
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
