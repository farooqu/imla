import AppKit
import Combine
import SwiftUI

typealias Phase = DictationController.Phase

/// What the pill shows. It keeps the last visible phase while the window fades
/// out, so the content doesn't collapse mid-fade.
@MainActor
final class OverlayModel: ObservableObject {
    @Published private(set) var phase: Phase = .listening
    private(set) var previous: Phase = .listening
    private(set) var changedAt = Date.distantPast
    // Per-frame animation state, deliberately not published.
    var smoothedLevel = 0.0
    var lastFrame: TimeInterval?

    func show(_ next: Phase, fresh: Bool) {
        previous = fresh ? next : phase
        phase = next
        changedAt = Date()
        if fresh { smoothedLevel = 0 }
    }
}

/// A floating, non-activating HUD, so focus stays in the app being dictated into.
@MainActor
final class OverlayWindow {
    /// Room around the pill for its shadow and for a notice, which widen it.
    static let size = NSSize(width: 480, height: 120)
    private static let pillHeight: CGFloat = 38

    private let panel: NSPanel
    private let controller: DictationController
    private let model = OverlayModel()
    private var cancellable: AnyCancellable?
    private var hiding = false

    init(controller: DictationController) {
        self.controller = controller
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: OverlayView(controller: controller, model: model))
        host.sizingOptions = []
        panel.contentView = host
        cancellable = controller.$phase.removeDuplicates().sink { [weak self] phase in
            phase == .idle ? self?.hide() : self?.show(phase)
        }
    }

    private func show(_ phase: Phase) {
        let fresh = !panel.isVisible || hiding
        model.show(phase, fresh: fresh)
        hiding = false
        if !panel.isVisible {
            panel.setFrameOrigin(origin(below: controller.anchor))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    /// Just below the caret, or above it near the bottom of the screen. Without
    /// a caret, at the bottom centre of the screen with the mouse.
    private func origin(below anchor: CGRect?) -> NSPoint {
        let half = Self.pillHeight / 2, gap: CGFloat = 14
        guard let anchor, let primary = NSScreen.screens.first else {
            let mouse = NSEvent.mouseLocation
            let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
            return NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 16 + half - Self.size.height / 2)
        }
        // Accessibility uses a top-left origin on the primary screen; AppKit, bottom-left.
        let top = primary.frame.maxY - anchor.minY, bottom = primary.frame.maxY - anchor.maxY
        let point = NSPoint(x: anchor.minX, y: bottom)
        let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? primary).visibleFrame
        var centerY = bottom - gap - half
        if centerY - half < visible.minY + 4 { centerY = top + gap + half }
        // Keep the whole window on screen, so a wide notice isn't cut off near an edge.
        let x = min(max(anchor.minX - Self.size.width / 2, visible.minX), visible.maxX - Self.size.width)
        return NSPoint(x: x, y: centerY - Self.size.height / 2)
    }

    private func hide() {
        guard panel.isVisible else { return }
        hiding = true
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
            Task { @MainActor in if self.hiding { self.panel.orderOut(nil); self.hiding = false } }
        }
    }
}

struct OverlayView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var model: OverlayModel

    private var message: String? {
        switch model.phase {
        case .failed(let text): text
        case .done(let notice): notice
        default: nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Bars(controller: controller, model: model).frame(width: Bars.width, height: Bars.height)
            if let message {
                // As wide as a short message needs; long ones wrap onto a second line.
                ViewThatFits(in: .horizontal) {
                    Text(message).fixedSize()
                    Text(message).lineLimit(2).frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .animation(.easeInOut(duration: 0.2), value: message)
        // Centred in a window larger than the pill, so the shadow is never clipped.
        .frame(width: OverlayWindow.size.width, height: OverlayWindow.size.height)
    }
}

/// Small bars whose colour and motion say what Imla is doing: gray following
/// your voice while listening, a blue sweep while transcribing, a slow purple
/// wave while cleaning up, green when done.
private struct Bars: View {
    @ObservedObject var controller: DictationController
    let model: OverlayModel

    static let count = 13
    static let barWidth: CGFloat = 3
    static let gap: CGFloat = 3
    static let height: CGFloat = 20
    static var width: CGFloat { CGFloat(count) * barWidth + CGFloat(count - 1) * gap }
    private static let rest = 0.12

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let dt = min(0.05, t - (model.lastFrame ?? t))
                model.lastFrame = t
                // Rise quickly with the voice and settle slowly, so bars don't flicker.
                let target = Double(controller.level)
                let rate = target > model.smoothedLevel ? 14.0 : 5.0
                model.smoothedLevel += (target - model.smoothedLevel) * min(1, rate * dt)

                let elapsed = timeline.date.timeIntervalSince(model.changedAt)
                let mix = smoothstep(min(1, elapsed / 0.35))
                let from = Self.color(model.previous).resolve(in: context.environment)
                let to = Self.color(model.phase).resolve(in: context.environment)
                let color = Color(Color.Resolved(red: lerp(from.red, to.red, mix), green: lerp(from.green, to.green, mix),
                                                 blue: lerp(from.blue, to.blue, mix), opacity: lerp(from.opacity, to.opacity, mix)))
                for i in 0..<Self.count {
                    let a = amplitude(model.previous, i, t), b = amplitude(model.phase, i, t)
                    let h = max(Self.barWidth, size.height * lerp(a, b, Double(mix)))
                    let x = CGFloat(i) * (Self.barWidth + Self.gap)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: Self.barWidth, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(color))
                }
            }
        }
    }

    /// Bar height from 0 to 1 for a phase.
    private func amplitude(_ phase: Phase, _ i: Int, _ t: TimeInterval) -> Double {
        let x = Double(i)
        let profile = 0.35 + 0.65 * sin(.pi * (x + 0.5) / Double(Self.count))
        switch phase {
        case .listening:
            let wobble = 0.8 + 0.2 * sin(t * 7 + x * 1.7)
            return max(Self.rest, min(1, model.smoothedLevel * 1.2) * profile * wobble)
        case .transcribing:
            let sweep = 0.5 + 0.5 * sin(t * 7 - x * 0.7)
            return Self.rest + 0.4 * sweep * sweep * profile
        case .polishing:
            return Self.rest + 0.3 * (0.5 + 0.5 * sin(t * 3.2 - x * 0.45)) * profile
        case .done, .failed, .idle:
            return Self.rest
        }
    }

    private static func color(_ phase: Phase) -> Color {
        switch phase {
        // Neutral, so red stays free for errors and green for done.
        case .listening: Color.primary.opacity(0.7)
        case .transcribing: Color(nsColor: .systemBlue).opacity(0.85)
        case .polishing: Color(nsColor: .systemPurple).opacity(0.85)
        case .done: Color(nsColor: .systemGreen).opacity(0.9)
        case .failed: Color(nsColor: .systemOrange).opacity(0.9)
        case .idle: Color.secondary
        }
    }
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func lerp(_ a: Float, _ b: Float, _ t: Double) -> Float { a + (b - a) * Float(t) }
private func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }
