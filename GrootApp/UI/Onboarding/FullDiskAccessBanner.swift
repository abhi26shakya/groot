import SwiftUI

/// Shown until Full Disk Access is granted. Without it, monitoring can't see
/// most folders, so we surface this prominently and make granting one click.
struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Grant Full Disk Access").font(.headline)
                Text("Groot needs Full Disk Access to monitor and organize your files. "
                     + "Open Settings, enable Groot, then click Re-check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 8) {
                Button("Open Settings") { AppModel.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Re-check") { model.recheckFullDiskAccess() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.orange.opacity(0.4)))
    }
}
