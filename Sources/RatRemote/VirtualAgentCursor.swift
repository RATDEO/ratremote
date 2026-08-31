import AppKit
import CoreGraphics
import Foundation

enum AgentCursorActivity {
    case hidden
    case idle
    case thinking
    case acting
}

@MainActor
final class VirtualAgentCursor {
    private let size = CGSize(width: 27, height: 32)
    private let hotSpot = CGPoint(x: 3, y: 3)
    private var panel: NSPanel?
    private var cursorView: VirtualAgentCursorView?
    private var targetBounds: CGRect?
    private var basePosition: CGPoint?
    private var activity: AgentCursorActivity = .hidden
    private var motionTimer: Timer?
    private var pulseTimer: Timer?
    private var phase: Double = 0
    private var pulseStart: Date?
    private var cursorColor: NSColor {
        NSColor.controlAccentColor
    }

    func show(targetWindow: WindowCaptureTarget?, activity: AgentCursorActivity = .idle) {
        targetBounds = targetWindow?.bounds
        if basePosition == nil || targetBounds.map({ !$0.contains(basePosition ?? .zero) }) == true {
            basePosition = initialPosition(for: targetWindow)
        }
        self.activity = activity
        ensurePanel()
        cursorView?.cursorColor = cursorColor
        cursorView?.activity = activity
        panel?.orderFrontRegardless()
        updateTimer()
        positionPanel(animated: false)
    }

    func setActivity(_ activity: AgentCursorActivity) {
        guard activity != .hidden else {
            hide()
            return
        }
        self.activity = activity
        cursorView?.activity = activity
        ensurePanel()
        panel?.orderFrontRegardless()
        updateTimer()
        positionPanel(animated: false)
    }

    func move(to point: CGPoint, animated: Bool = true) {
        basePosition = clamped(point)
        if activity == .hidden {
            activity = .acting
        }
        ensurePanel()
        cursorView?.activity = activity
        panel?.orderFrontRegardless()
        positionPanel(animated: animated)
    }

    func moveBy(dx: Double, dy: Double, fallbackWindow: WindowCaptureTarget?) -> CGPoint {
        if targetBounds == nil {
            targetBounds = fallbackWindow?.bounds
        }
        let start = basePosition ?? initialPosition(for: fallbackWindow)
        let point = clamped(CGPoint(x: start.x + dx, y: start.y - dy))
        move(to: point)
        return point
    }

    func click(at point: CGPoint) {
        move(to: point)
        pulseStart = Date()
        cursorView?.pulseFraction = 0
        cursorView?.needsDisplay = true
        startPulseTimer()
    }

    func currentPosition(fallbackWindow: WindowCaptureTarget?) -> CGPoint {
        if targetBounds == nil {
            targetBounds = fallbackWindow?.bounds
        }
        if let basePosition {
            return clamped(basePosition)
        }
        let position = initialPosition(for: fallbackWindow)
        basePosition = position
        return position
    }

    func hide(after delay: TimeInterval = 0.35) {
        motionTimer?.invalidate()
        motionTimer = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        activity = .hidden
        cursorView?.activity = .hidden
        guard let panel else { return }
        if delay <= 0 {
            panel.orderOut(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak panel] in
            guard let self, self.activity == .hidden else { return }
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let view = VirtualAgentCursorView(frame: CGRect(origin: .zero, size: size))
        view.cursorColor = cursorColor
        view.activity = activity

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view

        self.panel = panel
        self.cursorView = view
    }

    private func updateTimer() {
        motionTimer?.invalidate()
        motionTimer = nil
        guard activity == .thinking else {
            positionPanel(animated: false)
            return
        }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func startPulseTimer() {
        pulseTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 45.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickPulse()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func tick() {
        phase += 0.18
        positionPanel(animated: false)
        cursorView?.needsDisplay = true
    }

    private func tickPulse() {
        guard let pulseStart else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            return
        }

        let fraction = min(1, Date().timeIntervalSince(pulseStart) / 0.28)
        cursorView?.pulseFraction = fraction
        cursorView?.needsDisplay = true
        if fraction >= 1 {
            self.pulseStart = nil
            pulseTimer?.invalidate()
            pulseTimer = nil
        }
    }

    private func positionPanel(animated: Bool) {
        guard let panel, let basePosition else { return }
        let point = displayedPoint(from: basePosition)
        let appKit = appKitPoint(fromQuartzPoint: point)
        let origin = CGPoint(
            x: appKit.x - hotSpot.x,
            y: appKit.y - (size.height - hotSpot.y)
        )
        let frame = CGRect(origin: origin, size: size)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func displayedPoint(from point: CGPoint) -> CGPoint {
        guard activity == .thinking else { return point }
        let radius = 1.4
        return clamped(CGPoint(
            x: point.x + cos(phase) * radius,
            y: point.y + sin(phase * 1.35) * radius
        ))
    }

    private func initialPosition(for targetWindow: WindowCaptureTarget?) -> CGPoint {
        if let targetWindow {
            return CGPoint(x: targetWindow.bounds.midX, y: targetWindow.bounds.midY)
        }
        return CGEvent(source: nil)?.location ?? CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX, y: CGDisplayBounds(CGMainDisplayID()).midY)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let bounds = targetBounds ?? CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: min(bounds.maxX - 1, max(bounds.minX, point.x)),
            y: min(bounds.maxY - 1, max(bounds.minY, point.y))
        )
    }

    private func appKitPoint(fromQuartzPoint point: CGPoint) -> CGPoint {
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let quartzFrame = CGDisplayBounds(CGDirectDisplayID(displayID.uint32Value))
            guard quartzFrame.contains(point) else { continue }
            return CGPoint(
                x: screen.frame.minX + (point.x - quartzFrame.minX),
                y: screen.frame.maxY - (point.y - quartzFrame.minY)
            )
        }

        let screen = NSScreen.main
        let screenFrame = screen?.frame ?? CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080))
        let displayFrame = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: screenFrame.minX + (point.x - displayFrame.minX),
            y: screenFrame.maxY - (point.y - displayFrame.minY)
        )
    }

}

private final class VirtualAgentCursorView: NSView {
    var cursorColor: NSColor = .systemBlue {
        didSet { needsDisplay = true }
    }
    var activity: AgentCursorActivity = .hidden {
        didSet { needsDisplay = true }
    }
    var pulseFraction: Double = 1 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard activity != .hidden else { return }

        if activity == .thinking {
            drawThinkingHalo()
        }
        if pulseFraction < 1 {
            drawPulse()
        }
        drawCursor()
    }

    private func drawCursor() {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 3, y: 3))
        path.line(to: CGPoint(x: 4.8, y: 27.4))
        path.line(to: CGPoint(x: 10.6, y: 21.7))
        path.line(to: CGPoint(x: 15.2, y: 30.2))
        path.line(to: CGPoint(x: 21.3, y: 26.7))
        path.line(to: CGPoint(x: 16.3, y: 18.1))
        path.line(to: CGPoint(x: 24, y: 16.4))
        path.close()
        path.lineJoinStyle = .miter
        path.lineCapStyle = .butt

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = CGSize(width: 0, height: -0.5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.set()
        (cursorColor.usingColorSpace(.deviceRGB) ?? cursorColor).withAlphaComponent(0.96).setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 2
        path.miterLimit = 10
        path.stroke()

        NSColor.black.withAlphaComponent(0.72).setStroke()
        path.lineWidth = 1
        path.miterLimit = 10
        path.stroke()
    }

    private func drawThinkingHalo() {
        let halo = NSBezierPath(ovalIn: CGRect(x: 0.5, y: 0.5, width: 13, height: 13))
        cursorColor.withAlphaComponent(0.28).setStroke()
        halo.lineWidth = 1
        halo.stroke()
    }

    private func drawPulse() {
        let radius = 5 + pulseFraction * 9
        let alpha = max(0, 0.28 * (1 - pulseFraction))
        let rect = CGRect(x: 5 - radius, y: 4 - radius, width: radius * 2, height: radius * 2)
        let pulse = NSBezierPath(ovalIn: rect)
        cursorColor.withAlphaComponent(alpha).setStroke()
        pulse.lineWidth = 1.2
        pulse.stroke()
    }
}
