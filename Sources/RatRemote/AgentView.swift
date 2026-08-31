import SwiftUI

struct AgentView: View {
    @ObservedObject var coordinator: RemoteCoordinator
    @ObservedObject var store: SettingsStore

    @State private var showsWindowSelector = false

    var body: some View {
        ScrollView {
            content
        }
        .scrollContentBackground(.hidden)
    }

    private var content: some View {
        VStack(spacing: 18) {
                PageIntro(
                    index: "03",
                    eyebrow: "Agent",
                    title: "Set the goal.",
                    accent: "Watch it happen.",
                    description: "A bounded observe–plan–act loop with a separate cursor and human approval exactly where it matters."
                )
                automationPanel
        }
        .frame(maxWidth: .infinity)
        .padding(22)
    }

    private var automationPanel: some View {
        AppPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Automation Loop", systemImage: "repeat")

                if coordinator.isAutomationRunning,
                   let orbState = coordinator.activityOrbState {
                    HStack(spacing: 14) {
                        ThinkingOrb(state: orbState, size: 64)
                            .contentTransition(.opacity)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(coordinator.activityOrbLabel ?? "Working\u{2026}")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Step \(coordinator.automationStepCount) of \(store.settings.automationMaxSteps)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .glassWell()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Target")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(coordinator.selectedWindowTitle)
                            .font(.system(size: 13))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        coordinator.refreshWindowTargets()
                        showsWindowSelector = true
                    } label: {
                        Label("Choose Window", systemImage: "rectangle.on.rectangle")
                    }
                }
                .padding(12)
                .glassWell()
                .sheet(isPresented: $showsWindowSelector) {
                    WindowTargetPickerView(coordinator: coordinator)
                }

                TextField("Instruction", text: $coordinator.automationInstructionText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...10)
                    .disabled(coordinator.isAutomationRunning)

                HStack(spacing: 10) {
                    Button {
                        if coordinator.isAutomationRunning {
                            coordinator.stopAutomation()
                        } else {
                            coordinator.startAutomationFromInstructionBox()
                        }
                    } label: {
                        Label(coordinator.isAutomationRunning ? "Stop Loop" : "Start Loop", systemImage: coordinator.isAutomationRunning ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.liquidGlassProminent)

                    Button {
                        coordinator.approvePendingAutomationStep()
                    } label: {
                        Label("Run Suggested Step", systemImage: "checkmark.circle")
                    }
                    .disabled(!coordinator.hasPendingAutomationApproval || coordinator.isAutomationRunning)

                    Button {
                        coordinator.allowAllPendingAutomationSteps()
                    } label: {
                        Label("Allow All", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(!coordinator.hasPendingAutomationApproval || coordinator.isAutomationRunning)

                    Button {
                        coordinator.clearPendingAutomationStep()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .disabled(!coordinator.hasPendingAutomationApproval || coordinator.isAutomationRunning)
                    .help("Clear suggested step")
                }

                VStack(spacing: 0) {
                    DetailRow(title: "Loop", value: coordinator.automationStatus)
                    DetailRow(title: "Cursor", value: coordinator.agentCursorStatus)
                    DetailRow(title: "Step", value: "\(coordinator.automationStepCount)/\(store.settings.automationMaxSteps)")
                    if !coordinator.automationLastSummary.isEmpty {
                        DetailRow(title: "Decision", value: coordinator.automationLastSummary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Slider(value: automationMaxStepsSliderBinding, in: 0...1) {
                        Text("Max steps: \(store.settings.automationMaxSteps)")
                    } minimumValueLabel: {
                        Text("\(AppSettings.minAutomationMaxSteps)")
                    } maximumValueLabel: {
                        Text("\(AppSettings.maxAutomationMaxSteps)")
                    }
                    .liquidGlassSlider()
                    Toggle("Allow all approval prompts", isOn: $store.settings.automationAllowAllApprovals)
                    Toggle("Separate agent cursor", isOn: $store.settings.useSeparateAgentCursor)
                        .help("When a window target is selected, send input directly to that app while drawing a separate agent cursor.")
                    if let note = coordinator.agentInputCompatibilityNote {
                        Text(note)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Slider(value: $store.settings.automationStepDelay, in: AppSettings.minAutomationStepDelay...AppSettings.maxAutomationStepDelay) {
                        Text("Step delay")
                    } minimumValueLabel: {
                        Text("0.2s")
                    } maximumValueLabel: {
                        Text("10s")
                    }
                    .liquidGlassSlider()
                }
                .font(.system(size: 12))
            }
            .animation(.easeOut(duration: 0.2), value: coordinator.isAutomationRunning)
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

}

struct WindowTargetPickerView: View {
    @ObservedObject var coordinator: RemoteCoordinator
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose Window")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Only the selected window is sent to the agent.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    coordinator.refreshWindowTargets()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh windows")

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close")
            }
            .padding(18)
            .background(AppTheme.headerMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppTheme.glassStroke)
                    .frame(height: 1)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    WindowTargetCard(
                        title: "Entire display",
                        subtitle: "All visible screens",
                        thumbnail: nil,
                        systemImage: "display",
                        isSelected: coordinator.selectedWindowTarget == nil
                    ) {
                        coordinator.selectWindowTarget(nil)
                        dismiss()
                    }

                    ForEach(coordinator.availableWindowTargets) { target in
                        WindowTargetCard(
                            title: target.shortTitle,
                            subtitle: target.appName,
                            thumbnail: target.thumbnail,
                            systemImage: "macwindow",
                            isSelected: coordinator.selectedWindowTarget?.id == target.id
                        ) {
                            coordinator.selectWindowTarget(target)
                            dismiss()
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 760, height: 560)
        .foregroundStyle(AppTheme.cream)
        .tint(AppTheme.interactiveAccent)
        .preferredColorScheme(.dark)
        .background(BlueprintBackdrop())
        .onAppear {
            coordinator.refreshWindowTargets()
        }
    }
}

private struct WindowTargetCard: View {
    let title: String
    let subtitle: String
    let thumbnail: NSImage?
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.16))

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(.secondary)
                    }

                    if isSelected {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(8)
                            }
                            Spacer()
                        }
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.cream)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nativeGlass(cornerRadius: 10, tint: isSelected ? AppTheme.interactiveAccent.opacity(0.16) : nil)
    }
}
