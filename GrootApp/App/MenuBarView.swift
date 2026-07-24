import SwiftUI
import GrootKit

/// Compact popover shown from the menu-bar icon: status + quick controls.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                Text("Groot").font(.headline)
                Spacer()
                Circle()
                    .fill(model.isRunning ? .green : .secondary)
                    .frame(width: 8, height: 8)
                Text(model.isRunning ? "Running" : "Paused")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Label("\(model.runningCount) agents active", systemImage: "circle.hexagongrid")
                .font(.callout)
            Label("\(model.filesOrganized) files organized", systemImage: "tray.full")
                .font(.callout)
            if !model.pendingApprovals.isEmpty {
                Label("\(model.pendingApprovals.count) awaiting approval", systemImage: "bell.badge")
                    .font(.callout).foregroundStyle(.orange)
            }

            Divider()

            Button {
                Task { await model.toggleRunning() }
            } label: {
                Label(model.isRunning ? "Pause all agents" : "Start all agents",
                      systemImage: model.isRunning ? "pause.fill" : "play.fill")
            }

            Button {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Dashboard", systemImage: "square.grid.2x2")
            }

            Button {
                openWindow(id: "recovery")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Recovery Center", systemImage: "clock.arrow.circlepath")
            }

            Toggle(isOn: Binding(
                get: { model.showBubbles },
                set: { on in
                    model.showBubbles = on
                    if on { model.presentBubbles() } else { model.hideBubbles() }
                })) {
                Label("Floating bubbles", systemImage: "circle.circle")
            }

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Groot", systemImage: "power")
            }
        }
        .padding(14)
        .frame(width: 260)
        .buttonStyle(.plain)
    }
}
