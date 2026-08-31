import AppKit
import SwiftUI

@MainActor
final class LiquidKeyboardController {
    private let executor: ActionExecutor
    private var panel: LiquidKeyboardPanel?
    private var targetApplication: NSRunningApplication?
    private var currentDevMode = false
    private var magnificationIndex = 0
    private var dragStartOrigin: CGPoint?
    private var remoteDragActive = false
    private let magnificationScales: [CGFloat] = [1.0, 1.15, 1.3]

    init(executor: ActionExecutor) {
        self.executor = executor
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func toggle(devMode: Bool, targetApplication: NSRunningApplication?) {
        if isVisible, currentDevMode == devMode {
            hide()
            return
        }
        show(devMode: devMode, targetApplication: targetApplication)
    }

    func show(devMode: Bool, targetApplication: NSRunningApplication?) {
        currentDevMode = devMode
        if let targetApplication {
            self.targetApplication = targetApplication
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        updateContent(for: panel)
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func setDevMode(_ devMode: Bool) {
        guard currentDevMode != devMode else { return }
        currentDevMode = devMode
        guard let panel else { return }
        updateContent(for: panel)
        resize(panel, preservingCenter: true)
    }

    private func magnify() {
        magnificationIndex = (magnificationIndex + 1) % magnificationScales.count
        guard let panel else { return }
        updateContent(for: panel)
        resize(panel, preservingCenter: true)
    }

    private func beginDrag() {
        guard let panel else { return }
        dragStartOrigin = panel.frame.origin
    }

    private func drag(by translation: CGSize) {
        guard let panel, let dragStartOrigin else { return }
        let size = panel.frame.size
        let origin = CGPoint(
            x: dragStartOrigin.x + translation.width,
            y: dragStartOrigin.y - translation.height
        )
        panel.setFrame(NSRect(origin: clamped(origin: origin, size: size), size: size), display: true)
    }

    private func endDrag() {
        dragStartOrigin = nil
    }

    func beginRemoteDrag(at screenLocation: CGPoint) -> Bool {
        guard let panel,
              panel.isVisible,
              remoteDragRegionContains(screenLocation, in: panel.frame) else {
            return false
        }
        remoteDragActive = true
        return true
    }

    func dragRemote(from previousLocation: CGPoint, to currentLocation: CGPoint) -> Bool {
        guard let panel, remoteDragActive else { return false }
        let delta = CGSize(
            width: currentLocation.x - previousLocation.x,
            height: currentLocation.y - previousLocation.y
        )
        let size = panel.frame.size
        let origin = CGPoint(
            x: panel.frame.origin.x + delta.width,
            y: panel.frame.origin.y + delta.height
        )
        panel.setFrame(NSRect(origin: clamped(origin: origin, size: size), size: size), display: true)
        return true
    }

    func endRemoteDrag() -> Bool {
        let wasActive = remoteDragActive
        remoteDragActive = false
        return wasActive
    }

    private func makePanel() -> LiquidKeyboardPanel {
        let panel = LiquidKeyboardPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // The header has its own drag gesture. Treating the entire panel as a
        // draggable background can steal remote-generated clicks from keys.
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        // Buttons still receive down/up events without asking AppKit to route
        // every synthetic remote mouse-move through this large SwiftUI panel.
        panel.acceptsMouseMovedEvents = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func updateContent(for panel: LiquidKeyboardPanel) {
        let size = keyboardSize()
        let keyboard = LiquidKeyboardView(
            devMode: currentDevMode,
            targetTitle: targetApplication?.localizedName ?? "Frontmost app",
            onOutput: { [weak self] output in
                self?.handle(output)
            },
            onDevModeChange: { [weak self] devMode in
                self?.setDevMode(devMode)
            },
            onMagnify: { [weak self] in
                self?.magnify()
            },
            onDragStart: { [weak self] in
                self?.beginDrag()
            },
            onDragChanged: { [weak self] translation in
                self?.drag(by: translation)
            },
            onDragEnd: { [weak self] in
                self?.endDrag()
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )
        .frame(width: size.width, height: size.height)

        panel.contentView = NSHostingView(rootView: keyboard)
    }

    private func handle(_ output: LiquidKeyboardOutput) {
        switch output {
        case .text(let text):
            executor.typeKeyboardText(text, targetApplication: targetApplication)
        case .key(let key, let modifiers):
            executor.press(key: key, modifiers: modifiers, targetApplication: targetApplication)
        }
    }

    private func position(_ panel: NSPanel) {
        let size = keyboardSize()
        let screen = screenForKeyboard()
        let visibleFrame = screen.visibleFrame
        let origin = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 26
        )
        panel.setFrame(NSRect(origin: clamped(origin: origin, size: size), size: size), display: true)
    }

    private func resize(_ panel: NSPanel, preservingCenter: Bool) {
        let size = keyboardSize()
        let currentFrame = panel.frame
        let origin: CGPoint
        if preservingCenter, currentFrame.width > 0, currentFrame.height > 0 {
            origin = CGPoint(
                x: currentFrame.midX - size.width / 2,
                y: currentFrame.midY - size.height / 2
            )
        } else {
            let visibleFrame = screenForKeyboard().visibleFrame
            origin = CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + 26)
        }
        panel.setFrame(NSRect(origin: clamped(origin: origin, size: size), size: size), display: true)
    }

    private func keyboardSize() -> NSSize {
        let screen = screenForKeyboard()
        let maxWidth = max(320, screen.visibleFrame.width - 48)
        let maxHeight = max(280, screen.visibleFrame.height - 48)
        let scale = magnificationScales[magnificationIndex]
        let width = min(1_220 * scale, maxWidth)
        let height = min(430 * scale, maxHeight)
        return NSSize(width: width, height: height)
    }

    private func clamped(origin: CGPoint, size: NSSize) -> CGPoint {
        let screen = NSScreen.screens.first { screen in
            screen.visibleFrame.intersects(NSRect(origin: origin, size: size))
        } ?? screenForKeyboard()
        let visibleFrame = screen.visibleFrame
        let minX = visibleFrame.minX + 12
        let maxX = max(minX, visibleFrame.maxX - size.width - 12)
        let minY = visibleFrame.minY + 12
        let maxY = max(minY, visibleFrame.maxY - size.height - 12)
        return CGPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }

    private func remoteDragRegionContains(_ point: CGPoint, in frame: CGRect) -> Bool {
        guard frame.contains(point) else { return false }
        let topBandHeight: CGFloat = 78
        let controlClusterWidth: CGFloat = 176
        let inTopBand = point.y >= frame.maxY - topBandHeight
        let inControlCluster = point.x >= frame.maxX - controlClusterWidth
        return inTopBand && !inControlCluster
    }

    private func screenForKeyboard() -> NSScreen {
        let application = targetApplication ?? NSWorkspace.shared.frontmostApplication
        if let window = application.flatMap(frontmostWindowFrame),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(window) }) {
            return screen
        }
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func frontmostWindowFrame(for application: NSRunningApplication) -> CGRect? {
        guard application.processIdentifier != NSRunningApplication.current.processIdentifier else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef,
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
}

private final class LiquidKeyboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum LiquidKeyboardOutput {
    case text(String)
    case key(String, modifiers: [String] = [])
}

private enum LiquidKeyboardModifier: String, CaseIterable {
    case function
    case control
    case option
    case command

    var title: String {
        switch self {
        case .function: "fn"
        case .control: "⌃ control"
        case .option: "⌥ option"
        case .command: "⌘ command"
        }
    }
}

private enum LiquidKeyboardKeyKind {
    case character(String, shifted: String? = nil, key: String? = nil)
    case command(String, key: String, width: CGFloat = 1.0)
    case modifier(LiquidKeyboardModifier)
    case shift
    case capsLock
    case space
    case arrowCluster
    case devToggle
    case close
}

private struct LiquidKeyboardKey: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String?
    let help: String?
    let width: CGFloat
    let kind: LiquidKeyboardKeyKind

    init(
        _ title: String,
        id: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        help: String? = nil,
        width: CGFloat = 1,
        kind: LiquidKeyboardKeyKind
    ) {
        self.id = id ?? "\(title)-\(subtitle ?? "")-\(systemImage ?? "")"
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.help = help
        self.width = width
        self.kind = kind
    }
}

private struct LiquidKeyboardView: View {
    let devMode: Bool
    let targetTitle: String
    let onOutput: (LiquidKeyboardOutput) -> Void
    let onDevModeChange: (Bool) -> Void
    let onMagnify: () -> Void
    let onDragStart: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnd: () -> Void
    let onClose: () -> Void

    @State private var shifted = false
    @State private var capsLocked = false
    @State private var activeModifiers = Set<LiquidKeyboardModifier>()
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 7) {
                ForEach(macBookRows.indices, id: \.self) { index in
                    keyboardRow(
                        macBookRows[index],
                        height: index == 0 ? 36 : (index == macBookRows.count - 1 ? 54 : 50)
                    )
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.16),
                                    Color.cyan.opacity(0.06),
                                    Color.orange.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.24), radius: 26, x: 0, y: 18)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14, weight: .semibold))
                Text(targetTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .nativeGlassCapsule(tint: Color.secondary.opacity(0.08), interactive: true)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onDragStart()
                        }
                        onDragChanged(value.translation)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnd()
                    }
            )
            .help("Drag keyboard")

            Spacer()

            Button(action: onMagnify) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 30)
                    .nativeGlassCapsule(tint: Color.blue.opacity(0.12), interactive: true)
            }
            .buttonStyle(.plain)
            .help("Increase keyboard size")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 30)
                    .nativeGlass(cornerRadius: 15, tint: Color.red.opacity(0.10), interactive: true)
            }
            .buttonStyle(.plain)
            .help("Hide keyboard")
        }
        .padding(.horizontal, 2)
    }

    private func keyboardRow(_ keys: [LiquidKeyboardKey], height: CGFloat) -> some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 7
            let totalSpacing = spacing * CGFloat(max(0, keys.count - 1))
            let totalUnits = keys.reduce(CGFloat.zero) { $0 + $1.width }
            let unitWidth = max(18, (proxy.size.width - totalSpacing) / max(totalUnits, 1))

            HStack(spacing: spacing) {
                ForEach(keys) { key in
                    keyButton(key)
                        .frame(width: unitWidth * key.width)
                }
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func keyButton(_ key: LiquidKeyboardKey) -> some View {
        if case .arrowCluster = key.kind {
            arrowCluster
        } else {
            Button {
                handle(key)
            } label: {
            let label = displayTitle(for: key)
            HStack(spacing: 5) {
                if let systemImage = key.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                if !label.isEmpty || key.subtitle != nil {
                    VStack(spacing: 1) {
                        if !label.isEmpty {
                            Text(label)
                                .font(.system(size: key.width > 1.8 ? 15 : 14, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        if let subtitle = key.subtitle {
                            Text(subtitle)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 6)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardKeySurface(cornerRadius: 8, tint: tint(for: key))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var arrowCluster: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 4
            let keyWidth = (proxy.size.width - gap * 2) / 3
            let keyHeight = (proxy.size.height - gap) / 2
            ZStack(alignment: .topLeading) {
                arrowButton("up", image: "arrow.up")
                    .frame(width: keyWidth, height: keyHeight)
                    .offset(x: keyWidth + gap)
                arrowButton("left", image: "arrow.left")
                    .frame(width: keyWidth, height: keyHeight)
                    .offset(y: keyHeight + gap)
                arrowButton("down", image: "arrow.down")
                    .frame(width: keyWidth, height: keyHeight)
                    .offset(x: keyWidth + gap, y: keyHeight + gap)
                arrowButton("right", image: "arrow.right")
                    .frame(width: keyWidth, height: keyHeight)
                    .offset(x: (keyWidth + gap) * 2, y: keyHeight + gap)
            }
        }
    }

    private func arrowButton(_ key: String, image: String) -> some View {
        Button {
            onOutput(.key(key, modifiers: outputModifiers()))
            resetLatches()
        } label: {
            Image(systemName: image)
                .font(.system(size: 11, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .keyboardKeySurface(cornerRadius: 7)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func handle(_ key: LiquidKeyboardKey) {
        switch key.kind {
        case .character(let text, let shiftedText, let keyName):
            let outputText = characterOutput(text: text, shiftedText: shiftedText)
            let modifiers = outputModifiers()
            if modifiers.isEmpty {
                onOutput(.text(outputText))
            } else {
                onOutput(.key(keyName ?? text.lowercased(), modifiers: modifiers))
            }
            resetLatches()
        case .command(_, let keyName, _):
            onOutput(.key(keyName, modifiers: outputModifiers()))
            resetLatches()
        case .modifier(let modifier):
            if activeModifiers.contains(modifier) {
                activeModifiers.remove(modifier)
            } else {
                activeModifiers.insert(modifier)
            }
        case .shift:
            shifted.toggle()
        case .capsLock:
            capsLocked.toggle()
        case .space:
            if outputModifiers().isEmpty {
                onOutput(.text(" "))
            } else {
                onOutput(.key("space", modifiers: outputModifiers()))
            }
            resetLatches()
        case .devToggle:
            onDevModeChange(!devMode)
        case .close:
            onClose()
        case .arrowCluster:
            break
        }
    }

    private func outputModifiers() -> [String] {
        var modifiers = activeModifiers.map(\.rawValue).sorted()
        if shifted {
            modifiers.append("shift")
        }
        return modifiers
    }

    private func resetLatches() {
        shifted = false
        activeModifiers.removeAll()
    }

    private func displayTitle(for key: LiquidKeyboardKey) -> String {
        switch key.kind {
        case .character(let text, let shiftedText, _):
            characterOutput(text: text, shiftedText: shiftedText)
        default:
            key.title
        }
    }

    private func tint(for key: LiquidKeyboardKey) -> Color? {
        switch key.kind {
        case .modifier(let modifier):
            activeModifiers.contains(modifier) ? Color.blue.opacity(0.20) : nil
        case .shift:
            shifted ? Color.blue.opacity(0.20) : nil
        case .capsLock:
            capsLocked ? Color.blue.opacity(0.20) : nil
        case .devToggle:
            devMode ? Color.green.opacity(0.16) : nil
        case .close:
            Color.red.opacity(0.08)
        default:
            nil
        }
    }

    private func helpText(for key: LiquidKeyboardKey) -> String {
        if let help = key.help {
            return help
        }
        return switch key.kind {
        case .modifier(let modifier):
            "Latch \(modifier.title)"
        case .shift:
            "Latch Shift"
        case .capsLock:
            "Caps Lock"
        case .devToggle:
            "Toggle terminal keys"
        case .close:
            "Hide keyboard"
        default:
            key.title
        }
    }

    private func characterOutput(text: String, shiftedText: String?) -> String {
        if shifted, let shiftedText { return shiftedText }
        guard text.count == 1, text.first?.isLetter == true else { return text }
        return capsLocked != shifted ? text.uppercased() : text.lowercased()
    }

    private var macBookRows: [[LiquidKeyboardKey]] {
        [
            [commandKey("esc", key: "escape", help: "Escape", width: 1.25)]
                + (1...12).map { commandKey("F\($0)", key: "f\($0)", help: "F\($0)") }
                + [LiquidKeyboardKey("", systemImage: "keyboard.chevron.compact.down", help: "Hide keyboard", width: 1.25, kind: .close)],
            characterRow([
                ("`", "~"),
                ("1", "!"), ("2", "@"), ("3", "#"), ("4", "$"), ("5", "%"), ("6", "^"),
                ("7", "&"), ("8", "*"), ("9", "("), ("0", ")"), ("-", "_"), ("=", "+")
            ]) + [LiquidKeyboardKey("delete", systemImage: "delete.left", help: "Delete", width: 1.65, kind: .command("Delete", key: "delete"))],
            [commandKey("tab", key: "tab", help: "Tab", width: 1.45)]
                + characterRow([("q", nil), ("w", nil), ("e", nil), ("r", nil), ("t", nil), ("y", nil), ("u", nil), ("i", nil), ("o", nil), ("p", nil), ("[", "{"), ("]", "}"), ("\\", "|")]),
            [LiquidKeyboardKey("caps lock", help: "Caps Lock", width: 1.75, kind: .capsLock)]
                + characterRow([("a", nil), ("s", nil), ("d", nil), ("f", nil), ("g", nil), ("h", nil), ("j", nil), ("k", nil), ("l", nil), (";", ":"), ("'", "\"")])
                + [LiquidKeyboardKey("return", systemImage: "return", help: "Return", width: 1.85, kind: .command("Return", key: "return"))],
            [LiquidKeyboardKey("shift", id: "left-shift", systemImage: "shift", help: "Shift", width: 2.25, kind: .shift)]
                + characterRow([("z", nil), ("x", nil), ("c", nil), ("v", nil), ("b", nil), ("n", nil), ("m", nil), (",", "<"), (".", ">"), ("/", "?")])
                + [LiquidKeyboardKey("shift", id: "right-shift", systemImage: "shift", help: "Shift", width: 2.25, kind: .shift)],
            [
                modifierKey(.function, width: 1.0),
                modifierKey(.control, width: 1.1),
                modifierKey(.option, width: 1.1),
                modifierKey(.command, width: 1.35),
                LiquidKeyboardKey("", help: "Space", width: 5.4, kind: .space),
                modifierKey(.command, id: "right-command", width: 1.35),
                modifierKey(.option, id: "right-option", width: 1.1),
                LiquidKeyboardKey("", id: "arrow-cluster", help: "Arrow keys", width: 3.0, kind: .arrowCluster)
            ]
        ]
    }

    private func characterRow(_ pairs: [(String, String?)]) -> [LiquidKeyboardKey] {
        pairs.map { text, shiftedText in
            LiquidKeyboardKey(text, subtitle: shiftedText, kind: .character(text, shifted: shiftedText, key: text))
        }
    }

    private func commandKey(_ title: String, systemImage: String? = nil, key: String, help: String, width: CGFloat = 1) -> LiquidKeyboardKey {
        LiquidKeyboardKey(title, systemImage: systemImage, help: help, width: width, kind: .command(help, key: key))
    }

    private func modifierKey(_ modifier: LiquidKeyboardModifier, id: String? = nil, width: CGFloat = 1) -> LiquidKeyboardKey {
        let help: String
        switch modifier {
        case .function:
            help = "Function"
        case .control:
            help = "Control"
        case .option:
            help = "Option"
        case .command:
            help = "Command"
        }
        return LiquidKeyboardKey(modifier.title, id: id, help: help, width: width, kind: .modifier(modifier))
    }
}

private extension View {
    func keyboardKeySurface(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                shape.fill(tint ?? Color.white.opacity(0.09))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.stroke(Color.white.opacity(0.18), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}
