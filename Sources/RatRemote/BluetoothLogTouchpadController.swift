import Foundation

extension Notification.Name {
    static let bluetoothLogTouchpadDelta = Notification.Name("bluetoothLogTouchpadDelta")
    static let bluetoothLogRemoteButton = Notification.Name("bluetoothLogRemoteButton")
    static let bluetoothLogTouchpadStatus = Notification.Name("bluetoothLogTouchpadStatus")
}

final class BluetoothLogTouchpadController: @unchecked Sendable {
    private let center = NotificationCenter.default
    private var process: Process?
    private var pipe: Pipe?
    private var readBuffer = Data()
    private var previousPoint: (x: Int, y: Int)?
    private var lastEventDate = Date.distantPast
    private let maxReadBufferBytes = 64 * 1024

    func start() {
        if let process, process.isRunning {
            return
        }
        stop()

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style", "compact",
            "--predicate",
            #"process == "BTLEServer" AND eventMessage CONTAINS[c] "Delayed multitouch data""#
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] process in
            self?.postStatus("Bluetooth log: exited \(process.terminationStatus)")
        }

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }

        do {
            try process.run()
            self.process = process
            self.pipe = pipe
            self.lastEventDate = Date()
            postStatus("Bluetooth log: listening")
        } catch {
            postStatus("Bluetooth log: failed \(error.localizedDescription)")
        }
    }

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        pipe = nil
        readBuffer.removeAll()
        previousPoint = nil
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        if readBuffer.count > maxReadBufferBytes {
            readBuffer.removeFirst(readBuffer.count - maxReadBufferBytes)
        }
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[..<newline]
            readBuffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handle(line: line)
        }
    }

    private func handle(line: String) {
        lastEventDate = Date()
        guard let bytes = parseBytes(from: line) else { return }
        let isMultitouchLine = line.localizedCaseInsensitiveContains("multitouch data")

        if let button = parseButton(from: bytes, allowPayloadOnlyReport: !isMultitouchLine) {
            postButton(button)
            return
        }

        guard isMultitouchLine, bytes.count >= 8 else { return }

        // Observed Siri Remote packets are 12 bytes. Offsets 2...3 and 6...7
        // carry stable little-endian touch coordinates in the Bluetooth log.
        let x = Int(UInt16(bytes[2]) | (UInt16(bytes[3]) << 8))
        let y = Int(UInt16(bytes[6]) | (UInt16(bytes[7]) << 8))

        if let previousPoint {
            let dx = x - previousPoint.x
            let dy = y - previousPoint.y
            if abs(dx) <= 2000, abs(dy) <= 2000, dx != 0 || dy != 0 {
                DispatchQueue.main.async { [center] in
                    center.post(
                        name: .bluetoothLogTouchpadDelta,
                        object: nil,
                        userInfo: ["dx": Double(dx), "dy": Double(dy), "x": x, "y": y]
                    )
                }
            }
        }

        previousPoint = (x, y)
    }

    private func parseBytes(from line: String) -> [UInt8]? {
        guard let marker = line.range(of: "bytes = ") else { return nil }
        let tail = line[marker.upperBound...]
        guard let hexStart = tail.range(of: "0x")?.upperBound else { return nil }
        let hexTail = tail[hexStart...]
        let hex = hexTail.prefix { $0.isHexDigit }
        guard hex.count >= 2 else { return nil }

        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard next <= hex.endIndex else { break }
            let pair = String(hex[index..<next])
            if pair.count == 2, let byte = UInt8(pair, radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }

    private func parseButton(from bytes: [UInt8], allowPayloadOnlyReport: Bool) -> String? {
        if latestRemoteReportTVButton(from: bytes, allowPayloadOnlyReport: allowPayloadOnlyReport) {
            return "tv"
        }

        for offset in [0, 1] where bytes.count >= offset + 2 {
            guard isLikelyButtonReport(bytes, payloadOffset: offset) else { continue }
            switch (bytes[offset], bytes[offset + 1]) {
            case (0x01, 0x00): return "tv"
            case (0x40, 0x00): return "back"
            case (0x00, 0x01): return "playPause"
            case (0x02, 0x00): return "volumeUp"
            case (0x04, 0x00): return "volumeDown"
            case (0x80, 0x00): return "mute"
            case (0x10, 0x00): return "power"
            case (0x08, 0x00): return "center"
            case (0x00, 0x02): return "up"
            case (0x00, 0x04): return "right"
            case (0x00, 0x08): return "down"
            case (0x00, 0x10): return "left"
            default:
                break
            }
        }
        return nil
    }

    private func latestRemoteReportTVButton(from bytes: [UInt8], allowPayloadOnlyReport: Bool) -> Bool {
        if bytes.count >= 2, bytes[0] == 0xFB {
            return (bytes[1] & 0x01) != 0
        }
        if allowPayloadOnlyReport, bytes.count == 3 {
            return (bytes[0] & 0x01) != 0
        }
        return false
    }

    private func isLikelyButtonReport(_ bytes: [UInt8], payloadOffset: Int) -> Bool {
        let payloadEnd = payloadOffset + 2
        guard bytes.count >= payloadEnd else { return false }
        if bytes.count <= payloadEnd {
            return true
        }
        guard bytes.count <= payloadEnd + 2 else { return false }
        return bytes[payloadEnd...].allSatisfy { $0 == 0 }
    }

    private func postButton(_ button: String) {
        DispatchQueue.main.async { [center] in
            center.post(
                name: .bluetoothLogRemoteButton,
                object: nil,
                userInfo: ["button": button, "pressed": true]
            )
        }
    }

    private func postStatus(_ status: String) {
        DispatchQueue.main.async { [center] in
            center.post(name: .bluetoothLogTouchpadStatus, object: nil, userInfo: ["status": status])
        }
    }

    func isHealthy() -> Bool {
        process?.isRunning == true
    }

    func needsRestart() -> Bool {
        guard let process else { return false }
        return !process.isRunning
    }
}
