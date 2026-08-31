import SwiftUI

struct RemoteView: View {
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
                    index: "01",
                    eyebrow: "Command remote",
                    title: "Your Mac,",
                    accent: "within reach.",
                    description: "Point, speak, and act from the remote already in your hand. Fast input, local intelligence, visible boundaries."
                )
                commandPanel
                deviceStatusPanel
                tuningPanel
        }
        .frame(maxWidth: .infinity)
        .padding(22)
    }

    private var commandPanel: some View {
        AppPanel {
            VStack(spacing: 18) {
                SectionTitle(title: "Command Remote", systemImage: "wand.and.rays")

                Button {
                    coordinator.toggleRecording()
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: coordinator.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 54, weight: .regular))
                        Text(coordinator.isRecording ? "Stop Listening" : "Start Listening")
                            .font(AppTheme.display(size: 27, weight: .semibold))
                        Text(store.settings.isAgentModeEnabled ? store.settings.agentShortcut.title : "Mode: \(store.settings.inputMode.title)")
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

                if store.settings.isAgentModeEnabled {
                    HStack(spacing: 10) {
                    Button {
                        coordinator.toggleAgentRecording()
                    } label: {
                        Label(coordinator.isRecording ? "Stop Agent" : "Agent Command", systemImage: "sparkles")
                    }
                    .buttonStyle(.liquidGlassProminent)

                    Button {
                        coordinator.openAccessibilityApprovalFlow()
                    } label: {
                        Label("Accessibility", systemImage: "lock.open")
                    }
                    }

                    agentHotkeyControls
                }

                if !coordinator.lastTranscript.isEmpty {
                    transcriptPreview(coordinator.lastTranscript)
                }

                if !coordinator.lastError.isEmpty {
                    Text(coordinator.lastError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var deviceStatusPanel: some View {
        AppPanel {
            VStack(spacing: 0) {
                SectionTitle(title: "Status", systemImage: "checklist")
                    .padding(.bottom, 8)
                DetailRow(title: "State", value: coordinator.status)
                DetailRow(title: "Microphone", value: coordinator.activeMicrophoneStatus, tint: .blue)
                DetailRow(title: "Remote", value: coordinator.remoteConnectionStatus, tint: coordinator.remoteConnectionStatus.hasPrefix("Connected") ? .green : .orange)
                DetailRow(title: "Remote mic relay", value: coordinator.remoteMicRelayStatus)
                DetailRow(title: "Last recording", value: coordinator.lastRecordingStatus)
                DetailRow(title: "Paste target", value: coordinator.pasteTargetStatus)

                Divider()
                    .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Siri-button push-to-talk")
                        .font(AppTheme.mono(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                    Text("Hold the Siri button to record from the microphone selected in Settings. macOS reserves the Siri Remote’s Bluetooth audio stream for Apple system services, so standalone apps cannot receive that stream directly.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tuningPanel: some View {
        AppPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Remote Tuning", systemImage: "slider.horizontal.3")
                Slider(value: $store.settings.remoteSensitivity, in: AppSettings.minRemoteSensitivity...AppSettings.maxRemoteSensitivity) {
                    Text("Pointer speed")
                }
                .liquidGlassSlider()
                Slider(value: $store.settings.scrollSensitivity, in: 1...40) {
                    Text("Scroll speed")
                }
                .liquidGlassSlider()
                Slider(value: $store.settings.swipeSensitivity, in: AppSettings.minSwipeSensitivity...AppSettings.maxSwipeSensitivity) {
                    Text("Swipe gesture sensitivity")
                }
                .liquidGlassSlider()
            }
        }
    }

    private var agentHotkeyControls: some View {
        HStack(spacing: 10) {
            Label(store.settings.agentShortcut.title, systemImage: "keyboard")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button(coordinator.isCapturingShortcut ? "Recording..." : "Record Agent Hotkey") {
                coordinator.beginShortcutCapture(kind: .agent)
            }
            .disabled(coordinator.isCapturingShortcut)

            Button("Clear") {
                coordinator.clearShortcut(kind: .agent)
            }
        }
        .controlSize(.small)
        .padding(12)
        .glassWell()
    }

    @ViewBuilder
    private func transcriptPreview(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Last Transcript")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .glassWell()
    }
}
