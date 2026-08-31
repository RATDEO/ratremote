import AppKit
import SwiftUI

private let panelMargin: CGFloat = 14

@MainActor
final class TranscriptionOverlayPanel: ObservableObject {
    @Published fileprivate var displayedState: ThinkingOrbState = .listening
    @Published fileprivate var displayedLabel = "Agent listening\u{2026}"
    private var panel: NSPanel?

    func showListening() {
        show(state: .listening, label: "Agent listening\u{2026}")
    }

    func showWorking() {
        show(state: .working, label: "Working\u{2026}")
    }

    private func show(state: ThinkingOrbState, label: String) {
        displayedState = state
        displayedLabel = label
        ensurePanel()
        guard let panel else { return }
        sizeAndPositionPanel(panel, for: state)
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Panel lifecycle

    private func ensurePanel() {
        guard panel == nil else { return }

        let hosting = NSHostingController(rootView: OverlayContent(model: self))
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = 24
        hosting.view.layer?.masksToBounds = true

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 158, height: 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        self.panel = panel
    }

    private func sizeAndPositionPanel(_ panel: NSPanel, for state: ThinkingOrbState) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panelSize = state == .listening
            ? NSSize(width: 158, height: 42)
            : NSSize(width: 270, height: 76)
        let visible = screen.visibleFrame
        let x = visible.maxX - panelSize.width - panelMargin
        let y = visible.maxY - panelSize.height - panelMargin
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize), display: true, animate: panel.isVisible)
    }
}

// MARK: - Content view

private struct OverlayContent: View {
    @ObservedObject var model: TranscriptionOverlayPanel

    var body: some View {
        HStack(spacing: model.displayedState == .listening ? 8 : 14) {
            ThinkingOrb(
                state: model.displayedState,
                size: model.displayedState == .listening ? 22 : 58
            )

            Text(model.displayedLabel)
                .font(.system(
                    size: model.displayedState == .listening ? 12 : 18,
                    weight: model.displayedState == .listening ? .regular : .medium
                ))
                .foregroundStyle(model.displayedState == .listening ? .secondary : .primary)
                .lineLimit(1)
        }
        .padding(.horizontal, model.displayedState == .listening ? 12 : 18)
        .padding(.vertical, model.displayedState == .listening ? 7 : 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.displayedState == .listening ? .center : .leading)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .animation(.easeInOut(duration: 0.2), value: model.displayedState.rawValue)
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 24
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
