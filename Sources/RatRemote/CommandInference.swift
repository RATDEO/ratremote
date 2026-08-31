import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum CommandInferenceError: LocalizedError {
    case providerUnavailable(String)
    case invalidAction(String)
    case allProvidersFailed([String])

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let reason):
            reason
        case .invalidAction(let reason):
            "The command model returned an unsafe or invalid action. \(reason)"
        case .allProvidersFailed(let failures):
            "No command model was available. " + failures.joined(separator: " ")
        }
    }
}

enum CommandActionValidator {
    static func validate(_ response: CommandResponse) throws -> CommandResponse {
        guard response.actions.count <= 4 else {
            throw CommandInferenceError.invalidAction("Too many actions were requested.")
        }

        let validated = try response.actions.map { action in
            switch action.type {
            case .keyPress:
                let rawKey = action.key ?? action.text
                guard let rawKey,
                      let key = LocalCommandParser.canonicalKeyName(for: rawKey.lowercased()) else {
                    throw CommandInferenceError.invalidAction("A key press did not contain a valid key.")
                }
                let allowedModifiers = Set(["command", "control", "option", "shift"])
                guard Set(action.modifiers ?? []).isSubset(of: allowedModifiers) else {
                    throw CommandInferenceError.invalidAction("A key press contained an unknown modifier.")
                }
                return RemoteAction(
                    type: .keyPress,
                    text: nil,
                    key: key,
                    modifiers: action.modifiers,
                    url: nil,
                    x: nil,
                    y: nil,
                    amount: nil
                )
            case .pasteText:
                guard let text = action.text, text.count <= 8_000 else {
                    throw CommandInferenceError.invalidAction("Pasted text was missing or too long.")
                }
            case .openURL:
                guard let rawURL = action.url,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) else {
                    throw CommandInferenceError.invalidAction("Only HTTP and HTTPS URLs can be opened.")
                }
            case .openApplication:
                guard let text = action.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text.count <= 200 else {
                    throw CommandInferenceError.invalidAction("An application name was missing or too long.")
                }
            case .closeWindow, .quitApplication:
                if let text = action.text, text.count > 200 {
                    throw CommandInferenceError.invalidAction("An application name was too long.")
                }
            case .scroll, .swipe:
                for value in [action.x, action.y, action.amount].compactMap({ $0 }) where !value.isFinite || abs(value) > 1_000 {
                    throw CommandInferenceError.invalidAction("A gesture amount was outside the supported range.")
                }
            case .wait:
                guard let amount = action.amount, amount.isFinite, (0...10).contains(amount) else {
                    throw CommandInferenceError.invalidAction("A wait duration was outside the supported range.")
                }
            case .locateAndClick:
                guard let text = action.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text.count <= 500 else {
                    throw CommandInferenceError.invalidAction("A visual target description was invalid.")
                }
            case .click, .moveMouse, .runAppleScript, .typeText:
                throw CommandInferenceError.invalidAction("\(action.type.rawValue) is not enabled for on-device models.")
            }
            return action
        }

        return CommandResponse(actions: validated, spokenSummary: response.spokenSummary)
    }
}

@MainActor
final class CommandInferenceRouter {
    private let remoteClient: InferenceClient
    private let localModel: LocalModelManager
    private let appleProvider = AppleIntelligenceCommandProvider()

    init(remoteClient: InferenceClient, localModel: LocalModelManager) {
        self.remoteClient = remoteClient
        self.localModel = localModel
    }

    func command(request: CommandRequest, settings: AppSettings) async throws -> CommandResponse {
        switch settings.commandModelProvider {
        case .remoteServer:
            return try await remote(request: request, settings: settings)
        case .localGemma:
            return try await local(request: request)
        case .appleIntelligence:
            return try await apple(request: request)
        case .automatic:
            return try await automatic(request: request, settings: settings)
        }
    }

    private func automatic(request: CommandRequest, settings: AppSettings) async throws -> CommandResponse {
        var failures: [String] = []

        if appleProvider.isAvailable {
            do { return try await apple(request: request) }
            catch { failures.append("Apple Intelligence: \(error.localizedDescription)") }
        }

        if localModel.isModelInstalled, localModel.runtimeURL != nil {
            do { return try await local(request: request) }
            catch { failures.append("Local Gemma: \(error.localizedDescription)") }
        }

        do { return try await remote(request: request, settings: settings) }
        catch { failures.append("Remote server: \(error.localizedDescription)") }

        throw CommandInferenceError.allProvidersFailed(failures)
    }

    private func remote(request: CommandRequest, settings: AppSettings) async throws -> CommandResponse {
        try await remoteClient.command(
            text: request.text,
            screenshotBase64: request.screenshotBase64,
            screenContext: request.screenContext,
            serverURL: settings.inferenceServerURL,
            apiKey: settings.inferenceAPIKey,
            agentMode: request.agentMode ?? false
        )
    }

    private func local(request: CommandRequest) async throws -> CommandResponse {
        let endpoint = try await localModel.ensureRunning()
        let response = try await remoteClient.localCommand(
            text: request.text,
            screenContext: request.screenContext,
            serverURL: endpoint
        )
        return try CommandActionValidator.validate(response)
    }

    private func apple(request: CommandRequest) async throws -> CommandResponse {
        try CommandActionValidator.validate(await appleProvider.command(request))
    }
}

@MainActor
final class AppleIntelligenceCommandProvider {
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    var availabilityDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Ready"
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is not enabled"
            case .unavailable(.deviceNotEligible):
                return "This Mac is not eligible"
            case .unavailable(.modelNotReady):
                return "The on-device model is not ready"
            case .unavailable:
                return "Unavailable"
            }
        }
        #endif
        return "Requires macOS 26 or later"
    }

    func command(_ request: CommandRequest) async throws -> CommandResponse {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard isAvailable else {
                throw CommandInferenceError.providerUnavailable(availabilityDescription)
            }
            return try await generateCommand(request)
        }
        #endif
        throw CommandInferenceError.providerUnavailable(availabilityDescription)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generateCommand(_ request: CommandRequest) async throws -> CommandResponse {
        let session = LanguageModelSession(instructions: Self.instructions)
        let context = request.screenContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = if let context, !context.isEmpty {
            "Screen context: \(context)\n\nUser request: \(request.text)"
        } else {
            request.text
        }
        let response = try await session.respond(to: prompt, generating: AppleCommandPlan.self)
        let actions = response.content.actions.compactMap(\.remoteAction)
        return CommandResponse(actions: actions, spokenSummary: response.content.spokenSummary)
    }

    private static let instructions = """
    Convert a spoken Mac command into a short list of actions. Return no actions when the request is not a computer-control instruction. Prefer direct keyboard, application, URL, text, scrolling, and window actions. Use locateAndClick only for a named visible interface target. Never invent an application, URL, key, or text. Never generate scripts or raw screen coordinates. Return at most four actions.
    """
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct AppleCommandPlan {
    @Guide(description: "Zero to four safe Mac actions in execution order", .count(0...4))
    var actions: [AppleCommandAction]
    @Guide(description: "A very short optional summary")
    var spokenSummary: String?
}

@available(macOS 26.0, *)
@Generable
private struct AppleCommandAction {
    @Guide(description: "The action to execute")
    var type: AppleCommandActionType
    @Guide(description: "Literal text, application name, gesture direction, or visual target")
    var text: String?
    @Guide(description: "A single key name such as return, space, left, or a letter")
    var key: String?
    @Guide(description: "Keyboard modifiers: command, control, option, or shift")
    var modifiers: [String]?
    @Guide(description: "A complete http or https URL")
    var url: String?
    @Guide(description: "Scroll horizontal amount")
    var x: Double?
    @Guide(description: "Scroll vertical amount")
    var y: Double?
    @Guide(description: "Wait seconds or gesture amount")
    var amount: Double?

    var remoteAction: RemoteAction? {
        let actionType: ActionType = switch type {
        case .keyPress: .keyPress
        case .pasteText: .pasteText
        case .openURL: .openURL
        case .openApplication: .openApplication
        case .locateAndClick: .locateAndClick
        case .closeWindow: .closeWindow
        case .quitApplication: .quitApplication
        case .wait: .wait
        case .scroll: .scroll
        case .swipe: .swipe
        }
        return RemoteAction(type: actionType, text: text, key: key, modifiers: modifiers, url: url, x: x, y: y, amount: amount)
    }
}

@available(macOS 26.0, *)
@Generable
private enum AppleCommandActionType: String {
    case keyPress
    case pasteText
    case openURL
    case openApplication
    case locateAndClick
    case closeWindow
    case quitApplication
    case wait
    case scroll
    case swipe
}
#endif
