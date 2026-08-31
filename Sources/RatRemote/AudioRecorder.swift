import AVFoundation
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct AudioRecordingDiagnostics {
    let duration: Double
    let rms: Double
    let peak: Double

    var isSilent: Bool {
        peak < 0.001 && rms < 0.0001
    }

    var summary: String {
        String(format: "%.1fs, rms %.5f, peak %.5f", duration, rms, peak)
    }
}

enum AudioRecorderError: LocalizedError {
    case microphoneAccessDenied
    case noInputDevice
    case cannotAddInput
    case cannotAddOutput
    case unsupportedOutputType(device: String, supportedTypes: [String])

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            "Microphone access is not enabled. Open Privacy & Security > Microphone and allow RatRemote."
        case .noInputDevice:
            "The selected microphone is not available."
        case .cannotAddInput:
            "RatRemote could not use the selected microphone."
        case .cannotAddOutput:
            "RatRemote could not create an audio recording output."
        case .unsupportedOutputType(let device, let supportedTypes):
            "The selected microphone (\(device)) does not report a supported recording format. Supported types: \(supportedTypes.joined(separator: ", "))."
        }
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var activeInputDeviceName = ""

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var recordingContinuation: CheckedContinuation<URL?, Never>?
    private var recordingURL: URL?

    override init() {
        super.init()
        Self.removeOrphanedRecordings()
        refreshInputDevices()
    }

    func refreshInputDevices() {
        inputDevices = Self.availableInputDevices()
    }

    func remoteMicrophoneDeviceID() -> String? {
        Self.remoteMicrophoneDevice()?.uniqueID
    }

    func start(deviceID: String?) async throws {
        if isRecording { return }

        guard await Self.requestMicrophoneAccess() else {
            throw AudioRecorderError.microphoneAccessDenied
        }

        refreshInputDevices()
        let device = Self.device(for: deviceID) ?? AVCaptureDevice.default(for: .audio)
        guard let device else {
            throw AudioRecorderError.noInputDevice
        }
        activeInputDeviceName = device.localizedName

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AudioRecorderError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureAudioFileOutput()
        guard session.canAddOutput(output) else { throw AudioRecorderError.cannotAddOutput }
        session.addOutput(output)

        let supportedTypes: [AVFileType] = AVCaptureAudioFileOutput.availableOutputFileTypes()
        guard let fileType = Self.bestFileType(from: supportedTypes) else {
            throw AudioRecorderError.unsupportedOutputType(
                device: device.localizedName,
                supportedTypes: supportedTypes.map { $0.rawValue }
            )
        }
        output.audioSettings = Self.audioSettings(for: fileType)

        let url = Self.recordingURL(for: fileType)
        try? FileManager.default.removeItem(at: url)
        session.startRunning()
        output.startRecording(to: url, outputFileType: fileType, recordingDelegate: self)

        self.session = session
        self.output = output
        self.recordingURL = url
        isRecording = true
    }

    func stop() async -> URL? {
        guard isRecording, let output else { return nil }

        return await withCheckedContinuation { continuation in
            recordingContinuation = continuation
            output.stopRecording()
        }
    }

    nonisolated static func diagnostics(for url: URL) -> AudioRecordingDiagnostics? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return nil }

        let capacity: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var sampleCount = 0
        var squareSum = 0.0
        var peak = 0.0

        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: capacity)
            } catch {
                return nil
            }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)

            for channelIndex in 0..<channelCount {
                let channel = channels[channelIndex]
                for frameIndex in 0..<frameLength {
                    let sample = Double(channel[frameIndex])
                    let magnitude = abs(sample)
                    peak = max(peak, magnitude)
                    squareSum += sample * sample
                    sampleCount += 1
                }
            }
        }

        let duration = Double(file.length) / sampleRate
        let rms = sampleCount > 0 ? sqrt(squareSum / Double(sampleCount)) : 0
        return AudioRecordingDiagnostics(duration: duration, rms: rms, peak: peak)
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        Task { @MainActor in
            self.session?.stopRunning()
            self.session = nil
            self.output = nil
            self.isRecording = false
            self.activeInputDeviceName = ""
            let url = error == nil ? outputFileURL : nil
            self.recordingContinuation?.resume(returning: url)
            self.recordingContinuation = nil
            self.recordingURL = nil
        }
    }

    private static func availableInputDevices() -> [AudioInputDevice] {
        audioDevices()
            .filter { !isLegacyRemoteVirtualInput($0) }
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func device(for id: String?) -> AVCaptureDevice? {
        guard let id, !id.isEmpty else { return AVCaptureDevice.default(for: .audio) }
        return audioDevices().first { $0.uniqueID == id && !isLegacyRemoteVirtualInput($0) }
    }

    private static func remoteMicrophoneDevice() -> AVCaptureDevice? {
        nil
    }

    private static func isLegacyRemoteVirtualInput(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        return name.contains("siri remote mic") || name.contains("apple tv remote mic")
    }

    private static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    private static func bestFileType(from supportedTypes: [AVFileType]) -> AVFileType? {
        let preferredTypes: [AVFileType] = [.wav, .m4a, .aiff, .aifc, .caf]
        return preferredTypes.first { supportedTypes.contains($0) } ?? supportedTypes.first
    }

    private static func audioSettings(for fileType: AVFileType) -> [String: Any] {
        switch fileType {
        case .wav, .aiff, .aifc, .caf:
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        default:
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
        }
    }

    static func microphoneAccessStatusDescription() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
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

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private static func recordingURL(for fileType: AVFileType) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RatRemote-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension(for: fileType))
    }

    private static func removeOrphanedRecordings() {
        let directory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let audioExtensions: Set<String> = ["wav", "m4a", "aiff", "aifc", "caf", "audio"]
        for file in files where file.lastPathComponent.hasPrefix("RatRemote-") && audioExtensions.contains(file.pathExtension.lowercased()) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func fileExtension(for fileType: AVFileType) -> String {
        switch fileType {
        case .wav: "wav"
        case .m4a: "m4a"
        case .aiff: "aiff"
        case .aifc: "aifc"
        case .caf: "caf"
        default: "audio"
        }
    }
}
