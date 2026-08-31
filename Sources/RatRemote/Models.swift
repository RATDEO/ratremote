import Foundation

enum InputMode: String, CaseIterable, Codable, Identifiable {
    case command
    case dictation
    case vision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command: "Command"
        case .dictation: "Dictation"
        case .vision: "Vision"
        }
    }
}

enum SpeechEngine: String, CaseIterable, Codable, Identifiable {
    case appleOnDevice
    case remoteServer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleOnDevice: "Apple on-device"
        case .remoteServer: "Remote server"
        }
    }
}

enum CommandModelProvider: String, CaseIterable, Codable, Identifiable {
    case automatic
    case remoteServer
    case localGemma
    case appleIntelligence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .remoteServer: "Remote server"
        case .localGemma: "Local Gemma 4 E2B"
        case .appleIntelligence: "Apple Intelligence"
        }
    }
}

enum AppShortcutKind {
    case dictation
    case agent
}

struct SpeechLocaleOption: Identifiable, Hashable {
    let id: String
    let title: String

    static let options: [SpeechLocaleOption] = [
        .init(id: "en_GB", title: "English (UK)"),
        .init(id: "en_US", title: "English (US)"),
        .init(id: "en_AU", title: "English (Australia)"),
        .init(id: "en_CA", title: "English (Canada)"),
        .init(id: "fr_FR", title: "French (France)"),
        .init(id: "de_DE", title: "German (Germany)"),
        .init(id: "es_ES", title: "Spanish (Spain)"),
        .init(id: "it_IT", title: "Italian (Italy)"),
        .init(id: "ja_JP", title: "Japanese (Japan)")
    ]

    static func normalizedIdentifier(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }

        let current = Locale.current.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.isEmpty ? "en_GB" : current
    }
}

enum LegacyLocalTranscriptionShortcut: String, Codable {
    case controlOptionSpace
    case commandShiftSpace
    case controlOptionD
    case controlOptionR
    case f13
    case disabled
}

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt16?
    var modifierFlags: UInt
    var title: String

    static let defaultTranscription = KeyboardShortcut(
        keyCode: 49,
        modifierFlags: 786_432,
        title: "Control-Option-Space"
    )

    static let defaultAgent = KeyboardShortcut(
        keyCode: 49,
        modifierFlags: 1_572_864,
        title: "Command-Option-Space"
    )

    static let disabled = KeyboardShortcut(keyCode: nil, modifierFlags: 0, title: "Disabled")

    var isEnabled: Bool {
        keyCode != nil
    }
}

struct AppSettings: Codable, Equatable {
    static let minRemoteSensitivity = 0.2
    static let maxRemoteSensitivity = 1.0
    static let defaultRemoteSensitivity = 0.45
    static let minSwipeSensitivity = 0.25
    static let maxSwipeSensitivity = 4.0
    static let defaultSwipeSensitivity = 1.0
    static let minAutomationMaxSteps = 1
    static let maxAutomationMaxSteps = 100
    static let defaultAutomationMaxSteps = 12
    static let automationRuntimeLimitSeconds: TimeInterval = 20 * 60
    static let maxConsecutiveWaitOnlyAutomationSteps = 3
    static let minAutomationStepDelay = 0.2
    static let maxAutomationStepDelay = 10.0
    static let defaultAutomationStepDelay = 1.2

    var transcriptionServerURL: String = "http://127.0.0.1:8787"
    var transcriptionAPIKey: String = ""
    var inferenceServerURL: String = "http://127.0.0.1:8787"
    var inferenceAPIKey: String = ""
    var commandModelProvider: CommandModelProvider = .automatic
    var computerUseServerURL: String = "http://127.0.0.1:8787"
    var computerUseAPIKey: String = ""
    var inputMode: InputMode = .dictation
    var speechEngine: SpeechEngine = .appleOnDevice
    var speechLocaleIdentifier: String = SpeechLocaleOption.normalizedIdentifier(Locale.current.identifier)
    var microphoneDeviceID: String = ""
    var remoteSensitivity: Double = Self.defaultRemoteSensitivity
    var scrollSensitivity: Double = 10
    var swipeSensitivity: Double = Self.defaultSwipeSensitivity
    var automationMaxSteps: Int = Self.defaultAutomationMaxSteps
    var automationStepDelay: Double = Self.defaultAutomationStepDelay
    var automationAllowAllApprovals: Bool = false
    var useSeparateAgentCursor: Bool = false
    var isAgentModeEnabled: Bool = false
    var dictationShortcut: KeyboardShortcut = .defaultTranscription
    var agentShortcut: KeyboardShortcut = .defaultAgent
    var pasteDictation: Bool = true
    var includeScreenContextForCommands: Bool = false
    var speakOnPlayPause: Bool = false
    var clickVisionResult: Bool = true

    enum CodingKeys: String, CodingKey {
        case transcriptionServerURL
        case transcriptionAPIKey
        case inferenceServerURL
        case inferenceAPIKey
        case commandModelProvider
        case computerUseServerURL
        case computerUseAPIKey
        case inputMode
        case speechEngine
        case speechLocaleIdentifier
        case microphoneDeviceID
        case remoteSensitivity
        case scrollSensitivity
        case swipeSensitivity
        case automationMaxSteps
        case automationStepDelay
        case automationAllowAllApprovals
        case useSeparateAgentCursor
        case isAgentModeEnabled
        case dictationShortcut
        case agentShortcut
        case pasteDictation
        case includeScreenContextForCommands
        case speakOnPlayPause
        case clickVisionResult
    }

    enum LegacyCodingKeys: String, CodingKey {
        case serverURL
        case transcriptionAPIKey
        case inferenceAPIKey
        case computerUseAPIKey
        case localTranscriptionShortcut
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyServerURL = try legacyContainer.decodeIfPresent(String.self, forKey: .serverURL)
        transcriptionServerURL = try container.decodeIfPresent(String.self, forKey: .transcriptionServerURL) ?? legacyServerURL ?? transcriptionServerURL
        inferenceServerURL = try container.decodeIfPresent(String.self, forKey: .inferenceServerURL) ?? legacyServerURL ?? inferenceServerURL
        computerUseServerURL = try container.decodeIfPresent(String.self, forKey: .computerUseServerURL) ?? legacyServerURL ?? computerUseServerURL
        transcriptionAPIKey = try container.decodeIfPresent(String.self, forKey: .transcriptionAPIKey) ?? legacyContainer.decodeIfPresent(String.self, forKey: .transcriptionAPIKey) ?? ""
        inferenceAPIKey = try container.decodeIfPresent(String.self, forKey: .inferenceAPIKey) ?? legacyContainer.decodeIfPresent(String.self, forKey: .inferenceAPIKey) ?? ""
        commandModelProvider = try container.decodeIfPresent(CommandModelProvider.self, forKey: .commandModelProvider) ?? commandModelProvider
        computerUseAPIKey = try container.decodeIfPresent(String.self, forKey: .computerUseAPIKey) ?? legacyContainer.decodeIfPresent(String.self, forKey: .computerUseAPIKey) ?? ""
        inputMode = try container.decodeIfPresent(InputMode.self, forKey: .inputMode) ?? inputMode
        speechEngine = try container.decodeIfPresent(SpeechEngine.self, forKey: .speechEngine) ?? speechEngine
        speechLocaleIdentifier = SpeechLocaleOption.normalizedIdentifier(
            try container.decodeIfPresent(String.self, forKey: .speechLocaleIdentifier) ?? speechLocaleIdentifier
        )
        microphoneDeviceID = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceID) ?? microphoneDeviceID
        remoteSensitivity = Self.normalizedRemoteSensitivity(
            try container.decodeIfPresent(Double.self, forKey: .remoteSensitivity) ?? remoteSensitivity
        )
        print("[Settings] loaded remoteSensitivity=\(String(format: "%.6f", remoteSensitivity))")
        scrollSensitivity = try container.decodeIfPresent(Double.self, forKey: .scrollSensitivity) ?? scrollSensitivity
        swipeSensitivity = Self.normalizedSwipeSensitivity(
            try container.decodeIfPresent(Double.self, forKey: .swipeSensitivity) ?? swipeSensitivity
        )
        automationMaxSteps = Self.normalizedAutomationMaxSteps(
            try container.decodeIfPresent(Int.self, forKey: .automationMaxSteps) ?? automationMaxSteps
        )
        automationStepDelay = Self.normalizedAutomationStepDelay(
            try container.decodeIfPresent(Double.self, forKey: .automationStepDelay) ?? automationStepDelay
        )
        automationAllowAllApprovals = try container.decodeIfPresent(Bool.self, forKey: .automationAllowAllApprovals) ?? automationAllowAllApprovals
        useSeparateAgentCursor = try container.decodeIfPresent(Bool.self, forKey: .useSeparateAgentCursor) ?? useSeparateAgentCursor
        isAgentModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAgentModeEnabled) ?? isAgentModeEnabled
        if let shortcut = try? container.decodeIfPresent(KeyboardShortcut.self, forKey: .dictationShortcut) {
            dictationShortcut = shortcut
        } else if let shortcut = try? legacyContainer.decodeIfPresent(KeyboardShortcut.self, forKey: .localTranscriptionShortcut) {
            dictationShortcut = shortcut
        } else if let legacy = try? legacyContainer.decodeIfPresent(LegacyLocalTranscriptionShortcut.self, forKey: .localTranscriptionShortcut) {
            dictationShortcut = Self.shortcut(from: legacy)
        }
        agentShortcut = (try? container.decodeIfPresent(KeyboardShortcut.self, forKey: .agentShortcut)) ?? agentShortcut
        pasteDictation = try container.decodeIfPresent(Bool.self, forKey: .pasteDictation) ?? pasteDictation
        includeScreenContextForCommands = try container.decodeIfPresent(Bool.self, forKey: .includeScreenContextForCommands) ?? includeScreenContextForCommands
        speakOnPlayPause = try container.decodeIfPresent(Bool.self, forKey: .speakOnPlayPause) ?? speakOnPlayPause
        clickVisionResult = try container.decodeIfPresent(Bool.self, forKey: .clickVisionResult) ?? clickVisionResult
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcriptionServerURL, forKey: .transcriptionServerURL)
        try container.encode(transcriptionAPIKey, forKey: .transcriptionAPIKey)
        try container.encode(inferenceServerURL, forKey: .inferenceServerURL)
        try container.encode(inferenceAPIKey, forKey: .inferenceAPIKey)
        try container.encode(commandModelProvider, forKey: .commandModelProvider)
        try container.encode(computerUseServerURL, forKey: .computerUseServerURL)
        try container.encode(computerUseAPIKey, forKey: .computerUseAPIKey)
        try container.encode(inputMode, forKey: .inputMode)
        try container.encode(speechEngine, forKey: .speechEngine)
        try container.encode(speechLocaleIdentifier, forKey: .speechLocaleIdentifier)
        try container.encode(microphoneDeviceID, forKey: .microphoneDeviceID)
        try container.encode(remoteSensitivity, forKey: .remoteSensitivity)
        try container.encode(scrollSensitivity, forKey: .scrollSensitivity)
        try container.encode(swipeSensitivity, forKey: .swipeSensitivity)
        try container.encode(automationMaxSteps, forKey: .automationMaxSteps)
        try container.encode(automationStepDelay, forKey: .automationStepDelay)
        try container.encode(automationAllowAllApprovals, forKey: .automationAllowAllApprovals)
        try container.encode(useSeparateAgentCursor, forKey: .useSeparateAgentCursor)
        try container.encode(isAgentModeEnabled, forKey: .isAgentModeEnabled)
        try container.encode(dictationShortcut, forKey: .dictationShortcut)
        try container.encode(agentShortcut, forKey: .agentShortcut)
        try container.encode(pasteDictation, forKey: .pasteDictation)
        try container.encode(includeScreenContextForCommands, forKey: .includeScreenContextForCommands)
        try container.encode(speakOnPlayPause, forKey: .speakOnPlayPause)
        try container.encode(clickVisionResult, forKey: .clickVisionResult)
    }

    private static func shortcut(from legacy: LegacyLocalTranscriptionShortcut) -> KeyboardShortcut {
        switch legacy {
        case .controlOptionSpace:
            .defaultTranscription
        case .commandShiftSpace:
            KeyboardShortcut(keyCode: 49, modifierFlags: 1_179_648, title: "Command-Shift-Space")
        case .controlOptionD:
            KeyboardShortcut(keyCode: 2, modifierFlags: 786_432, title: "Control-Option-D")
        case .controlOptionR:
            KeyboardShortcut(keyCode: 15, modifierFlags: 786_432, title: "Control-Option-R")
        case .f13:
            KeyboardShortcut(keyCode: 105, modifierFlags: 0, title: "F13")
        case .disabled:
            .disabled
        }
    }

    static func normalizedRemoteSensitivity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultRemoteSensitivity }
        if value < minRemoteSensitivity || value > maxRemoteSensitivity {
            return defaultRemoteSensitivity
        }
        return value
    }

    static func normalizedSwipeSensitivity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSwipeSensitivity }
        if value < minSwipeSensitivity || value > maxSwipeSensitivity {
            return defaultSwipeSensitivity
        }
        return value
    }

    static func normalizedAutomationMaxSteps(_ value: Int) -> Int {
        min(max(value, minAutomationMaxSteps), maxAutomationMaxSteps)
    }

    static func automationMaxStepsSliderValue(for steps: Int) -> Double {
        let normalized = Double(normalizedAutomationMaxSteps(steps))
        let minValue = Double(minAutomationMaxSteps)
        let maxValue = Double(maxAutomationMaxSteps)
        guard maxValue > minValue, normalized > minValue else { return 0 }
        return log(normalized / minValue) / log(maxValue / minValue)
    }

    static func automationMaxSteps(fromSliderValue value: Double) -> Int {
        let clamped = Swift.min(Swift.max(value, 0), 1)
        let minValue = Double(minAutomationMaxSteps)
        let maxValue = Double(maxAutomationMaxSteps)
        let raw = minValue * pow(maxValue / minValue, clamped)
        return normalizedAutomationMaxSteps(Int(raw.rounded()))
    }

    static func normalizedAutomationStepDelay(_ value: Double) -> Double {
        guard value.isFinite else { return defaultAutomationStepDelay }
        return min(max(value, minAutomationStepDelay), maxAutomationStepDelay)
    }
}

struct TranscriptionRequest: Codable {
    let audioBase64: String
    let mimeType: String
    let language: String?
}

struct TranscriptionResponse: Codable {
    let text: String
}

struct CommandRequest: Codable {
    let text: String
    let screenshotBase64: String?
    let agentMode: Bool?
    let screenContext: String?
}

struct CommandResponse: Codable {
    let actions: [RemoteAction]
    let spokenSummary: String?

    init(actions: [RemoteAction], spokenSummary: String? = nil) {
        self.actions = actions
        self.spokenSummary = spokenSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actions = try container.decode([RemoteAction].self, forKey: .actions)
        spokenSummary = try container.decodeIfPresent(FlexibleString.self, forKey: .spokenSummary)?.value
    }

    enum CodingKeys: String, CodingKey {
        case actions, spokenSummary
    }
}

struct AutomationStepRequest: Codable {
    let instruction: String
    let screenshotBase64: String?
    let screenContext: String?
    let stepIndex: Int
    let maxSteps: Int
    let lastActionSummary: String?
}

struct AutomationStepResponse: Codable {
    let actions: [RemoteAction]
    let spokenSummary: String?
    let criteriaSummary: String?
    let shouldContinue: Bool?
    let requiresApproval: Bool?
    let safetyNote: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actions = try container.decode([RemoteAction].self, forKey: .actions)
        spokenSummary = try container.decodeIfPresent(FlexibleString.self, forKey: .spokenSummary)?.value
        criteriaSummary = try container.decodeIfPresent(FlexibleString.self, forKey: .criteriaSummary)?.value
        shouldContinue = try container.decodeIfPresent(Bool.self, forKey: .shouldContinue)
        requiresApproval = try container.decodeIfPresent(Bool.self, forKey: .requiresApproval)
        safetyNote = try container.decodeIfPresent(FlexibleString.self, forKey: .safetyNote)?.value
    }

    enum CodingKeys: String, CodingKey {
        case actions, spokenSummary, criteriaSummary, shouldContinue, requiresApproval, safetyNote
    }
}

struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([String].self) {
            value = array.joined(separator: "\n")
        } else {
            value = ""
        }
    }
}

struct VisionRequest: Codable {
    let prompt: String
    let imageBase64: String
}

struct VisionResponse: Codable {
    let x: Double
    let y: Double
    let confidence: Double?
    let label: String?
}

struct RemoteAction: Codable, Identifiable {
    var id = UUID()
    let type: ActionType
    let text: String?
    let key: String?
    let modifiers: [String]?
    let url: String?
    let x: Double?
    let y: Double?
    let amount: Double?

    enum CodingKeys: String, CodingKey {
        case type, text, key, modifiers, url, x, y, amount
    }
}

enum ActionType: String, Codable {
    case typeText = "type_text"
    case pasteText = "paste_text"
    case keyPress = "key_press"
    case openURL = "open_url"
    case openApplication = "open_app"
    case click
    case locateAndClick = "locate_and_click"
    case closeWindow = "close_window"
    case quitApplication = "quit_app"
    case wait
    case moveMouse = "move_mouse"
    case scroll
    case swipe
    case runAppleScript = "run_applescript"
}
