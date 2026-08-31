import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case remote
    case dictation
    case commands
    case agent
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .remote: "Remote"
        case .dictation: "Dictation"
        case .commands: "Commands"
        case .agent: "Agent"
        case .diagnostics: "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .remote: "appletvremote.gen4"
        case .dictation: "mic"
        case .commands: "wand.and.rays"
        case .agent: "testtube.2"
        case .diagnostics: "stethoscope"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: RemoteCoordinator
    @ObservedObject var store: SettingsStore

    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        ZStack {
            BlueprintBackdrop()

            VStack(spacing: 0) {
                settingsHeader

                HStack(spacing: 0) {
                    settingsSidebar

                    ScrollView {
                        selectedContent
                            .padding(24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .foregroundStyle(AppTheme.cream)
        .tint(AppTheme.interactiveAccent)
        .buttonStyle(.liquidGlass)
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, idealWidth: 880, minHeight: 620, idealHeight: 700)
        .onChange(of: store.settings.isAgentModeEnabled) { _, enabled in
            coordinator.agentModeSettingDidChange(enabled: enabled)
            if !enabled, selectedSection == .agent {
                selectedSection = .general
            }
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 21, weight: .medium))

            VStack(alignment: .leading, spacing: 2) {
                Text("RatRemote Settings")
                    .font(.system(size: 18, weight: .semibold))
                Text("Configure control, dictation, services, and permissions.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.cream.opacity(0.58))
            }

            Spacer()

            StatusChip(
                title: coordinator.remoteConnectionStatus.hasPrefix("Connected") ? "Remote connected" : coordinator.remoteConnectionStatus,
                systemImage: "dot.radiowaves.left.and.right",
                tint: coordinator.remoteConnectionStatus.hasPrefix("Connected") ? .green : .orange
            )
        }
        .padding(.horizontal, 22)
        .frame(height: 70)
        .background(AppTheme.headerMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.glassStroke)
                .frame(height: 1)
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("SETTINGS")
                .font(AppTheme.mono(size: 8, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.cream.opacity(0.48))
                .padding(.horizontal, 11)
                .padding(.bottom, 5)

            settingsSidebarButton(.general)
            settingsSidebarButton(.remote)
            settingsSidebarButton(.dictation)
            settingsSidebarButton(.commands)

            if store.settings.isAgentModeEnabled {
                Divider()
                    .padding(.vertical, 5)
                settingsSidebarButton(.agent, badge: "EXPERIMENTAL")
            }

            Spacer()
            settingsSidebarButton(.diagnostics)
        }
        .padding(14)
        .frame(width: 190)
        .background(AppTheme.sidebarMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppTheme.glassStroke)
                .frame(width: 1)
        }
    }

    private func settingsSidebarButton(_ section: SettingsSection, badge: String? = nil) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.system(size: 13, weight: .semibold))
                    if let badge {
                        Text(badge)
                            .font(AppTheme.mono(size: 6, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(AppTheme.orange)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, badge == nil ? 11 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .nativeGlass(
            cornerRadius: 12,
            tint: selectedSection == section ? AppTheme.cream.opacity(0.10) : AppTheme.cream.opacity(0.025),
            interactive: true
        )
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .general:
            generalSettings
        case .remote:
            remoteSettings
        case .dictation:
            dictationSettings
        case .commands:
            commandSettings
        case .agent:
            agentSettings
        case .diagnostics:
            diagnosticsSettings
        }
    }

    private var generalSettings: some View {
        SettingsPage(
            title: "General",
            description: "Choose how RatRemote behaves during everyday use.",
            systemImage: "gearshape"
        ) {
            SettingsCard(title: "Default behaviour", systemImage: "switch.2") {
                Picker("Default input mode", selection: $store.settings.inputMode) {
                    ForEach(InputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Paste dictation directly into the active app", isOn: $store.settings.pasteDictation)
                Toggle("Speak selected text when Play/Pause is pressed", isOn: $store.settings.speakOnPlayPause)
            }

            SettingsCard(title: "System access", systemImage: "lock.shield") {
                settingsStatusRow("Accessibility", coordinator.accessibilityStatus)
                settingsStatusRow("Microphone", coordinator.microphoneAccessStatus)
                settingsStatusRow("Speech recognition", coordinator.speechAuthorizationStatus)

                HStack {
                    Button("Open Accessibility Settings") {
                        coordinator.openAccessibilityApprovalFlow()
                    }
                    Button("Request Speech & Mic Access") {
                        coordinator.requestSpeechAuthorization()
                    }
                }
            }

            experimentalAgentCard
        }
    }

    private var experimentalAgentCard: some View {
        SettingsCard(title: "Experimental features", systemImage: "testtube.2", tint: AppTheme.orange.opacity(0.12)) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppTheme.orange)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Agent mode is experimental")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Agent automation can inspect a selected window and perform multi-step actions. It is not a primary RatRemote feature and may behave unpredictably. Keep approval prompts enabled while testing.")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.cream.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 18)

                Toggle("Enable", isOn: $store.settings.isAgentModeEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Enable experimental Agent mode")
            }
        }
    }

    private var remoteSettings: some View {
        SettingsPage(
            title: "Remote",
            description: "Tune the Siri Remote and review its connection state.",
            systemImage: "appletvremote.gen4"
        ) {
            SettingsCard(title: "Movement", systemImage: "slider.horizontal.3") {
                Slider(value: $store.settings.remoteSensitivity, in: AppSettings.minRemoteSensitivity...AppSettings.maxRemoteSensitivity) {
                    Text("Pointer speed")
                }
                .liquidGlassSlider()

                Slider(value: $store.settings.scrollSensitivity, in: 1...40) {
                    Text("Scroll speed")
                }
                .liquidGlassSlider()

                Slider(value: $store.settings.swipeSensitivity, in: AppSettings.minSwipeSensitivity...AppSettings.maxSwipeSensitivity) {
                    Text("Swipe sensitivity")
                }
                .liquidGlassSlider()
            }

            SettingsCard(title: "Connection", systemImage: "dot.radiowaves.left.and.right") {
                settingsStatusRow("Remote", coordinator.remoteConnectionStatus)
                settingsStatusRow("Touchpad backend", coordinator.bleTouchpadStatus)
                settingsStatusRow("Last input", coordinator.lastRemoteHIDInput)
                settingsStatusRow("Controller", coordinator.gcDiagnostic)
            }
        }
    }

    private var dictationSettings: some View {
        SettingsPage(
            title: "Dictation",
            description: "Configure speech recognition, microphone input, and activation.",
            systemImage: "mic"
        ) {
            SettingsCard(title: "Speech", systemImage: "waveform") {
                LiquidGlassPicker("Engine", selection: $store.settings.speechEngine) {
                    ForEach(SpeechEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                LiquidGlassPicker("Language", selection: $store.settings.speechLocaleIdentifier) {
                    ForEach(SpeechLocaleOption.options) { locale in
                        Text(locale.title).tag(locale.id)
                    }
                }
                LiquidGlassPicker("Microphone", selection: $store.settings.microphoneDeviceID) {
                    Text("System Default").tag("")
                    ForEach(coordinator.microphoneDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                Button("Refresh Microphones") {
                    coordinator.refreshMicrophones()
                }
            }

            SettingsCard(title: "Activation", systemImage: "keyboard") {
                settingsStatusRow(
                    "Shortcut",
                    coordinator.isCapturingShortcut ? "Press a key combination" : store.settings.dictationShortcut.title
                )
                settingsStatusRow("Registration", coordinator.dictationHotKeyStatus)
                HStack {
                    Button(coordinator.isCapturingShortcut ? "Recording…" : "Record Shortcut") {
                        coordinator.beginShortcutCapture(kind: .dictation)
                    }
                    .disabled(coordinator.isCapturingShortcut)
                    Button("Clear") {
                        coordinator.clearShortcut(kind: .dictation)
                    }
                }
            }

            SettingsCard(title: "Remote transcription server", systemImage: "server.rack") {
                settingsField("Server URL", text: $store.settings.transcriptionServerURL)
                settingsSecureField("API key", text: $store.settings.transcriptionAPIKey)
                Button("Test Transcription Server") {
                    coordinator.testServer(.transcription)
                }
            }
        }
    }

    private var commandSettings: some View {
        SettingsPage(
            title: "Commands",
            description: "Choose the model used to interpret spoken remote commands.",
            systemImage: "wand.and.rays"
        ) {
            SettingsCard(title: "Command model", systemImage: "brain") {
                LiquidGlassPicker("Provider", selection: $store.settings.commandModelProvider) {
                    ForEach(CommandModelProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }

                if store.settings.commandModelProvider == .automatic || store.settings.commandModelProvider == .remoteServer {
                    settingsField("Inference server URL", text: $store.settings.inferenceServerURL)
                    settingsSecureField("Inference API key", text: $store.settings.inferenceAPIKey)
                }

                Toggle("Include screen context with commands", isOn: $store.settings.includeScreenContextForCommands)
                settingsStatusRow("Apple Intelligence", coordinator.appleIntelligenceStatus)

                Button("Test Selected Command Model") {
                    coordinator.testCommandModel()
                }
            }

            SettingsCard(title: "Local model", systemImage: "desktopcomputer") {
                LocalModelSettingsView(coordinator: coordinator)
            }
        }
    }

    private var agentSettings: some View {
        SettingsPage(
            title: "Agent — Experimental",
            description: "Advanced automation controls. Review every action and use only with non-sensitive work.",
            systemImage: "testtube.2",
            accent: AppTheme.orange
        ) {
            SettingsCard(title: "Safety", systemImage: "exclamationmark.shield", tint: AppTheme.orange.opacity(0.12)) {
                Label("Experimental feature — not intended as a primary control mode", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.orange)
                Toggle("Allow all approval prompts", isOn: $store.settings.automationAllowAllApprovals)
                Text("Leave this off for the safest experience. When off, RatRemote pauses before suggested actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard(title: "Automation loop", systemImage: "repeat") {
                Slider(value: automationMaxStepsSliderBinding, in: 0...1) {
                    Text("Maximum steps: \(store.settings.automationMaxSteps)")
                } minimumValueLabel: {
                    Text("\(AppSettings.minAutomationMaxSteps)")
                } maximumValueLabel: {
                    Text("\(AppSettings.maxAutomationMaxSteps)")
                }
                .liquidGlassSlider()

                Slider(value: $store.settings.automationStepDelay, in: AppSettings.minAutomationStepDelay...AppSettings.maxAutomationStepDelay) {
                    Text("Step delay")
                } minimumValueLabel: {
                    Text("0.2s")
                } maximumValueLabel: {
                    Text("10s")
                }
                .liquidGlassSlider()

                Toggle("Use a separate agent cursor", isOn: $store.settings.useSeparateAgentCursor)
                if let note = coordinator.agentInputCompatibilityNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                settingsStatusRow("Loop", coordinator.automationStatus)
                settingsStatusRow("Cursor", coordinator.agentCursorStatus)
            }

            SettingsCard(title: "Activation", systemImage: "keyboard") {
                settingsStatusRow(
                    "Shortcut",
                    coordinator.isCapturingShortcut ? "Press a key combination" : store.settings.agentShortcut.title
                )
                settingsStatusRow("Registration", coordinator.agentHotKeyStatus)
                HStack {
                    Button(coordinator.isCapturingShortcut ? "Recording…" : "Record Agent Shortcut") {
                        coordinator.beginShortcutCapture(kind: .agent)
                    }
                    .disabled(coordinator.isCapturingShortcut)
                    Button("Clear") {
                        coordinator.clearShortcut(kind: .agent)
                    }
                }
            }

            SettingsCard(title: "Computer use", systemImage: "macwindow") {
                settingsField("Computer-use server URL", text: $store.settings.computerUseServerURL)
                settingsSecureField("Computer-use API key", text: $store.settings.computerUseAPIKey)
                Toggle("Click located vision targets automatically", isOn: $store.settings.clickVisionResult)
                Button("Test Computer-Use Server") {
                    coordinator.testServer(.computerUse)
                }
            }
        }
    }

    private var diagnosticsSettings: some View {
        SettingsPage(
            title: "Diagnostics",
            description: "Connection tests and technical status for troubleshooting.",
            systemImage: "stethoscope"
        ) {
            SettingsCard(title: "Service tests", systemImage: "checkmark.seal") {
                HStack {
                    Button("Transcription") { coordinator.testServer(.transcription) }
                    Button("Commands") { coordinator.testServer(.inference) }
                    Button("Computer Use") { coordinator.testServer(.computerUse) }
                }
            }

            SettingsCard(title: "Runtime status", systemImage: "info.circle") {
                settingsStatusRow("Application", coordinator.status)
                settingsStatusRow("Recording", coordinator.lastRecordingStatus)
                settingsStatusRow("Remote mic relay", coordinator.remoteMicRelayStatus)
                settingsStatusRow("Paste target", coordinator.pasteTargetStatus)
                settingsStatusRow("Insert method", coordinator.insertionStatus)
                settingsStatusRow("Running app", coordinator.runningAppPath)

                if !coordinator.lastError.isEmpty {
                    Text(coordinator.lastError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            SettingsCard(title: "Touchpad event log", systemImage: "list.bullet.rectangle") {
                HStack {
                    Spacer()
                    Button("Copy") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(coordinator.touchpadLog.joined(separator: "\n"), forType: .string)
                    }
                    Button("Clear") {
                        coordinator.clearTouchpadLog()
                    }
                }

                Text(coordinator.touchpadLog.isEmpty ? "(no events)" : coordinator.touchpadLog.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(12)
                    .glassWell()
            }
        }
    }

    private var automationMaxStepsSliderBinding: Binding<Double> {
        Binding(
            get: {
                AppSettings.automationMaxStepsSliderValue(for: store.settings.automationMaxSteps)
            },
            set: { value in
                store.settings.automationMaxSteps = AppSettings.automationMaxSteps(fromSliderValue: value)
            }
        )
    }

    private func settingsStatusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(AppTheme.cream.opacity(0.66))
            Spacer()
            Text(value.isEmpty ? "Unavailable" : value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
        .padding(.vertical, 3)
    }

    private func settingsField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.cream.opacity(0.66))
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func settingsSecureField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.cream.opacity(0.66))
            SecureField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let description: String
    let systemImage: String
    var accent: Color = AppTheme.cream
    let content: Content

    init(
        title: String,
        description: String,
        systemImage: String,
        accent: Color = AppTheme.cream,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppTheme.display(size: 28, weight: .semibold))
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.cream.opacity(0.64))
                }
            }
            .padding(.horizontal, 3)

            content
        }
        .frame(maxWidth: 650, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color?
    let content: Content

    init(
        title: String,
        systemImage: String,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: systemImage)
                .font(AppTheme.mono(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(AppTheme.cream.opacity(0.78))

            Divider()
                .overlay(AppTheme.separator)

            content
        }
        .padding(18)
        .nativeGlass(cornerRadius: 18, tint: tint)
    }
}

private struct LocalModelSettingsView: View {
    @ObservedObject var coordinator: RemoteCoordinator
    @ObservedObject private var manager: LocalModelManager

    init(coordinator: RemoteCoordinator) {
        self.coordinator = coordinator
        self.manager = coordinator.localModelManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Local Gemma", value: manager.status)
            Text("Gemma 4 E2B Q4_0 runs locally through llama.cpp. Download it once to keep command inference available offline.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if !manager.isModelInstalled {
                    Button(manager.isDownloading ? "Downloading…" : "Download Model") {
                        coordinator.downloadLocalModel()
                    }
                    .disabled(manager.isDownloading)
                }
                if manager.isModelInstalled && !manager.isRunning {
                    Button("Start") { coordinator.startLocalModel() }
                }
                if manager.isRunning {
                    Button("Stop") { coordinator.stopLocalModel() }
                }
            }

            if manager.runtimeURL == nil {
                Button(manager.isDownloadingRuntime ? "Installing Runtime…" : "Install llama.cpp Runtime") {
                    coordinator.downloadLocalModelRuntime()
                }
                .disabled(manager.isDownloadingRuntime)
                Text("The runtime is stored in RatRemote's Application Support folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
