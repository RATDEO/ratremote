import SwiftUI

struct MainView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var coordinator: RemoteCoordinator
    @ObservedObject var store: SettingsStore

    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            BlueprintBackdrop()

            VStack(spacing: 0) {
                header

                HStack(spacing: 0) {
                    sidebar
                        .zIndex(2)

                    ZStack {
                        if selectedTab == 0 {
                            RemoteView(coordinator: coordinator, store: store)
                                .zIndex(0)
                                .transition(.opacity)
                        } else if selectedTab == 1 {
                            TranscriptionView(coordinator: coordinator, store: store)
                                .zIndex(0)
                                .transition(.opacity)
                        } else {
                            AgentView(coordinator: coordinator, store: store)
                                .zIndex(0)
                                .transition(.opacity)
                        }
                    }
                    .zIndex(0)
                    .animation(.easeOut(duration: 0.18), value: selectedTab)
                }
            }
        }
        .foregroundStyle(AppTheme.cream)
        .tint(AppTheme.interactiveAccent)
        .buttonStyle(.liquidGlass)
        .preferredColorScheme(.dark)
        .background(WindowConfigurator())
        .frame(minWidth: 920, minHeight: 660)
        .onChange(of: store.settings.isAgentModeEnabled) { _, enabled in
            if !enabled, selectedTab == 2 {
                selectedTab = 0
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(AppTheme.cream.opacity(0.22), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 0) {
                        Text("RAT")
                        Text("·")
                            .foregroundStyle(AppTheme.orange)
                        Text("SYSTEMS")
                    }
                    .font(AppTheme.mono(size: 12, weight: .semibold))
                    .tracking(2.1)

                    Text("RAT REMOTE  /  PRODUCT 01")
                        .font(AppTheme.mono(size: 8, weight: .medium))
                        .tracking(1.45)
                        .foregroundStyle(AppTheme.cream.opacity(0.56))
                }
            }

            Rectangle()
                .fill(AppTheme.cream.opacity(0.2))
                .frame(width: 1, height: 38)

            HStack(spacing: 9) {
                if let orbState = coordinator.activityOrbState {
                    ThinkingOrb(state: orbState, size: 22)
                        .transition(.scale.combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(coordinator.activityOrbLabel ?? "CONTROL SURFACE")
                        .font(AppTheme.mono(size: 9, weight: .semibold))
                        .tracking(1.35)
                    Text(coordinator.status)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.cream.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .animation(.easeOut(duration: 0.2), value: coordinator.activityOrbState?.rawValue)

            Spacer()

            StatusChip(
                title: coordinator.remoteConnectionStatus.hasPrefix("Connected") ? "Connected" : coordinator.remoteConnectionStatus,
                systemImage: "dot.radiowaves.left.and.right",
                tint: coordinator.remoteConnectionStatus.hasPrefix("Connected") ? .green : .orange
            )

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open RatRemote Settings")
        }
        .padding(.horizontal, 24)
        .frame(height: 82)
        .background(AppTheme.headerMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.glassStroke)
                .frame(height: 1)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTROL MODES")
                .font(AppTheme.mono(size: 8, weight: .semibold))
                .tracking(1.45)
                .foregroundStyle(AppTheme.cream.opacity(0.48))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            SidebarButton(title: "Remote", systemImage: "appletvremote.gen4", isSelected: selectedTab == 0) {
                selectedTab = 0
            }
            SidebarButton(title: "Dictation", systemImage: "mic", isSelected: selectedTab == 1) {
                selectedTab = 1
            }
            if store.settings.isAgentModeEnabled {
                SidebarButton(title: "Agent", systemImage: "sparkles.rectangle.stack", isSelected: selectedTab == 2) {
                    selectedTab = 2
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text("LOCAL BY DEFAULT")
                Text("TACTILE BY DESIGN")
            }
            .font(AppTheme.mono(size: 7, weight: .medium))
            .tracking(1.1)
            .foregroundStyle(AppTheme.cream.opacity(0.42))
            .padding(.horizontal, 10)

            SidebarStatusIcons(
                microphoneStatus: coordinator.activeMicrophoneStatus,
                accessibilityStatus: coordinator.accessibilityStatus
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 20)
        .frame(width: 172)
        .background(AppTheme.sidebarMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppTheme.glassStroke)
                .frame(width: 1)
        }
    }
}

enum AppTheme {
    static let cobalt = Color(red: 0 / 255, green: 31 / 255, blue: 142 / 255)
    static let cobaltDeep = Color(red: 0 / 255, green: 24 / 255, blue: 115 / 255)
    static let cream = Color(red: 241 / 255, green: 234 / 255, blue: 217 / 255)
    static let paper = Color(red: 247 / 255, green: 242 / 255, blue: 232 / 255)
    static let ink = Color(red: 23 / 255, green: 22 / 255, blue: 19 / 255)
    static let orange = Color(red: 217 / 255, green: 87 / 255, blue: 43 / 255)
    static let interactiveAccent = Color(red: 112 / 255, green: 161 / 255, blue: 1)

    static let windowMaterial = cobalt
    static let headerMaterial = Color.black.opacity(0.13)
    static let sidebarMaterial = cobaltDeep.opacity(0.74)
    static let panelMaterial = Color.white.opacity(0.085)
    static let controlMaterial = Color.white.opacity(0.09)
    static let subtleBackground = cream.opacity(0.075)
    static let glassStroke = cream.opacity(0.20)
    static let separator = cream.opacity(0.13)

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func display(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

struct BlueprintBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(
                Path(bounds),
                with: .linearGradient(
                    Gradient(colors: [AppTheme.cobalt, AppTheme.cobaltDeep]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            let spacing: CGFloat = 16
            let dot = AppTheme.cream.opacity(0.13)
            var x: CGFloat = 8
            while x < size.width {
                var y: CGFloat = 8
                while y < size.height {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.25, height: 1.25)),
                        with: .color(dot)
                    )
                    y += spacing
                }
                x += spacing
            }

            let ringCenter = CGPoint(x: size.width * 0.88, y: size.height * 0.22)
            for diameter in [240.0, 330.0, 460.0] {
                let ring = CGRect(
                    x: ringCenter.x - diameter / 2,
                    y: ringCenter.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.stroke(
                    Path(ellipseIn: ring),
                    with: .color(AppTheme.orange.opacity(diameter == 240 ? 0.20 : 0.09)),
                    lineWidth: 1
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

struct AppPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .nativeGlass(cornerRadius: 18)
    }
}

struct PageIntro: View {
    let index: String
    let eyebrow: String
    let title: String
    let accent: String
    let description: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 28) {
            VStack(alignment: .leading, spacing: 13) {
                Text("\(index)  /  \(eyebrow.uppercased())")
                    .font(AppTheme.mono(size: 9, weight: .semibold))
                    .tracking(1.45)
                    .foregroundStyle(AppTheme.cream.opacity(0.62))

                VStack(alignment: .leading, spacing: -5) {
                    Text(title)
                        .font(AppTheme.display(size: 38, weight: .medium))
                        .fixedSize(horizontal: true, vertical: false)
                    Text(accent)
                        .font(AppTheme.display(size: 38, weight: .medium))
                        .italic()
                        .foregroundStyle(AppTheme.orange)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 20)

            Text(description)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(AppTheme.cream.opacity(0.72))
                .frame(maxWidth: 370, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }
}

struct SectionTitle: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.cream.opacity(0.56))
            }
            Text(title)
                .font(AppTheme.mono(size: 10, weight: .semibold))
                .tracking(1.15)
                .textCase(.uppercase)
            Spacer()
        }
    }
}

struct StatusChip: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Image(systemName: systemImage)
            Text(title)
        }
        .font(AppTheme.mono(size: 9, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(AppTheme.cream)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .nativeGlassCapsule(tint: AppTheme.cream.opacity(0.06))
    }
}

struct SidebarButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AppTheme.cream : AppTheme.cream.opacity(0.72))
        .modifier(SelectedSidebarGlass(isSelected: isSelected))
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(AppTheme.mono(size: 9, weight: .medium))
                .tracking(0.45)
                .foregroundStyle(AppTheme.cream.opacity(0.56))
            Spacer(minLength: 12)
            Text(value.isEmpty ? "None" : value)
                .foregroundStyle(tint ?? AppTheme.cream)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.separator)
                .frame(height: 1)
        }
    }
}

struct SidebarStatusIcons: View {
    let microphoneStatus: String
    let accessibilityStatus: String

    var body: some View {
        HStack(spacing: 10) {
            SidebarStatusIcon(
                systemImage: microphoneImage,
                tint: microphoneTint,
                tooltip: "Microphone: \(displayValue(microphoneStatus))"
            )
            SidebarStatusIcon(
                systemImage: accessibilityImage,
                tint: accessibilityTint,
                tooltip: "Accessibility: \(displayValue(accessibilityStatus))"
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.separator)
                .frame(height: 1)
        }
    }

    private var microphoneImage: String {
        let lower = microphoneStatus.lowercased()
        if lower.contains("idle") { return "mic" }
        if lower.contains("unavailable") || lower.contains("denied") { return "mic.slash" }
        return "mic.fill"
    }

    private var microphoneTint: Color {
        let lower = microphoneStatus.lowercased()
        if lower.contains("unavailable") || lower.contains("denied") { return .red }
        if lower.contains("idle") || lower.contains("default") { return .secondary }
        return .blue
    }

    private var accessibilityImage: String {
        accessibilityStatus.lowercased().contains("granted") ? "accessibility" : "lock.trianglebadge.exclamationmark"
    }

    private var accessibilityTint: Color {
        accessibilityStatus.lowercased().contains("granted") ? .green : .orange
    }

    private func displayValue(_ value: String) -> String {
        value.isEmpty ? "Unknown" : value
    }
}

struct SidebarStatusIcon: View {
    let systemImage: String
    let tint: Color
    let tooltip: String

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.subtleBackground)
                .frame(width: 34, height: 34)
                .overlay {
                    Circle()
                        .stroke(AppTheme.glassStroke, lineWidth: 1)
                }

            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppTheme.cream)
        }
        .frame(width: 34, height: 34, alignment: .center)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle()
                        .stroke(AppTheme.cobaltDeep.opacity(0.9), lineWidth: 1.5)
                }
                .offset(x: -3, y: -3)
        }
        .help(tooltip)
        .accessibilityLabel(Text(tooltip))
    }
}

struct SelectedSidebarGlass: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content.nativeGlass(cornerRadius: 12, tint: AppTheme.cream.opacity(0.10), interactive: true)
        } else {
            content.nativeGlass(cornerRadius: 12, tint: AppTheme.cream.opacity(0.025), interactive: true)
        }
    }
}

enum LiquidGlassButtonProminence {
    case standard
    case prominent
}

struct LiquidGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    var prominence: LiquidGlassButtonProminence = .standard

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .background(fillColor(configuration: configuration), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        AppTheme.cream.opacity(configuration.isPressed ? 0.38 : 0.24),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: Color.black.opacity(configuration.isPressed ? 0.08 : 0.16),
                radius: configuration.isPressed ? 3 : 9,
                y: configuration.isPressed ? 1 : 4
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        prominence == .prominent ? .white : AppTheme.cream
    }

    private func fillColor(configuration: Configuration) -> Color {
        let base = prominence == .prominent
            ? AppTheme.interactiveAccent.opacity(0.42)
            : AppTheme.controlMaterial
        return configuration.isPressed ? base.opacity(0.72) : base
    }
}

extension ButtonStyle where Self == LiquidGlassButtonStyle {
    static var liquidGlass: LiquidGlassButtonStyle {
        LiquidGlassButtonStyle()
    }

    static var liquidGlassProminent: LiquidGlassButtonStyle {
        LiquidGlassButtonStyle(prominence: .prominent)
    }
}

private struct LiquidGlassSliderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .controlSize(.large)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .background(AppTheme.controlMaterial.opacity(0.82), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(AppTheme.glassStroke, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.10), radius: 8, y: 3)
    }
}

struct LiquidGlassPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    let content: Content

    init(
        _ title: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .lineLimit(1)

            Spacer(minLength: 12)

            Picker("", selection: $selection) {
                content
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.large)
            .frame(width: 190)
            .accessibilityLabel(Text(title))
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .background(AppTheme.controlMaterial.opacity(0.82), in: Capsule())
        .overlay {
            Capsule()
                .stroke(AppTheme.glassStroke, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 8, y: 3)
    }
}

extension View {
    @ViewBuilder
    func nativeGlass(cornerRadius: CGFloat = 10, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .allowsHitTesting(false)
                shape
                    .fill(tint ?? AppTheme.panelMaterial)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .stroke(AppTheme.glassStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
    }

    @ViewBuilder
    func nativeGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        self
            .background(.ultraThinMaterial, in: Capsule())
            .background(tint ?? AppTheme.controlMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(AppTheme.glassStroke, lineWidth: 1).allowsHitTesting(false)
            }
    }

    func glassWell(cornerRadius: CGFloat = 10) -> some View {
        nativeGlass(cornerRadius: cornerRadius)
    }

    func liquidGlassSlider() -> some View {
        modifier(LiquidGlassSliderModifier())
    }

}
