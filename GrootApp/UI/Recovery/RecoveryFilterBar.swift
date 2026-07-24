import SwiftUI
import GrootKit

/// Filter/search controls for the Recovery Center: agent, kind, revert-state,
/// and a live search field. All the bindings compose (AND) into one
/// `JournalFilter` the parent view rebuilds on every change.
struct RecoveryFilterBar: View {
    @Binding var agentFilter: AgentID?
    @Binding var kindFilter: Set<FileOperationKind>
    @Binding var revertState: JournalFilter.RevertState
    @Binding var searchText: String
    let availableAgents: [AgentID]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by filename or path", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .frame(minWidth: 220)

            Divider().frame(height: 16)

            Menu(agentFilter.map { $0.raw.capitalized } ?? "All agents") {
                Button("All agents") { agentFilter = nil }
                if !availableAgents.isEmpty { Divider() }
                ForEach(availableAgents, id: \.self) { agent in
                    Button(agent.raw.capitalized) { agentFilter = agent }
                }
            }

            Menu(kindLabel) {
                Button("All kinds") { kindFilter = [] }
                Divider()
                ForEach([FileOperationKind.move, .rename, .trash], id: \.self) { kind in
                    Button {
                        toggle(kind)
                    } label: {
                        Label(kind.rawValue.capitalized,
                              systemImage: kindFilter.contains(kind) ? "checkmark" : "")
                    }
                }
            }

            Picker("", selection: $revertState) {
                Text("All").tag(JournalFilter.RevertState.any)
                Text("Applied").tag(JournalFilter.RevertState.appliedOnly)
                Text("Reverted").tag(JournalFilter.RevertState.revertedOnly)
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .labelsHidden()

            Spacer()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var kindLabel: String {
        kindFilter.isEmpty
            ? "All kinds"
            : kindFilter.map(\.rawValue.capitalized).sorted().joined(separator: ", ")
    }

    private func toggle(_ kind: FileOperationKind) {
        if kindFilter.contains(kind) { kindFilter.remove(kind) } else { kindFilter.insert(kind) }
    }
}
