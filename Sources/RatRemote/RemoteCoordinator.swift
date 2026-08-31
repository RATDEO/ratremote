import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation

@MainActor
final class RemoteCoordinator: ObservableObject, RemoteInputControllerDelegate {
    @Published private(set) var status = "Idle"
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastError = ""

    let overlayPanel = TranscriptionOverlayPanel()
    @Published private(set) var activeMicrophoneStatus = "Default"
    @Published private(set) var lastRecordingStatus = "None"
    @Published private(set) var remoteMicRelayStatus = "Not started"
    @Published private(set) var remoteConnectionStatus = "Searching"
    @Published private(set) var remoteBatteryStatus = "Unavailable"
    @Published private(set) var lastRemoteHIDInput = "None"
    @Published private(set) var touchpadLog: [String] = []
    @Published private(set) var gcDiagnostic = "No controller"
    @Published private(set) var bleTouchpadStatus = "Initializing"
    @Published private(set) var isCapturingShortcut = false
    @Published private(set) var accessibilityStatus = "Unknown"
    @Published private(set) var dictationHotKeyStatus = "Unknown"
    @Published private(set) var agentHotKeyStatus = "Unknown"
    @Published private(set) var microphoneAccessStatus = "Unknown"
    @Published private(set) var speechAuthorizationStatus = "Unknown"
    @Published private(set) var isRecording = false
    @Published private(set) var microphoneDevices: [AudioInputDevice] = []
    @Published private(set) var pasteTargetStatus = "None"
    @Published private(set) var insertionStatus = "Idle"
    @Published private(set) var runningAppPath = ""
    @Published private(set) var isAutomationRunning = false
    @Published private(set) var isAutomationPaused = false
    @Published var automationInstructionText = ""
    @Published private(set) var automationStatus = "Idle"
    @Published private(set) var automationStepCount = 0
    @Published private(set) var automationLastSummary = ""
    @Published private(set) var hasPendingAutomationApproval = false
    @Published private(set) var availableWindowTargets: [WindowCaptureTarget] = []
    @Published private(set) var selectedWindowTarget: WindowCaptureTarget?
    @Published private(set) var agentCursorStatus = "Hidden"
    var selectedWindowTitle: String {
        selectedWindowTarget?.displayTitle ?? "Entire display"
    }

    var agentInputCompatibilityNote: String? {
        guard settingsStore.settings.useSeparateAgentCursor else { return nil }
        guard let selectedWindowTarget else {
            return "Select a window target to use separate agent input."
        }
        if selectedWindowTarget.isIPhoneMirroring {
            return "iPhone Mirroring uses targeted background taps and swipes with the separate agent cursor."
        }
        return "Background input is enabled for keys, text, clicks, scrolls, and drags without moving your cursor."
    }

    private enum DirectTouchpadMode {
        case pointer
        case clickWheel
    }

    let settingsStore: SettingsStore
    let recorder = AudioRecorder()

    private let client = InferenceClient()
    let localModelManager = LocalModelManager()
    private lazy var commandRouter = CommandInferenceRouter(remoteClient: client, localModel: localModelManager)
    private let localSpeech = LocalSpeechService()
    private let executor = ActionExecutor()
    private lazy var liquidKeyboard = LiquidKeyboardController(executor: executor)
    private let remoteAudioRelay = SiriRemoteAudioRelay()
    private var activeWorkflow: RecordingWorkflow = .selectedMode(.dictation)
    private var agentPushToTalkActive = false
    private var remoteFallbackRecordingStarted = false
    private var mediaWasPlaying = false
    private var mediaResumeScript: String?
    private var mediaResumeUsesPlayPauseKey = false
    private var mediaResumeUsesSystemMediaPlay = false
    private var playPausePressCount = 0
    private var playPausePressTask: Task<Void, Never>?
    private let playPausePressWindowNanos: UInt64 = 420_000_000
    private var keyboardPressCount = 0
    private var keyboardPressTask: Task<Void, Never>?
    private let keyboardPressWindowNanos: UInt64 = 360_000_000
    private var lastKeyboardTriggerRequest = Date.distantPast
    private let keyboardTriggerDuplicateWindow: TimeInterval = 0.16
    private var remoteMouseButtonDown = false
    private var remoteKeyboardDragActive = false
    private var remoteClickStabilizer = RemoteClickStabilizer()
    private var remoteTouchpadPressStartedAt = Date.distantPast
    private var lastDirectTouchpadEvent = Date.distantPast
    private var lastMultitouchRecoveryAttempt = Date.distantPast
    private var lastRemoteHIDInputUpdate = Date.distantPast
    private var lastTouchpadBackendRestart = Date.distantPast
    private let touchpadWatchdogIntervalNanos: UInt64 = 30_000_000_000
    private let touchpadBackendRestartCooldown: TimeInterval = 60
    private let multitouchRecoveryCooldown: TimeInterval = 2
    private var remoteInputBackendsRunning = false
    private var isSystemSleeping = false
    private var wakeRecoveryTask: Task<Void, Never>?
    private let wakeRecoveryDelayNanos: UInt64 = 15_000_000_000
    private var workspaceActivationObserver: Any?
    private var workspaceWillSleepObserver: Any?
    private var workspaceDidWakeObserver: Any?
    private var lastExternalApplication: NSRunningApplication?
    private var recordingTargetApplication: NSRunningApplication?
    private var automationTask: Task<Void, Never>?
    private var pendingAutomationActions: [RemoteAction] = []
    private var pendingAutomationTargetApplication: NSRunningApplication?
    private var pendingAutomationInstruction: String?
    private var pendingAutomationNextStep = 1
    private var pendingAutomationShouldContinue = false
    private var pendingAutomationLastActionSummary: String?
    private let agentInputMonitor = AgentInputMonitor()
    private var backgroundAgentSessionActive = false
    private var backgroundAgentYieldUntil: Date?
    private let backgroundAgentUserYieldDuration: TimeInterval = 1.4
    private lazy var input = RemoteInputController { [weak self] in
        self?.settingsStore.settings ?? AppSettings()
    }
    private let multitouch = SiriRemoteMultitouchController()
    private let bleTouchpad = BLETouchpadController()
    private let bluetoothLogTouchpad = BluetoothLogTouchpadController()

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        input.delegate = self
        setupBLENotifications()
        microphoneDevices = recorder.inputDevices
        logTouchpad("VERSION=2026-05-28-2010 remote-trackpad-drag")
        logTouchpad("accessibility=\(AXIsProcessTrusted() ? "GRANTED" : "DENIED")")
        logTouchpad("sensitivity=\(settingsStore.settings.remoteSensitivity)")
    }
    
    private func setupBLENotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleBLEMove(_:)), name: .bleTouchpadMove, object: nil)
        center.addObserver(self, selector: #selector(handleBLEClick(_:)), name: .bleTouchpadClick, object: nil)
        center.addObserver(self, selector: #selector(handleBLEScroll(_:)), name: .bleTouchpadScroll, object: nil)
        center.addObserver(self, selector: #selector(handleBLEStatus(_:)), name: .bleTouchpadStatus, object: nil)
        center.addObserver(self, selector: #selector(handleBLERemoteBatteryStatus(_:)), name: .bleRemoteBatteryStatus, object: nil)
        center.addObserver(self, selector: #selector(handleMultitouchMove(_:)), name: .siriRemoteMultitouchMove, object: nil)
        center.addObserver(self, selector: #selector(handleMultitouchEnd(_:)), name: .siriRemoteMultitouchEnd, object: nil)
        center.addObserver(self, selector: #selector(handleMultitouchStatus(_:)), name: .siriRemoteMultitouchStatus, object: nil)
        center.addObserver(self, selector: #selector(handleBluetoothLogDelta(_:)), name: .bluetoothLogTouchpadDelta, object: nil)
        center.addObserver(self, selector: #selector(handleBluetoothLogRemoteButton(_:)), name: .bluetoothLogRemoteButton, object: nil)
        center.addObserver(self, selector: #selector(handleBluetoothLogStatus(_:)), name: .bluetoothLogTouchpadStatus, object: nil)
    }
    
    @objc private func handleBLEMove(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let x = userInfo["x"] as? Double,
              let y = userInfo["y"] as? Double else { return }
        logTouchpad(
            "BLE move x=\(String(format: "%.3f", x)) y=\(String(format: "%.3f", y))",
            throttleKey: "ble-move",
            minimumInterval: 0.35
        )
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        
        bleTouchpadInactivityTimer?.invalidate()
        bleTouchpadInactivityTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.touchpadNeedsInitialPosition = true
            }
        }
        
        if touchpadNeedsInitialPosition {
            lastTouchpadScreenPosition = (x: x * screenFrame.width, y: y * screenFrame.height)
            touchpadNeedsInitialPosition = false
            return
        }
        
        let deltaX = (x - lastTouchpadScreenPosition.x / screenFrame.width) * screenFrame.width
        let deltaY = -(y - lastTouchpadScreenPosition.y / screenFrame.height) * screenFrame.height
        lastTouchpadScreenPosition = (x: x * screenFrame.width, y: y * screenFrame.height)
        let sensitivity = settingsStore.settings.remoteSensitivity
        logTouchpad(
            "BLE sensitivity=\(String(format: "%.6f", sensitivity)) move=\(String(format: "%.1f", deltaX * sensitivity)),\(String(format: "%.1f", deltaY * sensitivity))",
            throttleKey: "ble-scaled-move",
            minimumInterval: 0.35
        )
        moveRemotePointer(dx: deltaX * sensitivity, dy: deltaY * sensitivity)
    }
    
    @objc private func handleBLEClick(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let pressed = userInfo["pressed"] as? Bool else { return }
        logTouchpad("BLE click pressed=\(pressed)")
        handleRemoteTouchpadButton(pressed: pressed)
    }
    
    @objc private func handleBLEScroll(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let amount = userInfo["amount"] as? Double else { return }
        logTouchpad(
            "BLE scroll amount=\(String(format: "%.3f", amount))",
            throttleKey: "ble-scroll",
            minimumInterval: 0.35
        )
        executor.scroll(amount: amount)
    }
    
    @objc private func handleBLEStatus(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let status = userInfo["status"] as? String else { return }
        bleTouchpadStatus = status
    }

    @objc private func handleBLERemoteBatteryStatus(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let status = userInfo["status"] as? String else { return }
        remoteBatteryStatus = status
    }

    @objc private func handleMultitouchMove(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let x = userInfo["x"] as? Double,
              let y = userInfo["y"] as? Double else { return }
        lastDirectTouchpadEvent = Date()
        let sens = settingsStore.settings.remoteSensitivity
        if userInfo["reset"] as? Bool == true {
            remoteDidEndTouchpadInteraction()
        }
        if let count = userInfo["count"] as? Int {
            logTouchpad(
                "multitouch count=\(count) x=\(String(format: "%.3f", x)) y=\(String(format: "%.3f", y)) sens=\(String(format: "%.6f", sens)) init=\(touchpadNeedsInitialPosition)",
                throttleKey: "multitouch-move",
                minimumInterval: 0.35
            )
        }
        remoteDidTouchpadMove(x: x, y: y)
    }

    @objc private func handleMultitouchEnd(_ notification: Notification) {
        remoteDidEndTouchpadInteraction()
    }

    @objc private func handleMultitouchStatus(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let status = userInfo["status"] as? String else { return }
        bleTouchpadStatus = status
        logTouchpad(status)
    }

    @objc private func handleBluetoothLogDelta(_ notification: Notification) {
        guard Date().timeIntervalSince(lastDirectTouchpadEvent) > 0.25 else { return }
        guard let userInfo = notification.userInfo,
              let dx = userInfo["dx"] as? Double,
              let dy = userInfo["dy"] as? Double else { return }
        lastDirectTouchpadEvent = Date()
        let sensitivity = settingsStore.settings.remoteSensitivity
        let scaledDX = max(-80, min(80, dx * sensitivity * 0.12))
        let scaledDY = max(-80, min(80, dy * sensitivity * 0.12))
        logTouchpad(
            "btlog dx=\(String(format: "%.1f", dx)) dy=\(String(format: "%.1f", dy)) move=\(String(format: "%.1f", scaledDX)),\(String(format: "%.1f", scaledDY))",
            throttleKey: "btlog-delta",
            minimumInterval: 0.35
        )
        moveRemotePointer(dx: scaledDX, dy: -scaledDY)
    }

    @objc private func handleBluetoothLogRemoteButton(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let button = userInfo["button"] as? String,
              userInfo["pressed"] as? Bool == true else { return }
        logTouchpad("btlog button \(button)")
        remoteDidObserveHIDInput("bluetooth log button \(button)")
        guard button == "tv" else { return }
        remoteDidRequestKeyboard()
    }

    @objc private func handleBluetoothLogStatus(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let status = userInfo["status"] as? String else { return }
        bleTouchpadStatus = status
        logTouchpad(status)
    }

    func start() {
        runningAppPath = executor.runningAppPath()
        refreshAccessibilityStatus()
        if !AXIsProcessTrusted() {
            executor.requestAccessibilityPermission()
        }
        refreshPermissionStatuses()
        startTrackingFrontmostApplication()
        startRemoteInputBackends(reason: "app start")
        startTrackingSleepWake()
        startTouchpadWatchdog()
    }

    func openBluetoothSettingsForExclusivePairing() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else { return }
        NSWorkspace.shared.open(url)
    }

    func beginExclusiveRemotePairing() {
        lastError = ""
        remoteMicRelayStatus = "Pairing requested"
        bleTouchpad.beginExclusivePairing()
    }

    func cancelExclusiveRemotePairing() {
        bleTouchpad.cancelExclusivePairing()
    }

    func stop() {
        localModelManager.stop()
        stopAutomation()
        endBackgroundAgentSession()
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        stopTrackingSleepWake()
        stopTrackingFrontmostApplication()
        bleTouchpadInactivityTimer?.invalidate()
        playPausePressTask?.cancel()
        playPausePressTask = nil
        playPausePressCount = 0
        keyboardPressTask?.cancel()
        keyboardPressTask = nil
        keyboardPressCount = 0
        lastKeyboardTriggerRequest = .distantPast
        finishRemoteTouchpadButtonPress()
        liquidKeyboard.hide()
        stopTouchpadWatchdog()
        logFlushWorkItem?.cancel()
        flushLogBuffer()
        NotificationCenter.default.removeObserver(self)
        stopRemoteInputBackends(reason: "app stop")
    }

    private func startTrackingSleepWake() {
        stopTrackingSleepWake()
        let center = NSWorkspace.shared.notificationCenter
        workspaceWillSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.prepareForSystemSleep()
            }
        }
        workspaceDidWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverFromSystemWake()
            }
        }
    }

    private func stopTrackingSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        if let workspaceWillSleepObserver {
            center.removeObserver(workspaceWillSleepObserver)
        }
        if let workspaceDidWakeObserver {
            center.removeObserver(workspaceDidWakeObserver)
        }
        workspaceWillSleepObserver = nil
        workspaceDidWakeObserver = nil
    }

    private func prepareForSystemSleep() {
        isSystemSleeping = true
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        logTouchpad("system sleep: stopping remote input backends")
        resetTouchpadStateForBackendRestart()
        stopRemoteInputBackends(reason: "system sleep")
    }

    private func recoverFromSystemWake() {
        isSystemSleeping = false
        wakeRecoveryTask?.cancel()
        logTouchpad("system wake: scheduling remote input restart")
        resetTouchpadStateForBackendRestart()
        let delay = wakeRecoveryDelayNanos
        wakeRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            guard !Task.isCancelled, !self.isSystemSleeping else { return }
            self.startRemoteInputBackends(reason: "system wake")
            self.wakeRecoveryTask = nil
        }
    }

    private func startRemoteInputBackends(reason: String) {
        guard !isSystemSleeping else {
            logTouchpad("remote input start skipped while sleeping: \(reason)")
            return
        }
        guard !remoteInputBackendsRunning else { return }
        logTouchpad("remote input backends starting: \(reason)")
        input.start()
        _ = multitouch.start()
        bleTouchpad.start()
        bluetoothLogTouchpad.start()
        lastDirectTouchpadEvent = Date()
        resetTouchpadStateForBackendRestart()
        remoteInputBackendsRunning = true
    }

    private func stopRemoteInputBackends(reason: String) {
        guard remoteInputBackendsRunning else { return }
        logTouchpad("remote input backends stopping: \(reason)")
        input.stop()
        multitouch.stop()
        bleTouchpad.stop()
        bluetoothLogTouchpad.stop()
        input.stopRemoteMicrophonePolling()
        remoteAudioRelay.discardCapture()
        remoteInputBackendsRunning = false
    }

    private func resetTouchpadStateForBackendRestart() {
        if remoteKeyboardDragActive {
            remoteKeyboardDragActive = false
            _ = liquidKeyboard.endRemoteDrag()
        }
        if remoteMouseButtonDown {
            remoteMouseButtonDown = false
            executor.mouseUpCurrent()
        }
        remoteClickStabilizer.reset()
        remoteTouchpadPressStartedAt = .distantPast
        bleTouchpadInactivityTimer?.invalidate()
        bleTouchpadInactivityTimer = nil
        touchpadNeedsInitialPosition = true
        directTouchpadMode = nil
        lastClickWheelAngle = nil
        lastClickWheelRadius = nil
        clickWheelArbitrator.reset()
        swipeGestureFired = false
        lastTouchpadScreenPosition = (x: 0, y: 0)
        lastDirectTouchpadPosition = (x: 0, y: 0)
        touchpadStartPosition = (x: 0, y: 0)
        touchpadLastPosition = (x: 0, y: 0)
        touchpadMinPosition = (x: 0, y: 0)
        touchpadMaxPosition = (x: 0, y: 0)
        touchpadStartRadius = 0
    }

    private func startTouchpadWatchdog() {
        stopTouchpadWatchdog()
        let interval = touchpadWatchdogIntervalNanos
        touchpadWatchdogTask = Task.detached { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self.checkTouchpadHealth()
            }
        }
    }

    private func stopTouchpadWatchdog() {
        touchpadWatchdogTask?.cancel()
        touchpadWatchdogTask = nil
    }

    private func checkTouchpadHealth() {
        guard remoteInputBackendsRunning, !isSystemSleeping else { return }
        recoverMultitouchIfNeeded(trigger: "watchdog")
        guard bluetoothLogTouchpad.needsRestart() else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTouchpadBackendRestart) >= touchpadBackendRestartCooldown else {
            return
        }

        lastTouchpadBackendRestart = now
        logTouchpad("watchdog: bluetooth log fallback exited, restarting")
        bluetoothLogTouchpad.stop()
        bluetoothLogTouchpad.start()
        if !bluetoothLogTouchpad.isHealthy() {
            logTouchpad("watchdog: bluetooth log fallback is not running")
        }
    }

    func toggleRecording() {
        if isRecording {
            finishRecording()
        } else {
            beginRecording(workflow: .selectedMode(settingsStore.settings.inputMode))
        }
    }

    func toggleDictationRecording() {
        if isRecording {
            finishRecording()
        } else {
            beginRecording(workflow: .dictationOnly)
        }
    }

    func toggleAgentRecording() {
        guard settingsStore.settings.isAgentModeEnabled else {
            lastError = "Agent mode is experimental. Enable it in Settings before using Agent commands."
            return
        }
        if isRecording {
            finishRecording()
        } else {
            beginRecording(workflow: .agentCommand)
        }
    }

    func agentModeSettingDidChange(enabled: Bool) {
        if !enabled {
            stopAutomation()
            endBackgroundAgentSession()
        }
        input.registerCurrentHotKeys()
    }

    func beginRecording(workflow: RecordingWorkflow, deviceIDOverride: String? = nil) {
        activeWorkflow = workflow
        recordingTargetApplication = currentTargetApplication()
        pasteTargetStatus = recordingTargetApplication?.localizedName ?? "None"
        if workflow == .dictationOnly {
            traceMedia("begin dictation; checking media target=\(pasteTargetStatus)")
            pauseMediaPlayback()
        }

        lastTranscript = ""
        lastError = ""
        lastRecordingStatus = "Recording"
        overlayPanel.showListening()

        Task {
            do {
                try await recorder.start(deviceID: deviceIDOverride ?? settingsStore.settings.microphoneDeviceID)
                isRecording = true
                activeMicrophoneStatus = recorder.activeInputDeviceName.isEmpty ? "Default" : recorder.activeInputDeviceName
                status = workflow.listeningStatus
                insertionStatus = "Waiting"
            } catch {
                overlayPanel.hide()
                refreshPermissionStatuses()
                lastError = error.localizedDescription
                status = "Recording failed"
                activeMicrophoneStatus = "Unavailable"
            }
        }
    }

    func finishRecording() {
        let settings = settingsStore.settings
        let workflow = activeWorkflow
        status = "Transcribing"
        overlayPanel.showWorking()

        Task {
            defer { overlayPanel.hide() }
            guard let url = await recorder.stop() else {
                isRecording = false
                status = "No recording"
                activeMicrophoneStatus = "Idle"
                if workflow == .dictationOnly { resumeMediaPlayback() }
                return
            }
            let recordedMicrophoneName = activeMicrophoneStatus
            isRecording = false
            activeMicrophoneStatus = "Idle"
            await processRecordedAudio(
                url,
                recordedMicrophoneName: recordedMicrophoneName,
                workflow: workflow,
                settings: settings
            )
        }
    }

    private func processRecordedAudio(
        _ url: URL,
        recordedMicrophoneName: String,
        workflow: RecordingWorkflow,
        settings: AppSettings
    ) async {
        // Recordings can contain highly sensitive speech. Retain them only for
        // the duration of diagnostics/transcription, including early returns.
        defer { try? FileManager.default.removeItem(at: url) }
        var failureStage = RecordingFailureStage.transcription
        do {
            let diagnostics = await Task.detached(priority: .utility) {
                AudioRecorder.diagnostics(for: url)
            }.value
            if let diagnostics {
                lastRecordingStatus = diagnostics.summary
                if diagnostics.isSilent {
                    status = "No speech detected"
                    lastError = "The selected microphone (\(recordedMicrophoneName)) recorded silence."
                    lastTranscript = ""
                    if workflow == .dictationOnly { resumeMediaPlayback() }
                    return
                }
            } else {
                lastRecordingStatus = "Could not inspect audio"
            }

            let text = try await transcribe(audioURL: url, settings: settings, forceLocal: workflow == .dictationOnly)
            lastTranscript = text
            guard !text.isEmpty else {
                status = "No speech detected"
                if workflow == .dictationOnly { resumeMediaPlayback() }
                return
            }

            failureStage = .handling
            try await handle(
                text: text,
                settings: settings,
                workflow: workflow,
                targetApplication: recordingTargetApplication
            )
            if workflow == .dictationOnly { resumeMediaPlayback() }
            if !isAutomationRunning { status = "Idle" }
        } catch LocalSpeechError.emptyResult {
            lastError = ""
            status = "No speech detected"
            activeMicrophoneStatus = "Idle"
            if workflow == .dictationOnly { resumeMediaPlayback() }
        } catch {
            lastError = userFacingRecordingError(error, stage: failureStage, workflow: workflow, settings: settings)
            status = failureStage.failureStatus(for: workflow)
            insertionStatus = "Failed"
            activeMicrophoneStatus = "Idle"
            if workflow == .dictationOnly { resumeMediaPlayback() }
        }
    }

    func requestSpeechAuthorization() {
        status = "Requesting speech and microphone permission"
        Task {
            let microphoneOK = await AudioRecorder.requestMicrophoneAccess()
            let speechOK = await localSpeech.requestAuthorization()
            refreshPermissionStatuses()

            switch (microphoneOK, speechOK) {
            case (true, true):
                status = "Speech and microphone permissions granted"
                lastError = ""
            case (false, true):
                status = "Microphone permission denied"
                lastError = "Open Privacy & Security > Microphone and allow RatRemote."
                openPrivacySettingsPane("Privacy_Microphone")
            case (true, false):
                status = "Speech permission denied"
                lastError = "Open Privacy & Security > Speech Recognition and allow RatRemote."
                openPrivacySettingsPane("Privacy_SpeechRecognition")
            case (false, false):
                status = "Speech and microphone permissions denied"
                lastError = "Open Privacy & Security and allow RatRemote for Microphone and Speech Recognition."
                openPrivacySettingsPane("Privacy_Microphone")
            }
        }
    }

    func refreshMicrophones() {
        recorder.refreshInputDevices()
        microphoneDevices = recorder.inputDevices
    }

    func requestAccessibilityPermission() {
        executor.requestAccessibilityPermission()
        executor.openAccessibilitySettings()
        refreshAccessibilityStatus()
        status = "Requested Accessibility permission"
    }

    func openAccessibilityApprovalFlow() {
        runningAppPath = executor.runningAppPath()
        openRunningAppInFinder()
        executor.requestAccessibilityPermission()
        executor.openAccessibilitySettings()
        refreshAccessibilityStatus()
        status = "Approve RatRemote in Accessibility"
    }

    func openRunningAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: runningAppPath)])
    }

    func refreshAccessibilityStatus() {
        accessibilityStatus = executor.accessibilityStatus()
    }

    func refreshPermissionStatuses() {
        microphoneAccessStatus = AudioRecorder.microphoneAccessStatusDescription()
        speechAuthorizationStatus = localSpeech.authorizationStatusDescription()
    }

    private func openPrivacySettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func startTrackingFrontmostApplication() {
        guard workspaceActivationObserver == nil else { return }
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.rememberExternalApplication(application)
            }
        }
    }

    private func stopTrackingFrontmostApplication() {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        workspaceActivationObserver = nil
    }

    private func rememberExternalApplication(_ application: NSRunningApplication?) {
        guard let application, !isRatRemote(application) else { return }
        lastExternalApplication = application
        if !isRecording {
            pasteTargetStatus = application.localizedName ?? "Unknown"
        }
    }

    private func currentTargetApplication() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, !isRatRemote(frontmost) {
            return frontmost
        }
        return lastExternalApplication
    }

    private func selectedTargetApplication(fallback: NSRunningApplication?) -> NSRunningApplication? {
        if let selectedWindowTarget,
           let application = NSRunningApplication(processIdentifier: selectedWindowTarget.ownerPID),
           !application.isTerminated {
            return application
        }
        return fallback
    }

    private var useBackgroundAgentInput: Bool {
        settingsStore.settings.useSeparateAgentCursor && selectedWindowTarget != nil
    }

    private func beginBackgroundAgentSession(activity: AgentCursorActivity = .thinking) {
        guard useBackgroundAgentInput, let selectedWindowTarget else { return }
        backgroundAgentSessionActive = true
        agentCursorStatus = cursorStatusTitle(activity)
        executor.showVirtualCursor(targetWindow: selectedWindowTarget, activity: activity)
        agentInputMonitor.start(targetPID: selectedWindowTarget.ownerPID, targetBounds: selectedWindowTarget.bounds) { [weak self] in
            Task { @MainActor in
                self?.handleAgentInputInterruption()
            }
        }
    }

    private func setBackgroundAgentActivity(_ activity: AgentCursorActivity) {
        guard backgroundAgentSessionActive else { return }
        agentCursorStatus = cursorStatusTitle(activity)
        executor.setVirtualCursorActivity(activity)
    }

    private func endBackgroundAgentSession() {
        guard backgroundAgentSessionActive else { return }
        backgroundAgentSessionActive = false
        backgroundAgentYieldUntil = nil
        agentCursorStatus = "Hidden"
        agentInputMonitor.stop()
        executor.hideVirtualCursor()
    }

    private func handleAgentInputInterruption() {
        guard backgroundAgentSessionActive else { return }
        if selectedWindowTarget?.isIPhoneMirroring == true {
            backgroundAgentYieldUntil = Date().addingTimeInterval(backgroundAgentUserYieldDuration)
            agentCursorStatus = "Yielding"
            executor.setVirtualCursorActivity(.idle)
            if isAutomationRunning || automationTask != nil {
                automationStatus = "Yielding to user"
            }
            status = "Agent yielding to user"
            insertionStatus = "User input"
            lastError = ""
            traceAutomation("yielding to user input hasTarget=\(selectedWindowTarget != nil)")
            return
        }

        let wasAutomating = isAutomationRunning || isAutomationPaused || automationTask != nil
        automationTask?.cancel()
        automationTask = nil
        if wasAutomating {
            isAutomationRunning = false
            isAutomationPaused = false
            automationStatus = "Interrupted by user"
        }
        status = "Agent yielded to user"
        insertionStatus = "Interrupted by user"
        lastError = "User input in the selected target window paused the separate agent cursor."
        endBackgroundAgentSession()
    }

    private func waitForBackgroundAgentYieldIfNeeded() async throws {
        while let yieldUntil = backgroundAgentYieldUntil {
            let remaining = yieldUntil.timeIntervalSinceNow
            if remaining <= 0 {
                backgroundAgentYieldUntil = nil
                break
            }
            agentCursorStatus = "Yielding"
            if isAutomationRunning || automationTask != nil {
                automationStatus = "Yielding to user"
            }
            status = "Agent yielding to user"
            executor.setVirtualCursorActivity(.idle)
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 0.25) * 1_000_000_000))
        }
    }

    private func waitForPauseIfNeeded() async throws {
        while isAutomationPaused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func cursorStatusTitle(_ activity: AgentCursorActivity) -> String {
        switch activity {
        case .hidden:
            "Hidden"
        case .idle:
            "Idle"
        case .thinking:
            "Thinking"
        case .acting:
            "Acting"
        }
    }

    private func isRatRemote(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier == Bundle.main.bundleIdentifier || application.processIdentifier == NSRunningApplication.current.processIdentifier
    }

    private func activateTargetApplication(_ application: NSRunningApplication?) async {
        _ = await activatePasteTarget(application)
    }

    private func activateAgentTarget(_ application: NSRunningApplication?) async {
        if useBackgroundAgentInput {
            return
        }
        if executor.activateWindow(selectedWindowTarget) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            return
        }
        await activateTargetApplication(application)
    }

    private func withAgentInputTarget<T>(
        targetApplication: NSRunningApplication?,
        operation: () async throws -> T
    ) async throws -> T {
        await activateAgentTarget(targetApplication)
        return try await operation()
    }

    private func activatePasteTarget(_ application: NSRunningApplication?) async -> Bool {
        guard let application, !application.isTerminated else { return false }
        _ = application.activate()
        try? await Task.sleep(nanoseconds: 700_000_000)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
            return true
        }
        if let bundleURL = application.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    func beginShortcutCapture(kind: AppShortcutKind) {
        isCapturingShortcut = true
        status = "Press a key combo"
        input.beginShortcutCapture(kind: kind)
    }

    func clearShortcut(kind: AppShortcutKind) {
        switch kind {
        case .dictation:
            settingsStore.settings.dictationShortcut = .disabled
        case .agent:
            settingsStore.settings.agentShortcut = .disabled
        }
        isCapturingShortcut = false
        input.cancelShortcutCapture()
        input.registerCurrentHotKeys()
        status = "Hotkey disabled"
    }

    enum ServerRole {
        case transcription
        case inference
        case computerUse
    }

    func testServer(_ role: ServerRole = .inference) {
        let settings = settingsStore.settings
        let target: (label: String, url: String, apiKey: String) = switch role {
        case .transcription:
            ("Transcription", settings.transcriptionServerURL, settings.transcriptionAPIKey)
        case .inference:
            ("Inference", settings.inferenceServerURL, settings.inferenceAPIKey)
        case .computerUse:
            ("Computer use", settings.computerUseServerURL, settings.computerUseAPIKey)
        }
        status = "Checking \(target.label.lowercased()) server"
        Task {
            do {
                let result = try await client.health(serverURL: target.url, apiKey: target.apiKey)
                status = "\(target.label): \(result)"
                lastError = ""
            } catch {
                status = "\(target.label) unavailable"
                lastError = userFacingServerError(error, label: target.label, url: target.url)
            }
        }
    }

    var appleIntelligenceStatus: String {
        AppleIntelligenceCommandProvider().availabilityDescription
    }

    func startLocalModel() {
        status = "Starting local model"
        Task {
            do {
                _ = try await localModelManager.ensureRunning()
                status = "Local Gemma ready"
                lastError = ""
            } catch {
                status = "Local Gemma unavailable"
                lastError = error.localizedDescription
            }
        }
    }

    func stopLocalModel() {
        localModelManager.stop()
        status = "Local Gemma stopped"
    }

    func downloadLocalModel() {
        Task { await localModelManager.downloadModel() }
    }

    func downloadLocalModelRuntime() {
        Task { await localModelManager.downloadRuntime() }
    }

    func testCommandModel() {
        let settings = settingsStore.settings
        status = "Testing command model"
        Task {
            do {
                let response = try await commandRouter.command(
                    request: CommandRequest(text: "press command shift p", screenshotBase64: nil, agentMode: false, screenContext: nil),
                    settings: settings
                )
                status = "Command model ready (\(response.actions.count) action\(response.actions.count == 1 ? "" : "s"))"
                lastError = ""
            } catch {
                status = "Command model unavailable"
                lastError = error.localizedDescription
            }
        }
    }

    func refreshWindowTargets() {
        availableWindowTargets = executor.windowTargets()
        if let selectedWindowTarget,
           let refreshed = availableWindowTargets.first(where: { $0.id == selectedWindowTarget.id }) {
            self.selectedWindowTarget = refreshed
        } else if selectedWindowTarget != nil {
            automationStatus = "Target window unavailable"
        }
    }

    func selectWindowTarget(_ target: WindowCaptureTarget?) {
        if backgroundAgentSessionActive {
            endBackgroundAgentSession()
        }
        selectedWindowTarget = target
        if target?.isIPhoneMirroring == true, settingsStore.settings.useSeparateAgentCursor {
            automationStatus = "Target: iPhone Mirroring"
        } else {
            automationStatus = target == nil ? "Target: entire display" : "Target: \(target?.shortTitle ?? "")"
        }
        status = "Automation target selected"
    }

    func clearWindowTarget() {
        selectWindowTarget(nil)
    }

    @discardableResult
    func startAutomationFromInstructionBox() -> Bool {
        let trimmed = automationInstructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            automationStatus = "Missing instruction"
            lastError = "Enter an automation instruction first."
            return false
        }
        guard !isAutomationRunning else { return false }
        automationInstructionText = trimmed

        let targetApplication = selectedTargetApplication(fallback: currentTargetApplication())
        clearPendingAutomationApprovalState()
        automationStepCount = 0
        automationLastSummary = ""
        automationStatus = "Starting"
        status = "Automation starting"
        lastError = ""
        isAutomationRunning = true

        automationTask = Task { [weak self] in
            await self?.runAutomationLoop(instruction: trimmed, targetApplication: targetApplication)
        }
        return true
    }

    @discardableResult
    func enterAutomationInstructionAndStartLoop(_ instruction: String) -> Bool {
        guard !isAutomationRunning else { return false }
        automationInstructionText = instruction
        return startAutomationFromInstructionBox()
    }

    func stopAutomation() {
        automationTask?.cancel()
        automationTask = nil
        endBackgroundAgentSession()
        if isAutomationRunning || isAutomationPaused {
            automationStatus = "Stopped"
            status = "Automation stopped"
        }
        isAutomationRunning = false
        isAutomationPaused = false
    }

    func pauseAutomation() {
        guard isAutomationRunning, !isAutomationPaused else { return }
        isAutomationPaused = true
        automationStatus = "Paused"
        status = "Automation paused"
        lastError = ""
    }

    func resumeAutomation() {
        guard isAutomationPaused else { return }
        isAutomationPaused = false
        automationStatus = "Resuming"
        status = "Automation resuming"
        lastError = ""
    }

    func approvePendingAutomationStep() {
        runPendingAutomationStep(resumeAfterApproval: false)
    }

    func allowAllPendingAutomationSteps() {
        settingsStore.settings.automationAllowAllApprovals = true
        runPendingAutomationStep(resumeAfterApproval: true)
    }

    private func runPendingAutomationStep(resumeAfterApproval: Bool) {
        guard hasPendingAutomationApproval, !pendingAutomationActions.isEmpty else { return }
        let actions = pendingAutomationActions
        let targetApplication = pendingAutomationTargetApplication
        let instruction = pendingAutomationInstruction
        let nextStep = pendingAutomationNextStep
        let shouldContinue = pendingAutomationShouldContinue
        let lastActionSummary = pendingAutomationLastActionSummary
        clearPendingAutomationApprovalState()
        automationStatus = resumeAfterApproval ? "Allowing all approvals" : "Running approved step"
        status = resumeAfterApproval ? "Automation resuming" : "Automation approved step"
        lastError = ""
        isAutomationRunning = resumeAfterApproval && shouldContinue

        automationTask = Task { [weak self] in
            await self?.executePendingAutomationStep(
                actions: actions,
                targetApplication: targetApplication,
                instruction: instruction,
                nextStep: nextStep,
                shouldContinue: shouldContinue,
                lastActionSummary: lastActionSummary,
                resumeAfterApproval: resumeAfterApproval
            )
        }
    }

    private func executePendingAutomationStep(
        actions: [RemoteAction],
        targetApplication: NSRunningApplication?,
        instruction: String?,
        nextStep: Int,
        shouldContinue: Bool,
        lastActionSummary: String?,
        resumeAfterApproval: Bool
    ) async {
        do {
            try await executeAgentActions(
                actions,
                settings: settingsStore.settings,
                actionFrame: captureForAgent()?.frame,
                targetApplication: targetApplication
            )
            automationLastSummary = "\(resumeAfterApproval ? "Allowed" : "Approved"): \(actionsDescription(actions))"

            if resumeAfterApproval,
               shouldContinue,
               let instruction {
                await runAutomationLoop(
                    instruction: instruction,
                    targetApplication: targetApplication,
                    startStep: nextStep,
                    initialLastActionSummary: lastActionSummary
                )
                return
            }

            automationStatus = "Approved step complete"
            status = "Idle"
            isAutomationRunning = false
            automationTask = nil
        } catch {
            automationStatus = "Approved step failed"
            status = "Automation failed"
            lastError = error.localizedDescription
            isAutomationRunning = false
            automationTask = nil
        }
    }

    func clearPendingAutomationStep() {
        clearPendingAutomationApprovalState()
        automationStatus = "Idle"
        lastError = ""
    }

    private func clearPendingAutomationApprovalState() {
        pendingAutomationActions = []
        pendingAutomationTargetApplication = nil
        pendingAutomationInstruction = nil
        pendingAutomationNextStep = 1
        pendingAutomationShouldContinue = false
        pendingAutomationLastActionSummary = nil
        hasPendingAutomationApproval = false
    }

    private func runAutomationLoop(
        instruction: String,
        targetApplication: NSRunningApplication?,
        startStep: Int = 1,
        initialLastActionSummary: String? = nil
    ) async {
        let settings = settingsStore.settings
        let maxSteps = AppSettings.normalizedAutomationMaxSteps(settings.automationMaxSteps)
        let stepDelay = AppSettings.normalizedAutomationStepDelay(settings.automationStepDelay)
        let runStartedAt = Date()
        let runtimeLimit = AppSettings.automationRuntimeLimitSeconds
        var consecutiveWaitOnlySteps = 0
        var lastActionSummary = initialLastActionSummary
        let managesBackgroundSession = useBackgroundAgentInput
        if managesBackgroundSession {
            beginBackgroundAgentSession(activity: .thinking)
        }
        defer {
            if managesBackgroundSession {
                endBackgroundAgentSession()
            }
        }

        do {
            await activateAgentTarget(targetApplication)

            guard startStep <= maxSteps else {
                automationStatus = "Step limit reached"
                status = "Automation limit reached"
                isAutomationRunning = false
                automationTask = nil
                return
            }

            for step in startStep...maxSteps {
                try Task.checkCancellation()
                try await waitForPauseIfNeeded()
                try await waitForBackgroundAgentYieldIfNeeded()
                if Date().timeIntervalSince(runStartedAt) > runtimeLimit {
                    let minutes = Int(runtimeLimit / 60)
                    traceAutomation("stopped at step \(step): runtime exceeded \(minutes)m")
                    automationStatus = "Time limit reached"
                    status = "Automation stopped"
                    lastError = "Automation stopped after \(minutes) minutes without completing."
                    isAutomationRunning = false
                    automationTask = nil
                    return
                }
                automationStepCount = step
                automationStatus = "Observing screen"
                status = "Automation step \(step)"
                setBackgroundAgentActivity(.thinking)

                guard let capture = captureForAgent() else {
                    traceAutomation("screen capture failed at step \(step)")
                    automationStatus = "Screen capture failed"
                    status = "Automation failed"
                    if lastError.isEmpty {
                        lastError = "RatRemote could not capture the selected automation target."
                    }
                    isAutomationRunning = false
                    automationTask = nil
                    return
                }

                automationStatus = "Reading screen"
                setBackgroundAgentActivity(.thinking)
                let screenContext = await screenContextText(for: capture, settings: settings, instruction: instruction)

                automationStatus = "Planning step"
                setBackgroundAgentActivity(.thinking)
                let response = try await client.automationStep(
                    instruction: instruction,
                    screenshotBase64: capture.imageBase64,
                    screenContext: screenContext,
                    stepIndex: step,
                    maxSteps: maxSteps,
                    lastActionSummary: lastActionSummary,
                    serverURL: settings.inferenceServerURL,
                    apiKey: settings.inferenceAPIKey
                )

                let summary = normalizedAutomationSummary(response: response)
                let plannedActions = repairedAutomationActions(
                    response.actions,
                    instruction: instruction,
                    summary: summary
                )
                automationLastSummary = summary
                traceAutomation("step=\(step) windowScoped=\(capture.isWindowScoped) instructionLength=\(instruction.count)")
                if let screenContext {
                    traceAutomation("screenContextLength=\(screenContext.count)")
                }
                if let blockReason = automationHardBlockReason(
                    instruction: instruction,
                    screenContext: screenContext,
                    response: response,
                    actions: plannedActions
                ) {
                    traceAutomation("blocked protected-trait response summaryLength=\(summary.count) criteriaLength=\(response.criteriaSummary?.count ?? 0) safetyNoteLength=\(response.safetyNote?.count ?? 0)")
                    automationStatus = "Blocked"
                    status = "Automation blocked"
                    lastError = blockReason
                    isAutomationRunning = false
                    automationTask = nil
                    return
                }
                let approvalReason = automationApprovalReason(instruction: instruction, screenContext: screenContext, response: response)
                traceAutomation("decision requiresApproval=\(response.requiresApproval ?? false) approvalSource=\(approvalReason ?? "none") allowAll=\(settingsStore.settings.automationAllowAllApprovals) backgroundInput=\(useBackgroundAgentInput) shouldContinue=\(response.shouldContinue.map(String.init) ?? "nil") summaryLength=\(summary.count) criteriaLength=\(response.criteriaSummary?.count ?? 0) safetyNoteLength=\(response.safetyNote?.count ?? 0) actions=\(actionsDescription(response.actions)) executableActions=\(actionsDescription(plannedActions))")

                if let approvalReason {
                    pendingAutomationActions = plannedActions
                    pendingAutomationTargetApplication = targetApplication
                    pendingAutomationInstruction = instruction
                    pendingAutomationNextStep = step + 1
                    pendingAutomationShouldContinue = response.shouldContinue != false && step < maxSteps
                    pendingAutomationLastActionSummary = summary
                    hasPendingAutomationApproval = !plannedActions.isEmpty
                    automationStatus = plannedActions.isEmpty ? "Needs review" : "Needs approval"
                    status = "Automation paused"
                    let note = response.safetyNote ?? "Automation paused before a sensitive or social action. Review the suggested step before running it."
                    lastError = "\(approvalReason): \(note)"
                    isAutomationRunning = false
                    automationTask = nil
                    return
                }

                guard !plannedActions.isEmpty else {
                    traceAutomation("no actions at step \(step): shouldContinue=\(response.shouldContinue ?? false) summaryLength=\(summary.count)")
                    automationStatus = response.shouldContinue == true ? "No action returned" : "Complete"
                    status = response.shouldContinue == true ? "Automation stopped" : "Automation complete"
                    isAutomationRunning = false
                    automationTask = nil
                    return
                }

                let isWaitOnlyStep = plannedActions.allSatisfy { $0.type == .wait }
                if isWaitOnlyStep && response.shouldContinue != false {
                    consecutiveWaitOnlySteps += 1
                    if consecutiveWaitOnlySteps >= AppSettings.maxConsecutiveWaitOnlyAutomationSteps {
                        traceAutomation("stopped at step \(step): repeated wait-only actions summaryLength=\(summary.count)")
                        automationStatus = "No progress"
                        status = "Automation stopped"
                        lastError = "Automation stopped after repeated wait-only steps with no progress."
                        isAutomationRunning = false
                        automationTask = nil
                        return
                    }
                } else {
                    consecutiveWaitOnlySteps = 0
                }

                automationStatus = "Acting"
                setBackgroundAgentActivity(.acting)
                try await waitForBackgroundAgentYieldIfNeeded()
                try await executeAgentActions(
                    plannedActions,
                    settings: settings,
                    actionFrame: capture.frame,
                    targetApplication: targetApplication
                )
                lastActionSummary = summary

                if response.shouldContinue == false {
                    automationStatus = "Complete"
                    status = "Automation complete"
                    isAutomationRunning = false
                    automationTask = nil
                    return
                }

                automationStatus = "Waiting \(String(format: "%.1f", stepDelay))s"
                setBackgroundAgentActivity(.idle)
                try await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000))
            }

            automationStatus = "Step limit reached"
            status = "Automation limit reached"
            } catch is CancellationError {
                traceAutomation("cancelled at step \(automationStepCount)")
                automationStatus = "Stopped"
                status = "Automation stopped"
            } catch let error as URLError where error.code == .cancelled {
                traceAutomation("cancelled at step \(automationStepCount)")
                automationStatus = "Stopped"
                status = "Automation stopped"
            } catch {
                let message = userFacingAutomationError(error, settings: settings)
                traceAutomation("failed at step \(automationStepCount) errorType=\(String(reflecting: type(of: error)))")
                automationStatus = "Failed"
                status = "Automation failed"
                lastError = message
            }

        isAutomationRunning = false
        isAutomationPaused = false
        automationTask = nil
    }

    private func captureForAgent() -> ScreenCaptureContext? {
        if let selectedWindowTarget {
            if let capture = executor.captureWindow(selectedWindowTarget) {
                return capture
            }
            refreshWindowTargets()
            if let refreshed = self.selectedWindowTarget,
               let capture = executor.captureWindow(refreshed) {
                return capture
            }
            lastError = "RatRemote could not capture the selected window. Choose it again or grant Screen Recording permission."
            return nil
        }
        return executor.captureDisplay()
    }

    private func screenContextText(for capture: ScreenCaptureContext, settings: AppSettings, instruction: String? = nil) async -> String? {
        let trimmedInstruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawContext: String?
        if !trimmedInstruction.isEmpty {
            rawContext = try? await client.automationScreenContext(
                instruction: trimmedInstruction,
                screenshotBase64: capture.imageBase64,
                serverURL: settings.computerUseServerURL,
                apiKey: settings.computerUseAPIKey
            )
        } else {
            rawContext = try? await client.screenContext(
                screenshotBase64: capture.imageBase64,
                serverURL: settings.computerUseServerURL,
                apiKey: settings.computerUseAPIKey
            )
        }
        let targetLine = capture.isWindowScoped ? "Target window: \(capture.title)" : "Target: entire display"
        guard let rawContext, !rawContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return targetLine
        }
        return "\(targetLine)\n\(rawContext)"
    }

    private func handle(
        text: String,
        settings: AppSettings,
        workflow: RecordingWorkflow,
        targetApplication: NSRunningApplication?
    ) async throws {
        let managesBackgroundSession = workflow.resolvedMode != .dictation && useBackgroundAgentInput
        if managesBackgroundSession {
            beginBackgroundAgentSession(activity: .thinking)
        }
        defer {
            if managesBackgroundSession && !isAutomationRunning {
                endBackgroundAgentSession()
            }
        }

        switch workflow.resolvedMode {
        case .dictation:
            let activated = await activatePasteTarget(targetApplication)
            let diagnostics = await executor.insertText(text, targetApplication: targetApplication)
            insertionStatus = diagnostics.summary
            if !diagnostics.accessibilityTrusted {
                lastError = "Dictation was copied to the clipboard, but macOS blocked automatic paste. Allow RatRemote in Privacy & Security > Accessibility."
                executor.requestAccessibilityPermission()
                executor.openAccessibilitySettings()
                refreshAccessibilityStatus()
            }
            if !activated {
                lastError = "Transcript copied to clipboard, but RatRemote could not activate the paste target."
            }
        case .command:
            let isAgentMode = workflow == .agentCommand
            if isAgentMode, isStopAutomationTranscript(text) {
                stopAutomation()
                insertionStatus = "Automation stopped"
                lastError = ""
                return
            }
            if isAgentMode, isPauseAutomationTranscript(text) {
                pauseAutomation()
                insertionStatus = "Automation paused"
                lastError = ""
                return
            }
            if isAgentMode, isResumeAutomationTranscript(text) {
                resumeAutomation()
                insertionStatus = "Automation resumed"
                lastError = ""
                return
            }
            if isAgentMode, let automationInstruction = automationInstructionFromAgentTranscript(text) {
                let started = enterAutomationInstructionAndStartLoop(automationInstruction)
                insertionStatus = started ? "Automation started" : "Automation already running"
                return
            }

            let commandTargetApplication = selectedTargetApplication(fallback: targetApplication)
            await activateAgentTarget(commandTargetApplication)
            if isAgentMode, let dictatedText = agentDictatedText(from: text) {
                let backgroundInput = useBackgroundAgentInput
                let activated = backgroundInput ? true : await activatePasteTarget(commandTargetApplication)
                let diagnostics = await executor.insertText(
                    dictatedText,
                    targetApplication: commandTargetApplication,
                    targetWindow: selectedWindowTarget,
                    useBackgroundInput: backgroundInput
                )
                insertionStatus = diagnostics.summary
                traceAgent("agent dictation insert transcriptLength=\(text.count) insertedLength=\(dictatedText.count)")
                if !activated {
                    lastError = "Transcript copied to clipboard, but RatRemote could not activate the paste target."
                }
                return
            }
            let localActions = isAgentMode ? highConfidenceAgentLocalActions(for: text) : LocalCommandParser.actions(for: text)
            if !localActions.isEmpty {
                try await executeAgentActions(
                    localActions,
                    settings: settings,
                    targetApplication: commandTargetApplication
                )
                insertionStatus = "Local command"
                return
            }
            insertionStatus = isAgentMode ? "Agent server" : "Command server"
            let capture = optionalCaptureForCommand(
                enabled: isAgentMode || settings.includeScreenContextForCommands
            )
            let screenshot = capture?.imageBase64
            let screenContext: String?
            if isAgentMode, let capture {
                insertionStatus = "Reading screen"
                screenContext = await screenContextText(for: capture, settings: settings)
                insertionStatus = "Agent server"
            } else {
                screenContext = nil
            }
            let response = try await commandRouter.command(
                request: CommandRequest(
                    text: text,
                    screenshotBase64: screenshot,
                    agentMode: isAgentMode,
                    screenContext: screenContext
                ),
                settings: settings
            )
            traceAgent("transcriptLength=\(text.count)")
            if let screenContext {
                traceAgent("screenContextLength=\(screenContext.count)")
            }
            traceAgent("llmActions=\(actionsDescription(response.actions))")
            let actions = isAgentMode ? repairedAgentActions(response.actions, transcript: text) : response.actions
            if isAgentMode {
                traceAgent("repairedActions=\(actionsDescription(actions))")
            }
            try await executeAgentActions(
                actions,
                settings: settings,
                actionFrame: capture?.frame,
                targetApplication: commandTargetApplication
            )
        case .vision:
            let visionTargetApplication = selectedTargetApplication(fallback: targetApplication)
            await activateAgentTarget(visionTargetApplication)
            executor.dismissTransientUI(targetWindow: selectedWindowTarget, useBackgroundInput: useBackgroundAgentInput)
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let capture = captureForAgent() else { return }
            let target: VisionResponse
            do {
                target = try await client.locate(
                    prompt: text,
                    screenshotBase64: capture.imageBase64,
                    serverURL: settings.computerUseServerURL,
                    apiKey: settings.computerUseAPIKey
                )
            } catch {
                if isSearchFieldPrompt(text), executor.focusSearchFieldInFrontmostBrowser() {
                    insertionStatus = "Focused search field"
                    return
                }
                throw error
            }
            try await withAgentInputTarget(targetApplication: visionTargetApplication) {
                executor.clickNormalized(
                    x: target.x,
                    y: target.y,
                    in: capture.frame,
                    targetWindow: selectedWindowTarget,
                    useBackgroundInput: useBackgroundAgentInput
                )
            }
        }
    }

    private func executeAgentActions(
        _ actions: [RemoteAction],
        settings: AppSettings,
        actionFrame: CGRect? = nil,
        targetApplication: NSRunningApplication?
    ) async throws {
        let startedBackgroundSession = useBackgroundAgentInput && !backgroundAgentSessionActive
        if startedBackgroundSession {
            beginBackgroundAgentSession(activity: .acting)
        }
        defer {
            if startedBackgroundSession {
                endBackgroundAgentSession()
            }
        }
        try await withAgentInputTarget(targetApplication: targetApplication) {
            try await execute(actions, settings: settings, actionFrame: actionFrame)
        }
    }

    private func execute(_ actions: [RemoteAction], settings: AppSettings, actionFrame: CGRect? = nil) async throws {
        for action in actions {
            try await waitForBackgroundAgentYieldIfNeeded()
            switch action.type {
            case .wait:
                let seconds = max(0, min(10, action.amount ?? 1))
                insertionStatus = "Waiting \(String(format: "%.1f", seconds))s"
                setBackgroundAgentActivity(.idle)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            case .locateAndClick:
                guard let prompt = visualPrompt(for: action),
                      !prompt.isEmpty else {
                    traceAgent("locate_and_click skipped: no target text in action=\(actionsDescription([action]))")
                    continue
                }
                setBackgroundAgentActivity(.thinking)
                executor.dismissTransientUI(targetWindow: selectedWindowTarget, useBackgroundInput: useBackgroundAgentInput)
                try await Task.sleep(nanoseconds: 200_000_000)
                guard let capture = captureForAgent() else {
                    continue
                }
                insertionStatus = "Locating: \(prompt)"
                traceAgent("locate promptLength=\(prompt.count)")
                let target: VisionResponse
                do {
                    target = try await client.locate(
                        prompt: prompt,
                        screenshotBase64: capture.imageBase64,
                        serverURL: settings.computerUseServerURL,
                        apiKey: settings.computerUseAPIKey
                    )
                } catch {
                    throw error
                }
                traceAgent("locate result x=\(String(format: "%.4f", target.x)) y=\(String(format: "%.4f", target.y))")
                if settings.clickVisionResult {
                    setBackgroundAgentActivity(.acting)
                    try await waitForBackgroundAgentYieldIfNeeded()
                    executor.clickNormalized(
                        x: target.x,
                        y: target.y,
                        in: capture.frame,
                        targetWindow: selectedWindowTarget,
                        useBackgroundInput: useBackgroundAgentInput
                    )
                    insertionStatus = "Clicked: \(target.label ?? prompt)"
                } else {
                    insertionStatus = "Located: \(target.label ?? prompt)"
                }
            default:
                setBackgroundAgentActivity(.acting)
                executor.execute(
                    action,
                    actionFrame: actionFrame,
                    targetWindow: selectedWindowTarget,
                    useBackgroundInput: useBackgroundAgentInput
                )
            }
        }
    }

    private func repairedAutomationActions(
        _ actions: [RemoteAction],
        instruction: String,
        summary: String
    ) -> [RemoteAction] {
        let toolRepaired = actions.map { repairActionToolChoice($0) }
        let fallbackPrompt = automationFallbackVisualPrompt(
            instruction: instruction,
            summary: summary,
            actions: toolRepaired
        )
        var repaired: [RemoteAction] = []
        var didRepair = false

        for action in toolRepaired {
            switch action.type {
            case .locateAndClick:
                if let prompt = visualPrompt(for: action), !prompt.isEmpty {
                    if shouldReplaceAutomationLocatePrompt(prompt), let fallbackPrompt {
                        repaired.append(locateAndClickAction(prompt: fallbackPrompt))
                        didRepair = true
                    } else {
                        repaired.append(action)
                    }
                } else if let fallbackPrompt {
                    repaired.append(locateAndClickAction(prompt: fallbackPrompt))
                    didRepair = true
                } else {
                    traceAutomation("dropping locate_and_click without prompt action=\(actionsDescription([action]))")
                    didRepair = true
                }
            case .click:
                if isZeroCoordinateClick(action) || (action.x == nil && action.y == nil) {
                    if let prompt = visualPrompt(for: action) ?? fallbackPrompt {
                        repaired.append(locateAndClickAction(prompt: prompt))
                        didRepair = true
                    } else {
                        traceAutomation("dropping raw click without target action=\(actionsDescription([action]))")
                        didRepair = true
                    }
                } else {
                    repaired.append(action)
                }
            default:
                repaired.append(action)
            }
        }

        if didRepair {
            traceAutomation("repaired automation actions from=\(actionsDescription(actions)) to=\(actionsDescription(repaired))")
        }
        return repaired
    }

    private func shouldReplaceAutomationLocatePrompt(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        if normalized.contains("green heart") ||
            normalized.contains("pink x") ||
            normalized.contains("red x") ||
            normalized.contains("button") ||
            normalized.contains("icon") {
            return false
        }
        return normalized.contains("tinder interface") ||
            normalized.contains("tinder app window") ||
            normalized.contains("mirroring window") ||
            normalized.contains("profile card") ||
            normalized.contains("current profile")
    }

    private func locateAndClickAction(prompt: String) -> RemoteAction {
        RemoteAction(type: .locateAndClick, text: prompt, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)
    }

    private func isZeroCoordinateClick(_ action: RemoteAction) -> Bool {
        action.type == .click && (action.x ?? 0) == 0 && (action.y ?? 0) == 0
    }

    private func automationFallbackVisualPrompt(
        instruction: String,
        summary: String,
        actions: [RemoteAction]
    ) -> String? {
        let actionText = actions
            .flatMap { [$0.text, $0.key, $0.url] }
            .compactMap { $0 }
            .joined(separator: " ")
        for source in [actionText, summary, instruction] {
            if let prompt = automationFallbackVisualPrompt(from: source) {
                return prompt
            }
        }
        return nil
    }

    private func automationFallbackVisualPrompt(from text: String) -> String? {
        let normalized = text.lowercased()
        if normalized.contains("green heart") ||
            (normalized.contains("heart") && normalized.contains("tinder")) ||
            (normalized.contains("like") && normalized.contains("tinder")) {
            return "green heart like button on the Tinder profile card"
        }
        if normalized.contains("pink x") ||
            normalized.contains("red x") ||
            normalized.contains("x icon") ||
            normalized.contains("nope") ||
            normalized.contains("dislike") {
            return "pink X reject button on the Tinder profile card"
        }
        return nil
    }

    private func normalizedAutomationSummary(response: AutomationStepResponse) -> String {
        let summary = response.spokenSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let criteria = response.criteriaSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty, !criteria.isEmpty {
            return "\(summary) Criteria: \(criteria)"
        }
        if !summary.isEmpty {
            return summary
        }
        if !criteria.isEmpty {
            return "Criteria: \(criteria)"
        }
        if response.actions.isEmpty {
            return response.shouldContinue == false ? "Done" : "No action"
        }
        return actionsDescription(response.actions)
    }

    private func automationApprovalReason(instruction: String, screenContext: String?, response: AutomationStepResponse) -> String? {
        return nil
    }

    private func automationHardBlockReason(
        instruction: String,
        screenContext: String?,
        response: AutomationStepResponse,
        actions: [RemoteAction]
    ) -> String? {
        return nil
    }

    private func automationNeedsApproval(instruction: String, screenContext: String?, response: AutomationStepResponse) -> Bool {
        return false
    }

    private func actionSearchText(_ action: RemoteAction) -> String {
        let parts: [String?] = [
            action.type.rawValue,
            action.text,
            action.key,
            action.url,
            action.modifiers?.joined(separator: " "),
            action.x.map { String($0) },
            action.y.map { String($0) },
            action.amount.map { String($0) }
        ]
        return parts.compactMap { $0 }.joined(separator: " ")
    }

    private func visualPrompt(for action: RemoteAction) -> String? {
        let candidate = action.text ?? action.url ?? action.key
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return nil }
        return visualPromptText(from: trimmed.lowercased())
    }

    private func isSearchFieldPrompt(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return (lower.contains("search") || lower.contains("query")) &&
            (lower.contains("bar") || lower.contains("field") || lower.contains("box") || lower.contains("input"))
    }

    private func highConfidenceAgentLocalActions(for text: String) -> [RemoteAction] {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\.,!?]+$"#, with: "", options: .regularExpression)
        if let actions = quickToolActions(for: normalized) {
            return actions
        }
        let deterministicActions = LocalCommandParser.actions(for: normalized)
        if !deterministicActions.isEmpty,
           deterministicActions.allSatisfy({ $0.type == .keyPress || $0.type == .click }) {
            return deterministicActions
        }
        if isOpenCommand(normalized) {
            if !deterministicActions.isEmpty {
                return deterministicActions
            }
        }
        if let url = knownWebDestinationURL(for: normalized) {
            return [RemoteAction(type: .openURL, text: nil, key: nil, modifiers: nil, url: url, x: nil, y: nil, amount: nil)]
        }
        return []
    }

    private func isOpenCommand(_ normalized: String) -> Bool {
        [
            "open ",
            "launch ",
            "start ",
            "go to ",
            "show me ",
            "bring up "
        ].contains { normalized.hasPrefix($0) }
    }

    private func agentDictatedText(from transcript: String) -> String? {
        let pattern = #"^\s*(write|type)(?:\s+(?:out|this|that))?\s*[:,-]?\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(transcript.startIndex..., in: transcript)
        guard let match = regex.firstMatch(in: transcript, range: range),
              let textRange = Range(match.range(at: 2), in: transcript) else {
            return nil
        }
        let dictatedText = String(transcript[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return dictatedText.isEmpty ? nil : dictatedText
    }

    private func automationInstructionFromAgentTranscript(_ transcript: String) -> String? {
        let patterns = [
            #"^\s*(?:start|begin|run|launch|create)(?:\s+an?)?\s+automation\s*(?:[:;,.\-]|\band\b)?\s+(.+?)\s*$"#,
            #"^\s*(?:start|begin)\s+agent\s+automation\s*(?:[:;,.\-]|\band\b)?\s+(.+?)\s*$"#,
            #"^\s*automate\s*(?:[:;,.\-])?\s+(.+?)\s*$"#
        ]
        let range = NSRange(transcript.startIndex..., in: transcript)

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: transcript, range: range),
                  let instructionRange = Range(match.range(at: 1), in: transcript) else {
                continue
            }
            let instruction = String(transcript[instructionRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return instruction.isEmpty ? nil : instruction
        }

        return nil
    }

    private func isStopAutomationTranscript(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\.,!?]+$"#, with: "", options: .regularExpression)
        return [
            "stop automation",
            "stop the automation",
            "cancel automation",
            "cancel the automation",
            "end automation",
            "end the automation"
        ].contains(normalized)
    }

    private func isPauseAutomationTranscript(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\.,!?]+$"#, with: "", options: .regularExpression)
        return [
            "pause automation",
            "pause the automation"
        ].contains(normalized)
    }

    private func isResumeAutomationTranscript(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\.,!?]+$"#, with: "", options: .regularExpression)
        return [
            "resume automation",
            "resume the automation",
            "continue automation",
            "continue the automation"
        ].contains(normalized)
    }

    private func optionalCaptureForCommand(enabled: Bool) -> ScreenCaptureContext? {
        guard enabled else { return nil }
        let previousError = lastError
        guard let capture = captureForAgent() else {
            lastError = previousError
            traceAgent("screen capture unavailable for command; continuing without screenshot")
            return nil
        }
        return capture
    }

    private func quickToolActions(for normalized: String) -> [RemoteAction]? {
        if let tabNumber = requestedTabNumber(from: normalized) {
            return [keyAction("\(tabNumber)", modifiers: ["command"])]
        }

        switch normalized {
        case "fullscreen", "full screen", "go fullscreen", "make fullscreen":
            return [keyAction("f")]
        case "escape", "press escape", "esc":
            return [keyAction("escape")]
        case "play", "pause", "play pause", "toggle play", "toggle pause", "start video", "pause video", "resume video":
            return [keyAction("space")]
        case "mute", "unmute", "toggle mute":
            return [keyAction("m")]
        case "copy":
            return [keyAction("c", modifiers: ["command"])]
        case "paste":
            return [keyAction("v", modifiers: ["command"])]
        case "cut":
            return [keyAction("x", modifiers: ["command"])]
        case "undo":
            return [keyAction("z", modifiers: ["command"])]
        case "redo":
            return [keyAction("z", modifiers: ["command", "shift"])]
        case "select all":
            return [keyAction("a", modifiers: ["command"])]
        case "save", "save file", "save document":
            return [keyAction("s", modifiers: ["command"])]
        case "find", "find in page", "search page":
            return [keyAction("f", modifiers: ["command"])]
        case "print":
            return [keyAction("p", modifiers: ["command"])]
        case "new tab", "open new tab":
            return [keyAction("t", modifiers: ["command"])]
        case "new window", "open new window":
            return [keyAction("n", modifiers: ["command"])]
        case "new private window", "private window", "open private window", "incognito window":
            return [keyAction("n", modifiers: ["command", "shift"])]
        case "reopen tab", "reopen closed tab", "restore tab", "restore closed tab":
            return [keyAction("t", modifiers: ["command", "shift"])]
        case "close tab", "close the tab", "close current tab":
            return [keyAction("w", modifiers: ["command"])]
        case "close window", "close this window":
            return [RemoteAction(type: .closeWindow, text: nil, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)]
        case "quit app", "quit application", "quit this app":
            return [RemoteAction(type: .quitApplication, text: nil, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)]
        case "next tab", "switch to next tab":
            return [keyAction("tab", modifiers: ["control"])]
        case "previous tab", "prev tab", "switch to previous tab":
            return [keyAction("tab", modifiers: ["control", "shift"])]
        case "first tab":
            return [keyAction("1", modifiers: ["command"])]
        case "last tab":
            return [keyAction("9", modifiers: ["command"])]
        case "refresh", "reload", "refresh page", "reload page", "refresh browser", "reload browser", "click refresh", "click reload", "click the refresh button", "click the reload button":
            return [keyAction("r", modifiers: ["command"])]
        case "hard refresh", "force refresh", "reload without cache":
            return [keyAction("r", modifiers: ["command", "shift"])]
        case "go back", "back", "browser back", "click back", "click the back button":
            return [keyAction("left", modifiers: ["command"])]
        case "go forward", "forward", "browser forward", "click forward", "click the forward button":
            return [keyAction("right", modifiers: ["command"])]
        case "address bar", "focus address bar", "url bar", "focus url bar", "location bar":
            return [keyAction("l", modifiers: ["command"])]
        case "downloads", "show downloads", "open downloads":
            return [keyAction("l", modifiers: ["command", "option"])]
        case "open file":
            return [keyAction("o", modifiers: ["command"])]
        case "minimize", "minimise", "minimize window", "minimise window":
            return [keyAction("m", modifiers: ["command"])]
        case "hide app", "hide this app":
            return [keyAction("h", modifiers: ["command"])]
        case "hide other apps", "hide others":
            return [keyAction("h", modifiers: ["command", "option"])]
        case "app switcher", "switch apps":
            return [keyAction("tab", modifiers: ["command"])]
        case "screenshot", "take screenshot":
            return [keyAction("5", modifiers: ["command", "shift"])]
        case "spotlight", "open spotlight":
            return [keyAction("space", modifiers: ["command"])]
        case "force quit", "force quit apps":
            return [keyAction("escape", modifiers: ["command", "option"])]
        case "page up":
            return [keyAction("page_up")]
        case "page down":
            return [keyAction("page_down")]
        case "top of page", "go to top", "scroll to top":
            return [keyAction("home", modifiers: ["command"])]
        case "bottom of page", "go to bottom", "scroll to bottom":
            return [keyAction("end", modifiers: ["command"])]
        case "volume up":
            return [keyAction("up", modifiers: ["command"])]
        case "volume down":
            return [keyAction("down", modifiers: ["command"])]
        case "skip forward", "forward ten seconds":
            return [keyAction("right")]
        case "skip back", "back ten seconds", "rewind":
            return [keyAction("left")]
        case "captions", "toggle captions", "subtitles":
            return [keyAction("c")]
        default:
            if normalized.hasPrefix("close tab ") || normalized.contains(" close tab") {
                return [keyAction("w", modifiers: ["command"])]
            }
            if normalized.contains("refresh") || normalized.contains("reload") {
                return [keyAction("r", modifiers: ["command"])]
            }
            return nil
        }
    }

    private func requestedTabNumber(from normalized: String) -> Int? {
        let patterns = [
            #"^(go to|switch to|open|select|show)\s+(the\s+)?([a-z0-9]+)(st|nd|rd|th)?\s+tab$"#,
            #"^(go to|switch to|open|select|show)\s+tab\s+([a-z0-9]+)(st|nd|rd|th)?$"#,
            #"^tab\s+([a-z0-9]+)(st|nd|rd|th)?$"#,
            #"^([a-z0-9]+)(st|nd|rd|th)?\s+tab$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..., in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: range) else { continue }
            for index in stride(from: match.numberOfRanges - 1, through: 1, by: -1) {
                guard let valueRange = Range(match.range(at: index), in: normalized) else { continue }
                let token = String(normalized[valueRange])
                if let number = tabNumber(from: token) {
                    return number
                }
            }
        }
        return nil
    }

    private func tabNumber(from token: String) -> Int? {
        let cleaned = token
            .lowercased()
            .replacingOccurrences(of: #"(\d+)(st|nd|rd|th)$"#, with: "$1", options: .regularExpression)
        if let number = Int(cleaned), (1...9).contains(number) {
            return number
        }
        let words = [
            "first": 1,
            "one": 1,
            "second": 2,
            "two": 2,
            "third": 3,
            "three": 3,
            "fourth": 4,
            "four": 4,
            "fifth": 5,
            "five": 5,
            "sixth": 6,
            "six": 6,
            "seventh": 7,
            "seven": 7,
            "eighth": 8,
            "eight": 8,
            "ninth": 9,
            "nine": 9,
            "last": 9
        ]
        return words[cleaned]
    }

    private func keyAction(_ key: String, modifiers: [String] = []) -> RemoteAction {
        RemoteAction(type: .keyPress, text: nil, key: key, modifiers: modifiers.isEmpty ? nil : modifiers, url: nil, x: nil, y: nil, amount: nil)
    }

    private func knownWebDestinationURL(for normalized: String) -> String? {
        let mentionsYouTube = normalized.contains("youtube") || normalized.contains("you tube")
        let subscriptionRequest = normalized.contains("subscription") || normalized.contains("subscriptions") || normalized.contains("subs")
        if subscriptionRequest, mentionsYouTube || normalized.contains("subscription page") || normalized.contains("subscriptions page") {
            return "https://www.youtube.com/feed/subscriptions"
        }

        if mentionsYouTube, normalized.contains("history") {
            return "https://www.youtube.com/feed/history"
        }
        if mentionsYouTube, normalized.contains("library") {
            return "https://www.youtube.com/feed/you"
        }
        if mentionsYouTube, normalized.contains("trending") {
            return "https://www.youtube.com/feed/trending"
        }
        return nil
    }

    private func repairedAgentActions(_ actions: [RemoteAction], transcript: String) -> [RemoteAction] {
        let toolRepaired = actions.map { repairActionToolChoice($0) }
        if let guarded = guardUnsafeRawClick(toolRepaired, transcript: transcript) {
            return guarded
        }
        if let closeAction = closeOrQuitAction(for: transcript) {
            if toolRepaired.contains(where: { $0.type == .closeWindow || $0.type == .quitApplication || $0.type == .locateAndClick || $0.type == .click }) {
                insertionStatus = "Agent close: \(closeAction.text ?? "frontmost")"
                return [closeAction]
            }
            if toolRepaired.isEmpty {
                insertionStatus = "Agent close: \(closeAction.text ?? "frontmost")"
                return [closeAction]
            }
            return toolRepaired
        }

        guard let visualAction = visualElementAction(for: transcript),
              !toolRepaired.contains(where: { $0.type == .locateAndClick }) else {
            return toolRepaired
        }

        if toolRepaired.isEmpty || toolRepaired.contains(where: { $0.type == .click }) {
            insertionStatus = "Agent visual: \(visualAction.text ?? "target")"
            return actionsReplacingRawClicks(in: toolRepaired, with: visualAction)
        }

        if toolRepaired.contains(where: { $0.type == .openURL || $0.type == .openApplication }) {
            var repaired = toolRepaired
            if !repaired.contains(where: { $0.type == .wait }) {
                repaired.append(RemoteAction(type: .wait, text: nil, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: 2))
            }
            repaired.append(visualAction)
            insertionStatus = "Agent visual: \(visualAction.text ?? "target")"
            return repaired
        }
        return toolRepaired
    }

    private func guardUnsafeRawClick(_ actions: [RemoteAction], transcript: String) -> [RemoteAction]? {
        let isUnsafeClick: (RemoteAction) -> Bool = {
            $0.type == .click && ($0.x ?? 0) == 0 && ($0.y ?? 0) == 0
        }
        guard actions.contains(where: isUnsafeClick) else {
            return nil
        }
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\.,!?]+$"#, with: "", options: .regularExpression)
        if ["click", "left click", "mouse click", "click here"].contains(normalized) {
            return actions
        }
        if let visualAction = visualElementAction(for: transcript) {
            insertionStatus = "Agent visual: \(visualAction.text ?? "target")"
            traceAgent("raw click guarded visualTargetLength=\(visualAction.text?.count ?? 0)")
            return actionsReplacingRawClicks(in: actions, with: visualAction)
        }
        if let clickAction = actions.first(where: isUnsafeClick),
           let prompt = visualPrompt(for: clickAction) {
            let visualAction = RemoteAction(type: .locateAndClick, text: prompt, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)
            insertionStatus = "Agent visual: \(prompt)"
            traceAgent("raw click guarded fallbackTargetLength=\(prompt.count)")
            return actionsReplacingRawClicks(in: actions, with: visualAction)
        }
        traceAgent("raw click guarded -> dropped transcriptLength=\(transcript.count)")
        return actions.filter { !isUnsafeClick($0) }
    }

    private func repairActionToolChoice(_ action: RemoteAction) -> RemoteAction {
        let text = [action.text, action.url, action.key]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if let quickActions = quickToolActions(for: text),
           quickActions.count == 1,
           action.type == .locateAndClick || action.type == .click || action.type == .keyPress {
            return quickActions[0]
        }
        if action.type == .locateAndClick || action.type == .click {
            if text.contains("refresh") || text.contains("reload") {
                return keyAction("r", modifiers: ["command"])
            }
            if text.contains("back") {
                return keyAction("left", modifiers: ["command"])
            }
            if text.contains("forward") {
                return keyAction("right", modifiers: ["command"])
            }
        }
        return action
    }

    private func actionsReplacingRawClicks(in actions: [RemoteAction], with visualAction: RemoteAction) -> [RemoteAction] {
        guard !actions.isEmpty else { return [visualAction] }
        var didInsert = false
        var repaired: [RemoteAction] = []
        for action in actions {
            if action.type == .click {
                if !didInsert {
                    repaired.append(visualAction)
                    didInsert = true
                }
            } else {
                repaired.append(action)
            }
        }
        if !didInsert {
            repaired.append(visualAction)
        }
        return repaired
    }

    private func visualElementAction(for transcript: String) -> RemoteAction? {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\.,!?]+$"#, with: "", options: .regularExpression)
        let prefixes = [
            "click on ",
            "click ",
            "tap on ",
            "tap ",
            "select ",
            "focus on ",
            "focus ",
            "put the cursor in ",
            "put cursor in "
        ]
        guard let target = targetAfterPrefix(prefixes, in: normalized), !target.isEmpty else {
            return nil
        }
        let prompt = visualPromptText(from: target)
        guard !prompt.isEmpty else { return nil }
        return RemoteAction(type: .locateAndClick, text: prompt, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)
    }

    private func visualPromptText(from target: String) -> String {
        let cleaned = target
            .replacingOccurrences(of: #"^(the|this|current)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.contains("search") {
            return "page search input field"
        }
        if cleaned.contains("refresh") || cleaned.contains("reload") {
            return "browser reload button"
        }
        if cleaned == "back" || cleaned.contains("back button") {
            return "browser back button"
        }
        if cleaned == "forward" || cleaned.contains("forward button") {
            return "browser forward button"
        }
        return cleaned
    }

    private func closeOrQuitAction(for transcript: String) -> RemoteAction? {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\.,!?]+$"#, with: "", options: .regularExpression)

        if let target = targetAfterPrefix(["quit ", "exit "], in: normalized) {
            return RemoteAction(type: .quitApplication, text: target.isEmpty ? nil : target, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)
        }
        if ["quit", "exit"].contains(normalized) {
            return RemoteAction(type: .quitApplication, text: nil, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)
        }
        if let target = targetAfterPrefix(["close ", "shut ", "dismiss "], in: normalized) {
            return RemoteAction(type: .closeWindow, text: target.isEmpty ? nil : target, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)
        }
        if ["close", "close window", "close app", "close this app", "close this window"].contains(normalized) {
            return RemoteAction(type: .closeWindow, text: nil, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)
        }
        return nil
    }

    private func targetAfterPrefix(_ prefixes: [String], in text: String) -> String? {
        for prefix in prefixes where text.hasPrefix(prefix) {
            let rawTarget = String(text.dropFirst(prefix.count))
            return normalizedCloseTarget(rawTarget)
        }
        return nil
    }

    private func actionsDescription(_ actions: [RemoteAction]) -> String {
        // Action payloads may contain dictated text, URLs, or page content.
        // Operational logs only need the action kinds.
        actions.map(\.type.rawValue).joined(separator: ",")
    }

    private func traceAgent(_ message: String) {
        appendTrace(message, filename: "agent-actions.log")
    }

    private func traceAutomation(_ message: String) {
        appendTrace(message, filename: "automation-actions.log")
    }

    private func traceMedia(_ message: String) {
        appendTrace(message, filename: "media-actions.log")
    }

    private func appendTrace(_ message: String, filename: String) {
        TraceLog.append(message, filename: filename)
    }

    private func normalizedCloseTarget(_ target: String) -> String {
        let fillerTargets = Set(["app", "application", "window", "this app", "this application", "this window", "current app", "current application", "current window", "the app", "the application", "the window"])
        let cleaned = target
            .replacingOccurrences(of: #"^(the|this|current)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(app|application|window)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fillerTargets.contains(cleaned) ? "" : cleaned
    }

    private func userFacingRecordingError(
        _ error: Error,
        stage: RecordingFailureStage,
        workflow: RecordingWorkflow,
        settings: AppSettings
    ) -> String {
        if isNetworkError(error) {
            switch stage {
            case .transcription where settings.speechEngine == .remoteServer:
                return userFacingServerError(error, label: "Transcription", url: settings.transcriptionServerURL)
            case .handling where workflow.resolvedMode == .command:
                return userFacingServerError(error, label: "Command inference", url: settings.inferenceServerURL)
            case .handling where workflow.resolvedMode == .vision:
                return userFacingServerError(error, label: "Computer-use", url: settings.computerUseServerURL)
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func userFacingAutomationError(_ error: Error, settings: AppSettings) -> String {
        if isNetworkError(error) {
            return userFacingServerError(error, label: "Automation inference", url: settings.inferenceServerURL)
        }
        if let inferenceError = error as? InferenceError {
            return "Automation inference failed. \(inferenceError.localizedDescription)"
        }
        return error.localizedDescription
    }

    private func userFacingServerError(_ error: Error, label: String, url: String) -> String {
        if let inferenceError = error as? InferenceError {
            return "\(label) server at \(url) responded, but RatRemote could not use it. \(inferenceError.localizedDescription)"
        }
        if isNetworkError(error) {
            let nsError = error as NSError
            return "\(label) server is unreachable at \(url). \(error.localizedDescription) (NSURLError \(nsError.code)). Check Local Network permission for RatRemote and confirm the server is on the same LAN."
        }
        return "\(label) server is unavailable at \(url). \(error.localizedDescription)"
    }

    private func isNetworkError(_ error: Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain
    }

    private func transcribe(audioURL: URL, settings: AppSettings, forceLocal: Bool = false) async throws -> String {
        if forceLocal {
            return try await localSpeech.transcribe(
                audioURL: audioURL,
                localeIdentifier: settings.speechLocaleIdentifier
            )
        }

        switch settings.speechEngine {
        case .appleOnDevice:
            return try await localSpeech.transcribe(
                audioURL: audioURL,
                localeIdentifier: settings.speechLocaleIdentifier
            )
        case .remoteServer:
            return try await client.transcribe(
                audioURL: audioURL,
                serverURL: settings.transcriptionServerURL,
                apiKey: settings.transcriptionAPIKey,
                language: settings.speechLocaleIdentifier
            )
        }
    }

    private func pauseMediaPlayback() {
        mediaWasPlaying = false
        mediaResumeScript = nil
        mediaResumeUsesPlayPauseKey = false
        mediaResumeUsesSystemMediaPlay = false

        if pauseBrowserMediaInRunningBrowsers() {
            traceMedia("pause handled by browser media scan")
            return
        }

        if pauseMusicIfPlaying() {
            traceMedia("pause handled by Music")
            return
        }

        if pauseSpotifyIfPlaying() {
            traceMedia("pause handled by Spotify")
            return
        }

        let mediaRemoteActive = MediaRemoteCommandSender.isPlaybackActive()
        let safariMediaActive = safariHasActiveHTMLMediaPlaybackAssertion()
        guard mediaRemoteActive || safariMediaActive else {
            traceMedia("pause skipped; no active system media detected mediaRemoteActive=false safariHTMLMediaActive=false")
            return
        }

        postSystemMediaPause()
        mediaWasPlaying = true
        mediaResumeUsesPlayPauseKey = true
        traceMedia("pause handled by system media pause fallback resumePlayPause=\(mediaWasPlaying) mediaRemoteActive=\(mediaRemoteActive) safariMediaActive=\(safariMediaActive)")
    }

    private func safariHasActiveHTMLMediaPlaybackAssertion() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            traceMedia("Safari HTML media assertion check failed: \(error.localizedDescription)")
            return false
        }

        guard process.terminationStatus == 0 else {
            traceMedia("Safari HTML media assertion check exited \(process.terminationStatus)")
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }

        for line in output.components(separatedBy: .newlines)
            where line.contains("pid ") &&
                line.contains("(Safari)") &&
                line.contains("com.apple.WebCore: HTMLMediaElement playback") {
            traceMedia("Safari HTMLMediaElement playback assertion matched")
            return true
        }
        return false
    }

    private func pauseBrowserMediaInRunningBrowsers() -> Bool {
        for application in NSWorkspace.shared.runningApplications where isSupportedBrowser(application) {
            if pauseBrowserMedia(in: application) {
                return true
            }
        }
        return false
    }

    private func isSupportedBrowser(_ application: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        return [
            "com.apple.Safari",
            "com.apple.Safari.WebApp",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac"
        ].contains(bundleIdentifier)
    }

    private func resumeMediaPlayback() {
        guard mediaWasPlaying else {
            traceMedia("resume skipped; mediaWasPlaying=false")
            return
        }
        if mediaResumeUsesPlayPauseKey {
            traceMedia("resume via synthetic play/pause key")
            postPlayPauseMediaKey()
        } else if mediaResumeUsesSystemMediaPlay {
            traceMedia("resume via system media play")
            postSystemMediaPlay()
        } else if let mediaResumeScript {
            traceMedia("resume via media script")
            _ = runMediaScript(mediaResumeScript)
        }
        mediaWasPlaying = false
        self.mediaResumeScript = nil
        mediaResumeUsesPlayPauseKey = false
        mediaResumeUsesSystemMediaPlay = false
    }

    private func pauseBrowserMedia(in application: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        switch bundleIdentifier {
        case "com.apple.Safari":
            let pauseScript = """
            tell application "Safari"
                set pausedCount to 0
                repeat with browserDocument in documents
                    try
                        set pausedCount to pausedCount + ((do JavaScript "\(Self.pausePageMediaJavaScript)" in browserDocument) as integer)
                    end try
                end repeat
                return pausedCount
            end tell
            """
            if mediaScriptReturnedPositiveNumber(pauseScript) {
                mediaWasPlaying = true
                mediaResumeScript = """
                tell application "Safari"
                    repeat with browserDocument in documents
                        try
                            do JavaScript "\(Self.resumePageMediaJavaScript)" in browserDocument
                        end try
                    end repeat
                end tell
                """
                traceMedia("Safari JavaScript pause succeeded")
                return true
            }
            traceMedia("Safari JavaScript pause failed")
            return false
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac":
            let appName = application.localizedName ?? "Google Chrome"
            let pauseScript = """
            tell application "\(appName)"
                set pausedCount to 0
                repeat with browserWindow in windows
                    repeat with browserTab in tabs of browserWindow
                        try
                            set pausedCount to pausedCount + ((execute browserTab javascript "\(Self.pausePageMediaJavaScript)") as integer)
                        end try
                    end repeat
                end repeat
                return pausedCount
            end tell
            """
            if mediaScriptReturnedPositiveNumber(pauseScript) {
                mediaWasPlaying = true
                mediaResumeScript = """
                tell application "\(appName)"
                    repeat with browserWindow in windows
                        repeat with browserTab in tabs of browserWindow
                            try
                                execute browserTab javascript "\(Self.resumePageMediaJavaScript)"
                            end try
                        end repeat
                    end repeat
                end tell
                """
                traceMedia("\(appName) JavaScript pause succeeded")
                return true
            }
            traceMedia("\(appName) JavaScript pause returned 0")
        default:
            break
        }
        return false
    }

    private func postPlayPauseMediaKey() {
        if MediaRemoteCommandSender.send(command: .togglePlayPause) {
            traceMedia("MediaRemote togglePlayPause sent")
            return
        }
        traceMedia("MediaRemote togglePlayPause unavailable; posting synthetic NX play/pause")
        postMediaSystemEvent(keyCode: 16, isDown: true)
        usleep(30_000)
        postMediaSystemEvent(keyCode: 16, isDown: false)
    }

    private func postNextTrackMediaKey() {
        if MediaRemoteCommandSender.send(command: .nextTrack) {
            traceMedia("MediaRemote nextTrack sent")
            return
        }
        traceMedia("MediaRemote nextTrack unavailable; posting synthetic NX next")
        postMediaSystemEvent(keyCode: 17, isDown: true)
        usleep(30_000)
        postMediaSystemEvent(keyCode: 17, isDown: false)
    }

    private func postPreviousTrackMediaKey() {
        if MediaRemoteCommandSender.send(command: .previousTrack) {
            traceMedia("MediaRemote previousTrack sent")
            return
        }
        traceMedia("MediaRemote previousTrack unavailable; posting synthetic NX previous")
        postMediaSystemEvent(keyCode: 18, isDown: true)
        usleep(30_000)
        postMediaSystemEvent(keyCode: 18, isDown: false)
    }

    private func postSystemMediaPlay() {
        if MediaRemoteCommandSender.send(command: .play) {
            traceMedia("MediaRemote play sent")
            return
        }
        traceMedia("MediaRemote play unavailable; posting synthetic NX play/pause")
        postMediaSystemEvent(keyCode: 16, isDown: true)
        usleep(30_000)
        postMediaSystemEvent(keyCode: 16, isDown: false)
    }

    private func postSystemMediaPause() {
        if MediaRemoteCommandSender.send(command: .pause) {
            traceMedia("MediaRemote pause sent")
            return
        }
        traceMedia("MediaRemote pause unavailable; posting synthetic NX play/pause")
        postMediaSystemEvent(keyCode: 16, isDown: true)
        usleep(30_000)
        postMediaSystemEvent(keyCode: 16, isDown: false)
    }

    private func postMediaSystemEvent(keyCode: Int, isDown: Bool) {
        let keyState = isDown ? 0x0A00 : 0x0B00
        let data1 = (keyCode << 16) | keyState
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        if let event {
            event.cgEvent?.setIntegerValueField(.eventSourceUserData, value: AgentInputSyntheticMarker.value)
            NSApp.postEvent(event, atStart: false)
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func pauseMusicIfPlaying() -> Bool {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) else {
            return false
        }
        let stateScript = #"tell application "Music" to get player state as text"#
        guard runMediaScript(stateScript).lowercased().contains("playing") else {
            return false
        }
        _ = runMediaScript(#"tell application "Music" to pause"#)
        mediaWasPlaying = true
        mediaResumeScript = #"tell application "Music" to play"#
        return true
    }

    private func pauseSpotifyIfPlaying() -> Bool {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
            return false
        }
        let stateScript = #"tell application "Spotify" to get player state as text"#
        guard runMediaScript(stateScript).lowercased().contains("playing") else {
            return false
        }
        _ = runMediaScript(#"tell application "Spotify" to pause"#)
        mediaWasPlaying = true
        mediaResumeScript = #"tell application "Spotify" to play"#
        return true
    }

    private func mediaScriptReturnedPositiveNumber(_ script: String) -> Bool {
        Int(runMediaScript(script).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 > 0
    }

    private func runMediaScript(_ script: String) -> String {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error),
              error == nil else {
            return ""
        }
        return result.stringValue ?? "\(result.int32Value)"
    }

    func remoteConnectionDidChange(_ status: String) {
        remoteConnectionStatus = status
    }

    func remoteBatteryDidChange(_ status: String) {
        remoteBatteryStatus = status
    }

    func remoteHotKeyRegistrationDidChange(dictation: String, agent: String) {
        dictationHotKeyStatus = dictation
        agentHotKeyStatus = agent
    }

    func remoteDidCaptureShortcut(_ shortcut: KeyboardShortcut, kind: AppShortcutKind) {
        switch kind {
        case .dictation:
            settingsStore.settings.dictationShortcut = shortcut
        case .agent:
            settingsStore.settings.agentShortcut = shortcut
        }
        input.registerCurrentHotKeys()
        isCapturingShortcut = false
        status = "Hotkey set: \(shortcut.title)"
    }

    func remoteDidCancelShortcutCapture() {
        isCapturingShortcut = false
        status = "Hotkey capture cancelled"
    }

    func remoteDidRequestDictationToggle() {
        toggleDictationRecording()
    }

    func remoteDidPressPlayPauseMediaButton() {
        playPausePressCount += 1
        playPausePressTask?.cancel()
        traceMedia("remote play/pause press count=\(playPausePressCount)")
        playPausePressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: playPausePressWindowNanos)
            guard !Task.isCancelled else { return }
            let finalCount = playPausePressCount
            playPausePressCount = 0
            playPausePressTask = nil
            handlePlayPausePressSequence(count: finalCount)
        }
    }

    private func handlePlayPausePressSequence(count: Int) {
        switch count {
        case 0:
            return
        case 1:
            traceMedia("remote play/pause single press -> toggle play/pause")
            postPlayPauseMediaKey()
        case 2:
            traceMedia("remote play/pause double press -> next track")
            postNextTrackMediaKey()
        default:
            traceMedia("remote play/pause triple press -> previous track")
            postPreviousTrackMediaKey()
        }
    }

    func remoteDidRequestAgentToggle() {
        toggleAgentRecording()
    }

    func remoteDidBeginAgentPushToTalk() {
        guard !agentPushToTalkActive else { return }
        agentPushToTalkActive = true
        if isRecording {
            finishRecording()
        }
        activeWorkflow = settingsStore.settings.isAgentModeEnabled
            ? .agentCommand
            : .selectedMode(settingsStore.settings.inputMode)
        recordingTargetApplication = currentTargetApplication()
        pasteTargetStatus = recordingTargetApplication?.localizedName ?? "None"
        lastTranscript = ""
        lastError = ""
        lastRecordingStatus = "Preparing Siri-button push-to-talk"
        overlayPanel.showListening()
        status = "Preparing microphone"
        Task {
            var relayReady = false
            do {
                try prepareRemoteMicRelayIfNeeded()
                relayReady = true
            } catch {
                logTouchpad("remote mic: direct relay unavailable: \(error.localizedDescription)")
            }

            var fallbackError: Error?
            do {
                try await recorder.start(deviceID: settingsStore.settings.microphoneDeviceID)
                remoteFallbackRecordingStarted = recorder.isRecording
            } catch {
                fallbackError = error
                remoteFallbackRecordingStarted = false
            }

            guard agentPushToTalkActive else {
                if remoteFallbackRecordingStarted {
                    _ = await recorder.stop()
                    remoteFallbackRecordingStarted = false
                }
                remoteAudioRelay.discardCapture()
                overlayPanel.hide()
                return
            }

            guard relayReady || remoteFallbackRecordingStarted else {
                agentPushToTalkActive = false
                isRecording = false
                activeMicrophoneStatus = "Unavailable"
                remoteMicRelayStatus = "Unavailable"
                status = "Microphone unavailable"
                lastError = fallbackError?.localizedDescription ?? "No microphone input is available."
                overlayPanel.hide()
                return
            }

            isRecording = true
            if remoteFallbackRecordingStarted {
                activeMicrophoneStatus = "\(recorder.activeInputDeviceName) (Siri button)"
                remoteMicRelayStatus = "Siri button + selected Mac microphone"
                lastRecordingStatus = "Recording selected microphone"
            } else {
                activeMicrophoneStatus = "Siri Remote audio"
                remoteMicRelayStatus = "Receiving remote audio"
                lastRecordingStatus = "Recording remote audio"
            }
            status = "Hold Siri: listening for command"
            insertionStatus = "Waiting"
        }
    }

    private func prepareRemoteMicRelayIfNeeded() throws {
        input.enableRemoteMicrophoneStreaming()
        remoteMicRelayStatus = "Checking for remote audio"
        try remoteAudioRelay.beginCapture()
        input.startRemoteMicrophonePolling()
        logTouchpad("remote mic: audio probe started")
    }

    func remoteDidEndAgentPushToTalk() {
        guard agentPushToTalkActive else { return }
        agentPushToTalkActive = false
        input.stopRemoteMicrophonePolling()
        status = "Transcribing"
        overlayPanel.showWorking()
        let settings = settingsStore.settings
        let workflow = activeWorkflow
        Task {
            defer { overlayPanel.hide() }
            let fallbackURL: URL?
            if remoteFallbackRecordingStarted {
                fallbackURL = await recorder.stop()
                remoteFallbackRecordingStarted = false
            } else {
                fallbackURL = nil
            }

            var directURL: URL?
            if remoteAudioRelay.isCapturing {
                directURL = try? remoteAudioRelay.finishCapture()
            }

            isRecording = false
            activeMicrophoneStatus = "Idle"

            if let directURL {
                if let fallbackURL {
                    try? FileManager.default.removeItem(at: fallbackURL)
                }
                remoteMicRelayStatus = "Captured \(remoteAudioRelay.decodedFrameCount) remote frames"
                await processRecordedAudio(
                    directURL,
                    recordedMicrophoneName: "Siri Remote audio",
                    workflow: workflow,
                    settings: settings
                )
                return
            }

            if let fallbackURL {
                remoteMicRelayStatus = "Siri button + selected Mac microphone"
                await processRecordedAudio(
                    fallbackURL,
                    recordedMicrophoneName: "Selected Mac microphone (Siri button)",
                    workflow: workflow,
                    settings: settings
                )
                return
            }

            remoteAudioRelay.discardCapture()
            remoteMicRelayStatus = "No microphone audio"
            status = "Microphone failed"
            lastError = "The selected microphone did not produce a recording."
        }
    }

    func remoteDidObserveHIDInput(_ description: String) {
        let now = Date()
        if now.timeIntervalSince(lastRemoteHIDInputUpdate) >= 0.25 {
            lastRemoteHIDInput = description
            lastRemoteHIDInputUpdate = now
        }
        logTouchpad("input: \(description)", throttleKey: "hid-input", minimumInterval: 0.5)
        recoverMultitouchIfNeeded(trigger: "remote input")
    }

    private func recoverMultitouchIfNeeded(trigger: String) {
        guard remoteInputBackendsRunning, !isSystemSleeping, !multitouch.isActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMultitouchRecoveryAttempt) >= multitouchRecoveryCooldown else { return }
        lastMultitouchRecoveryAttempt = now

        if multitouch.start() {
            touchpadNeedsInitialPosition = true
            lastDirectTouchpadEvent = now
            logTouchpad("multitouch recovered after \(trigger)")
        } else {
            logTouchpad(
                "multitouch recovery waiting for remote after \(trigger)",
                throttleKey: "multitouch-recovery",
                minimumInterval: 30
            )
        }
    }
    
    func remoteDidUpdateGCDiagnostic(_ diagnostic: String) {
        gcDiagnostic = diagnostic
    }

    func remoteDidRequestClick() {
        executor.clickCurrentMouse()
    }

    func remoteDidRequestEscape() {
        executor.press(key: "escape")
    }

    func remoteDidRequestKeyboard() {
        let now = Date()
        guard now.timeIntervalSince(lastKeyboardTriggerRequest) > keyboardTriggerDuplicateWindow else {
            logTouchpad("keyboard duplicate trigger ignored")
            return
        }
        lastKeyboardTriggerRequest = now
        keyboardPressCount += 1
        keyboardPressTask?.cancel()
        logTouchpad("keyboard button press count=\(keyboardPressCount)")
        keyboardPressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: keyboardPressWindowNanos)
            guard !Task.isCancelled else { return }
            let finalCount = keyboardPressCount
            keyboardPressCount = 0
            keyboardPressTask = nil
            handleKeyboardButtonSequence(count: finalCount)
        }
    }

    private func handleKeyboardButtonSequence(count: Int) {
        guard count > 0 else { return }
        let devMode = false
        let targetApplication = currentTargetApplication()
        if let targetApplication {
            pasteTargetStatus = targetApplication.localizedName ?? "Unknown"
        }
        liquidKeyboard.toggle(devMode: devMode, targetApplication: targetApplication)
        status = liquidKeyboard.isVisible ? "Mac keyboard" : "Liquid keyboard hidden"
        logTouchpad("keyboard button \(count)x -> \(liquidKeyboard.isVisible ? "Mac keyboard" : "hidden")")
    }

    func remoteDidMovePointer(dx: Double, dy: Double) {
        logTouchpad(
            "move delta dx=\(String(format: "%.3f", dx)) dy=\(String(format: "%.3f", dy))",
            throttleKey: "remote-pointer-move",
            minimumInterval: 0.35
        )
        moveRemotePointer(dx: dx, dy: dy)
    }

    func remoteDidScroll(amount: Double) {
        logTouchpad(
            "scroll amount=\(String(format: "%.3f", amount))",
            throttleKey: "remote-scroll",
            minimumInterval: 0.35
        )
        executor.scroll(amount: amount)
    }

    func remoteDidScroll(dx: Double, dy: Double) {
        logTouchpad(
            "scroll dx=\(String(format: "%.3f", dx)) dy=\(String(format: "%.3f", dy))",
            throttleKey: "remote-scroll-axis",
            minimumInterval: 0.35
        )
        executor.scroll(dx: dx, dy: dy)
    }

    private var lastTouchpadScreenPosition = (x: 0.0, y: 0.0)
    private var lastDirectTouchpadPosition = (x: 0.0, y: 0.0)
    private var directTouchpadMode: DirectTouchpadMode?
    private var lastClickWheelAngle: Double?
    private var lastClickWheelRadius: Double?
    private var clickWheelArbitrator = ClickWheelGestureArbitrator()
    private var touchpadNeedsInitialPosition = true
    private var bleTouchpadInactivityTimer: Timer?
    private var touchpadWatchdogTask: Task<Void, Never>?
    private let directTouchpadPointScale = 3000.0
    private let clickWheelInnerRadius = 0.32
    private var touchpadStartPosition = (x: 0.0, y: 0.0)
    private var touchpadLastPosition = (x: 0.0, y: 0.0)
    private var touchpadMinPosition = (x: 0.0, y: 0.0)
    private var touchpadMaxPosition = (x: 0.0, y: 0.0)
    private var touchpadGestureStartedAt = Date.distantPast
    private var touchpadPathLength = 0.0
    private var swipeGestureFired = false
    private var lastSwipeEvaluation = "not evaluated"
    private var touchpadStartRadius: Double = 0

    func remoteDidTouchpadMove(x: Double, y: Double) {
        logTouchpad(
            "move x=\(String(format: "%.3f", x)) y=\(String(format: "%.3f", y))",
            throttleKey: "touchpad-move",
            minimumInterval: 0.35
        )
        let radius = hypot(x - 0.5, y - 0.5)

        if touchpadNeedsInitialPosition {
            lastDirectTouchpadPosition = (x: x, y: y)
            touchpadStartPosition = (x: x, y: y)
            touchpadLastPosition = (x: x, y: y)
            touchpadMinPosition = (x: x, y: y)
            touchpadMaxPosition = (x: x, y: y)
            touchpadGestureStartedAt = Date()
            touchpadPathLength = 0
            touchpadStartRadius = radius
            swipeGestureFired = false
            lastSwipeEvaluation = "not evaluated"
            if radius >= clickWheelInnerRadius {
                directTouchpadMode = .clickWheel
                lastClickWheelAngle = atan2(y - 0.5, x - 0.5)
                lastClickWheelRadius = radius
                clickWheelArbitrator.reset()
                logTouchpad("click wheel start radius=\(String(format: "%.3f", radius))")
            } else {
                directTouchpadMode = .pointer
                lastClickWheelAngle = nil
                lastClickWheelRadius = nil
                clickWheelArbitrator.reset()
            }
            touchpadNeedsInitialPosition = false
            return
        }

        touchpadPathLength += hypot(x - touchpadLastPosition.x, y - touchpadLastPosition.y)
        touchpadLastPosition = (x: x, y: y)
        touchpadMinPosition = (x: min(touchpadMinPosition.x, x), y: min(touchpadMinPosition.y, y))
        touchpadMaxPosition = (x: max(touchpadMaxPosition.x, x), y: max(touchpadMaxPosition.y, y))

        if directTouchpadMode == .clickWheel {
            let angle = atan2(y - 0.5, x - 0.5)
            guard let previousAngle = lastClickWheelAngle,
                  let previousRadius = lastClickWheelRadius else {
                lastClickWheelAngle = angle
                lastClickWheelRadius = radius
                return
            }
            var deltaAngle = angle - previousAngle
            if deltaAngle > .pi { deltaAngle -= 2 * .pi }
            if deltaAngle < -.pi { deltaAngle += 2 * .pi }
            lastClickWheelAngle = angle
            lastClickWheelRadius = radius

            guard abs(deltaAngle) < 1.2 else {
                logTouchpad("click wheel jump ignored da=\(String(format: "%.3f", deltaAngle))")
                return
            }

            let amount = -max(-80, min(80, deltaAngle * settingsStore.settings.scrollSensitivity * 10))
            if let emittedAmount = clickWheelArbitrator.consume(
                deltaAngle: deltaAngle,
                previousRadius: previousRadius,
                currentRadius: radius,
                scrollAmount: amount
            ) {
                logTouchpad(
                    "click wheel scroll committed=\(clickWheelArbitrator.isCommitted) da=\(String(format: "%.3f", deltaAngle)) amount=\(String(format: "%.1f", emittedAmount))",
                    throttleKey: "click-wheel-scroll",
                    minimumInterval: 0.35
                )
                executor.scroll(dx: 0, dy: emittedAmount)
            }
            return
        }

        let rawDeltaX = x - lastDirectTouchpadPosition.x
        let rawDeltaY = -(y - lastDirectTouchpadPosition.y)
        lastDirectTouchpadPosition = (x: x, y: y)

        guard abs(rawDeltaX) < 0.35, abs(rawDeltaY) < 0.35 else {
            logTouchpad("direct jump ignored dx=\(String(format: "%.3f", rawDeltaX)) dy=\(String(format: "%.3f", rawDeltaY))")
            return
        }

        let deltaX = rawDeltaX * directTouchpadPointScale
        let deltaY = rawDeltaY * directTouchpadPointScale
        let sensitivity = settingsStore.settings.remoteSensitivity
        let moveX = max(-120, min(120, deltaX * sensitivity))
        let moveY = max(-120, min(120, deltaY * sensitivity))
        logTouchpad(
            "direct sensitivity=\(String(format: "%.6f", sensitivity)) delta=\(String(format: "%.1f", deltaX)),\(String(format: "%.1f", deltaY)) move=\(String(format: "%.1f", moveX)),\(String(format: "%.1f", moveY))",
            throttleKey: "touchpad-direct-move",
            minimumInterval: 0.35
        )
        moveRemotePointer(dx: moveX, dy: moveY)
    }

    func remoteDidTouchpadClick(pressed: Bool) {
        logTouchpad("click pressed=\(pressed)")
        handleRemoteTouchpadButton(pressed: pressed)
    }

    func remoteDidEndTouchpadInteraction() {
        logTouchpad("touch ended")
        let wasPressing = remoteClickStabilizer.isPressed || remoteMouseButtonDown || remoteKeyboardDragActive
        if wasPressing {
            finishRemoteTouchpadButtonPress()
        }
        if !wasPressing, !swipeGestureFired {
            checkSwipeGesture()
        } else if wasPressing {
            lastSwipeEvaluation = "suppressed: touchpad button was pressed"
        }
        touchpadNeedsInitialPosition = true
        directTouchpadMode = nil
        lastClickWheelAngle = nil
        lastClickWheelRadius = nil
        clickWheelArbitrator.reset()
    }

    private func handleRemoteTouchpadButton(pressed: Bool) {
        if pressed {
            guard !remoteClickStabilizer.isPressed, !remoteMouseButtonDown, !remoteKeyboardDragActive else { return }
            if liquidKeyboard.beginRemoteDrag(at: NSEvent.mouseLocation) {
                remoteKeyboardDragActive = true
                logTouchpad("keyboard remote drag start")
                return
            }
            guard remoteClickStabilizer.beginPress() else { return }
            remoteTouchpadPressStartedAt = Date()
            logTouchpad("click stabilization armed")
            return
        }
        finishRemoteTouchpadButtonPress()
    }

    private func finishRemoteTouchpadButtonPress() {
        if remoteKeyboardDragActive {
            remoteKeyboardDragActive = false
            _ = liquidKeyboard.endRemoteDrag()
            logTouchpad("keyboard remote drag end")
        }

        switch remoteClickStabilizer.endPress() {
        case .click:
            executor.clickCurrentMouse()
            logTouchpad("stabilized click delivered")
        case .endDrag:
            if remoteMouseButtonDown {
                executor.mouseUpCurrent()
                logTouchpad("stabilized drag ended")
            }
        case .none:
            if remoteMouseButtonDown {
                executor.mouseUpCurrent()
            }
        }
        if remoteMouseButtonDown {
            remoteMouseButtonDown = false
        }
        remoteTouchpadPressStartedAt = .distantPast
    }

    private func moveRemotePointer(dx: Double, dy: Double) {
        let previousLocation = NSEvent.mouseLocation
        if remoteKeyboardDragActive {
            executor.moveBy(dx: dx, dy: dy)
            let currentLocation = NSEvent.mouseLocation
            _ = liquidKeyboard.dragRemote(from: previousLocation, to: currentLocation)
            return
        }

        if remoteClickStabilizer.isPressed {
            let duration = Date().timeIntervalSince(remoteTouchpadPressStartedAt)
            switch remoteClickStabilizer.move(dx: dx, dy: dy, pressedDuration: duration) {
            case .suppressed:
                logTouchpad(
                    "click jitter suppressed dx=\(String(format: "%.1f", dx)) dy=\(String(format: "%.1f", dy))",
                    throttleKey: "click-jitter",
                    minimumInterval: 0.2
                )
            case .beginDrag(let accumulatedDX, let accumulatedDY):
                remoteMouseButtonDown = true
                executor.mouseDownCurrent()
                executor.dragCurrentMouseBy(dx: accumulatedDX, dy: accumulatedDY)
                logTouchpad(
                    "stabilized drag began dx=\(String(format: "%.1f", accumulatedDX)) dy=\(String(format: "%.1f", accumulatedDY))"
                )
            case .drag(let dragDX, let dragDY):
                executor.dragCurrentMouseBy(dx: dragDX, dy: dragDY)
            }
            return
        }

        if remoteMouseButtonDown {
            executor.dragCurrentMouseBy(dx: dx, dy: dy)
            return
        }
        executor.moveBy(dx: dx, dy: dy)
    }

    private func checkSwipeGesture() {
        let evaluation = RemoteSwipeRecognizer.evaluate(
            RemoteSwipeMetrics(
                startX: touchpadStartPosition.x,
                startY: touchpadStartPosition.y,
                endX: touchpadLastPosition.x,
                endY: touchpadLastPosition.y,
                minX: touchpadMinPosition.x,
                minY: touchpadMinPosition.y,
                maxX: touchpadMaxPosition.x,
                maxY: touchpadMaxPosition.y,
                pathLength: touchpadPathLength,
                duration: Date().timeIntervalSince(touchpadGestureStartedAt),
                sensitivity: settingsStore.settings.swipeSensitivity
            )
        )
        lastSwipeEvaluation = evaluation.summary
        logTouchpad(
            "swipe check result=\(evaluation.summary) threshold=\(String(format: "%.3f", evaluation.travelThreshold)) edge=\(String(format: "%.3f", evaluation.edgeInset)) straightness=\(String(format: "%.3f", evaluation.straightness))"
        )

        guard let direction = evaluation.direction else { return }
        swipeGestureFired = true
        switch direction {
        case .right:
            logTouchpad("swipe gesture: right -> Ctrl+LeftArrow")
            executor.press(key: "left", modifiers: ["control"])
        case .left:
            logTouchpad("swipe gesture: left -> Ctrl+RightArrow")
            executor.press(key: "right", modifiers: ["control"])
        case .down:
            logTouchpad("swipe gesture: down -> Cmd+M")
            executor.press(key: "m", modifiers: ["command"])
        case .up:
            logTouchpad("swipe gesture: up -> Mission Control app")
            executor.showMissionControl()
        }
    }

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var logBuffer: [String] = []
    private var logFlushWorkItem: DispatchWorkItem?
    private var logFlushScheduled = false
    private var lastLogByThrottleKey: [String: Date] = [:]
    private let maxTouchpadLogEntries = 80
    private let maxBufferedTouchpadLogEntries = 80
    private func logTouchpad(
        _ message: @autoclosure () -> String,
        throttleKey: String? = nil,
        minimumInterval: TimeInterval = 0
    ) {
        if let throttleKey, minimumInterval > 0 {
            let now = Date()
            if let previous = lastLogByThrottleKey[throttleKey],
               now.timeIntervalSince(previous) < minimumInterval {
                return
            }
            lastLogByThrottleKey[throttleKey] = now
        }

        let resolvedMessage = message()
        let timestamp = Self.logDateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(resolvedMessage)"
        logBuffer.append(line)
        TraceLog.append(resolvedMessage, filename: "remote-input.log")
        if logBuffer.count >= maxBufferedTouchpadLogEntries {
            logFlushWorkItem?.cancel()
            flushLogBuffer()
            return
        }

        guard !logFlushScheduled else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flushLogBuffer()
        }
        logFlushWorkItem = work
        logFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func flushLogBuffer() {
        logFlushScheduled = false
        logFlushWorkItem = nil
        guard !logBuffer.isEmpty else { return }
        touchpadLog.append(contentsOf: logBuffer)
        logBuffer.removeAll()
        let excess = touchpadLog.count - maxTouchpadLogEntries
        if excess > 0 {
            touchpadLog.removeFirst(excess)
        }
    }

    func clearTouchpadLog() {
        flushLogBuffer()
        touchpadLog.removeAll()
    }

    private static let pausePageMediaJavaScript = """
    (() => {
      const seen = new Set();
      const media = [];
      const collect = root => {
        if (!root || seen.has(root)) return;
        seen.add(root);
        try {
          media.push(...root.querySelectorAll('video,audio'));
          root.querySelectorAll('*').forEach(element => {
            if (element.shadowRoot) collect(element.shadowRoot);
          });
          root.querySelectorAll('iframe,frame').forEach(frame => {
            try { collect(frame.contentDocument); } catch (_) {}
          });
        } catch (_) {}
      };
      collect(document);
      let count = 0;
      for (const element of media) {
        if (!element.paused && !element.ended) {
          element.dataset.ratRemoteWasPlaying = '1';
          element.pause();
          count += 1;
        }
      }
      return count;
    })()
    """.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")

    private static let resumePageMediaJavaScript = """
    (() => {
      const seen = new Set();
      const media = [];
      const collect = root => {
        if (!root || seen.has(root)) return;
        seen.add(root);
        try {
          media.push(...root.querySelectorAll('video,audio'));
          root.querySelectorAll('*').forEach(element => {
            if (element.shadowRoot) collect(element.shadowRoot);
          });
          root.querySelectorAll('iframe,frame').forEach(frame => {
            try { collect(frame.contentDocument); } catch (_) {}
          });
        } catch (_) {}
      };
      collect(document);
      const resumable = media.filter(element => element.dataset.ratRemoteWasPlaying === '1');
      for (const element of resumable) {
        delete element.dataset.ratRemoteWasPlaying;
        element.play();
      }
      return resumable.length;
    })()
    """.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")

}

@MainActor
private enum MediaRemoteCommandSender {
    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    enum PlaybackState: Int32 {
        case unknown = 0
        case playing = 1
        case paused = 2
        case stopped = 3
        case interrupted = 4
    }

    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Void
    private typealias GetPlaybackState = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    private static var handle: UnsafeMutableRawPointer?
    private static var sendCommand: SendCommand?
    private static var getPlaybackState: GetPlaybackState?
    private static var getNowPlayingInfo: GetNowPlayingInfo?

    static func send(command: Command) -> Bool {
        guard loadFrameworkIfNeeded() else { return false }
        if sendCommand == nil, let symbol = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(symbol, to: SendCommand.self)
        }
        guard let sendCommand else { return false }
        sendCommand(command.rawValue, nil)
        return true
    }

    static func playbackState() -> PlaybackState {
        guard loadFrameworkIfNeeded() else { return .unknown }
        if getPlaybackState == nil, let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPlaybackState") {
            getPlaybackState = unsafeBitCast(symbol, to: GetPlaybackState.self)
        }
        guard let getPlaybackState else { return .unknown }

        let semaphore = DispatchSemaphore(value: 0)
        var rawState = PlaybackState.unknown.rawValue
        getPlaybackState(DispatchQueue.global(qos: .userInitiated)) { state in
            rawState = state
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 0.2)
        return PlaybackState(rawValue: rawState) ?? .unknown
    }

    static func isPlaybackActive() -> Bool {
        if playbackState() == .playing {
            return true
        }

        guard let first = nowPlayingMetrics() else {
            return false
        }
        if let playbackRate = first.playbackRate, playbackRate > 0.01 {
            return true
        }
        guard let firstElapsedTime = first.elapsedTime else {
            return false
        }

        Thread.sleep(forTimeInterval: 0.18)
        guard let secondElapsedTime = nowPlayingMetrics()?.elapsedTime else {
            return false
        }
        return secondElapsedTime - firstElapsedTime > 0.05
    }

    private struct NowPlayingMetrics {
        let playbackRate: Double?
        let elapsedTime: Double?
    }

    private static func nowPlayingMetrics() -> NowPlayingMetrics? {
        guard let info = nowPlayingInfo() else { return nil }
        let dictionary = info as NSDictionary
        return NowPlayingMetrics(
            playbackRate: numberValue(in: dictionary, keySuffix: "PlaybackRate", excluding: "DefaultPlaybackRate"),
            elapsedTime: numberValue(in: dictionary, keySuffix: "ElapsedTime")
        )
    }

    private static func nowPlayingInfo() -> CFDictionary? {
        guard loadFrameworkIfNeeded() else { return nil }
        if getNowPlayingInfo == nil, let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(symbol, to: GetNowPlayingInfo.self)
        }
        guard let getNowPlayingInfo else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var result: CFDictionary?
        getNowPlayingInfo(DispatchQueue.global(qos: .userInitiated)) { info in
            result = info
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 0.2)
        return result
    }

    private static func numberValue(in dictionary: NSDictionary, keySuffix: String, excluding excludedKeyPart: String? = nil) -> Double? {
        for key in dictionary.allKeys {
            let keyString = String(describing: key)
            if let excludedKeyPart, keyString.contains(excludedKeyPart) {
                continue
            }
            guard keyString.hasSuffix(keySuffix) else { continue }
            let value = dictionary[key]
            if let number = value as? NSNumber {
                return number.doubleValue
            }
            if let string = value as? String, let number = Double(string) {
                return number
            }
        }
        return nil
    }

    private static func loadFrameworkIfNeeded() -> Bool {
        if handle != nil { return true }
        guard let loadedHandle = dlopen(frameworkPath, RTLD_LAZY) else {
            return false
        }
        handle = loadedHandle
        return true
    }
}

enum RecordingWorkflow: Equatable {
    case dictationOnly
    case agentCommand
    case selectedMode(InputMode)

    var resolvedMode: InputMode {
        switch self {
        case .dictationOnly:
            .dictation
        case .agentCommand:
            .command
        case .selectedMode(let mode):
            mode
        }
    }

    var listeningStatus: String {
        switch self {
        case .dictationOnly:
            "Listening for dictation"
        case .agentCommand:
            "Listening for command"
        case .selectedMode(let mode):
            "Listening: \(mode.title)"
        }
    }
}

private enum RecordingFailureStage {
    case transcription
    case handling

    func failureStatus(for workflow: RecordingWorkflow) -> String {
        switch self {
        case .transcription:
            "Transcription failed"
        case .handling where workflow.resolvedMode == .command:
            "Command failed"
        case .handling where workflow.resolvedMode == .vision:
            "Vision failed"
        case .handling:
            "Error"
        }
    }
}
