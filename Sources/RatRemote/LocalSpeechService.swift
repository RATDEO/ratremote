import AVFoundation
import Foundation
@preconcurrency import Speech

enum LocalSpeechError: LocalizedError {
    case authorizationDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Speech recognition permission is not enabled."
        case .recognizerUnavailable:
            "Apple speech recognition is not available for this locale."
        case .onDeviceRecognitionUnavailable:
            "On-device recognition is not available for this locale on this Mac."
        case .emptyResult:
            "Apple speech recognition returned no text."
        }
    }
}

final class LocalSpeechService: @unchecked Sendable {
    func authorizationStatusDescription() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            "Granted"
        case .notDetermined:
            "Not requested"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        @unknown default:
            "Unknown"
        }
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(audioURL: URL, localeIdentifier: String) async throws -> String {
        let localeIdentifier = SpeechLocaleOption.normalizedIdentifier(localeIdentifier)
        guard await requestAuthorization() else {
            throw LocalSpeechError.authorizationDenied
        }

        if #available(macOS 26.0, *) {
            do {
                let text = try await transcribeWithDictationTranscriber(
                    audioURL: audioURL,
                    localeIdentifier: localeIdentifier
                )
                if !text.isEmpty { return text }
            } catch {
                let fallback = try await transcribeWithLegacyRecognizer(
                    audioURL: audioURL,
                    localeIdentifier: localeIdentifier
                )
                if !fallback.isEmpty { return fallback }
                throw error
            }
        }

        return try await transcribeWithLegacyRecognizer(
            audioURL: audioURL,
            localeIdentifier: localeIdentifier
        )
    }

    @available(macOS 26.0, *)
    private func transcribeWithDictationTranscriber(audioURL: URL, localeIdentifier: String) async throws -> String {
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw LocalSpeechError.onDeviceRecognitionUnavailable
        }
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm, .farField],
            transcriptionOptions: [.punctuation],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence]
        )

        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported {
            throw LocalSpeechError.onDeviceRecognitionUnavailable
        }
        if status != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        try await AssetInventory.reserve(locale: locale)

        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .lingering)
        )

        let resultTask = Task {
            var finalPieces: [String] = []
            var candidates: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                candidates.append(text)
                if result.isFinal {
                    finalPieces.append(text)
                }
            }
            let joinedFinals = finalPieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let longestCandidate = candidates.max { $0.count < $1.count } ?? ""

            if joinedFinals.count >= longestCandidate.count {
                return joinedFinals
            }
            return longestCandidate
        }

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let text = try await resultTask.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw LocalSpeechError.emptyResult }
            return text
        } catch {
            resultTask.cancel()
            throw error
        }
    }

    private func transcribeWithLegacyRecognizer(audioURL: URL, localeIdentifier: String) async throws -> String {
        let locale = Locale(identifier: SpeechLocaleOption.normalizedIdentifier(localeIdentifier))
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw LocalSpeechError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw LocalSpeechError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var latestText = ""
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error, !didResume {
                    didResume = true
                    if latestText.isEmpty {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: latestText)
                    }
                    return
                }

                guard let result, !didResume else { return }
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    latestText = text
                }
                guard result.isFinal else { return }
                didResume = true
                if latestText.isEmpty {
                    continuation.resume(throwing: LocalSpeechError.emptyResult)
                } else {
                    continuation.resume(returning: latestText)
                }
            }

            _ = task
        }
    }
}
