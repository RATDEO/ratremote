import AppKit
import CoreBluetooth
import Foundation

extension Notification.Name {
    static let bleTouchpadMove = Notification.Name("bleTouchpadMove")
    static let bleTouchpadClick = Notification.Name("bleTouchpadClick")
    static let bleTouchpadScroll = Notification.Name("bleTouchpadScroll")
    static let bleTouchpadStatus = Notification.Name("bleTouchpadStatus")
    static let bleRemoteBatteryStatus = Notification.Name("bleRemoteBatteryStatus")
    static let siriRemoteAudioPacket = Notification.Name("siriRemoteAudioPacket")
}

final class BLETouchpadController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager?
    private var targetPeripheral: CBPeripheral?
    private var inputChar: CBCharacteristic?
    private var outputChar: CBCharacteristic?
    private var inputReportCharacteristics: [CBCharacteristic] = []
    private var writableReportCharacteristics: [CBCharacteristic] = []
    private var batteryChar: CBCharacteristic?
    private var isScanning = false
    private var exclusivePairingRequested = false
    private var pairingTimeoutWorkItem: DispatchWorkItem?
    
    private let hidServiceUUID = CBUUID(string: "1812")
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let center = NotificationCenter.default
    private var lastTouchpadClick = false
    private static let verboseInputLogging = ProcessInfo.processInfo.environment["RATREMOTE_VERBOSE_INPUT"] == "1"
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
        print("[BLE] Started")
    }

    deinit {
        stop()
    }
    
    func start() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func beginExclusivePairing() {
        exclusivePairingRequested = true
        pairingTimeoutWorkItem?.cancel()
        if let peripheral = targetPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
            targetPeripheral = nil
        }
        resetDiscoveredCharacteristics()
        guard let centralManager else {
            start()
            postStatus("Pairing: starting Bluetooth")
            return
        }
        guard centralManager.state == .poweredOn else {
            postStatus("Pairing: waiting for Bluetooth")
            return
        }
        scanForExclusivePairing(using: centralManager)
    }

    func cancelExclusivePairing() {
        exclusivePairingRequested = false
        pairingTimeoutWorkItem?.cancel()
        pairingTimeoutWorkItem = nil
        if isScanning {
            centralManager?.stopScan()
            isScanning = false
        }
        postStatus("Pairing cancelled")
    }
    
    func stop() {
        if isScanning, let cm = centralManager {
            cm.stopScan()
            isScanning = false
        }
        if let p = targetPeripheral {
            centralManager?.cancelPeripheralConnection(p)
        }
        targetPeripheral = nil
        inputChar = nil
        outputChar = nil
        inputReportCharacteristics = []
        writableReportCharacteristics = []
        batteryChar = nil
        exclusivePairingRequested = false
        pairingTimeoutWorkItem?.cancel()
        pairingTimeoutWorkItem = nil
        centralManager = nil
    }
    
    private func postStatus(_ status: String) {
        center.post(name: .bleTouchpadStatus, object: nil, userInfo: ["status": status])
    }

    private func postBatteryStatus(_ status: String) {
        center.post(name: .bleRemoteBatteryStatus, object: nil, userInfo: ["status": status])
    }
    
    private func postMove(x: Double, y: Double) {
        center.post(name: .bleTouchpadMove, object: nil, userInfo: ["x": x, "y": y])
    }
    
    private func postClick(pressed: Bool) {
        center.post(name: .bleTouchpadClick, object: nil, userInfo: ["pressed": pressed])
    }
    
    private func postScroll(amount: Double) {
        center.post(name: .bleTouchpadScroll, object: nil, userInfo: ["amount": amount])
    }

    private static func debugLog(_ message: @autoclosure () -> String) {
        guard verboseInputLogging else { return }
        print(message())
    }
    
    // MARK: - CBCentralManagerDelegate
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[BLE] Powered on")
            let connected = central.retrieveConnectedPeripherals(withServices: [hidServiceUUID])
            TraceLog.append(
                "CoreBluetooth connected HID candidateCount=\(connected.count)",
                filename: "remote-audio.log"
            )
            if let remote = connected.first(where: isLikelySiriRemote) {
                connect(remote, using: central, source: "connected HID")
            } else if exclusivePairingRequested {
                scanForExclusivePairing(using: central)
            } else {
                postStatus("BLE: system-owned; pair exclusively for remote audio")
            }
        case .poweredOff:
            postStatus("BLE: off")
        case .unauthorized:
            postStatus("BLE: no permission")
        case .unknown:
            postStatus("BLE: initializing")
        case .resetting:
            break
        case .unsupported:
            postStatus("BLE: unsupported")
        @unknown default:
            postStatus("BLE: unknown state")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "unknown"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasHID = services.contains(hidServiceUUID)
        let isRemote = name.contains("Siri") || name.contains("Apple TV") || name.contains("Remote")
        
        let isSerialNamedRemote = isLikelySiriRemote(peripheral)
        if (isRemote || isSerialNamedRemote || (exclusivePairingRequested && hasHID)), targetPeripheral == nil {
            Self.debugLog("[BLE] Compatible device found hasHID=\(hasHID) RSSI=\(RSSI)")
            connect(peripheral, using: central, source: "scan")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLE] Connected")
        targetPeripheral = peripheral
        pairingTimeoutWorkItem?.cancel()
        pairingTimeoutWorkItem = nil
        peripheral.delegate = self
        peripheral.discoverServices([hidServiceUUID, batteryServiceUUID])
        postStatus(exclusivePairingRequested ? "Pairing: connected, authenticating" : "BLE: discovering")
        TraceLog.append(
            "CoreBluetooth connected",
            filename: "remote-audio.log"
        )
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        print("[BLE] Connect failed: \(error?.localizedDescription ?? "unknown")")
        postStatus("BLE: failed")
        TraceLog.append(
            "CoreBluetooth connect failed error=\(error?.localizedDescription ?? "unknown")",
            filename: "remote-audio.log"
        )
        if exclusivePairingRequested {
            scanForExclusivePairing(using: central)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        print("[BLE] Disconnected: \(error?.localizedDescription ?? "normal")")
        targetPeripheral = nil
        resetDiscoveredCharacteristics()
        postStatus("BLE: disconnected")
        postBatteryStatus("Unavailable")
        if exclusivePairingRequested {
            scanForExclusivePairing(using: central)
        }
    }
    
    // MARK: - CBPeripheralDelegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            print("[BLE] Service error: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            print("[BLE] Service: \(service.uuid)")
            if service.uuid == hidServiceUUID || service.uuid == batteryServiceUUID {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let error {
            print("[BLE] Char error: \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else { return }
        
        for char in characteristics {
            let uuid = char.uuid.uuidString.lowercased()
            let props = char.properties
            print("[BLE] Char: \(char.uuid) props=\(props.rawValue)")
            TraceLog.append(
                "CoreBluetooth characteristic service=\(service.uuid) uuid=\(char.uuid) props=\(props.rawValue)",
                filename: "remote-audio.log"
            )

            if service.uuid == batteryServiceUUID && char.uuid == batteryLevelUUID {
                batteryChar = char
                peripheral.readValue(for: char)
                if props.contains(.notify) || props.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
            
            // HID Report Map (2A4B)
            if uuid == "00002a4b-0000-1000-8000-00805f9b34fb" {
                peripheral.readValue(for: char)
            }
            
            // HID Report (2A4D)
            if uuid == "00002a4d-0000-1000-8000-00805f9b34fb" {
                if props.contains(.notify) || props.contains(.indicate) {
                    inputReportCharacteristics.append(char)
                    inputChar = inputChar ?? char
                    peripheral.setNotifyValue(true, for: char)
                    print("[BLE] HID input report subscribed")
                }
                if props.contains(.write) || props.contains(.writeWithoutResponse) {
                    writableReportCharacteristics.append(char)
                    outputChar = outputChar ?? char
                    let writeType: CBCharacteristicWriteType = props.contains(.write) ? .withResponse : .withoutResponse
                    peripheral.writeValue(Data([0xAF]), for: char, type: writeType)
                    print("[BLE] HID report enabled")
                }
            }
        }
        
        // Fallback: assign by properties
        if inputChar == nil || outputChar == nil {
            for char in characteristics {
                let props = char.properties
                if props.contains(.notify) && inputChar == nil {
                    inputChar = char
                    print("[BLE] Input char (fallback)")
                }
                if (props.contains(.write) || props.contains(.writeWithoutResponse)) && outputChar == nil {
                    outputChar = char
                    print("[BLE] Output char (fallback)")
                }
            }
        }
        
        if !inputReportCharacteristics.isEmpty, !writableReportCharacteristics.isEmpty {
            print("[BLE] Activated \(inputReportCharacteristics.count) input and \(writableReportCharacteristics.count) writable HID reports")
            postStatus("Pairing: enabling remote reports")
        } else if let _ = inputChar, let _ = outputChar {
            activate(peripheral)
        } else {
            print("[BLE] Missing chars: in=\(inputChar != nil) out=\(outputChar != nil)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            print("[BLE] Write error: \(error.localizedDescription)")
        } else {
            print("[BLE] Write OK: \(characteristic.uuid)")
        }
        TraceLog.append(
            "CoreBluetooth write uuid=\(characteristic.uuid) result=\(error?.localizedDescription ?? "success")",
            filename: "remote-audio.log"
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        TraceLog.append(
            "CoreBluetooth notify uuid=\(characteristic.uuid) active=\(characteristic.isNotifying) result=\(error?.localizedDescription ?? "success")",
            filename: "remote-audio.log"
        )
        if let error {
            postStatus("Pairing failed: \(error.localizedDescription)")
        } else if characteristic.isNotifying,
                  inputReportCharacteristics.contains(where: { $0 === characteristic }),
                  !writableReportCharacteristics.isEmpty {
            exclusivePairingRequested = false
            postStatus("Exclusively paired: remote mic ready")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            print("[BLE] Update error: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }

        if data.count >= 90 {
            TraceLog.append(
                "CoreBluetooth candidate uuid=\(characteristic.uuid) len=\(data.count)",
                filename: "remote-audio.log"
            )
        }

        if let batteryChar, batteryChar.uuid == characteristic.uuid {
            let percent = Int(data[0])
            guard (0...100).contains(percent) else { return }
            postBatteryStatus("\(percent)%")
            return
        }
        
        if data.count == 99 {
            center.post(name: .siriRemoteAudioPacket, object: self, userInfo: ["data": data])
            return
        }

        if inputReportCharacteristics.contains(where: { $0 === characteristic }) ||
            (inputChar?.uuid == characteristic.uuid) {
            parseHIDReport(data)
        }
    }
    
    // MARK: - Activation
    
    private func activate(_ peripheral: CBPeripheral) {
        guard let oc = outputChar, let ic = inputChar else { return }
        
        peripheral.writeValue(Data([0xAF]), for: oc, type: .withResponse)
        peripheral.setNotifyValue(true, for: ic)
        print("[BLE] Activated HID")
        postStatus("BLE: active")
    }
    
    private func beginScan() {
        guard targetPeripheral == nil else { return }
        isScanning = true
        centralManager?.scanForPeripherals(withServices: [hidServiceUUID], options: nil)
    }

    private func scanForExclusivePairing(using central: CBCentralManager) {
        guard targetPeripheral == nil else { return }
        if isScanning { central.stopScan() }
        isScanning = true
        postStatus("Pairing: scanning — hold Back + Volume Up")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.exclusivePairingRequested, self.targetPeripheral == nil else { return }
            self.centralManager?.stopScan()
            self.isScanning = false
            self.postStatus("Pairing timed out — hold Back + Volume Up and retry")
        }
        pairingTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
    }

    private func resetDiscoveredCharacteristics() {
        inputChar = nil
        outputChar = nil
        inputReportCharacteristics = []
        writableReportCharacteristics = []
        batteryChar = nil
    }

    private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager, source: String) {
        guard targetPeripheral == nil else { return }
        if isScanning {
            central.stopScan()
            isScanning = false
        }
        targetPeripheral = peripheral
        peripheral.delegate = self
        postStatus("BLE: connecting")
        TraceLog.append(
            "CoreBluetooth selecting source=\(source) state=\(peripheral.state.rawValue)",
            filename: "remote-audio.log"
        )
        central.connect(peripheral, options: nil)
    }

    private func isLikelySiriRemote(_ peripheral: CBPeripheral) -> Bool {
        guard let name = peripheral.name else { return false }
        let lowered = name.lowercased()
        if lowered.contains("siri") || lowered.contains("apple tv") || lowered.contains("remote") {
            return true
        }
        // Some Siri Remotes expose an alphanumeric Bluetooth identifier instead of a product name.
        return name.count >= 10 && name.first == "C" && name.allSatisfy { ($0.isASCII && $0.isLetter) || $0.isNumber }
    }
    
    // MARK: - HID Report Parsing
    
    private func parseHIDReport(_ data: Data) {
        guard !data.isEmpty else { return }
        let reportID = data[0]
        
        switch reportID {
        case 0x01:
            parseButtons(data)
        case 0x02:
            parseTouchpad(data)
        default:
            let hex = data.map { String($0, radix: 16) }.joined(separator: " ")
            Self.debugLog("[BLE] Report 0x\(String(reportID, radix: 16)): \(hex)")
        }
    }
    
    private func parseButtons(_ data: Data) {
        guard data.count >= 2 else { return }
        let buttons = data[1]
        let touchpadClick = (buttons & 0x80) != 0
        guard touchpadClick != lastTouchpadClick else { return }
        lastTouchpadClick = touchpadClick
        postClick(pressed: touchpadClick)
        if touchpadClick {
            Self.debugLog("[BLE] Click down")
        } else {
            Self.debugLog("[BLE] Click up")
        }
    }
    
    private func parseTouchpad(_ data: Data) {
        guard data.count >= 3 else { return }
        
        let buttons = data[1]
        let xLow = Int(data[2])
        let xHigh = data.count > 3 ? Int(data[3]) : 0
        let x = Double((xHigh << 8) | xLow)
        let y = data.count > 4 ? Double(Int8(bitPattern: data[4])) : 0
        let pressure = data.count > 5 ? Double(data[5]) : 0
        
        let nx = x / 4095.0
        let ny = (y + 2048.0) / 4095.0
        
        let touching = (buttons & 0x01) != 0 || pressure > 0
        
        if touching {
            postMove(x: nx, y: ny)
            Self.debugLog("[BLE] Touch x=\(nx) y=\(ny)")
        }
    }
}
