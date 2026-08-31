import AVFoundation
import Foundation
import Copus

enum SiriRemoteAudioError: LocalizedError {
    case decoderCreationFailed(Int32)
    case recordingCreationFailed(String)
    case noAudioFrames

    var errorDescription: String? {
        switch self {
        case .decoderCreationFailed(let code):
            "RatRemote could not create its Opus audio decoder (error \(code))."
        case .recordingCreationFailed(let detail):
            "RatRemote could not create the remote microphone recording. \(detail)"
        case .noAudioFrames:
            "The Siri Remote did not send any microphone audio frames."
        }
    }
}

@MainActor
final class SiriRemoteAudioRelay {
    private static let sampleRate = 48_000.0
    private static let samplesPerFrame = 960
    private var decoder: OpaquePointer?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var observer: NSObjectProtocol?
    private(set) var decodedFrameCount = 0
    private(set) var decodedSampleCount = 0

    var isCapturing: Bool {
        decoder != nil && audioFile != nil
    }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .siriRemoteAudioPacket,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let data = notification.userInfo?["data"] as? Data else { return }
            Task { @MainActor in self?.consume(report: data) }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let decoder { opus_decoder_destroy(decoder) }
    }

    func beginCapture() throws {
        discardCapture()
        TraceLog.append("capture begin", filename: "remote-audio.log")

        var decoderError: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(Self.sampleRate), 1, &decoderError), decoderError == OPUS_OK else {
            throw SiriRemoteAudioError.decoderCreationFailed(decoderError)
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RatRemote-SiriRemote-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            self.decoder = decoder
            self.audioFile = file
            self.recordingURL = url
            decodedFrameCount = 0
            decodedSampleCount = 0
        } catch {
            opus_decoder_destroy(decoder)
            throw SiriRemoteAudioError.recordingCreationFailed(error.localizedDescription)
        }
    }

    func finishCapture() throws -> URL {
        TraceLog.append(
            "capture finish decodedFrames=\(decodedFrameCount) decodedSamples=\(decodedSampleCount)",
            filename: "remote-audio.log"
        )
        guard let url = recordingURL else { throw SiriRemoteAudioError.noAudioFrames }
        audioFile = nil
        if let decoder { opus_decoder_destroy(decoder) }
        decoder = nil
        recordingURL = nil
        guard decodedFrameCount > 0, decodedSampleCount > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw SiriRemoteAudioError.noAudioFrames
        }
        return url
    }

    func discardCapture() {
        audioFile = nil
        if let decoder { opus_decoder_destroy(decoder) }
        decoder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        decodedFrameCount = 0
        decodedSampleCount = 0
    }

    private func consume(report: Data) {
        guard let packet = Self.opusPacket(from: report),
              let decoder,
              let audioFile else { return }

        var pcm = [Int16](repeating: 0, count: Self.samplesPerFrame)
        let decodedSamples: Int32 = packet.withUnsafeBytes { packetBytes in
            guard let base = packetBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return opus_decode(
                decoder,
                base,
                Int32(packet.count),
                &pcm,
                Int32(Self.samplesPerFrame),
                0
            )
        }
        guard decodedSamples > 0 else { return }

        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(decodedSamples)
        ), let channel = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(decodedSamples)
        pcm.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: Int(decodedSamples))
        }

        do {
            try audioFile.write(from: buffer)
            decodedFrameCount += 1
            decodedSampleCount += Int(decodedSamples)
        } catch {
            // Keep capturing. A zero-frame result is surfaced when the button is released.
        }
    }

    nonisolated static func opusPacket(from report: Data) -> Data? {
        guard report.count == 99 else { return nil }
        let packetLength = Int(report[4])
        guard packetLength > 0,
              packetLength <= 94,
              5 + packetLength <= report.count else { return nil }
        return report.subdata(in: 5..<(5 + packetLength))
    }
}
