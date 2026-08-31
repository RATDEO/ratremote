import CoreFoundation
import Foundation
import IOKit

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mm: MTVector
    var zero2: Int32
    var zero3: Int32
    var unknown: Float
}

extension Notification.Name {
    static let siriRemoteMultitouchMove = Notification.Name("siriRemoteMultitouchMove")
    static let siriRemoteMultitouchEnd = Notification.Name("siriRemoteMultitouchEnd")
    static let siriRemoteMultitouchStatus = Notification.Name("siriRemoteMultitouchStatus")
}

final class SiriRemoteMultitouchController: @unchecked Sendable {
    private typealias MTContactFrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32, UnsafeMutableRawPointer?) -> Void
    private typealias MTDeviceCreateList = @convention(c) () -> Unmanaged<CFArray>
    private typealias MTDeviceGetDeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias MTDeviceGetSensorSurfaceDimensions = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias MTDeviceGetService = @convention(c) (UnsafeMutableRawPointer) -> io_service_t
    private typealias MTRegisterContactFrameCallbackWithRefcon = @convention(c) (UnsafeMutableRawPointer, MTContactFrameCallback, UnsafeMutableRawPointer?) -> Void
    private typealias MTUnregisterContactFrameCallback = @convention(c) (UnsafeMutableRawPointer, MTContactFrameCallback) -> Void
    private typealias MTDeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias MTDeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private struct DeviceCandidate {
        let pointer: UnsafeMutableRawPointer
        let id: Int32
        let service: io_service_t
        let width: Int32
        let height: Int32
        let productID: Int
        let transport: String?
        let productName: String?
        let manufacturer: String?

        var area: Int32 {
            width * height
        }

        var isSiriRemote: Bool {
            let knownRemoteProductIDs: Set<Int> = [789, 788, 621, 614, 634, 610, 609, 608]
            let name = "\(productName ?? "") \(manufacturer ?? "")".lowercased()
            return knownRemoteProductIDs.contains(productID) ||
                (name.contains("remote") && (name.contains("siri") || name.contains("apple tv") || name.contains("apple")))
        }
    }

    private let center = NotificationCenter.default
    private var handle: UnsafeMutableRawPointer?
    private var retainedDeviceList: CFArray?
    private var selectedDevice: UnsafeMutableRawPointer?
    private var unregisterCallback: MTUnregisterContactFrameCallback?
    private var stopDevice: MTDeviceStop?
    private var lastFrameWithTouches: Int32 = -1
    private var activeTouchIdentifier: Int32?
    private let pendingFrameLock = NSLock()
    private var pendingFrame: PendingFrame?
    private var frameDeliveryScheduled = false

    private struct PendingFrame {
        let x: Double
        let y: Double
        let velocityX: Double
        let velocityY: Double
        let timestamp: Double
        let state: Int
        let frame: Int
        let count: Int
        let reset: Bool
    }

    private var createList: MTDeviceCreateList?
    private var getDeviceID: MTDeviceGetDeviceID?
    private var getDimensions: MTDeviceGetSensorSurfaceDimensions?
    private var getService: MTDeviceGetService?
    private var registerCallbackWithRefcon: MTRegisterContactFrameCallbackWithRefcon?
    private var startDevice: MTDeviceStart?

    nonisolated(unsafe) private static weak var activeController: SiriRemoteMultitouchController?

    var isActive: Bool {
        selectedDevice != nil
    }

    @discardableResult
    func start() -> Bool {
        guard handle == nil else { return selectedDevice != nil }
        guard loadFramework() else {
            stop()
            return false
        }
        guard let device = selectDevice() else {
            postStatus("Multitouch: no Siri Remote surface")
            stop()
            return false
        }

        selectedDevice = device.pointer
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        Self.activeController = self
        registerCallbackWithRefcon?(device.pointer, Self.contactFrameCallback, refcon)
        let startStatus = startDevice?(device.pointer, 0) ?? -1
        postStatus("Multitouch: device id=\(device.id) \(Int(device.width))x\(Int(device.height)) pid=\(device.productID) transport=\(device.transport ?? "?") start=\(startStatus)")
        return selectedDevice != nil
    }

    func stop() {
        if let selectedDevice {
            unregisterCallback?(selectedDevice, Self.contactFrameCallback)
            Thread.sleep(forTimeInterval: 0.05)
            _ = stopDevice?(selectedDevice)
        }
        selectedDevice = nil
        retainedDeviceList = nil
        activeTouchIdentifier = nil
        pendingFrameLock.withLock {
            pendingFrame = nil
            frameDeliveryScheduled = false
        }
        if let handle {
            dlclose(handle)
        }
        handle = nil
        if Self.activeController === self {
            Self.activeController = nil
        }
    }

    private func loadFramework() -> Bool {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else {
            postStatus("Multitouch: unavailable")
            return false
        }

        self.handle = handle
        createList = loadSymbol("MTDeviceCreateList", from: handle, as: MTDeviceCreateList.self)
        getDeviceID = loadSymbol("MTDeviceGetDeviceID", from: handle, as: MTDeviceGetDeviceID.self)
        getDimensions = loadSymbol("MTDeviceGetSensorSurfaceDimensions", from: handle, as: MTDeviceGetSensorSurfaceDimensions.self)
        getService = loadSymbol("MTDeviceGetService", from: handle, as: MTDeviceGetService.self)
        registerCallbackWithRefcon = loadSymbol("MTRegisterContactFrameCallbackWithRefcon", from: handle, as: MTRegisterContactFrameCallbackWithRefcon.self)
        unregisterCallback = loadSymbol("MTUnregisterContactFrameCallback", from: handle, as: MTUnregisterContactFrameCallback.self)
        startDevice = loadSymbol("MTDeviceStart", from: handle, as: MTDeviceStart.self)
        stopDevice = loadSymbol("MTDeviceStop", from: handle, as: MTDeviceStop.self)

        guard createList != nil,
              getDeviceID != nil,
              getDimensions != nil,
              getService != nil,
              registerCallbackWithRefcon != nil,
              startDevice != nil else {
            postStatus("Multitouch: missing symbols")
            return false
        }

        return true
    }

    private func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private func selectDevice() -> DeviceCandidate? {
        guard let createList, let getDeviceID, let getDimensions, let getService else { return nil }

        let array = createList().takeRetainedValue()
        retainedDeviceList = array
        let count = CFArrayGetCount(array)
        var candidates: [DeviceCandidate] = []

        for index in 0..<count {
            guard let value = CFArrayGetValueAtIndex(array, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: value)
            var width: Int32 = 0
            var height: Int32 = 0
            _ = getDimensions(device, &width, &height)
            var deviceID: UInt64 = 0
            _ = getDeviceID(device, &deviceID)
            let service = getService(device)
            let candidate = DeviceCandidate(
                pointer: device,
                id: Int32(truncatingIfNeeded: deviceID),
                service: service,
                width: width,
                height: height,
                productID: registryInt("ProductID", service: service) ?? 0,
                transport: registryString("Transport", service: service),
                productName: registryString("Product", service: service) ?? registryString("Product Name", service: service),
                manufacturer: registryString("Manufacturer", service: service)
            )
            candidates.append(candidate)
        }

        if !candidates.isEmpty {
            postStatus("Multitouch: found \(candidates.count) candidate device(s)")
        }

        if let override = ProcessInfo.processInfo.environment["RATREMOTE_MULTITOUCH_DEVICE_INDEX"],
           let overrideIndex = Int(override),
           candidates.indices.contains(overrideIndex) {
            return candidates[overrideIndex]
        }

        return candidates
            .filter(\.isSiriRemote)
            .min { lhs, rhs in lhs.area < rhs.area }
    }

    private func registryInt(_ key: String, service: io_service_t) -> Int? {
        guard service != 0,
              let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func registryString(_ key: String, service: io_service_t) -> String? {
        guard service != 0,
              let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return value as? String
    }

    private static let contactFrameCallback: MTContactFrameCallback = { _, touches, touchCount, _, frame, refcon in
        guard let refcon else { return }
        let controller = Unmanaged<SiriRemoteMultitouchController>.fromOpaque(refcon).takeUnretainedValue()
        controller.handleFrame(touches: touches, touchCount: Int(touchCount), frame: frame)
    }

    private func handleFrame(touches: UnsafeMutableRawPointer?, touchCount: Int, frame: Int32) {
        guard touchCount > 0, let touches else {
            if lastFrameWithTouches >= 0, frame != lastFrameWithTouches {
                lastFrameWithTouches = -1
                activeTouchIdentifier = nil
                DispatchQueue.main.async { [center] in
                    center.post(name: .siriRemoteMultitouchEnd, object: nil)
                }
            }
            return
        }

        lastFrameWithTouches = frame
        let touch = touches.bindMemory(to: MTTouch.self, capacity: touchCount)[0]
        if touch.state == 0 || touch.state >= 5 {
            activeTouchIdentifier = nil
            DispatchQueue.main.async { [center] in
                center.post(name: .siriRemoteMultitouchEnd, object: nil)
            }
            return
        }
        let reset = activeTouchIdentifier != touch.identifier || touch.state == 1 || touch.state == 3
        activeTouchIdentifier = touch.identifier
        let x = Double(touch.normalized.position.x)
        let y = Double(1 - touch.normalized.position.y)
        let velocityX = Double(touch.normalized.velocity.x)
        let velocityY = Double(-touch.normalized.velocity.y)
        let timestamp = touch.timestamp
        let state = Int(touch.state)
        let frameNumber = Int(touch.frame)
        enqueueFrame(PendingFrame(
            x: x,
            y: y,
            velocityX: velocityX,
            velocityY: velocityY,
            timestamp: timestamp,
            state: state,
            frame: frameNumber,
            count: touchCount,
            reset: reset
        ))
    }

    private func enqueueFrame(_ frame: PendingFrame) {
        let shouldSchedule = pendingFrameLock.withLock {
            pendingFrame = frame
            guard !frameDeliveryScheduled else { return false }
            frameDeliveryScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        // Keep at most one main-thread delivery queued. If rendering is busy,
        // newer absolute touch coordinates replace stale ones instead of
        // building an input backlog that makes the remote cursor feel delayed.
        DispatchQueue.main.async { [weak self] in
            self?.deliverPendingFrame()
        }
    }

    private func deliverPendingFrame() {
        guard let frame = pendingFrameLock.withLock({
            let frame = pendingFrame
            pendingFrame = nil
            frameDeliveryScheduled = false
            return frame
        }) else { return }

        center.post(
            name: .siriRemoteMultitouchMove,
            object: nil,
            userInfo: [
                "x": frame.x,
                "y": frame.y,
                "velocityX": frame.velocityX,
                "velocityY": frame.velocityY,
                "timestamp": frame.timestamp,
                "state": frame.state,
                "frame": frame.frame,
                "count": frame.count,
                "reset": frame.reset
            ]
        )
    }

    private func postStatus(_ status: String) {
        DispatchQueue.main.async { [center] in
            center.post(name: .siriRemoteMultitouchStatus, object: nil, userInfo: ["status": status])
        }
    }
}
