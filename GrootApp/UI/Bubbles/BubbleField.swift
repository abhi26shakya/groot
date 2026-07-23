import SwiftUI
import GrootKit

/// A self-contained physics field of glass "agent bubbles". Each agent gets a
/// bubble that drifts toward an anchor slot, softly repels its neighbors, can be
/// dragged, and expands on hover to reveal its live status.
///
/// Physics is a light spring/repulsion integrator stepped off the `TimelineView`
/// animation clock — deliberately simple; Metal is only warranted past ~30 bubbles.
struct BubbleField: View {
    @Environment(AppModel.self) private var model

    private struct Body2D { var pos: CGPoint; var vel: CGVector }
    @State private var bodies: [AgentID: Body2D] = [:]
    @State private var lastTick: Date = .now
    @State private var hovered: AgentID?
    @State private var dragging: AgentID?

    private let radius: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                ZStack {
                    ForEach(model.agents) { summary in
                        bubble(for: summary, in: geo.size)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onChange(of: timeline.date) { _, now in
                    step(to: now, size: geo.size)
                }
            }
        }
    }

    // MARK: One bubble

    @ViewBuilder
    private func bubble(for summary: AgentManager.AgentSummary, in size: CGSize) -> some View {
        let id = summary.id
        let color = Color(hex: summary.descriptor.colorHex)
        let pos = bodies[id]?.pos ?? seedPosition(for: id, in: size)
        let isHovered = hovered == id
        let running = summary.report.state == .running

        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(color.opacity(running ? 0.28 : 0.14)))
                .overlay(Circle().strokeBorder(color.opacity(0.55), lineWidth: 1))
                .shadow(color: color.opacity(running ? 0.5 : 0.2), radius: running ? 12 : 5)

            // Progress ring when a task is underway.
            if let progress = summary.report.progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
            }

            Image(systemName: summary.descriptor.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: radius * 2, height: radius * 2)
        .overlay(alignment: .bottom) {
            if isHovered { infoCard(summary).offset(y: radius * 2 + 8) }
        }
        .scaleEffect(isHovered ? 1.12 : 1.0)
        .position(pos)
        .animation(.spring(duration: 0.25), value: isHovered)
        .onHover { hovering in hovered = hovering ? id : (hovered == id ? nil : hovered) }
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragging = id
                    bodies[id] = Body2D(pos: value.location, vel: .zero)
                }
                .onEnded { _ in dragging = nil }
        )
    }

    private func infoCard(_ summary: AgentManager.AgentSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.descriptor.name).font(.caption.bold())
            if let task = summary.report.currentTask {
                Text(task).font(.caption2).foregroundStyle(.secondary)
            }
            if let last = summary.report.lastAction {
                Text(last).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: 180, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
        .zIndex(10)
    }

    // MARK: Physics

    private func step(to now: Date, size: CGSize) {
        let dt = min(max(now.timeIntervalSince(lastTick), 0), 1.0 / 30.0)
        lastTick = now
        guard size.width > 0, size.height > 0 else { return }

        let ids = model.agents.map(\.id)
        // Seed any new bubbles.
        for id in ids where bodies[id] == nil {
            bodies[id] = Body2D(pos: seedPosition(for: id, in: size), vel: .zero)
        }
        // Drop bubbles for agents that vanished.
        for key in bodies.keys where !ids.contains(key) { bodies[key] = nil }

        let anchors = anchorSlots(count: ids.count, in: size)

        for (index, id) in ids.enumerated() {
            guard id != dragging, var body = bodies[id] else { continue }
            let anchor = anchors[index]

            // Spring toward anchor.
            var fx = (anchor.x - body.pos.x) * 2.2
            var fy = (anchor.y - body.pos.y) * 2.2

            // Repulsion from other bubbles.
            for other in ids where other != id {
                guard let ob = bodies[other] else { continue }
                let dx = body.pos.x - ob.pos.x
                let dy = body.pos.y - ob.pos.y
                let distSq = max(dx * dx + dy * dy, 0.01)
                let minDist = radius * 2.3
                if distSq < minDist * minDist {
                    let dist = sqrt(distSq)
                    let push = (minDist - dist) * 6.0 / dist
                    fx += dx * push
                    fy += dy * push
                }
            }

            // Integrate with damping.
            body.vel.dx = (body.vel.dx + fx * dt) * 0.86
            body.vel.dy = (body.vel.dy + fy * dt) * 0.86
            body.pos.x += body.vel.dx * dt
            body.pos.y += body.vel.dy * dt

            // Keep inside bounds.
            body.pos.x = min(max(body.pos.x, radius), size.width - radius)
            body.pos.y = min(max(body.pos.y, radius), size.height - radius)

            bodies[id] = body
        }
    }

    /// Column-of-two anchor layout that scales to the panel.
    private func anchorSlots(count: Int, in size: CGSize) -> [CGPoint] {
        guard count > 0 else { return [] }
        let cols = count <= 3 ? 1 : 2
        let rows = Int(ceil(Double(count) / Double(cols)))
        var slots: [CGPoint] = []
        for i in 0..<count {
            let c = i % cols, r = i / cols
            let x = size.width * (Double(c) + 1) / Double(cols + 1)
            let y = size.height * (Double(r) + 1) / Double(rows + 1)
            slots.append(CGPoint(x: x, y: y))
        }
        return slots
    }

    private func seedPosition(for id: AgentID, in size: CGSize) -> CGPoint {
        // Deterministic pseudo-random from the id so bubbles don't all stack.
        let h = abs(id.raw.hashValue)
        let x = CGFloat(h % 100) / 100 * (size.width - radius * 2) + radius
        let y = CGFloat((h / 100) % 100) / 100 * (size.height - radius * 2) + radius
        return CGPoint(x: x, y: y)
    }
}
