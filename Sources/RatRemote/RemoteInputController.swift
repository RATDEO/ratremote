import AppKit
import Carbon.HIToolbox
import GameController
import IOKit.hid
import IOKit.hidsystem

@MainActor
protocol RemoteInputControllerDelegate: AnyObject {
    func remoteConnectionDidChange(_ status: String)
    func remoteBatteryDidChange(_ status: String)
    func remoteHotKeyRegistrationDidChange(dictation: String, agent: String)
    func remoteDidCaptureShortcut(_ shortcut: KeyboardShortcut, kind: AppShortcutKind)
    func remoteDidCancelShortcutCapture()
    func remoteDidRequestDictationToggle()
    func remoteDidPressPlayPauseMediaButton()
    func remoteDidRequestAgentToggle()
    func remoteDidBeginAgentPushToTalk()
    func remoteDidEndAgentPushToTalk()
    func remoteDidObserveHIDInput(_ description: String)
    func remoteDidUpdateGCDiagnostic(_ diagnostic: String)
    func remoteDidRequestClick()
    func remoteDidRequestEscape()
    func remoteDidRequestKeyboard()
    func remoteDidMovePointer(dx: Double, dy: Double)
    func remoteDidScroll(amount: Double)
    func remoteDidScroll(dx: Double, dy: Double)
    func remoteDidTouchpadMove(x: Double, y: Double)
    func remoteDidTouchpadClick(pressed: Bool)
    func remoteDidEndTouchpadInteraction()
}

@MainActor
final class RemoteInputController {
    weak var delegate: RemoteInputControllerDelegate?

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var mediaKeyEventTap: CFMachPort?
    private var mediaKeyRunLoopSource: CFRunLoopSource?
    private var connectedController: GCController?
    private var hidManager: IOHIDManager?
    private var hidRemoteIdentifiers = Set<String>()
    private var hidRemoteBatteryStatuses: [String: String] = [:]
    private var hidReportBuffers: [String: UnsafeMutablePointer<UInt8>] = [:]
    private var hidRemoteDevices: [String: IOHIDDevice] = [:]
    private var hidBufferedInputElements: [String: [IOHIDElement]] = [:]
    private var microphonePollTimer: Timer?
    private var lastPolledMicrophoneSequence: UInt16?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var hotKeyHandler: EventHandlerRef?
    private var lastDPad = (x: 0.0, y: 0.0)
    private var siriButtonIsPressed = false
    private var lastTouchpadPosition = (x: 0.0, y: 0.0)
    private var touchpadActive = false
    private var microDPadActive = false
    private var recentHIDEvents: [String: Date] = [:]
    private var lastPlayPauseMediaKeyDown = Date.distantPast
    private var lastKeyboardRequest = Date.distantPast
    private var capturingShortcutKind: AppShortcutKind?
    private var settings: () -> AppSettings
    private var isStarted = false

    private static let hotKeySignature = OSType(0x5254524D) // RTRM
    private static let dictationHotKeyID: UInt32 = 1
    private static let agentHotKeyID: UInt32 = 2
    private static let systemDefinedCGEventType = CGEventType(rawValue: 14)!
    private static let auxControlSubtype = 8
    private static let menuSubtype = 16
    private static let playKeyType = 16
    private static let menuKeyType = 25
    private static let keyDownState = 0x0A
    private static let verboseInputLogging = ProcessInfo.processInfo.environment["RATREMOTE_VERBOSE_INPUT"] == "1"

    init(settings: @escaping () -> AppSettings) {
        self.settings = settings
    }

    private static func debugLog(_ message: @autoclosure () -> String) {
        guard verboseInputLogging else { return }
        print(message())
    }

    func start() {
        guard !isStarted else {
            updateRemoteConnectionStatus()
            return
        }
        isStarted = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )
        if #available(macOS 11.3, *) {
            GCController.shouldMonitorBackgroundEvents = true
        }
        GCController.startWirelessControllerDiscovery { [weak self] in
            Task { @MainActor in
                self?.delegate?.remoteDidUpdateGCDiagnostic("GC discovery complete, controllers=\(GCController.controllers().count)")
            }
        }
        GCController.controllers().forEach(configure(controller:))
        startHIDRemoteDiscovery()
        updateRemoteConnectionStatus()
        installHotKeyHandler()
        registerCurrentHotKeys()
        installMediaKeyEventTap()
        installKeyboardFallback()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        stopMediaKeyEventTap()
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        globalEventMonitor = nil
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        localEventMonitor = nil
        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil
        for buffer in hidReportBuffers.values {
            buffer.deallocate()
        }
        hidReportBuffers.removeAll()
        hidRemoteDevices.removeAll()
        hidBufferedInputElements.removeAll()
        stopRemoteMicrophonePolling()
        hidRemoteIdentifiers.removeAll()
        hidRemoteBatteryStatuses.removeAll()
        recentHIDEvents.removeAll()
        connectedController = nil
        siriButtonIsPressed = false
        touchpadActive = false
        microDPadActive = false
        unregisterHotKeys()
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
        hotKeyHandler = nil
        GCController.stopWirelessControllerDiscovery()
        NotificationCenter.default.removeObserver(self)
    }

    func beginShortcutCapture(kind: AppShortcutKind) {
        capturingShortcutKind = kind
    }

    func cancelShortcutCapture() {
        capturingShortcutKind = nil
    }

    func enableRemoteMicrophoneStreaming() {
        for device in hidRemoteDevices.values {
            enableSiriRemoteMicrophone(on: device)
        }
    }

    func startRemoteMicrophonePolling() {
        stopRemoteMicrophonePolling()
        lastPolledMicrophoneSequence = nil
        pollRemoteMicrophoneValues()
        microphonePollTimer = Timer.scheduledTimer(withTimeInterval: 0.012, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollRemoteMicrophoneValues()
            }
        }
    }

    func stopRemoteMicrophonePolling() {
        microphonePollTimer?.invalidate()
        microphonePollTimer = nil
        lastPolledMicrophoneSequence = nil
    }

    func registerCurrentHotKeys() {
        unregisterHotKeys()
        let current = settings()
        let dictationStatus = registerHotKey(current.dictationShortcut, id: Self.dictationHotKeyID)
        let agentStatus = current.isAgentModeEnabled
            ? registerHotKey(current.agentShortcut, id: Self.agentHotKeyID)
            : "Disabled (experimental feature off)"
        delegate?.remoteHotKeyRegistrationDidChange(dictation: dictationStatus, agent: agentStatus)
    }

    private func installKeyboardFallback() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                _ = self.handle(event: event, source: "global")
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event, source: "local") ? nil : event
        }
    }

    private func handle(event: NSEvent, source: String) -> Bool {
        if event.type == .keyDown, let kind = capturingShortcutKind {
            capturingShortcutKind = nil
            if event.keyCode == UInt16(kVK_Escape) {
                delegate?.remoteDidCancelShortcutCapture()
            } else {
                delegate?.remoteDidCaptureShortcut(KeyboardShortcut(event: event), kind: kind)
            }
            return true
        }

        guard event.type == .systemDefined else { return false }
        guard !Self.isSyntheticMediaEvent(event) else { return false }
        if event.subtype.rawValue == Self.menuSubtype {
            requestKeyboard(source: "\(source) system menu subtype data1=\(event.data1) data2=\(event.data2)")
            return true
        }

        guard event.subtype.rawValue == Self.auxControlSubtype else {
            delegate?.remoteDidObserveHIDInput(
                "system defined source=\(source) subtype=\(event.subtype.rawValue) data1=\(event.data1) data2=\(event.data2)"
            )
            return false
        }

        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        let keyFlags = event.data1 & 0x0000FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == Self.keyDownState
        guard isKeyDown else { return false }

        switch keyCode {
        case Self.playKeyType:
            acceptPlayPauseMediaPress(
                source: source,
                data1: event.data1,
                data2: event.data2,
                flags: keyFlags
            )
            return true
        case Self.menuKeyType:
            requestKeyboard(source: "\(source) system menu")
            return true
        default:
            delegate?.remoteDidObserveHIDInput(
                "system defined source=\(source) subtype=\(event.subtype.rawValue) keyCode=\(keyCode) data1=\(event.data1) data2=\(event.data2)"
            )
            return false
        }
    }

    private func installMediaKeyEventTap() {
        stopMediaKeyEventTap()
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedCGEventType.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.mediaKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            delegate?.remoteDidObserveHIDInput("media key event tap unavailable; play/pause multi-press will use monitor fallback")
            return
        }

        mediaKeyEventTap = tap
        mediaKeyRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let mediaKeyRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), mediaKeyRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        delegate?.remoteDidObserveHIDInput("media key event tap installed")
    }

    private func stopMediaKeyEventTap() {
        if let mediaKeyEventTap {
            CGEvent.tapEnable(tap: mediaKeyEventTap, enable: false)
        }
        if let mediaKeyRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), mediaKeyRunLoopSource, .commonModes)
        }
        mediaKeyEventTap = nil
        mediaKeyRunLoopSource = nil
    }

    private func reenableMediaKeyEventTap() {
        if let mediaKeyEventTap {
            CGEvent.tapEnable(tap: mediaKeyEventTap, enable: true)
        }
    }

    private func acceptPlayPauseMediaPress(source: String, data1: Int, data2: Int, flags: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastPlayPauseMediaKeyDown) > 0.08 else {
            return
        }
        lastPlayPauseMediaKeyDown = now
        delegate?.remoteDidObserveHIDInput(
            "media key play/pause captured source=\(source) data1=\(data1) data2=\(data2) flags=0x\(String(flags, radix: 16))"
        )
        delegate?.remoteDidPressPlayPauseMediaButton()
    }

    private func requestKeyboard(source: String) {
        let now = Date()
        guard now.timeIntervalSince(lastKeyboardRequest) > 0.08 else {
            return
        }
        lastKeyboardRequest = now
        delegate?.remoteDidObserveHIDInput("keyboard trigger source=\(source)")
        delegate?.remoteDidRequestKeyboard()
    }

    private static func playPauseSystemMediaKey(from event: NSEvent) -> (data1: Int, data2: Int, flags: Int)? {
        guard event.type == .systemDefined, event.subtype.rawValue == auxControlSubtype else { return nil }
        guard !isSyntheticMediaEvent(event) else { return nil }
        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        guard keyCode == playKeyType else { return nil }
        let keyFlags = event.data1 & 0x0000FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == keyDownState
        guard isKeyDown else { return nil }
        return (event.data1, event.data2, keyFlags)
    }

    private static func keyboardSystemKey(from event: NSEvent) -> (data1: Int, data2: Int, flags: Int)? {
        guard event.type == .systemDefined else { return nil }
        guard !isSyntheticMediaEvent(event) else { return nil }
        if event.subtype.rawValue == menuSubtype {
            return (event.data1, event.data2, 0)
        }

        guard event.subtype.rawValue == auxControlSubtype else { return nil }
        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        guard keyCode == menuKeyType else { return nil }
        let keyFlags = event.data1 & 0x0000FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == keyDownState
        guard isKeyDown else { return nil }
        return (event.data1, event.data2, keyFlags)
    }

    private static func isSyntheticMediaEvent(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == AgentInputSyntheticMarker.value
    }

    private static let mediaKeyEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let controller = Unmanaged<RemoteInputController>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                controller.reenableMediaKeyEventTap()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == RemoteInputController.systemDefinedCGEventType,
              event.getIntegerValueField(.eventSourceUserData) != AgentInputSyntheticMarker.value,
              let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        if let mediaKey = RemoteInputController.playPauseSystemMediaKey(from: nsEvent) {
            Task { @MainActor in
                controller.acceptPlayPauseMediaPress(
                    source: "eventTap",
                    data1: mediaKey.data1,
                    data2: mediaKey.data2,
                    flags: mediaKey.flags
                )
            }
            return nil
        }

        guard let keyboardKey = RemoteInputController.keyboardSystemKey(from: nsEvent) else {
            return Unmanaged.passUnretained(event)
        }

        let subtype = nsEvent.subtype.rawValue
        Task { @MainActor in
            controller.delegate?.remoteDidObserveHIDInput(
                "system keyboard key captured subtype=\(subtype) data1=\(keyboardKey.data1) data2=\(keyboardKey.data2) flags=0x\(String(keyboardKey.flags, radix: 16))"
            )
            controller.requestKeyboard(source: "eventTap system menu subtype=\(subtype)")
        }
        return nil
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        configure(controller: controller)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController,
              controller == connectedController else { return }
        connectedController = nil
        delegate?.remoteDidUpdateGCDiagnostic("disconnected")
        updateRemoteConnectionStatus()
    }

    private func configure(controller: GCController) {
        connectedController = controller
        updateRemoteConnectionStatus()
        
        let hasMicro = controller.microGamepad != nil
        let hasExtended = controller.extendedGamepad != nil
        let gcInfo = "GC: category=\(controller.productCategory) micro=\(hasMicro) ext=\(hasExtended)"
        Self.debugLog("[GC] \(gcInfo)")
        delegate?.remoteDidUpdateGCDiagnostic(gcInfo)
        
        var touchpadResults = [setupPhysicalInputTouchpads(from: controller)]

        if let micro = controller.microGamepad {
            micro.reportsAbsoluteDpadValues = false
            micro.allowsRotation = false
            disableSystemGestures(for: micro.dpad)
            micro.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
                Task { @MainActor in
                    self?.handleMicroDPad(x: Double(xValue), y: Double(yValue), source: "micro.dpad")
                }
            }
            micro.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.delegate?.remoteDidRequestClick() }
            }
            micro.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.delegate?.remoteDidRequestEscape() }
            }
            if #available(macOS 10.15, *) {
                micro.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    Task { @MainActor in self?.requestKeyboard(source: "micro.buttonMenu") }
                }
            }
        }

        if let extended = controller.extendedGamepad {
            extended.buttonMenu.valueChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.requestKeyboard(source: "extended.buttonMenu") }
            }
            if #available(macOS 11.0, *) {
                extended.buttonHome?.valueChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    Task { @MainActor in self?.requestKeyboard(source: "extended.buttonHome") }
                }
            }
            extended.buttonA.valueChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.delegate?.remoteDidRequestClick() }
            }

            // Try KVC approach for touchpad
            touchpadResults.append(self.setupTouchpadKVC(from: controller))
        }
        
        delegate?.remoteDidUpdateGCDiagnostic("\(gcInfo) | \(touchpadResults.joined(separator: " | "))")
    }

    private func setupPhysicalInputTouchpads(from controller: GCController) -> String {
        let profile = controller.physicalInputProfile
        let touchpadNames = profile.touchpads.keys.sorted()
        let dpadNames = profile.dpads.keys.sorted()
        let buttonNames = profile.buttons.keys.sorted()

        profile.valueDidChangeHandler = { [weak self] profile, element in
            let elementName = element.localizedName ?? element.unmappedLocalizedName ?? element.aliases.sorted().first ?? String(describing: type(of: element))
            Task { @MainActor in
                guard let self else { return }
                self.delegate?.remoteDidObserveHIDInput("GC element \(elementName)")

                for (name, touchpad) in profile.touchpads where element == touchpad || element == touchpad.touchSurface || element.collection == touchpad.touchSurface {
                    self.handleControllerTouchpad(
                        name: name,
                        phase: "\(touchpad.touchState)",
                        x: Double(touchpad.touchSurface.xAxis.value),
                        y: Double(touchpad.touchSurface.yAxis.value),
                        buttonValue: Double(touchpad.button.value),
                        buttonPressed: touchpad.button.isPressed
                    )
                    return
                }

                for (name, button) in profile.buttons where element == button {
                    self.handleControllerButton(
                        name: name,
                        displayName: elementName,
                        value: Double(button.value),
                        pressed: button.isPressed
                    )
                    return
                }
            }
        }

        for (name, touchpad) in profile.touchpads {
            configure(touchpad: touchpad, name: name)
        }

        return "physical touchpads=\(touchpadNames) buttons=\(buttonNames) dpads=\(dpadNames)"
    }

    private func handleControllerButton(name: String, displayName: String, value: Double, pressed: Bool) {
        delegate?.remoteDidObserveHIDInput(
            "GC button \(displayName) key=\(name) value=\(String(format: "%.3f", value)) pressed=\(pressed)"
        )
        guard pressed, isKeyboardButtonName(name) || isKeyboardButtonName(displayName) else { return }
        requestKeyboard(source: "GC button \(displayName)")
    }

    private func isKeyboardButtonName(_ name: String) -> Bool {
        let normalized = name
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return normalized.contains("home") ||
            normalized.contains("tv") ||
            normalized.contains("television") ||
            normalized.contains("menu")
    }

    private func configure(touchpad: GCControllerTouchpad, name: String) {
        touchpad.reportsAbsoluteTouchSurfaceValues = true
        disableSystemGestures(for: touchpad)
        disableSystemGestures(for: touchpad.touchSurface)
        disableSystemGestures(for: touchpad.button)

        touchpad.touchDown = { [weak self] touchpad, xValue, yValue, buttonValue, buttonPressed in
            Task { @MainActor in
                self?.handleControllerTouchpad(
                    name: name,
                    phase: "down",
                    x: Double(xValue),
                    y: Double(yValue),
                    buttonValue: Double(buttonValue),
                    buttonPressed: buttonPressed
                )
            }
        }
        touchpad.touchMoved = { [weak self] touchpad, xValue, yValue, buttonValue, buttonPressed in
            Task { @MainActor in
                self?.handleControllerTouchpad(
                    name: name,
                    phase: "moved",
                    x: Double(xValue),
                    y: Double(yValue),
                    buttonValue: Double(buttonValue),
                    buttonPressed: buttonPressed
                )
            }
        }
        touchpad.touchUp = { [weak self] touchpad, xValue, yValue, buttonValue, buttonPressed in
            Task { @MainActor in
                self?.handleControllerTouchpad(
                    name: name,
                    phase: "up",
                    x: Double(xValue),
                    y: Double(yValue),
                    buttonValue: Double(buttonValue),
                    buttonPressed: buttonPressed
                )
            }
        }
        touchpad.touchSurface.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                guard touchpad.touchState != .up else { return }
                self?.handleControllerTouchpad(
                    name: name,
                    phase: "surface",
                    x: Double(xValue),
                    y: Double(yValue),
                    buttonValue: Double(touchpad.button.value),
                    buttonPressed: touchpad.button.isPressed
                )
            }
        }
        touchpad.button.pressedChangedHandler = { [weak self] _, value, pressed in
            Task { @MainActor in
                self?.delegate?.remoteDidObserveHIDInput("GC touchpad \(name) button value=\(String(format: "%.3f", Double(value))) pressed=\(pressed)")
                self?.delegate?.remoteDidTouchpadClick(pressed: pressed)
            }
        }
    }

    private func disableSystemGestures(for element: GCControllerElement) {
        element.preferredSystemGestureState = .disabled
    }

    private func setupTouchpadKVC(from controller: GCController) -> String {
        Self.debugLog("[KVC] Attempting touchpad discovery")
        
        // Try multiple KVC paths
        let paths = [
            ["platformInputController", "appleTVRemote", "touchpad"],
            ["platformInputController", "touchpad"],
            ["extendedGamepad", "touchpad"],
        ]
        
        for path in paths {
            var obj: NSObject? = controller as NSObject
            for key in path {
                obj = obj?.value(forKey: key) as? NSObject
                if obj == nil {
                    Self.debugLog("[KVC] Path \(path.joined(separator: ".")) failed at key '\(key)'")
                    break
                }
            }
            
            if let touchpad = obj {
                Self.debugLog("[KVC] Found touchpad via path \(path.joined(separator: "."))")
                let testKeys = ["xAxis", "yAxis", "x", "y", "position", "value", "touchCount", "buttonValue"]
                var foundKeys: [String] = []
                for key in testKeys {
                    if touchpad.value(forKey: key) != nil {
                        foundKeys.append(key)
                    }
                }
                
                // Try setting up the handler
                touchpad.setValue(self, forKey: "valueHandlerTarget")
                touchpad.setValue(#selector(handleTouchpadValue(source:)), forKey: "valueHandlerAction")
                Self.debugLog("[KVC] Set touchpad handler")
                return "KVC OK via \(path.joined(separator: ".")) keys=[\(foundKeys.joined(separator: ", "))]"
            }
        }
        
        if let platformInput = (controller as NSObject).value(forKey: "platformInputController") as? NSObject {
            Self.debugLog("[KVC] platformInputController found")
            let keys = ["appleTVRemote", "touchpad", "remote", "inputDevice"]
            var found: [String] = []
            for key in keys {
                if platformInput.value(forKey: key) != nil {
                    found.append(key)
                }
            }
            return "platformInput found, keys=[\(found.joined(separator: ", "))]"
        } else {
            Self.debugLog("[KVC] platformInputController not found on controller")
            return "no platformInputController"
        }
    }

    @objc private func handleTouchpadValue(source: NSObject) {
        let x = (source.value(forKey: "xAxis") as? NSNumber)?.doubleValue 
                 ?? (source.value(forKey: "x") as? NSNumber)?.doubleValue
                 ?? 0
        let y = (source.value(forKey: "yAxis") as? NSNumber)?.doubleValue
                 ?? (source.value(forKey: "y") as? NSNumber)?.doubleValue
                 ?? 0
        Self.debugLog("[KVC Touchpad] x=\(x) y=\(y)")

        delegate?.remoteDidTouchpadMove(x: x, y: y)
    }

    private func handleControllerTouchpad(
        name: String,
        phase: String,
        x: Double,
        y: Double,
        buttonValue: Double,
        buttonPressed: Bool
    ) {
        delegate?.remoteDidObserveHIDInput(
            "GC touchpad \(name) \(phase) x=\(String(format: "%.3f", x)) y=\(String(format: "%.3f", y)) button=\(String(format: "%.3f", buttonValue)) pressed=\(buttonPressed)"
        )

        if phase == "up" || phase == "\(GCControllerTouchpad.TouchState.up)" {
            touchpadActive = false
            delegate?.remoteDidEndTouchpadInteraction()
            return
        }

        touchpadActive = true
        delegate?.remoteDidTouchpadMove(
            x: normalizedTouchCoordinate(x),
            y: normalizedTouchCoordinate(y)
        )
    }

    private func handleMicroDPad(x: Double, y: Double, source: String) {
        delegate?.remoteDidObserveHIDInput(
            "GC \(source) x=\(String(format: "%.3f", x)) y=\(String(format: "%.3f", y))"
        )

        let deadzone = 0.02
        let isActive = abs(x) > deadzone || abs(y) > deadzone
        if !isActive {
            if microDPadActive {
                delegate?.remoteDidEndTouchpadInteraction()
            }
            microDPadActive = false
            lastDPad = (0, 0)
            return
        }

        microDPadActive = true
        lastDPad = (x, y)
        let scrollScale = settings().scrollSensitivity
        Self.debugLog("[D-pad] scroll dx=\(String(format: "%.3f", x * scrollScale)) dy=\(String(format: "%.3f", y * scrollScale))")
        delegate?.remoteDidScroll(dx: x * scrollScale, dy: y * scrollScale)
    }

    private func normalizedTouchCoordinate(_ value: Double) -> Double {
        if value >= 0, value <= 1 {
            return value
        }
        return min(1, max(0, (value + 1) / 2))
    }

    private func startHIDRemoteDiscovery() {
        requestHIDListenAccessIfNeeded()

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
        
        Self.debugLog("[HID] Creating manager")
        
        // BLE Apple accessories often report the Bluetooth company ID (0x004C),
        // while USB/HID-backed Apple accessories commonly report 0x05AC.
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey as String: 76],
            [kIOHIDVendorIDKey as String: 1452]
        ]
        
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        Self.debugLog("[HID] Set device matching for \(matches.count) patterns")

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let controller = Unmanaged<RemoteInputController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                controller.handleHIDDeviceMatched(device)
            }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let controller = Unmanaged<RemoteInputController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                controller.handleHIDDeviceRemoved(device)
            }
        }, context)

        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let controller = Unmanaged<RemoteInputController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                controller.handleHIDValue(value)
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        Self.debugLog("[HID] Manager open result: \(openResult) (0=success)")
        
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            Self.debugLog("[HID] Found \(devices.count) matched device(s)")
            for device in devices {
                self.handleHIDDeviceMatched(device)
                self.enumerateHIDElements(device)
            }
        } else {
            Self.debugLog("[HID] No devices matched")
        }
    }

    private func requestHIDListenAccessIfNeeded() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            delegate?.remoteDidObserveHIDInput("HID listen access granted")
        case kIOHIDAccessTypeDenied:
            // IOHIDCheckAccess can report denied for a signed development build
            // even while its IOHIDManager is actively receiving the remote's raw
            // reports. Treat this as advisory and never hijack startup by opening
            // System Settings. A user can change the permission explicitly if raw
            // input actually fails.
            delegate?.remoteDidObserveHIDInput("HID listen access probe denied; continuing with functional HID discovery")
        case kIOHIDAccessTypeUnknown:
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            delegate?.remoteDidObserveHIDInput("HID listen access requested granted=\(granted)")
        default:
            delegate?.remoteDidObserveHIDInput("HID listen access status=\(access.rawValue)")
        }
    }
    
    private func handleHIDDeviceMatched(_ device: IOHIDDevice) {
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
        
        Self.debugLog("[HID] Device matched vendor=0x\(String(vendorID, radix: 16)) product=0x\(String(productID, radix: 16)) transport=\(transport ?? "unknown") usagePage=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16))")
        
        let isRemote = isAppleTVRemote(device)
        if isRemote {
            let id = identifier(for: device)
            let reportKey = reportIdentifier(for: device, productIdentifier: id)
            let maximumInputLength = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? -1
            TraceLog.append(
                "collection matched key=\(reportKey) maxInput=\(maximumInputLength)",
                filename: "remote-audio.log"
            )
            hidRemoteIdentifiers.insert(id)
            hidRemoteDevices[reportKey] = device
            hidBufferedInputElements[reportKey] = bufferedInputElements(for: device)
            if let batteryStatus = batteryStatus(for: device) {
                hidRemoteBatteryStatuses[id] = batteryStatus
            }
            registerRawHIDReports(for: device, identifier: reportKey)
            enableSiriRemoteMicrophone(on: device)
            Self.debugLog("[HID] Recognized compatible remote product=\(productID)")
        } else {
            Self.debugLog("[HID] Device product=\(productID) is not a supported remote")
        }
        updateRemoteConnectionStatus()
    }

    private func registerRawHIDReports(for device: IOHIDDevice, identifier: String) {
        guard hidReportBuffers[identifier] == nil else { return }

        let length = 512
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        buffer.initialize(repeating: 0, count: length)
        hidReportBuffers[identifier] = buffer

        IOHIDDeviceRegisterInputReportCallback(device, buffer, length, { context, result, sender, type, reportID, report, reportLength in
            guard let context else { return }
            let controller = Unmanaged<RemoteInputController>.fromOpaque(context).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
            Task { @MainActor in
                controller.handleRawHIDReport(
                    result: result,
                    type: type,
                    reportID: reportID,
                    bytes: bytes
                )
            }
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    private func handleRawHIDReport(
        result: IOReturn,
        type: IOHIDReportType,
        reportID: UInt32,
        bytes: [UInt8]
    ) {
        guard result == kIOReturnSuccess else {
            TraceLog.append(
                "raw report error=0x\(String(UInt32(bitPattern: result), radix: 16)) id=\(reportID) len=\(bytes.count)",
                filename: "remote-audio.log"
            )
            delegate?.remoteDidObserveHIDInput("raw report error=0x\(String(UInt32(bitPattern: result), radix: 16))")
            return
        }

        if reportID == 0xFA || bytes.count >= 90 {
            TraceLog.append(
                "candidate report id=0x\(String(reportID, radix: 16)) len=\(bytes.count)",
                filename: "remote-audio.log"
            )
        }

        if let report = normalizedMicrophoneReport(reportID: reportID, bytes: bytes) {
            NotificationCenter.default.post(
                name: .siriRemoteAudioPacket,
                object: nil,
                userInfo: ["data": report]
            )
            return
        }

        if let voicePressed = latestSiriRemoteVoiceButtonState(reportID: reportID, bytes: bytes),
           voicePressed != siriButtonIsPressed {
            siriButtonIsPressed = voicePressed
            delegate?.remoteDidObserveHIDInput("rawHID Siri button pressed=\(voicePressed)")
            if voicePressed {
                delegate?.remoteDidBeginAgentPushToTalk()
            } else {
                delegate?.remoteDidEndAgentPushToTalk()
            }
            return
        }

        if latestSiriRemoteTVButtonPressed(reportID: reportID, bytes: bytes) {
            requestKeyboard(source: "rawHID report=0xfb usage=0x60")
            return
        }

        if let rawButton = siriRemoteRawButton(in: bytes) {
            switch rawButton {
            case .tv:
                requestKeyboard(source: "rawHID A2854 TV button")
                return
            case .playPause:
                acceptPlayPauseMediaPress(source: "rawHID A2854 play/pause", data1: 0, data2: Int(reportID), flags: 0)
                return
            default:
                break
            }
        }

        if bytes.count >= 3 {
            _ = bytes[0]
            let keyUsage = bytes[1]
            let keyEvent = bytes[2]
            if keyUsage == 0xCD, keyEvent == 0x01 {
                acceptPlayPauseMediaPress(source: "rawHID", data1: 0, data2: Int(reportID), flags: 0)
                return
            }
            if isKeyboardTriggerUsage(page: 0x0C, usage: UInt32(keyUsage)),
               keyEvent == 0x01 {
                requestKeyboard(source: "rawHID usage=0x\(String(keyUsage, radix: 16))")
                return
            }
            if bytes.count >= 4 {
                let extendedUsage = UInt32(bytes[1]) | (UInt32(bytes[2]) << 8)
                let extendedEvent = bytes[3]
                if isKeyboardTriggerUsage(page: 0x0C, usage: extendedUsage),
                   extendedEvent == 0x01 {
                    requestKeyboard(source: "rawHID usage=0x\(String(extendedUsage, radix: 16))")
                    return
                }
            }
        }

        let hex = bytes.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
        delegate?.remoteDidObserveHIDInput("RAW type=\(type.rawValue) id=\(reportID) len=\(bytes.count) \(hex)")
    }

    private func normalizedMicrophoneReport(reportID: UInt32, bytes: [UInt8]) -> Data? {
        // macOS's HID-over-GATT driver exposes each Siri Remote Report
        // characteristic as a separate collection. For the raw collections it
        // rewrites the report ID to 0xFF, so packet size is the reliable audio
        // discriminator. The microphone payload itself is always 99 bytes.
        if bytes.count == 99 {
            return Data(bytes)
        }
        if bytes.count == 100, (bytes[0] == 0xFA || bytes[0] == 0xFF) {
            return Data(bytes.dropFirst())
        }
        if reportID == 0xFA, bytes.count == 98 {
            return Data([UInt8(reportID)] + bytes)
        }
        return nil
    }

    private func enableSiriRemoteMicrophone(on device: IOHIDDevice) {
        guard let rawElements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) else {
            return
        }

        let elements = rawElements as! [IOHIDElement]
        var reports = Set<String>()
        for element in elements {
            let elementType = IOHIDElementGetType(element)
            guard elementType == kIOHIDElementTypeOutput || elementType == kIOHIDElementTypeFeature else {
                continue
            }
            let reportID = IOHIDElementGetReportID(element)
            let reportType: IOHIDReportType = elementType == kIOHIDElementTypeFeature ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput
            let key = "\(reportType.rawValue):\(reportID)"
            guard reports.insert(key).inserted else { continue }

            let enableReport = reportID == 0 ? [UInt8(0xAF)] : [UInt8(truncatingIfNeeded: reportID), 0xAF]
            let result = enableReport.withUnsafeBufferPointer { bytes in
                IOHIDDeviceSetReport(device, reportType, CFIndex(reportID), bytes.baseAddress!, bytes.count)
            }
            let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
            let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
            let enableBytes = enableReport.map { String(format: "%02x", $0) }.joined(separator: " ")
            TraceLog.append(
                "enable usage=\(usagePage):\(usage) type=\(reportType.rawValue) id=0x\(String(reportID, radix: 16)) bytes=\(enableBytes) result=0x\(String(UInt32(bitPattern: result), radix: 16))",
                filename: "remote-audio.log"
            )
            Self.debugLog("[HID] mic enable type=\(reportType.rawValue) id=\(reportID) result=0x\(String(UInt32(bitPattern: result), radix: 16))")
        }
    }
    
   private func handleHIDDeviceRemoved(_ device: IOHIDDevice) {
        let wasRemote = isAppleTVRemote(device)
        if wasRemote {
            let id = identifier(for: device)
            let reportKey = reportIdentifier(for: device, productIdentifier: id)
            hidRemoteDevices.removeValue(forKey: reportKey)
            hidBufferedInputElements.removeValue(forKey: reportKey)
            if let buffer = hidReportBuffers.removeValue(forKey: reportKey) {
                buffer.deallocate()
            }
            let stillConnected = hidReportBuffers.keys.contains { $0.hasPrefix("\(id)|") }
            if !stillConnected {
                hidRemoteIdentifiers.remove(id)
                hidRemoteBatteryStatuses.removeValue(forKey: id)
            }
        }
        updateRemoteConnectionStatus()
    }
    
    private func enumerateHIDElements(_ device: IOHIDDevice) {
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        Self.debugLog("[HID] Device product ID=\(productID); using input callbacks for element discovery")
    }

    private func updateRemoteConnectionStatus() {
        if let controller = connectedController {
            delegate?.remoteConnectionDidChange("Connected via GameController")
            let controllerBattery = batteryStatus(for: controller)
            delegate?.remoteBatteryDidChange(controllerBattery == "Unavailable" ? hidBatteryStatus() : controllerBattery)
        } else if let name = hidRemoteIdentifiers.sorted().first {
            delegate?.remoteConnectionDidChange("Connected via Bluetooth HID: \(name)")
            delegate?.remoteBatteryDidChange(hidRemoteBatteryStatuses[name] ?? "Unavailable")
        } else {
            delegate?.remoteConnectionDidChange("Searching")
            delegate?.remoteBatteryDidChange("Unavailable")
        }
    }

    private func hidBatteryStatus() -> String {
        for identifier in hidRemoteIdentifiers.sorted() {
            if let status = hidRemoteBatteryStatuses[identifier] {
                return status
            }
        }
        return "Unavailable"
    }

    private func batteryStatus(for controller: GCController) -> String {
        guard let battery = controller.battery else { return "Unavailable" }
        let percent = Int((battery.batteryLevel * 100).rounded())
        switch battery.batteryState {
        case .charging:
            return "\(percent)% charging"
        case .full:
            return "100% full"
        case .discharging:
            return "\(percent)%"
        case .unknown:
            return "\(percent)%"
        @unknown default:
            return "\(percent)%"
        }
    }

    private func batteryStatus(for device: IOHIDDevice) -> String? {
        let keys = ["BatteryPercent", "BatteryLevel", "BatteryLevelPercent", "BatteryCapacity"]
        for key in keys {
            if let number = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber {
                let value = number.doubleValue
                let percent = value <= 1.0 ? Int((value * 100).rounded()) : Int(value.rounded())
                return "\(max(0, min(100, percent)))%"
            }
        }
        return nil
    }

    private func identifier(for device: IOHIDDevice) -> String {
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int

        if let productID, let vendorID, let usagePage, let usage {
            Self.debugLog("HID device vendor=\(vendorID) product=\(productID) usagePage=\(usagePage) usage=\(usage)")
        }

        return "Apple TV Remote \(productID ?? 0)"
    }

    private func reportIdentifier(for device: IOHIDDevice, productIdentifier: String) -> String {
        let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
        return "\(productIdentifier)|\(usagePage):\(usage)"
    }

    private func bufferedInputElements(for device: IOHIDDevice) -> [IOHIDElement] {
        guard let rawElements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) else {
            return []
        }
        return (rawElements as! [IOHIDElement]).filter { element in
            let type = IOHIDElementGetType(element)
            guard type.rawValue >= kIOHIDElementTypeInput_Misc.rawValue,
                  type.rawValue <= kIOHIDElementTypeInput_ScanCodes.rawValue else {
                return false
            }
            let bits = IOHIDElementGetReportSize(element) * IOHIDElementGetReportCount(element)
            return bits >= 99 * 8
        }
    }

    private func pollRemoteMicrophoneValues() {
        for (key, elements) in hidBufferedInputElements {
            guard let device = hidRemoteDevices[key] else { continue }
            for element in elements {
                let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
                defer { valuePointer.deallocate() }
                let result = IOHIDDeviceGetValueWithOptions(
                    device,
                    element,
                    valuePointer,
                    UInt32(0x00040000) // kIOHIDDeviceGetValueWithoutUpdate
                )
                guard result == kIOReturnSuccess else { continue }
                let value = valuePointer.pointee.takeUnretainedValue()
                let length = IOHIDValueGetLength(value)
                guard length >= 99 else { continue }
                let bytes = Data(bytes: IOHIDValueGetBytePtr(value), count: length)
                guard let report = microphonePayload(from: bytes) else { continue }
                let sequence = UInt16(report[2]) | (UInt16(report[3]) << 8)
                guard sequence != lastPolledMicrophoneSequence else { continue }
                lastPolledMicrophoneSequence = sequence
                TraceLog.append(
                    "polled microphone key=\(key) len=\(length) seq=\(sequence)",
                    filename: "remote-audio.log"
                )
                NotificationCenter.default.post(
                    name: .siriRemoteAudioPacket,
                    object: nil,
                    userInfo: ["data": report]
                )
            }
        }
    }

    private func isAppleTVRemote(_ device: IOHIDDevice) -> Bool {
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        // Known Siri Remote product IDs:
        // 0x0315 (789) - 4th gen Siri Remote (2022)
        // 0x0314 (788) - 3rd gen Siri Remote (2018)
        // 0x026D (621) - older Siri Remote
        // 0x0262 (614) - older Siri Remote
        // 0x027A (634) - also reported for 4th gen
        // 0x0266 (614) - 3rd gen
        let validProductIDs: Set<Int> = [789, 788, 621, 614, 634, 610, 609, 608]
        return validProductIDs.contains(productID)
    }

    private func handleHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        if !isAppleTVRemote(device) {
            return
        }
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let byteLength = IOHIDValueGetLength(value)
        if byteLength >= 90 {
            let pointer = IOHIDValueGetBytePtr(value)
            let bytes = Data(bytes: pointer, count: byteLength)
            TraceLog.append(
                "buffered value page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)) len=\(byteLength)",
                filename: "remote-audio.log"
            )
            if let report = microphonePayload(from: bytes) {
                NotificationCenter.default.post(
                    name: .siriRemoteAudioPacket,
                    object: nil,
                    userInfo: ["data": report]
                )
                return
            }
        }
        let integerValue = IOHIDValueGetIntegerValue(value)
        let pressed = integerValue != 0

        let description = "page 0x\(String(usagePage, radix: 16)) usage 0x\(String(usage, radix: 16)) value \(integerValue)"
        guard shouldAcceptHIDEvent(description) else { return }
        delegate?.remoteDidObserveHIDInput(description)

        Self.debugLog("[HID Input] page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)) value=\(integerValue)")

        // Try touchpad handling first
        if handleTouchpadHID(page: usagePage, usage: usage, value: integerValue) {
            return
        }

        if usagePage == 0x0C, usage == 0xCD, pressed {
            acceptPlayPauseMediaPress(source: "HID consumer", data1: Int(usage), data2: integerValue, flags: 0)
            return
        }

        if isKeyboardTriggerUsage(page: usagePage, usage: usage), pressed {
            requestKeyboard(source: "HID page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16))")
            return
        }

        // Then try Siri button
        guard isSiriVoiceUsage(page: usagePage, usage: usage) else { return }
        guard pressed != siriButtonIsPressed else { return }
        siriButtonIsPressed = pressed

        if pressed {
            delegate?.remoteDidBeginAgentPushToTalk()
        } else {
            delegate?.remoteDidEndAgentPushToTalk()
        }
    }

    private func microphonePayload(from value: Data) -> Data? {
        guard value.count >= 99 else { return nil }
        for offset in 0...min(1, value.count - 99) {
            let candidate = value.subdata(in: offset..<(offset + 99))
            if SiriRemoteAudioRelay.opusPacket(from: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    private func shouldAcceptHIDEvent(_ description: String) -> Bool {
        let now = Date()
        recentHIDEvents = recentHIDEvents.filter { now.timeIntervalSince($0.value) < 0.5 }
        if let previous = recentHIDEvents[description], now.timeIntervalSince(previous) < 0.08 {
            return false
        }
        recentHIDEvents[description] = now
        return true
    }

    private func isSiriVoiceUsage(page: UInt32, usage: UInt32) -> Bool {
        if page == 0x0C {
            return [
                0x004, // Siri/voice button on current Apple TV Remote over Bluetooth HID
                0x0CF, // Voice Command
                0x221 // Search
            ].contains(usage)
        }

        if page == 0xFF00 || page == 0xFF01 || page == 0xFF02 {
            // Only 0x10 is the Siri button on vendor pages
            // 0xC, 0xD, 0xE are touchpad (X, Y, touch) and must NOT be here
            return usage == 0x0010
        }

        return false
    }

    private func isKeyboardTriggerUsage(page: UInt32, usage: UInt32) -> Bool {
        guard page == 0x0C else { return false }
        return [
            0x060, // Data On Screen: screen-icon TV/Home button on the latest Siri Remote.
            0x063, // VCR/TV, used by some remotes for a TV-mode button.
            0x089, // Media Select TV.
            0x222, // AC Go To, reported as TV/Home on some Apple remotes.
            0x223  // AC Home, the TV button above volume +.
        ].contains(usage)
    }

    private enum SiriRemoteRawButton {
        case tv
        case back
        case playPause
        case volumeUp
        case volumeDown
        case mute
        case power
        case center
        case dpad
    }

    private func siriRemoteRawButton(in bytes: [UInt8]) -> SiriRemoteRawButton? {
        // Siri Remote A2854 button notifications are two bytes. Some macOS HID
        // paths include one leading report/status byte, so inspect both offsets.
        for offset in [0, 1] where bytes.count >= offset + 2 {
            guard isLikelyShortButtonReport(bytes, payloadOffset: offset) else { continue }
            let pair = (bytes[offset], bytes[offset + 1])
            switch pair {
            case (0x01, 0x00): return .tv
            case (0x40, 0x00): return .back
            case (0x00, 0x01): return .playPause
            case (0x02, 0x00): return .volumeUp
            case (0x04, 0x00): return .volumeDown
            case (0x80, 0x00): return .mute
            case (0x10, 0x00): return .power
            case (0x08, 0x00): return .center
            case (0x00, 0x02), (0x00, 0x04), (0x00, 0x08), (0x00, 0x10):
                return .dpad
            default:
                break
            }
        }
        return nil
    }

    private func latestSiriRemoteTVButtonPressed(reportID: UInt32, bytes: [UInt8]) -> Bool {
        let payloadOffset: Int
        if reportID == 0xFB, bytes.first == 0xFB, bytes.count > 1 {
            payloadOffset = 1
        } else if reportID == 0xFB {
            payloadOffset = 0
        } else if bytes.first == 0xFB {
            payloadOffset = 1
        } else {
            return false
        }

        guard bytes.count > payloadOffset else { return false }
        return (bytes[payloadOffset] & 0x01) != 0
    }

    private func latestSiriRemoteVoiceButtonState(reportID: UInt32, bytes: [UInt8]) -> Bool? {
        let payloadOffset: Int
        if reportID == 0xFB, bytes.first == 0xFB, bytes.count > 1 {
            payloadOffset = 1
        } else if reportID == 0xFB {
            payloadOffset = 0
        } else if bytes.first == 0xFB {
            payloadOffset = 1
        } else {
            return nil
        }

        guard bytes.count > payloadOffset else { return nil }
        return (bytes[payloadOffset] & 0x20) != 0
    }

    private func isLikelyShortButtonReport(_ bytes: [UInt8], payloadOffset: Int) -> Bool {
        let payloadEnd = payloadOffset + 2
        guard bytes.count >= payloadEnd else { return false }
        if bytes.count <= payloadEnd {
            return true
        }

        // Allow tiny reports with padding after the 2-byte button payload, but do
        // not scan long touchpad/audio reports for coincidental byte pairs.
        guard bytes.count <= payloadEnd + 2 else { return false }
        return bytes[payloadEnd...].allSatisfy { $0 == 0 }
    }

    private func handleTouchpadHID(page: UInt32, usage: UInt32, value: Int) -> Bool {
        // Vendor-specific pages (Apple Siri Remote)
        let vendorPages: [UInt32] = [0xFF00, 0xFF01, 0xFF02]

        if vendorPages.contains(page) {
            // On vendor pages, any non-Siri usage is touchpad data
            // Known vendor usages: 0xC=X, 0xD=Y, 0xE=touch, 0xF=scroll, 0x10=button
            if !isSiriVoiceUsage(page: page, usage: usage) {
                switch usage {
                case 0x0C:
                    lastTouchpadPosition.x = Double(value) / 4095.0
                    touchpadActive = true
                    delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                    Self.debugLog("[HID Touchpad] vendor X=\(lastTouchpadPosition.x) Y=\(lastTouchpadPosition.y)")
                    return true
                case 0x0D:
                    lastTouchpadPosition.y = Double(value) / 4095.0
                    touchpadActive = true
                    delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                    Self.debugLog("[HID Touchpad] vendor X=\(lastTouchpadPosition.x) Y=\(lastTouchpadPosition.y)")
                    return true
                case 0x0E:
                    let wasActive = touchpadActive
                    touchpadActive = value != 0
                    if !wasActive && touchpadActive {
                        delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                    }
                    delegate?.remoteDidTouchpadClick(pressed: value != 0)
                    Self.debugLog("[HID Touchpad] vendor touch=\(touchpadActive)")
                    return true
                case 0x0F:
                    if value != 0 {
                        let scrollAmount = Double(value) / 4095.0
                        delegate?.remoteDidScroll(amount: scrollAmount)
                    }
                    return true
                default:
                    if value != 0 {
                        let normalized = Double(value) / 4095.0
                        if usage == 0x00 {
                            lastTouchpadPosition.x = normalized
                        } else if usage == 0x01 {
                            lastTouchpadPosition.y = normalized
                        } else if (usage % 2) == 0 {
                            lastTouchpadPosition.x = normalized
                        } else {
                            lastTouchpadPosition.y = normalized
                        }
                        touchpadActive = true
                        delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                        Self.debugLog("[HID Touchpad] vendor fallback usage=0x\(String(usage, radix: 16)) value=\(normalized)")
                    }
                    return true
                }
            }
            return false
        }

        // Generic Desktop page - Siri Remote touchpad likely uses this
        if page == 0x0001 {
            switch usage {
            case 0x30:
                // X axis
                lastTouchpadPosition.x = Double(value) / 4095.0
                touchpadActive = true
                delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                Self.debugLog("[HID Touchpad] GDesktop X=\(lastTouchpadPosition.x) Y=\(lastTouchpadPosition.y)")
                return true
            case 0x31:
                // Y axis
                lastTouchpadPosition.y = Double(value) / 4095.0
                touchpadActive = true
                delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                Self.debugLog("[HID Touchpad] GDesktop X=\(lastTouchpadPosition.x) Y=\(lastTouchpadPosition.y)")
                return true
            case 0x33:
                // Wheel/scroll
                if value != 0 {
                    let scrollAmount = Double(value) / 4095.0
                    delegate?.remoteDidScroll(amount: scrollAmount)
                }
                return true
            case 0x37:
                // Slider
                lastTouchpadPosition.y = Double(value) / 4095.0
                touchpadActive = true
                delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                Self.debugLog("[HID Touchpad] GDesktop slider=\(lastTouchpadPosition.y)")
                return true
            case 0x34:
                // VDial / scroll
                if value != 0 {
                    let scrollAmount = Double(value) / 4095.0
                    delegate?.remoteDidScroll(amount: scrollAmount)
                }
                return true
            case 0x42:
                // Pressure / touch detection
                if value != 0 && !touchpadActive {
                    touchpadActive = true
                    delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                } else if value == 0 {
                    touchpadActive = false
                }
                delegate?.remoteDidTouchpadClick(pressed: value != 0)
                Self.debugLog("[HID Touchpad] GDesktop pressure=\(value) active=\(touchpadActive)")
                return true
            case 0x45:
                // Hat switch / direction
                return true
            case 1:
                // Pointer collection (not a value, just a collection marker)
                return true
            case 2:
                // Mouse collection
                return true
            case 4:
                // Touch pad collection
                return true
            default:
                // Log but don't suppress other Generic Desktop events
                if value != 0 {
                    Self.debugLog("[HID Touchpad] GDesktop unknown usage=0x\(String(usage, radix: 16)) value=\(value)")
                }
                return false
            }
        }

        // Digitizer page (standard touchpad usages)
        if page == 0x000D {
            let touchpadUsages: Set<UInt32> = [0x0042, 0x0051, 0x0052, 0x0053, 0x0054, 0x0055, 0x0056, 0x0029, 0x0044]

            guard touchpadUsages.contains(usage) else { return false }

            switch usage {
            case 0x0051:
                lastTouchpadPosition.x = Double(value) / 4095.0
                touchpadActive = true
                delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                Self.debugLog("[HID Touchpad] digitizer X=\(lastTouchpadPosition.x) Y=\(lastTouchpadPosition.y)")
            case 0x0052:
                lastTouchpadPosition.y = Double(value) / 4095.0
                touchpadActive = true
                delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                Self.debugLog("[HID Touchpad] digitizer X=\(lastTouchpadPosition.x) Y=\(lastTouchpadPosition.y)")
            case 0x0053:
                break
            case 0x0054:
                if value != 0 && !touchpadActive {
                    touchpadActive = true
                    delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                }
            case 0x0055:
                if value > 0 && !touchpadActive {
                    touchpadActive = true
                } else if value == 0 {
                    touchpadActive = false
                }
            case 0x0056:
                if value == 0 {
                    touchpadActive = false
                }
            case 0x0029:
                let wasActive = touchpadActive
                touchpadActive = value != 0
                if !wasActive && touchpadActive {
                    delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                }
                delegate?.remoteDidTouchpadClick(pressed: value != 0)
                Self.debugLog("[HID Touchpad] digitizer tipSwitch=\(touchpadActive)")
            case 0x0042:
                if value != 0 && !touchpadActive {
                    touchpadActive = true
                }
            case 0x0044:
                if value != 0 {
                    let scrollAmount = Double(value) / 4095.0
                    delegate?.remoteDidScroll(amount: scrollAmount)
                }
            default:
                break
            }

            return true
        }

        // Consumer page - check for touchpad-related usages
        if page == 0x000C {
            if usage == 0x0041 || usage == 0x0080 {
                delegate?.remoteDidTouchpadClick(pressed: value != 0)
                Self.debugLog("[HID Touchpad] consumer select/click usage=0x\(String(usage, radix: 16)) value=\(value)")
                return true
            }
            if value != 0 {
                switch usage {
                case 0x0042:
                    delegate?.remoteDidScroll(dx: 0, dy: settings().scrollSensitivity)
                    Self.debugLog("[HID Touchpad] consumer ring up")
                    return true
                case 0x0043:
                    delegate?.remoteDidScroll(dx: 0, dy: -settings().scrollSensitivity)
                    Self.debugLog("[HID Touchpad] consumer ring down")
                    return true
                case 0x0044:
                    delegate?.remoteDidScroll(dx: -settings().scrollSensitivity, dy: 0)
                    Self.debugLog("[HID Touchpad] consumer ring left")
                    return true
                case 0x0045:
                    delegate?.remoteDidScroll(dx: settings().scrollSensitivity, dy: 0)
                    Self.debugLog("[HID Touchpad] consumer ring right")
                    return true
                default:
                    break
                }
            }

            let consumerTouchpadUsages: Set<UInt32> = [0x0238, 0x0239, 0x023A, 0x023B, 0x023C, 0x023D]
            if consumerTouchpadUsages.contains(usage) && value != 0 {
                let normalized = Double(value) / 4095.0
                switch usage {
                case 0x0238, 0x023A:
                    lastTouchpadPosition.x = normalized
                case 0x0239, 0x023B:
                    lastTouchpadPosition.y = normalized
                default:
                    break
                }
                touchpadActive = true
                delegate?.remoteDidTouchpadMove(x: lastTouchpadPosition.x, y: lastTouchpadPosition.y)
                Self.debugLog("[HID Touchpad] consumer usage=0x\(String(usage, radix: 16)) value=\(normalized)")
                return true
            }
            return false
        }

        // Button page
        if page == 0x0009 {
            // Button press on touchpad
            if usage == 0x0001 {
                touchpadActive = value != 0
                delegate?.remoteDidTouchpadClick(pressed: value != 0)
                Self.debugLog("[HID Touchpad] button page usage=0x\(String(usage, radix: 16)) value=\(value)")
            } else if value != 0 {
                touchpadActive = true
                delegate?.remoteDidTouchpadClick(pressed: true)
                Self.debugLog("[HID Touchpad] button page usage=0x\(String(usage, radix: 16)) value=\(value)")
            }
            return true
        }

        return false
    }

    private func installHotKeyHandler() {
        guard hotKeyHandler == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == RemoteInputController.hotKeySignature else {
                    return noErr
                }

                let controller = Unmanaged<RemoteInputController>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in
                    switch hotKeyID.id {
                    case RemoteInputController.dictationHotKeyID:
                        controller.delegate?.remoteDidRequestDictationToggle()
                    case RemoteInputController.agentHotKeyID:
                        controller.delegate?.remoteDidRequestAgentToggle()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            context,
            &hotKeyHandler
        )
    }

    private func registerHotKey(_ shortcut: KeyboardShortcut, id: UInt32) -> String {
        guard shortcut.isEnabled, let keyCode = shortcut.keyCode else { return "Disabled" }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref {
            hotKeyRefs[id] = ref
            return "Registered: \(shortcut.title)"
        }
        return "Unavailable: \(shortcut.title) (\(status))"
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }
}

private extension KeyboardShortcut {
    init(event: NSEvent) {
        let keyName = Self.keyName(for: event)
        let modifierParts = event.shortcutModifierNames
        let title = (modifierParts + [keyName]).joined(separator: "-")
        self.init(
            keyCode: event.keyCode,
            modifierFlags: event.normalizedShortcutModifierRawValue,
            title: title
        )
    }

    static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_Escape: "Escape"
        case kVK_Delete: "Delete"
        case kVK_ForwardDelete: "Forward Delete"
        case kVK_LeftArrow: "Left Arrow"
        case kVK_RightArrow: "Right Arrow"
        case kVK_UpArrow: "Up Arrow"
        case kVK_DownArrow: "Down Arrow"
        default:
            if let functionName = functionKeyName(for: Int(event.keyCode)) {
                functionName
            } else if let characters = event.charactersIgnoringModifiers,
                      !characters.isEmpty {
                characters.uppercased()
            } else {
                "Key \(event.keyCode)"
            }
        }
    }

    static func functionKeyName(for keyCode: Int) -> String? {
        let names: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
            kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
        ]
        return names[keyCode]
    }

    var carbonModifierFlags: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var carbonFlags: UInt32 = 0
        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        return carbonFlags
    }
}

private extension NSEvent {
    var normalizedShortcutModifierRawValue: UInt {
        UInt(modifierFlags.intersection(Self.shortcutModifierMask).rawValue)
    }

    var shortcutModifierNames: [String] {
        let flags = modifierFlags
        var names: [String] = []
        if flags.contains(.control) { names.append("Control") }
        if flags.contains(.option) { names.append("Option") }
        if flags.contains(.shift) { names.append("Shift") }
        if flags.contains(.command) { names.append("Command") }
        if flags.contains(.function) { names.append("Fn") }
        return names
    }

    static var shortcutModifierMask: NSEvent.ModifierFlags {
        [.control, .option, .shift, .command, .function]
    }
}
