import AppKit
import CoreGraphics
import Foundation

enum AgentInputSyntheticMarker {
    static let value: Int64 = 0x52524154435552
}

final class AgentInputMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var targetPID: pid_t?
    private var targetBounds: CGRect?
    private var onInterruption: (@Sendable () -> Void)?
    private var lastInterruption = Date.distantPast

    func start(targetPID: pid_t, targetBounds: CGRect, onInterruption: @escaping @Sendable () -> Void) {
        stop()
        self.targetPID = targetPID
        self.targetBounds = targetBounds.insetBy(dx: -10, dy: -10)
        self.onInterruption = onInterruption

        let mask = Self.eventMask(for: [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
            .keyDown,
            .flagsChanged
        ])

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        targetPID = nil
        targetBounds = nil
        onInterruption = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        guard event.getIntegerValueField(.eventSourceUserData) != AgentInputSyntheticMarker.value,
              event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()),
              let targetPID else {
            return
        }

        let isConflict: Bool
        switch type {
        case .keyDown, .flagsChanged:
            let eventTargetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            isConflict = eventTargetPID == targetPID || frontmostPID == targetPID
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .scrollWheel:
            isConflict = targetBounds?.contains(event.location) == true
        default:
            isConflict = false
        }

        guard isConflict else { return }
        let now = Date()
        guard now.timeIntervalSince(lastInterruption) > 0.8 else { return }
        lastInterruption = now
        let callback = onInterruption
        DispatchQueue.main.async {
            callback?()
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<AgentInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private static func eventMask(for types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
    }
}
