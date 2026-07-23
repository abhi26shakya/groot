import SwiftUI
import GrootKit

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if !model.hasFullDiskAccess {
                    FullDiskAccessBanner()
                }

                statRow

                actionRow

                if !model.pendingApprovals.isEmpty {
                    section("Needs your approval") {
                        ForEach(model.pendingApprovals) { request in
                            ApprovalCard(request: request)
                        }
                    }
                }

                if let report = model.storageReport, !report.insights.isEmpty {
                    section("Storage insights") {
                        StorageInsightsView(report: report)
                    }
                }

                if let report = model.duplicateReport, !report.groups.isEmpty {
                    section("Duplicates") {
                        DuplicateReportView(report: report)
                    }
                }

                section("Agents") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)],
                              spacing: 14) {
                        ForEach(model.agents) { summary in
                            AgentCard(summary: summary)
                        }
                    }
                }

                section("Recent activity") {
                    ActivityList()
                }
            }
            .padding(28)
        }
        .background(BackdropView())
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Groot").font(.largeTitle.bold())
                Text("AI Storage Management")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.toggleRunning() }
            } label: {
                Label(model.isRunning ? "Pause" : "Start",
                      systemImage: model.isRunning ? "pause.fill" : "play.fill")
                    .frame(width: 84)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private var statRow: some View {
        HStack(spacing: 14) {
            StatTile(title: "Active Agents", value: "\(model.runningCount)",
                     systemImage: "circle.hexagongrid.fill", tint: .green)
            StatTile(title: "Files Organized", value: "\(model.filesOrganized)",
                     systemImage: "tray.full.fill", tint: .blue)
            StatTile(title: "Storage Recovered", value: model.storageRecovered,
                     systemImage: "internaldrive.fill", tint: .purple)
            StatTile(title: "Uptime", value: Self.formatUptime(model.uptime),
                     systemImage: "clock.fill", tint: .orange)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            ActionButton(title: "Scan Duplicates", systemImage: "square.on.square",
                         busy: model.isScanning) {
                Task { await model.scanDuplicates() }
            }
            ActionButton(title: "Analyze Storage", systemImage: "chart.pie",
                         busy: model.isScanning) {
                Task { await model.analyzeStorage() }
            }
            ActionButton(title: "Tidy Desktop", systemImage: "sparkles") {
                Task { await model.organizeDesktop() }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            content()
        }
    }

    static func formatUptime(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// Soft gradient backdrop for the Vision-Pro-ish look.
private struct BackdropView: View {
    var body: some View {
        LinearGradient(
            colors: [Color(hex: "#0B1220"), Color(hex: "#131A2A")],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        .overlay(.ultraThinMaterial.opacity(0.0))
        .ignoresSafeArea()
    }
}
