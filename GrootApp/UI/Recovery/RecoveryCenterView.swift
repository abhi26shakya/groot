import SwiftUI
import GrootKit

/// The capstone of the safety model: a searchable, filterable, full history of
/// every operation Groot has performed, with single and batch restore, and
/// filesystem-inert retention controls.
struct RecoveryCenterView: View {
    @Environment(AppModel.self) private var model

    /// How far back "Clear reverted entries" reaches. Named once so the menu
    /// label and the actual cutoff computation can't drift apart.
    private static let retentionWindowDays = 30

    @State private var agentFilter: AgentID?
    @State private var kindFilter: Set<FileOperationKind> = []
    @State private var revertState: JournalFilter.RevertState = .any
    @State private var searchText = ""
    @State private var selection = Set<UUID>()
    @State private var showClearAllConfirm = false
    @State private var showBatchRestoreConfirm = false
    @State private var resultMessage: String?
    /// Fetched right before showing the "Clear all history" confirmation, so
    /// the warning can call out items that would lose their restore path.
    @State private var unrevertedTrashCount = 0

    private var filter: JournalFilter {
        JournalFilter(agentID: agentFilter, kinds: kindFilter, revertState: revertState,
                      searchText: searchText.isEmpty ? nil : searchText)
    }

    private var availableAgents: [AgentID] {
        Array(Set(model.recoveryEntries.map(\.agentID))).sorted { $0.raw < $1.raw }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            RecoveryFilterBar(
                agentFilter: $agentFilter, kindFilter: $kindFilter,
                revertState: $revertState, searchText: $searchText,
                availableAgents: availableAgents)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            if !selection.isEmpty { batchBar }

            list
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(BackdropView())
        .task(id: filter) { await model.loadRecovery(filter: filter) }
        .alert("Clear all history?", isPresented: $showClearAllConfirm) {
            Button("Clear", role: .destructive) { Task { await model.clearAllHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearAllWarning)
        }
        .alert("Restore \(selection.count) selected?", isPresented: $showBatchRestoreConfirm) {
            Button("Restore") { Task { await performBatchRestore() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Restore complete",
               isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(resultMessage ?? "")
        }
        .alert("Couldn't complete that",
               isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.clearLastError() } })) {
            Button("OK") { model.clearLastError() }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var clearAllWarning: String {
        var text = "Removes recorded operations from the Recovery Center. This never deletes or moves any file."
        if unrevertedTrashCount > 0 {
            text += " \(unrevertedTrashCount) item(s) currently in the Trash will no longer be restorable from Groot."
        }
        return text
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recovery Center").font(.title2.bold())
                Text("Every operation Groot has performed — nothing here is one-way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Clear reverted entries older than \(Self.retentionWindowDays) days") {
                    Task { await clearOldReverted() }
                }
                Button(role: .destructive) {
                    Task {
                        unrevertedTrashCount = await model.unrevertedTrashCount()
                        showClearAllConfirm = true
                    }
                } label: {
                    Text("Clear all history")
                }
            } label: {
                Label("Retention", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(20)
    }

    private var batchBar: some View {
        HStack {
            Text("\(selection.count) selected").font(.callout)
            Spacer()
            Button("Clear selection") { selection.removeAll() }
                .buttonStyle(.bordered)
            Button("Restore selected") { showBatchRestoreConfirm = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        if model.recoveryEntries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.recoveryEntries) { entry in
                        RecoveryRow(
                            entry: entry,
                            isSelected: selection.contains(entry.id),
                            onToggleSelect: { toggle(entry.id) },
                            onRestore: { Task { await restore(entry) } })
                        if entry.id != model.recoveryEntries.last?.id {
                            Divider().opacity(0.2).padding(.leading, 52)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No operations yet").font(.headline)
            Text("Groot hasn't moved anything.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    // `AppModel`'s undo/restore/batchRestore/clearHistory/clearAllHistory all
    // call `refresh()` internally, which keeps `recoveryEntries` current
    // against the last-loaded filter — no explicit reload needed here.

    private func restore(_ entry: JournalEntry) async {
        await model.restore(entry)
    }

    private func performBatchRestore() async {
        let entries = model.recoveryEntries.filter { selection.contains($0.id) }
        let outcome = await model.batchRestore(entries)
        selection.removeAll()
        resultMessage = outcome.skipped.isEmpty
            ? "Restored \(outcome.restoredCount) item(s)."
            : "Restored \(outcome.restoredCount), skipped \(outcome.skipped.count): "
              + outcome.skipped
                .map { "\(($0.entry.sourcePath as NSString).lastPathComponent) — \($0.reason)" }
                .joined(separator: "; ")
    }

    private func clearOldReverted() async {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.retentionWindowDays, to: Date()) ?? Date()
        await model.clearHistory(olderThan: cutoff, revertedOnly: true)
    }
}

/// Same Vision-Pro-ish gradient as the dashboard, kept private to each view
/// since neither imports the other.
private struct BackdropView: View {
    var body: some View {
        LinearGradient(
            colors: [Color(hex: "#0B1220"), Color(hex: "#131A2A")],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea()
    }
}
