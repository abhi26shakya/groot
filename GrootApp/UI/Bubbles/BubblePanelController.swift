import AppKit
import SwiftUI

/// Hosts the `BubbleField` in a borderless, transparent, always-floating panel
/// anchored to the bottom-right of the main screen. Non-activating so it never
/// steals focus from the app you're working in.
@MainActor
final class BubblePanelController {
    private var panel: NSPanel?
    private let model: AppModel

    private let size = CGSize(width: 340, height: 480)
    private let margin: CGFloat = 24

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if panel == nil { build() }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView:
            BubbleField()
                .environment(model)
                .frame(width: size.width, height: size.height)
        )
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        positionBottomRight(panel)
        self.panel = panel
    }

    private func positionBottomRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin)
        panel.setFrameOrigin(origin)
    }
}
