import SwiftUI

struct TranscriptionView: View {
    @ObservedObject var coordinator: RemoteCoordinator
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            content
        }
        .scrollContentBackground(.hidden)
    }

    private var content: some View {
        VStack(spacing: 18) {
                PageIntro(
                    index: "02",
                    eyebrow: "Dictation",
                    title: "Speak once.",
                    accent: "Keep moving.",
                    description: "Turn speech into polished text without breaking focus. On-device by default, ready wherever the cursor is."
                )
                dictationPanel
                speechPanel
                activationPanel
        }
        .frame(maxWidth: .infinity)
        .padding(22)
    }

    private var dictationPanel: some View {
        AppPanel {
            VStack(spacing: 18) {
                SectionTitle(title: "Dictation", systemImage: "text.cursor")

                Button {
                    coordinator.toggleDictationRecording()
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: coordinator.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 54))
                        Text(coordinator.isRecording ? "Stop Dictation" : "Start Dictation")
                            .font(AppTheme.display(size: 27, weight: .semibold))
                        Text(store.settings.dictationShortcut.title)
                            .font(AppTheme.mono(size: 9, weight: .medium))
                            .tracking(1.05)
                            .foregroundStyle(AppTheme.cream.opacity(0.58))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(coordinator.isRecording ? .red : AppTheme.cream)
                .nativeGlass(
                    cornerRadius: 16,
                    tint: (coordinator.isRecording ? Color.red : AppTheme.interactiveAccent).opacity(0.16)
                )

                if coordinator.isRecording {
                    VStack(spacing: 7) {
                        Text("Recording\u{2026}")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .glassWell()
                } else if !coordinator.lastTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Last Transcript")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(coordinator.lastTranscript)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .glassWell()
                }
            }
        }
    }

    private var speechPanel: some View {
        AppPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Speech", systemImage: "waveform")
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
                HStack {
                    Toggle("Paste direct dictation", isOn: $store.settings.pasteDictation)
                    Spacer()
                    Button("Refresh Microphones") {
                        coordinator.refreshMicrophones()
                    }
                }
            }
        }
    }

    private var activationPanel: some View {
        AppPanel {
            VStack(spacing: 0) {
                SectionTitle(title: "Activation", systemImage: "keyboard")
                    .padding(.bottom, 8)
                DetailRow(title: "Dictation hotkey", value: coordinator.isCapturingShortcut ? "Press a key combo" : store.settings.dictationShortcut.title)
                DetailRow(title: "Hotkey status", value: coordinator.dictationHotKeyStatus)
                DetailRow(title: "Microphone access", value: coordinator.microphoneAccessStatus)
                DetailRow(title: "Speech recognition", value: coordinator.speechAuthorizationStatus)
                DetailRow(title: "Accessibility", value: coordinator.accessibilityStatus)

                HStack {
                    Button(coordinator.isCapturingShortcut ? "Recording..." : "Record Hotkey") {
                        coordinator.beginShortcutCapture(kind: .dictation)
                    }
                    .disabled(coordinator.isCapturingShortcut)

                    Button("Clear") {
                        coordinator.clearShortcut(kind: .dictation)
                    }

                    Spacer()

                    Button("Approve Accessibility") {
                        coordinator.openAccessibilityApprovalFlow()
                    }
                }
                .padding(.top, 14)
            }
        }
    }

}
