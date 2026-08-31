import AppKit
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class SkyLightInputBridge {
    static let shared = SkyLightInputBridge()

    private typealias CGSMainConnectionIDFunction = @convention(c) () -> Int32
    private typealias CGSPostMouseEventToProcessFunction = @convention(c) (Int32, Int32, Int32, UnsafePointer<CGPoint>, Int32) -> Int32
    private typealias CGSGetWindowOwnerFunction = @convention(c) (Int32, Int32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias CGSConnectionGetPIDFunction = @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias CGSSetConnectionPropertyFunction = @convention(c) (Int32, Int32, UnsafeRawPointer, UnsafeRawPointer) -> Int32

    struct MicroActivationToken {
        fileprivate let connectionID: Int32
        fileprivate let restoreFrontmost: Bool
    }

    private let mainConnectionID: Int32
    private let postMouseEventToProcess: CGSPostMouseEventToProcessFunction?
    private let getWindowOwner: CGSGetWindowOwnerFunction?
    private let connectionGetPID: CGSConnectionGetPIDFunction?
    private let setConnectionProperty: CGSSetConnectionPropertyFunction?
    private let frontmostKey = "SetFrontmost" as CFString

    private init() {
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        guard let handle else {
            mainConnectionID = 0
            postMouseEventToProcess = nil
            getWindowOwner = nil
            connectionGetPID = nil
            setConnectionProperty = nil
            return
        }

        if let symbol = dlsym(handle, "CGSMainConnectionID") {
            let function = unsafeBitCast(symbol, to: CGSMainConnectionIDFunction.self)
            mainConnectionID = function()
        } else {
            mainConnectionID = 0
        }

        if let symbol = dlsym(handle, "CGSPostMouseEventToProcess") {
            postMouseEventToProcess = unsafeBitCast(symbol, to: CGSPostMouseEventToProcessFunction.self)
        } else {
            postMouseEventToProcess = nil
        }

        if let symbol = dlsym(handle, "CGSGetWindowOwner") {
            getWindowOwner = unsafeBitCast(symbol, to: CGSGetWindowOwnerFunction.self)
        } else {
            getWindowOwner = nil
        }

        if let symbol = dlsym(handle, "CGSConnectionGetPID") {
            connectionGetPID = unsafeBitCast(symbol, to: CGSConnectionGetPIDFunction.self)
        } else {
            connectionGetPID = nil
        }

        if let symbol = dlsym(handle, "CGSSetConnectionProperty") {
            setConnectionProperty = unsafeBitCast(symbol, to: CGSSetConnectionPropertyFunction.self)
        } else {
            setConnectionProperty = nil
        }
    }

    var isAvailable: Bool {
        mainConnectionID != 0 && (postMouseEventToProcess != nil || setConnectionProperty != nil)
    }

    var canPostMouseEventToProcess: Bool {
        mainConnectionID != 0 && postMouseEventToProcess != nil
    }

    var canMicroActivate: Bool {
        mainConnectionID != 0 && getWindowOwner != nil && setConnectionProperty != nil
    }

    func postMouseEvent(pid: pid_t, type: CGEventType, point: CGPoint, clickCount: Int32 = 1) -> Bool {
        guard let postMouseEventToProcess, mainConnectionID != 0 else {
            return false
        }
        var mutablePoint = point
        let result = withUnsafePointer(to: &mutablePoint) { pointer in
            postMouseEventToProcess(mainConnectionID, pid, Int32(type.rawValue), pointer, clickCount)
        }
        return result == 0
    }

    func click(pid: pid_t, point: CGPoint) -> Bool {
        let down = postMouseEvent(pid: pid, type: .leftMouseDown, point: point, clickCount: 1)
        usleep(5_000)
        let up = postMouseEvent(pid: pid, type: .leftMouseUp, point: point, clickCount: 1)
        return down && up
    }

    func drag(pid: pid_t, from start: CGPoint, to end: CGPoint, steps: Int = 10, stepDelay: useconds_t = 5_000) -> Bool {
        guard postMouseEvent(pid: pid, type: .leftMouseDown, point: start, clickCount: 1) else {
            return false
        }
        usleep(20_000)

        var delivered = true
        let count = max(1, steps)
        for step in 1...count {
            let progress = Double(step) / Double(count)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            delivered = postMouseEvent(pid: pid, type: .leftMouseDragged, point: point, clickCount: 1) && delivered
            usleep(stepDelay)
        }

        let up = postMouseEvent(pid: pid, type: .leftMouseUp, point: end, clickCount: 1)
        return delivered && up
    }

    func beginMicroActivation(pid: pid_t, windowID: CGWindowID?) -> MicroActivationToken? {
        guard let connectionID = windowOwnerConnectionID(windowID: windowID, expectedPID: pid),
              setFrontmost(connectionID: connectionID, frontmost: true) else {
            return nil
        }
        let restoreFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        return MicroActivationToken(connectionID: connectionID, restoreFrontmost: restoreFrontmost)
    }

    func endMicroActivation(_ token: MicroActivationToken) {
        _ = setFrontmost(connectionID: token.connectionID, frontmost: token.restoreFrontmost)
    }

    private func windowOwnerConnectionID(windowID: CGWindowID?, expectedPID: pid_t) -> Int32? {
        guard let windowID,
              let getWindowOwner,
              mainConnectionID != 0 else {
            return nil
        }

        var ownerConnectionID = Int32(0)
        let err = getWindowOwner(mainConnectionID, Int32(bitPattern: windowID), &ownerConnectionID)
        guard err == 0, ownerConnectionID != 0 else {
            return nil
        }

        if let connectionGetPID {
            var ownerPID = Int32(0)
            if connectionGetPID(ownerConnectionID, &ownerPID) == 0,
               ownerPID != 0,
               ownerPID != expectedPID {
                return nil
            }
        }

        return ownerConnectionID
    }

    private func setFrontmost(connectionID: Int32, frontmost: Bool) -> Bool {
        guard let setConnectionProperty, mainConnectionID != 0 else {
            return false
        }

        let value = frontmost ? kCFBooleanTrue : kCFBooleanFalse
        let keyPointer = UnsafeRawPointer(Unmanaged.passUnretained(frontmostKey).toOpaque())
        let valuePointer = UnsafeRawPointer(Unmanaged.passUnretained(value!).toOpaque())
        return setConnectionProperty(mainConnectionID, connectionID, keyPointer, valuePointer) == 0
    }
}
