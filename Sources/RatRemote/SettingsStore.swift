import Combine
import Foundation
import Security

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { save() }
    }

    private let url: URL
    private var lastSavedSecrets = SettingsSecrets()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RatRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        if let existingFiles = try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil) {
            for file in existingFiles {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        self.url = support.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            var settings = decoded
            settings.applySecureSecrets(fallingBackTo: decoded.secureSecrets)
            settings.speechLocaleIdentifier = SpeechLocaleOption.normalizedIdentifier(settings.speechLocaleIdentifier)
            settings.remoteSensitivity = AppSettings.normalizedRemoteSensitivity(settings.remoteSensitivity)
            print("[SettingsStore] loaded settings.json, remoteSensitivity=\(settings.remoteSensitivity)")
            self.settings = settings
            save()
        } else {
            print("[SettingsStore] no saved settings, using defaults")
            var settings = AppSettings()
            settings.applySecureSecrets(fallingBackTo: SettingsSecrets())
            self.settings = settings
            save()
        }
    }

    private func save() {
        let secrets = settings.secureSecrets
        var persistedSettings = settings
        if secrets != lastSavedSecrets {
            if KeychainSettings.store(secrets.transcriptionAPIKey, account: "transcription-api-key") {
                lastSavedSecrets.transcriptionAPIKey = secrets.transcriptionAPIKey
                persistedSettings.transcriptionAPIKey = ""
            }
            if KeychainSettings.store(secrets.inferenceAPIKey, account: "inference-api-key") {
                lastSavedSecrets.inferenceAPIKey = secrets.inferenceAPIKey
                persistedSettings.inferenceAPIKey = ""
            }
            if KeychainSettings.store(secrets.computerUseAPIKey, account: "computer-use-api-key") {
                lastSavedSecrets.computerUseAPIKey = secrets.computerUseAPIKey
                persistedSettings.computerUseAPIKey = ""
            }
        } else {
            persistedSettings.transcriptionAPIKey = ""
            persistedSettings.inferenceAPIKey = ""
            persistedSettings.computerUseAPIKey = ""
        }
        guard let data = try? JSONEncoder().encode(persistedSettings) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private struct SettingsSecrets: Equatable {
    var transcriptionAPIKey = ""
    var inferenceAPIKey = ""
    var computerUseAPIKey = ""
}

private extension AppSettings {
    var secureSecrets: SettingsSecrets {
        SettingsSecrets(
            transcriptionAPIKey: transcriptionAPIKey,
            inferenceAPIKey: inferenceAPIKey,
            computerUseAPIKey: computerUseAPIKey
        )
    }

    mutating func applySecureSecrets(fallingBackTo fallback: SettingsSecrets) {
        transcriptionAPIKey = KeychainSettings.read(account: "transcription-api-key") ?? fallback.transcriptionAPIKey
        inferenceAPIKey = KeychainSettings.read(account: "inference-api-key") ?? fallback.inferenceAPIKey
        computerUseAPIKey = KeychainSettings.read(account: "computer-use-api-key") ?? fallback.computerUseAPIKey
    }
}

private enum KeychainSettings {
    private static let service = Bundle.main.bundleIdentifier ?? "RatRemote"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func store(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return false
    }
}
