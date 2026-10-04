import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum TextInsertionResult {
    case clipboard
    case menu
    case direct
    case failed

    var title: String {
        switch self {
        case .clipboard: "Clipboard paste"
        case .menu: "Menu paste"
        case .direct: "Direct event paste"
        case .failed: "Failed"
        }
    }
}

struct TextInsertionDiagnostics {
    let result: TextInsertionResult
    let accessibilityTrusted: Bool
    let frontmostApplication: String
    let clipboardMatches: Bool
    let methods: [String]

    var summary: String {
        let trusted = accessibilityTrusted ? "AX yes" : "AX no"
        let clipboard = clipboardMatches ? "clip yes" : "clip no"
        let attempted = methods.joined(separator: "/")
        return "\(result.title) | \(frontmostApplication) | \(trusted) | \(clipboard) | \(attempted)"
    }
}

@MainActor
final class ActionExecutor {
    private let virtualCursor = VirtualAgentCursor()
    private var mouseEventNumber: Int64 = 0
    private var missionControlSelectionPending = false

    func accessibilityStatus() -> String {
        AXIsProcessTrusted() ? "Granted" : "Not granted"
    }

    func showVirtualCursor(targetWindow: WindowCaptureTarget?, activity: AgentCursorActivity) {
        virtualCursor.show(targetWindow: targetWindow, activity: activity)
    }

    func setVirtualCursorActivity(_ activity: AgentCursorActivity) {
        virtualCursor.setActivity(activity)
    }

    func hideVirtualCursor(after delay: TimeInterval = 0.35) {
        virtualCursor.hide(after: delay)
    }

    func runningAppPath() -> String {
        Bundle.main.bundlePath
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func windowTargets() -> [WindowCaptureTarget] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windows.compactMap { info in
            guard let windowID = Self.uint32Value(info[kCGWindowNumber as String]),
                  let ownerPIDValue = Self.int32Value(info[kCGWindowOwnerPID as String]),
                  ownerPIDValue != NSRunningApplication.current.processIdentifier,
                  let layer = Self.intValue(info[kCGWindowLayer as String]),
                  layer == 0,
                  let bounds = Self.windowBounds(from: info),
                  bounds.width >= 120,
                  bounds.height >= 90 else {
                return nil
            }

            let alpha = Self.doubleValue(info[kCGWindowAlpha as String]) ?? 1
            guard alpha > 0.05 else { return nil }

            let appName = (info[kCGWindowOwnerName as String] as? String) ?? "Unknown"
            let windowTitle = (info[kCGWindowName as String] as? String) ?? ""
            guard !appName.localizedCaseInsensitiveContains("RatRemote") else { return nil }

            return WindowCaptureTarget(
                id: CGWindowID(windowID),
                ownerPID: pid_t(ownerPIDValue),
                appName: appName,
                windowTitle: windowTitle,
                bounds: bounds,
                thumbnail: thumbnail(for: CGWindowID(windowID))
            )
        }
    }

    func captureDisplay() -> ScreenCaptureContext? {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()),
              let base64 = pngBase64(from: image) else {
            return nil
        }
        return ScreenCaptureContext(
            imageBase64: base64,
            frame: CGDisplayBounds(CGMainDisplayID()),
            title: "Entire display",
            isWindowScoped: false
        )
    }

    func captureWindow(_ target: WindowCaptureTarget) -> ScreenCaptureContext? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            target.id,
            [.boundsIgnoreFraming, .bestResolution]
        ),
        let base64 = pngBase64(from: image) else {
            return nil
        }

        return ScreenCaptureContext(
            imageBase64: base64,
            frame: currentBounds(for: target) ?? target.bounds,
            title: target.displayTitle,
            isWindowScoped: true
        )
    }

    func activateWindow(_ target: WindowCaptureTarget?) -> Bool {
        guard let target,
              let application = NSRunningApplication(processIdentifier: target.ownerPID) else {
            return false
        }
        _ = application.unhide()
        _ = application.activate(options: [.activateAllWindows])

        guard AXIsProcessTrusted() else {
            return true
        }

        let appElement = AXUIElementCreateApplication(target.ownerPID)
        _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard let window = matchingAXWindow(for: target, in: appElement) else {
            return forceFrontmostIfNeeded(application)
        }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return forceFrontmostIfNeeded(application)
    }

    private func forceFrontmostIfNeeded(_ application: NSRunningApplication) -> Bool {
        let pid = application.processIdentifier
        for _ in 0..<4 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            usleep(25_000)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e",
            "tell application \"System Events\" to set frontmost of first application process whose unix id is \(pid) to true"
        ]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            traceInput("window activation osascript failed pid=\(pid) error=\(error.localizedDescription)")
            return false
        }

        for _ in 0..<6 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            usleep(25_000)
        }
        traceInput("window activation not confirmed pid=\(pid) status=\(task.terminationStatus)")
        return false
    }

    private func currentBounds(for target: WindowCaptureTarget) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return windows.first { info in
            Self.uint32Value(info[kCGWindowNumber as String]) == target.id
        }.flatMap(Self.windowBounds)
    }

    private func thumbnail(for windowID: CGWindowID) -> NSImage? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func pngBase64(from image: CGImage) -> String? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:])?.base64EncodedString()
    }

    private static func windowBounds(from info: [String: Any]) -> CGRect? {
        guard let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        return CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
    }

    private static func uint32Value(_ value: Any?) -> UInt32? {
        if let value = value as? UInt32 { return value }
        if let value = value as? Int { return UInt32(exactly: value) }
        if let value = value as? NSNumber { return UInt32(exactly: value.int64Value) }
        return nil
    }

    private static func int32Value(_ value: Any?) -> Int32? {
        if let value = value as? Int32 { return value }
        if let value = value as? Int { return Int32(exactly: value) }
        if let value = value as? NSNumber { return Int32(exactly: value.int64Value) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    func execute(
        _ actions: [RemoteAction],
        actionFrame: CGRect? = nil,
        targetWindow: WindowCaptureTarget? = nil,
        useBackgroundInput: Bool = false
    ) {
        for action in actions {
            execute(
                action,
                actionFrame: actionFrame,
                targetWindow: targetWindow,
                useBackgroundInput: useBackgroundInput
            )
        }
    }

    func execute(_ action: RemoteAction) {
        execute(action, actionFrame: nil)
    }

    func execute(
        _ action: RemoteAction,
        actionFrame: CGRect?,
        targetWindow: WindowCaptureTarget? = nil,
        useBackgroundInput: Bool = false
    ) {
        let targetPID = backgroundTargetPID(targetWindow: targetWindow, useBackgroundInput: useBackgroundInput)
        switch action.type {
        case .typeText:
            if let text = action.text { type(text, targetPID: targetPID) }
        case .pasteText:
            if let text = action.text { paste(text, targetPID: targetPID) }
        case .keyPress:
            if let key = action.key { press(key: key, modifiers: action.modifiers ?? [], targetPID: targetPID) }
        case .openURL:
            if let value = action.url ?? action.text, let url = URL(string: value) {
                NSWorkspace.shared.open(url)
            }
        case .openApplication:
            if let value = action.text ?? action.url {
                openApplication(value)
            }
        case .click:
            if let x = action.x,
               let y = action.y,
               (0...1).contains(x),
               (0...1).contains(y),
               let frame = actionFrame {
                clickNormalized(
                    x: x,
                    y: y,
                    in: frame,
                    targetWindow: targetWindow,
                    useBackgroundInput: useBackgroundInput
                )
            } else if useBackgroundInput, action.x == nil, action.y == nil, let targetWindow {
                let point = virtualCursor.currentPosition(fallbackWindow: targetWindow)
                clickAbsolute(
                    x: point.x,
                    y: point.y,
                    targetPID: targetPID,
                    targetWindow: targetWindow,
                    targetWindowID: targetWindow.id
                )
            } else {
                click(x: action.x, y: action.y, targetPID: targetPID, targetWindow: targetWindow, targetWindowID: targetWindow?.id)
            }
        case .locateAndClick:
            break
        case .closeWindow:
            closeWindow(target: action.text ?? action.url)
        case .quitApplication:
            quitApplication(target: action.text ?? action.url)
        case .wait:
            let seconds = max(0, min(10, action.amount ?? 1))
            usleep(useconds_t(seconds * 1_000_000))
        case .moveMouse:
            moveBy(dx: action.x ?? 0, dy: action.y ?? 0, targetPID: targetPID, targetWindow: targetWindow)
        case .scroll:
            let location = targetWindow.map { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY) }
            if action.x != nil || action.y != nil {
                scroll(dx: action.x ?? 0, dy: action.y ?? 0, targetPID: targetPID, location: location, targetWindowID: targetWindow?.id)
            } else {
                scroll(amount: action.amount ?? 0, targetPID: targetPID, location: location, targetWindowID: targetWindow?.id)
            }
        case .swipe:
            swipe(
                direction: action.text ?? action.key,
                startX: action.x,
                startY: action.y,
                amount: action.amount,
                actionFrame: actionFrame,
                targetWindow: targetWindow,
                targetPID: targetPID
            )
        case .runAppleScript:
            if let script = action.text {
                _ = runAppleScript(script)
            }
        }
    }

    private func backgroundTargetPID(targetWindow: WindowCaptureTarget?, useBackgroundInput: Bool) -> pid_t? {
        guard useBackgroundInput, let targetWindow else { return nil }
        return targetWindow.ownerPID
    }

    func type(_ text: String) {
        paste(text)
    }

    func typeKeyboardText(_ text: String, targetApplication: NSRunningApplication?) {
        guard !text.isEmpty else { return }
        let targetPID = keyboardTargetPID(targetApplication)
        for character in text {
            postUnicodeText(String(character), targetPID: targetPID)
            usleep(18_000)
        }
    }

    private func type(_ text: String, targetPID: pid_t?) {
        paste(text, targetPID: targetPID)
    }

    func insertText(
        _ text: String,
        targetApplication: NSRunningApplication?,
        targetWindow: WindowCaptureTarget? = nil,
        useBackgroundInput: Bool = false
    ) async -> TextInsertionDiagnostics {
        let backgroundPID = backgroundTargetPID(targetWindow: targetWindow, useBackgroundInput: useBackgroundInput)
        let foregroundTarget = targetApplication.flatMap { application -> NSRunningApplication? in
            guard !application.isTerminated,
                  application.processIdentifier != NSRunningApplication.current.processIdentifier else {
                return nil
            }
            return application
        }
        let targetPID = backgroundPID ?? foregroundTarget?.processIdentifier
        let trusted = AXIsProcessTrusted()
        var methods: [String] = ["clipboard"]

        copyToClipboard(text)
        if let foregroundTarget, backgroundPID == nil, performPasteMenuItem(in: foregroundTarget) {
            methods.insert("accessibilityMenu", at: 0)
        } else if let targetPID {
            postPasteShortcut(to: targetPID)
            methods.insert("postToPid", at: 0)
        } else {
            pressPasteShortcut()
            methods.insert("hid", at: 0)
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        // Without Accessibility permission macOS drops the paste event. Keep the
        // transcript on the clipboard so the user's words are never lost.
        if trusted {
            _ = restoreClipboardIfBackedUp(text)
        }

        let result: TextInsertionResult = trusted && targetPID != nil ? .direct : .clipboard

        return TextInsertionDiagnostics(
            result: result,
            accessibilityTrusted: trusted,
            frontmostApplication: NSWorkspace.shared.frontmostApplication?.localizedName ?? "None",
            clipboardMatches: NSPasteboard.general.string(forType: .string) == text,
            methods: methods
        )
    }

    func paste(_ text: String) {
        copyToClipboard(text)
        pressPasteShortcut()
    }

    private func paste(_ text: String, targetPID: pid_t?) {
        copyToClipboard(text)
        if let targetPID {
            postPasteShortcut(to: targetPID)
        } else {
            pressPasteShortcut()
        }
    }

private struct ClipboardBackup {
    let items: [[NSPasteboard.PasteboardType: Data]]
}

private var clipboardBackup: ClipboardBackup?

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        // Back up all existing pasteboard items with every type
        if let items = pasteboard.pasteboardItems, !items.isEmpty {
            var backedUpItems: [[NSPasteboard.PasteboardType: Data]] = []
            for item in items {
                var typeData: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        typeData[type] = data
                    }
                }
                if !typeData.isEmpty {
                    backedUpItems.append(typeData)
                }
            }
            clipboardBackup = backedUpItems.isEmpty ? nil : ClipboardBackup(items: backedUpItems)
        } else {
            clipboardBackup = nil
        }
        // Write dictated text to clipboard (this overwrites existing)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

   private func restoreClipboardIfBackedUp(_ text: String) -> Bool {
        guard let backup = clipboardBackup else { return false }
        defer { clipboardBackup = nil }
        // Only restore if clipboard still has the dictated text (user hasn't changed it)
        if NSPasteboard.general.string(forType: .string) == text {
            NSPasteboard.general.clearContents()
            let items = backup.items.map { typeData -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in typeData {
                    item.setData(data, forType: type)
                }
                return item
            }
            NSPasteboard.general.writeObjects(items)
            return true
        }
        return false
    }

   private func pasteFromClipboard(_ text: String) async {
        copyToClipboard(text)
        try? await Task.sleep(nanoseconds: 500_000_000) // Increased wait for paste to complete
        pressPasteShortcut()
        try? await Task.sleep(nanoseconds: 200_000_000) // Wait after paste
        // Restore original clipboard content after pasting the dictated text
        _ = restoreClipboardIfBackedUp(text)
    }

    private func pressPasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0

        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
        commandDown?.flags = .maskCommand
        markSynthetic(commandDown)
        commandDown?.post(tap: .cghidEventTap)

        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        vDown?.flags = .maskCommand
        markSynthetic(vDown)
        vDown?.post(tap: .cghidEventTap)

        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vUp?.flags = .maskCommand
        markSynthetic(vUp)
        vUp?.post(tap: .cghidEventTap)

        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
        commandUp?.flags = []
        markSynthetic(commandUp)
        commandUp?.post(tap: .cghidEventTap)
    }

    private func postPasteShortcut(to pid: pid_t) {
        let source = eventSource(targetPID: pid)
        source?.localEventsSuppressionInterval = 0

        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
        commandDown?.flags = .maskCommand
        markSynthetic(commandDown)
        commandDown?.postToPid(pid)

        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        vDown?.flags = .maskCommand
        markSynthetic(vDown)
        vDown?.postToPid(pid)

        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vUp?.flags = .maskCommand
        markSynthetic(vUp)
        vUp?.postToPid(pid)

        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
        commandUp?.flags = []
        markSynthetic(commandUp)
        commandUp?.postToPid(pid)
    }

    private func performPasteMenuItem(in application: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarRef,
              CFGetTypeID(menuBarRef) == AXUIElementGetTypeID() else {
            return false
        }
        return pressMenuItem(named: "Paste", in: menuBarRef as! AXUIElement)
    }

    private func pressMenuItem(named name: String, in element: AXUIElement, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }

        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String,
           title == name,
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return false
        }

        for child in children {
            if pressMenuItem(named: name, in: child, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    func press(key: String, modifiers: [String] = []) {
        press(key: key, modifiers: modifiers, targetPID: nil)
    }

    func showMissionControl() {
        let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        guard FileManager.default.fileExists(atPath: missionControlURL.path) else {
            traceInput("mission-control backend=application-unavailable fallback=control-up")
            press(key: "up", modifiers: ["control"])
            return
        }

        // Launching the system app asks Dock to enter Mission Control directly.
        // Unlike a synthesized Control-Up chord, this does not leave the
        // gesture/keyboard transition active and pointer clicks remain usable.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [missionControlURL.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let succeeded = task.terminationReason == .exit && task.terminationStatus == 0
            traceInput("mission-control backend=application status=\(task.terminationStatus)")
            if succeeded {
                missionControlSelectionPending = true
            } else {
                press(key: "up", modifiers: ["control"])
            }
        } catch {
            traceInput("mission-control backend=application-failed error=\(error.localizedDescription) fallback=control-up")
            press(key: "up", modifiers: ["control"])
        }
    }

    func press(key: String, modifiers: [String] = [], targetApplication: NSRunningApplication?) {
        press(key: key, modifiers: modifiers, targetPID: keyboardTargetPID(targetApplication))
    }

    private func press(key: String, modifiers: [String] = [], targetPID: pid_t?) {
        guard let keyCode = Self.keyCode(for: key) else { return }
        press(keyCode: keyCode, flags: Self.flags(for: modifiers), targetPID: targetPID)
    }

    private func keyboardTargetPID(_ application: NSRunningApplication?) -> pid_t? {
        guard let application,
              !application.isTerminated,
              application.processIdentifier != NSRunningApplication.current.processIdentifier else {
            return nil
        }
        return application.processIdentifier
    }

    private func postUnicodeText(_ text: String, targetPID: pid_t?) {
        guard let source = targetPID.flatMap(eventSource(targetPID:)) ?? CGEventSource(stateID: .hidSystemState) else {
            return
        }
        source.localEventsSuppressionInterval = 0

        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        setUnicode(text, on: down)
        markSynthetic(down)
        postKeyboardEvent(down, targetPID: targetPID)
        usleep(18_000)

        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        setUnicode(text, on: up)
        markSynthetic(up)
        postKeyboardEvent(up, targetPID: targetPID)
    }

    private func setUnicode(_ text: String, on event: CGEvent?) {
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
    }

    private func postKeyboardEvent(_ event: CGEvent?, targetPID: pid_t?) {
        if let targetPID {
            event?.postToPid(targetPID)
        } else {
            event?.post(tap: .cghidEventTap)
        }
    }

    func dismissTransientUI() {
        press(key: "escape")
    }

    func dismissTransientUI(targetWindow: WindowCaptureTarget?, useBackgroundInput: Bool = false) {
        let targetPID = backgroundTargetPID(targetWindow: targetWindow, useBackgroundInput: useBackgroundInput)
        press(key: "escape", targetPID: targetPID)
    }

    func focusSearchFieldInFrontmostBrowser() -> Bool {
        if focusSearchFieldWithAccessibility() {
            return true
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName?.lowercased(),
              name.contains("safari") || name.contains("chrome") || name.contains("edge") || name.contains("brave") else {
            return false
        }

        if name.contains("safari") {
            return runAppleScript("""
            tell application "Safari"
                if not (exists front document) then return false
                do JavaScript "\(Self.browserSearchFieldJavaScript)" in front document
            end tell
            """)
        }

        let appName = app.localizedName ?? "Google Chrome"
        return runAppleScript("""
        tell application "\(appName)"
            if not (exists front window) then return false
            tell active tab of front window to execute javascript "\(Self.browserSearchFieldJavaScript)"
        end tell
        """)
    }

    private func focusSearchFieldWithAccessibility() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let target = findSearchField(in: appElement) else { return false }

        AXUIElementSetAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, target)
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if AXUIElementPerformAction(target, kAXPressAction as CFString) == .success {
            return true
        }

        if let center = centerPoint(of: target) {
            postClick(at: center)
            return true
        }
        return false
    }

    private func findSearchField(in root: AXUIElement) -> AXUIElement? {
        var best: (element: AXUIElement, score: Int)?
        collectSearchFieldCandidates(in: root, depth: 0, best: &best)
        return best?.element
    }

    private func collectSearchFieldCandidates(in element: AXUIElement, depth: Int, best: inout (element: AXUIElement, score: Int)?) {
        guard depth < 9 else { return }

        if let score = searchFieldScore(for: element), score > (best?.score ?? Int.min) {
            best = (element, score)
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return
        }
        for child in children {
            collectSearchFieldCandidates(in: child, depth: depth + 1, best: &best)
        }
    }

    private func searchFieldScore(for element: AXUIElement) -> Int? {
        let role = axString(element, kAXRoleAttribute)?.lowercased() ?? ""
        let subrole = axString(element, kAXSubroleAttribute)?.lowercased() ?? ""
        let text = [
            role,
            subrole,
            axString(element, kAXTitleAttribute),
            axString(element, kAXDescriptionAttribute),
            axString(element, kAXHelpAttribute),
            axString(element, kAXPlaceholderValueAttribute),
            axString(element, kAXValueAttribute)
        ].compactMap { $0?.lowercased() }.joined(separator: " ")

        let editableRole = role.contains("textfield") ||
            role.contains("combobox") ||
            role.contains("searchfield") ||
            role.contains("textarea")
        guard editableRole || text.contains("search") else { return nil }

        var score = 0
        if editableRole { score += 20 }
        if role.contains("searchfield") || subrole.contains("search") { score += 60 }
        if text.contains("search") { score += 50 }
        if text.contains("address") || text.contains("url") { score -= 35 }
        if let rect = rect(of: element) {
            guard rect.width > 80, rect.height > 14 else { return nil }
            score += min(25, Int(rect.width / 50))
            score -= max(0, Int((rect.minY - 220) / 40))
        }
        return score >= 35 ? score : nil
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func centerPoint(of element: AXUIElement) -> CGPoint? {
        guard let rect = rect(of: element) else { return nil }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func frontmostWindowRect() -> CGRect? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in ["AXFocusedWindow", "AXMainWindow"] {
            if let window = copyAXElementAttribute(attribute, from: appElement),
               let rect = rect(of: window),
               rect.width > 80,
               rect.height > 80 {
                return rect
            }
        }

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        return windows.compactMap { rect(of: $0) }.first { $0.width > 80 && $0.height > 80 }
    }

    private func matchingAXWindow(for target: WindowCaptureTarget, in appElement: AXUIElement) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        let targetTitle = target.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !targetTitle.isEmpty,
           let titled = windows.first(where: {
               axString($0, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) == targetTitle
           }) {
            return titled
        }

        return windows.first { window in
            guard let rect = rect(of: window) else { return false }
            return abs(rect.minX - target.bounds.minX) < 12 &&
                abs(rect.minY - target.bounds.minY) < 12 &&
                abs(rect.width - target.bounds.width) < 24 &&
                abs(rect.height - target.bounds.height) < 24
        } ?? windows.first
    }

    private func rect(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    func clickCurrentMouse() {
        click(x: nil, y: nil)
    }

    func moveBy(dx: Double, dy: Double) {
        moveBy(dx: dx, dy: dy, targetPID: nil, targetWindow: nil)
    }

    func mouseDownCurrent() {
        postCurrentMouseButton(type: .leftMouseDown, pressure: 1.0)
    }

    func mouseUpCurrent() {
        postCurrentMouseButton(type: .leftMouseUp, pressure: 0.0)
    }

    func dragCurrentMouseBy(dx: Double, dy: Double) {
        guard let event = CGEvent(source: nil) else { return }
        let current = event.location
        let point = DesktopPointerBounds.constrain(
            CGPoint(x: current.x + dx, y: current.y - dy),
            to: connectedDisplayBounds()
        )
        CGWarpMouseCursorPosition(point)
        let source = eventSource(targetPID: nil)
        source?.localEventsSuppressionInterval = 0
        let dragEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)
        prepareMouseEvent(
            dragEvent,
            clickState: 1,
            targetPID: nil,
            targetWindowID: nil,
            pressure: 1.0,
            eventNumber: nextMouseEventNumber()
        )
        postMouseEvent(dragEvent, targetPID: nil)
    }

    private func moveBy(dx: Double, dy: Double, targetPID: pid_t?, targetWindow: WindowCaptureTarget?) {
        guard let event = CGEvent(source: nil) else { return }
        if let targetPID {
            let point = virtualCursor.moveBy(dx: dx, dy: dy, fallbackWindow: targetWindow)
            let source = eventSource(targetPID: targetPID)
            let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            postMouseEvent(moveEvent, targetPID: targetPID)
            return
        }

        let current = event.location
        let point = DesktopPointerBounds.constrain(
            CGPoint(x: current.x + dx, y: current.y - dy),
            to: connectedDisplayBounds()
        )
        CGWarpMouseCursorPosition(point)
        // Post a synthetic mouse move event to unhide cursor when macOS has hidden it
        let source = CGEventSource(stateID: .combinedSessionState)
        let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        postMouseEvent(moveEvent, targetPID: nil)
    }

    private func connectedDisplayBounds() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
    }

    private func postCurrentMouseButton(type: CGEventType, pressure: Double) {
        guard let point = CGEvent(source: nil)?.location else { return }
        let source = eventSource(targetPID: nil)
        source?.localEventsSuppressionInterval = 0
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        prepareMouseEvent(
            event,
            clickState: 1,
            targetPID: nil,
            targetWindowID: nil,
            pressure: pressure,
            eventNumber: nextMouseEventNumber()
        )
        postMouseEvent(event, targetPID: nil)
    }

    func scroll(amount: Double) {
        scroll(amount: amount, targetPID: nil, location: nil)
    }

    private func scroll(amount: Double, targetPID: pid_t?, location: CGPoint? = nil, targetWindowID: CGWindowID? = nil) {
        scroll(dx: 0, dy: amount, targetPID: targetPID, location: location, targetWindowID: targetWindowID)
    }

    func scroll(dx: Double, dy: Double) {
        scroll(dx: dx, dy: dy, targetPID: nil, location: nil)
    }

    private func scroll(
        dx: Double,
        dy: Double,
        targetPID: pid_t?,
        location: CGPoint? = nil,
        targetWindowID: CGWindowID? = nil
    ) {
        let horizontalUnits = Int32(max(-60, min(60, dx)))
        let verticalUnits = Int32(max(-60, min(60, dy)))
        let source = eventSource(targetPID: targetPID)
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: verticalUnits, wheel2: horizontalUnits, wheel3: 0)
        if let location {
            event?.location = location
        }
        event?.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(verticalUnits))
        event?.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(horizontalUnits))
        event?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(verticalUnits))
        event?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(horizontalUnits))
        if let targetPID {
            event?.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
        }
        if let targetWindowID {
            let windowID = Int64(targetWindowID)
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        }
        markSynthetic(event)
        if targetPID != nil, let location {
            virtualCursor.move(to: location)
        }
        if let targetPID {
            event?.postToPid(targetPID)
        } else {
            event?.post(tap: .cghidEventTap)
        }
    }

    private func swipe(
        direction rawDirection: String?,
        startX: Double?,
        startY: Double?,
        amount: Double?,
        actionFrame: CGRect?,
        targetWindow: WindowCaptureTarget?,
        targetPID: pid_t?
    ) {
        let direction = (rawDirection ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["left", "right", "up", "down"].contains(direction) else { return }

        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        let frame = actionFrame ?? frontmostWindowRect() ?? displayBounds
        let isIPhoneMirroring = targetWindow?.isIPhoneMirroring == true
        let gestureBounds = gestureSafeBounds(frame: frame, targetWindow: targetWindow)
        let start: CGPoint
        if let startX,
           let startY,
           (0...1).contains(startX),
           (0...1).contains(startY),
           isUsableSwipeStart(x: startX, y: startY, isIPhoneMirroring: isIPhoneMirroring) {
            start = CGPoint(
                x: gestureBounds.minX + startX * gestureBounds.width,
                y: gestureBounds.minY + startY * gestureBounds.height
            )
        } else {
            start = CGPoint(x: gestureBounds.midX, y: gestureBounds.midY)
        }

        let fraction = min(0.85, max(0.05, amount ?? 0.35))
        let distance = max(80, min(gestureBounds.width, gestureBounds.height) * fraction)
        let end: CGPoint = switch direction {
        case "left":
            CGPoint(x: start.x - distance, y: start.y)
        case "right":
            CGPoint(x: start.x + distance, y: start.y)
        case "up":
            CGPoint(x: start.x, y: start.y - distance)
        default:
            CGPoint(x: start.x, y: start.y + distance)
        }

        if targetWindow?.prefersScrollBasedSwipes == true && targetWindow?.isIPhoneMirroring != true {
            if accessibilityScrollForSwipe(direction: direction, location: start, targetWindow: targetWindow) {
                return
            }
            scrollForSwipe(
                direction: direction,
                distance: distance,
                location: clamped(point: start, in: gestureBounds),
                targetPID: targetPID,
                targetWindowID: targetWindow?.id
            )
            return
        }

        drag(
            from: clamped(point: start, in: gestureBounds),
            to: clamped(point: end, in: gestureBounds),
            duration: isIPhoneMirroring ? 0.42 : 0.28,
            targetPID: targetPID,
            targetWindowID: targetWindow?.id,
            preferDirectProcessMouse: isIPhoneMirroring
        )
    }

    private func gestureSafeBounds(frame: CGRect, targetWindow: WindowCaptureTarget?) -> CGRect {
        let bounds = targetWindow?.bounds ?? frame
        let insetX = min(36, max(12, bounds.width * 0.06))
        let insetY = min(36, max(12, bounds.height * 0.06))
        let inset = bounds.insetBy(dx: insetX, dy: insetY)
        return inset.width > 40 && inset.height > 40 ? inset : bounds
    }

    private func isUsableSwipeStart(x: Double, y: Double, isIPhoneMirroring: Bool) -> Bool {
        guard !(x == 0 && y == 0) else { return false }
        guard isIPhoneMirroring else { return true }
        return x > 0.06 && x < 0.94 && y > 0.06 && y < 0.94
    }

    private func accessibilityScrollForSwipe(
        direction: String,
        location: CGPoint,
        targetWindow: WindowCaptureTarget?
    ) -> Bool {
        guard AXIsProcessTrusted(),
              let targetWindow,
              let actionName = accessibilityScrollActionName(for: direction) else {
            return false
        }

        let appElement = AXUIElementCreateApplication(targetWindow.ownerPID)
        let root = matchingAXWindow(for: targetWindow, in: appElement) ?? appElement
        let targetPoint = clamped(point: location, in: targetWindow.bounds)
        let candidate = scrollCandidate(
            in: root,
            actionName: actionName,
            point: targetPoint,
            requirePointContainment: true
        ) ?? scrollCandidate(
            in: root,
            actionName: actionName,
            point: targetPoint,
            requirePointContainment: false
        )

        guard let candidate else {
            return false
        }

        let result = AXUIElementPerformAction(candidate, actionName as CFString)
        if result == .success {
            print("[action] accessibility scroll swipe direction=\(direction) action=\(actionName)")
            return true
        }
        return false
    }

    private func accessibilityScrollActionName(for direction: String) -> String? {
        switch direction {
        case "left": "AXScrollLeftByPage"
        case "right": "AXScrollRightByPage"
        case "up": "AXScrollUpByPage"
        case "down": "AXScrollDownByPage"
        default: nil
        }
    }

    private func scrollCandidate(
        in root: AXUIElement,
        actionName: String,
        point: CGPoint,
        requirePointContainment: Bool
    ) -> AXUIElement? {
        var best: (element: AXUIElement, area: Double, depth: Int)?
        collectScrollCandidates(
            in: root,
            actionName: actionName,
            point: point,
            requirePointContainment: requirePointContainment,
            depth: 0,
            best: &best
        )
        return best?.element
    }

    private func collectScrollCandidates(
        in element: AXUIElement,
        actionName: String,
        point: CGPoint,
        requirePointContainment: Bool,
        depth: Int,
        best: inout (element: AXUIElement, area: Double, depth: Int)?
    ) {
        guard depth < 10 else { return }

        let rect = rect(of: element)
        let containsPoint = rect?.contains(point) ?? (depth == 0)
        if containsPoint || !requirePointContainment {
            if actionNames(of: element).contains(actionName) {
                let area = rect.map { max(1, $0.width * $0.height) } ?? Double.greatestFiniteMagnitude
                if best == nil ||
                    area < best!.area ||
                    (area == best!.area && depth > best!.depth) {
                    best = (element, area, depth)
                }
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return
        }

        for child in children {
            collectScrollCandidates(
                in: child,
                actionName: actionName,
                point: point,
                requirePointContainment: requirePointContainment,
                depth: depth + 1,
                best: &best
            )
        }
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String] else {
            return []
        }
        return actions
    }

    private func scrollForSwipe(
        direction: String,
        distance: Double,
        location: CGPoint,
        targetPID: pid_t?,
        targetWindowID: CGWindowID?
    ) {
        let units = max(80, min(900, distance * 1.35))
        let step = min(60, max(20, units / 8))
        let repetitions = max(2, min(18, Int(ceil(units / step))))
        let postBurst: (Double, Double) -> Void = { dx, dy in
            for _ in 0..<repetitions {
                self.scroll(dx: dx, dy: dy, targetPID: targetPID, location: location, targetWindowID: targetWindowID)
                usleep(8_000)
            }
        }
        print("[action] targeted scroll swipe direction=\(direction) repetitions=\(repetitions) targetPID=\(targetPID.map(String.init) ?? "hid")")
        switch direction {
        case "left":
            postBurst(-step, 0)
        case "right":
            postBurst(step, 0)
        case "up":
            postBurst(0, step)
        default:
            postBurst(0, -step)
        }
    }

    private func drag(
        from start: CGPoint,
        to end: CGPoint,
        duration: Double,
        targetPID: pid_t? = nil,
        targetWindowID: CGWindowID? = nil,
        preferDirectProcessMouse: Bool = false
    ) {
        let steps = 14
        let stepDelay = useconds_t(max(5_000, min(40_000, duration * 1_000_000 / Double(steps))))
        if targetPID == nil {
            CGWarpMouseCursorPosition(start)
        } else {
            virtualCursor.move(to: start)
        }

        if preferDirectProcessMouse, let targetPID {
            let delivered = SkyLightInputBridge.shared.drag(
                pid: targetPID,
                from: start,
                to: end,
                steps: steps,
                stepDelay: stepDelay
            )
            if delivered {
                virtualCursor.move(to: end, animated: false)
                virtualCursor.click(at: end)
                traceInput(
                    "drag backend=skylight pid=\(targetPID) window=\(targetWindowID.map(String.init) ?? "none") fromX=\(String(format: "%.1f", start.x)) fromY=\(String(format: "%.1f", start.y)) toX=\(String(format: "%.1f", end.x)) toY=\(String(format: "%.1f", end.y))"
                )
                return
            }
            traceInput(
                "drag backend=skylight-unavailable fallback=postToPid pid=\(targetPID) window=\(targetWindowID.map(String.init) ?? "none")"
            )
            if postHIDDragWithCursorRestore(from: start, to: end, duration: duration, steps: steps, stepDelay: stepDelay) {
                virtualCursor.move(to: end, animated: false)
                virtualCursor.click(at: end)
                traceInput(
                    "drag backend=hidBridge pid=\(targetPID) window=\(targetWindowID.map(String.init) ?? "none") fromX=\(String(format: "%.1f", start.x)) fromY=\(String(format: "%.1f", start.y)) toX=\(String(format: "%.1f", end.x)) toY=\(String(format: "%.1f", end.y))"
                )
                return
            }
        }

        let microActivation: SkyLightInputBridge.MicroActivationToken?
        if preferDirectProcessMouse, let targetPID {
            microActivation = SkyLightInputBridge.shared.beginMicroActivation(pid: targetPID, windowID: targetWindowID)
        } else {
            microActivation = nil
        }
        defer {
            if let microActivation {
                SkyLightInputBridge.shared.endMicroActivation(microActivation)
            }
        }

        let source = eventSource(targetPID: targetPID)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
        prepareMouseEvent(
            down,
            clickState: 1,
            targetPID: targetPID,
            targetWindowID: targetWindowID,
            pressure: 1.0,
            eventNumber: nextMouseEventNumber()
        )
        postMouseEvent(down, targetPID: targetPID)

        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            usleep(stepDelay)
            if targetPID != nil {
                virtualCursor.move(to: point, animated: false)
            }
            let moved = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)
            prepareMouseEvent(
                moved,
                clickState: 1,
                targetPID: targetPID,
                targetWindowID: targetWindowID,
                pressure: 1.0,
                eventNumber: nextMouseEventNumber()
            )
            postMouseEvent(moved, targetPID: targetPID)
        }

        usleep(20_000)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
        prepareMouseEvent(
            up,
            clickState: 1,
            targetPID: targetPID,
            targetWindowID: targetWindowID,
            pressure: 0.0,
            eventNumber: nextMouseEventNumber()
        )
        postMouseEvent(up, targetPID: targetPID)
        if targetPID != nil {
            virtualCursor.click(at: end)
        }
    }

    private func clamped(point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(bounds.maxX - 1, max(bounds.minX, point.x)),
            y: min(bounds.maxY - 1, max(bounds.minY, point.y))
        )
    }

    func screenshotBase64() -> String? {
        captureDisplay()?.imageBase64
    }

    private func openApplication(_ nameOrBundleIdentifier: String) {
        let trimmed = nameOrBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.contains("."),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            return
        }

        if let url = Self.applicationURL(named: trimmed) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    private func closeWindow(target: String?) {
        guard hasNamedTarget(target) else {
            print("[action] close_window ignored without named target")
            return
        }
        guard let application = runningApplication(named: target) else {
            print("[action] close_window target not found: \(target ?? "")")
            return
        }
        if closeAccessibilityWindow(in: application) {
            return
        }
        if closeWindowsWithAppleScript(in: application) {
            return
        }
        print("[action] close_window target has no closable windows: \(application.localizedName ?? target ?? "")")
    }

    private func quitApplication(target: String?) {
        if hasNamedTarget(target) {
            guard let application = runningApplication(named: target) else {
                print("[action] quit_app target not found: \(target ?? "")")
                return
            }
            application.terminate()
            return
        }
        if let application = runningApplication(named: target) {
            application.terminate()
        } else {
            press(key: "q", modifiers: ["command"])
        }
    }

    private func activateRunningApplication(named name: String?) {
        guard let application = runningApplication(named: name) else { return }
        _ = application.activate()
        usleep(200_000)
    }

    private func closeAccessibilityWindow(in application: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)

        for attribute in ["AXFocusedWindow", "AXMainWindow"] {
            if let window = copyAXElementAttribute(attribute, from: appElement),
               closeAXWindow(window) {
                return true
            }
        }

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return false
        }

        for window in windows where closeAXWindow(window) {
            return true
        }
        return false
    }

    private func closeAXWindow(_ window: AXUIElement) -> Bool {
        if AXUIElementPerformAction(window, "AXClose" as CFString) == .success {
            return true
        }

        if let closeButton = copyAXElementAttribute("AXCloseButton", from: window),
           AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success {
            return true
        }

        return false
    }

    private func closeWindowsWithAppleScript(in application: NSRunningApplication) -> Bool {
        guard let appName = application.localizedName, !appName.isEmpty else { return false }
        let escapedAppName = appName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = """
        tell application "\(escapedAppName)"
            if it is running then
                try
                    close every window
                    return "closed"
                on error
                    return "failed"
                end try
            end if
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: scriptSource)?.executeAndReturnError(&error)
        if let error {
            print("[action] close_window AppleScript error: \(error)")
            return false
        }
        return result?.stringValue == "closed"
    }

    private func copyAXElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func hasNamedTarget(_ target: String?) -> Bool {
        !Self.normalizedApplicationName(target ?? "").isEmpty
    }

    private func runningApplication(named name: String?) -> NSRunningApplication? {
        guard let name else { return nil }
        let normalized = Self.normalizedApplicationName(name)
        guard !normalized.isEmpty else { return nil }

        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.processIdentifier != NSRunningApplication.current.processIdentifier
        }

        if let exact = applications.first(where: { app in
            Self.normalizedApplicationName(app.localizedName ?? "") == normalized ||
            Self.normalizedApplicationName(app.bundleIdentifier ?? "") == normalized
        }) {
            return exact
        }

        return applications.first { app in
            let appName = Self.normalizedApplicationName(app.localizedName ?? "")
            let bundleID = Self.normalizedApplicationName(app.bundleIdentifier ?? "")
            return appName.contains(normalized) || bundleID.contains(normalized)
        }
    }

    private static func normalizedApplicationName(_ value: String) -> String {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: #"[\.,!?]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(the|this|current)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(app|application|window)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.app$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "chrome":
            return "google chrome"
        case "code", "vs code":
            return "visual studio code"
        case "settings", "preferences":
            return "system settings"
        case "chat gpt":
            return "chatgpt"
        default:
            return normalized
        }
    }

    private static func applicationURL(named name: String) -> URL? {
        let candidates = [
            name,
            "\(name).app"
        ]
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(NSHomeDirectory())/Applications"
        ]

        for root in roots {
            for candidate in candidates {
                let url = URL(fileURLWithPath: root).appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    func clickNormalized(x: Double, y: Double) {
        clickNormalized(x: x, y: y, in: CGDisplayBounds(CGMainDisplayID()))
    }

    func clickNormalized(
        x: Double,
        y: Double,
        in frame: CGRect,
        targetWindow: WindowCaptureTarget? = nil,
        useBackgroundInput: Bool = false
    ) {
        let targetPID = backgroundTargetPID(targetWindow: targetWindow, useBackgroundInput: useBackgroundInput)
        clickAbsolute(
            x: frame.minX + x * frame.width,
            y: frame.minY + y * frame.height,
            targetPID: targetPID,
            targetWindow: targetWindow,
            targetWindowID: targetWindow?.id
        )
    }

    private func press(keyCode: CGKeyCode, flags: CGEventFlags = [], targetPID: pid_t? = nil) {
        if let targetPID {
            postKey(keyCode: keyCode, flags: flags, targetPID: targetPID)
            return
        }

        // Mission Control ignores subsequent clicks when a long-lived process
        // invokes Control+Arrow through an in-process NSAppleScript. Run the
        // shortcut in a short-lived helper so the AppleEvent client is gone
        // before Mission Control starts accepting pointer input.
        if flags.contains(.maskControl) {
            if !postExternalSystemShortcut(keyCode: keyCode, flags: flags) {
                postNativeSystemShortcut(keyCode: keyCode, flags: flags)
            }
            return
        }

        if flags.contains(.maskCommand) {
            tryAppleScriptPress(keyCode: keyCode, flags: flags)
            return
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.localEventsSuppressionInterval = 0

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        markSynthetic(down)
        down?.post(tap: .cghidEventTap)
        usleep(50_000)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        markSynthetic(up)
        up?.post(tap: .cghidEventTap)
    }

    private func postExternalSystemShortcut(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let script = SystemShortcutEventSequence.appleScriptSource(keyCode: keyCode, flags: flags)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let succeeded = task.terminationReason == .exit && task.terminationStatus == 0
            traceInput(
                "shortcut backend=external-osascript keyCode=\(keyCode) flags=0x\(String(flags.rawValue, radix: 16)) status=\(task.terminationStatus)"
            )
            return succeeded
        } catch {
            traceInput(
                "shortcut backend=external-osascript-failed keyCode=\(keyCode) error=\(error.localizedDescription)"
            )
            return false
        }
    }

    private func postNativeSystemShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.localEventsSuppressionInterval = 0
        traceInput("shortcut backend=native keyCode=\(keyCode) flags=0x\(String(flags.rawValue, radix: 16))")

        for specification in SystemShortcutEventSequence.make(keyCode: keyCode, flags: flags) {
            let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: specification.keyCode,
                keyDown: specification.isKeyDown
            )
            event?.flags = specification.flags
            event?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags, targetPID: pid_t) {
        guard let source = eventSource(targetPID: targetPID) else { return }
        source.localEventsSuppressionInterval = 0

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        markSynthetic(down)
        down?.postToPid(targetPID)
        usleep(50_000)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        markSynthetic(up)
        up?.postToPid(targetPID)
    }

    private static let appleScriptCache = NSMutableDictionary()

    private func tryAppleScriptPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let modifierStr = modifierFlagsToString(flags)
        
        var scriptSource = "tell application \"System Events\" to key code \(keyCode)"
        if !modifierStr.isEmpty {
            scriptSource += " using \(modifierStr)"
        }
        
        var script = Self.appleScriptCache.object(forKey: scriptSource as NSString) as? NSAppleScript
        if script == nil {
            script = NSAppleScript(source: scriptSource)
            if let script {
                Self.appleScriptCache.setObject(script, forKey: scriptSource as NSString)
            }
        }
        
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error = error {
            print("[keypost] AppleScript error: \(error)")
        }
        if result == nil {
            fallBackCGEvent(keyCode: keyCode, flags: flags)
        }
    }

    private func fallBackCGEvent(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.localEventsSuppressionInterval = 0

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        markSynthetic(down)
        down?.post(tap: .cghidEventTap)
        usleep(50_000)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        markSynthetic(up)
        up?.post(tap: .cghidEventTap)
    }

    private func modifierFlagsToString(_ flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("control down") }
        if flags.contains(.maskCommand) { parts.append("command down") }
        if flags.contains(.maskShift) { parts.append("shift down") }
        if flags.contains(.maskAlternate) { parts.append("option down") }
        return parts.joined(separator: " and ")
    }

    private func click(
        x: Double?,
        y: Double?,
        targetPID: pid_t? = nil,
        targetWindow: WindowCaptureTarget? = nil,
        targetWindowID: CGWindowID? = nil
    ) {
        if let x, let y {
            clickAbsolute(x: x, y: y, targetPID: targetPID, targetWindow: targetWindow, targetWindowID: targetWindowID)
        } else if targetPID != nil {
            postClick(
                at: virtualCursor.currentPosition(fallbackWindow: targetWindow),
                targetPID: targetPID,
                targetWindow: targetWindow,
                targetWindowID: targetWindowID
            )
        } else if let event = CGEvent(source: nil) {
            postClick(at: event.location, targetPID: targetPID, targetWindow: targetWindow, targetWindowID: targetWindowID)
        }
    }

    private func clickAbsolute(
        x: Double,
        y: Double,
        targetPID: pid_t? = nil,
        targetWindow: WindowCaptureTarget? = nil,
        targetWindowID: CGWindowID? = nil
    ) {
        postClick(at: CGPoint(x: x, y: y), targetPID: targetPID, targetWindow: targetWindow, targetWindowID: targetWindowID)
    }

    private func postClick(
        at point: CGPoint,
        targetPID: pid_t? = nil,
        targetWindow: WindowCaptureTarget? = nil,
        targetWindowID: CGWindowID? = nil
    ) {
        if targetPID == nil {
            CGWarpMouseCursorPosition(point)
            if missionControlSelectionPending, postExternalSystemClick(at: point) {
                missionControlSelectionPending = false
                traceInput(
                    "click backend=mission-control-system-events x=\(String(format: "%.1f", point.x)) y=\(String(format: "%.1f", point.y))"
                )
                return
            }
            if activateWindowUnderPointer(at: point) {
                // Let WindowServer finish the app/window ordering transition
                // before delivering the click to the newly raised window.
                usleep(45_000)
            }
        } else if let targetPID {
            virtualCursor.click(at: point)
            if targetWindow?.isIPhoneMirroring != true,
               performAccessibilityClick(at: point, targetPID: targetPID) {
                traceInput(
                    "click backend=axPress pid=\(targetPID) window=\(targetWindowID.map(String.init) ?? "none") x=\(String(format: "%.1f", point.x)) y=\(String(format: "%.1f", point.y))"
                )
                return
            }
            if targetWindow?.isIPhoneMirroring == true {
                let delivered = SkyLightInputBridge.shared.click(pid: targetPID, point: point)
                if delivered {
                    traceInput(
                        "click backend=skylight pid=\(targetPID) window=\(targetWindowID.map(String.init) ?? "none") x=\(String(format: "%.1f", point.x)) y=\(String(format: "%.1f", point.y))"
                    )
                    return
                }
                traceInput(
                    "click backend=skylight-unavailable fallback=postToPid pid=\(targetPID) window=\(targetWindowID.map(String.init) ?? "none") x=\(String(format: "%.1f", point.x)) y=\(String(format: "%.1f", point.y))"
                )
                if postHIDClickWithCursorRestore(at: point) {
                    traceInput(
                        "click backend=hidBridge pid=\(targetPID) window=\(targetWindowID.map(String.init) ?? "none") x=\(String(format: "%.1f", point.x)) y=\(String(format: "%.1f", point.y))"
                    )
                    return
                }
            }
        }
        let source = eventSource(targetPID: targetPID)
        source?.localEventsSuppressionInterval = 0

        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        prepareMouseEvent(
            down,
            clickState: 1,
            targetPID: targetPID,
            targetWindowID: targetWindowID,
            pressure: 1.0,
            eventNumber: nextMouseEventNumber()
        )
        prepareMouseEvent(
            up,
            clickState: 1,
            targetPID: targetPID,
            targetWindowID: targetWindowID,
            pressure: 0.0,
            eventNumber: nextMouseEventNumber()
        )

        if targetPID == nil {
            let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            prepareMouseEvent(move, clickState: 0, targetPID: nil, targetWindowID: targetWindowID, pressure: 0)
            postMouseEvent(move, targetPID: nil)
        }
        let microActivation: SkyLightInputBridge.MicroActivationToken?
        if targetWindow?.isIPhoneMirroring == true, let targetPID {
            microActivation = SkyLightInputBridge.shared.beginMicroActivation(pid: targetPID, windowID: targetWindowID)
        } else {
            microActivation = nil
        }
        let backend = targetPID == nil ? "hid" : (microActivation == nil ? "postToPid" : "postToPid+microFrontmost")
        traceInput(
            "click backend=\(backend) pid=\(targetPID.map(String.init) ?? "none") window=\(targetWindowID.map(String.init) ?? "none") x=\(String(format: "%.1f", point.x)) y=\(String(format: "%.1f", point.y))"
        )
        defer {
            if let microActivation {
                SkyLightInputBridge.shared.endMicroActivation(microActivation)
            }
        }
        usleep(20_000)
        postMouseEvent(down, targetPID: targetPID)
        usleep(5_000)
        postMouseEvent(up, targetPID: targetPID)
    }

    private func activateWindowUnderPointer(at point: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        guard let info = windows.first(where: { info in
            guard Self.int32Value(info[kCGWindowOwnerPID as String]) != nil,
                  let layer = Self.intValue(info[kCGWindowLayer as String]),
                  layer == 0,
                  let bounds = Self.windowBounds(from: info),
                  bounds.width >= 80,
                  bounds.height >= 60,
                  bounds.contains(point) else {
                return false
            }
            return (Self.doubleValue(info[kCGWindowAlpha as String]) ?? 1) > 0.05
        }),
        let windowID = Self.uint32Value(info[kCGWindowNumber as String]),
        let ownerPID = Self.int32Value(info[kCGWindowOwnerPID as String]),
        ownerPID != getpid() else {
            return false
        }

        let target = WindowCaptureTarget(
            id: CGWindowID(windowID),
            ownerPID: pid_t(ownerPID),
            appName: (info[kCGWindowOwnerName as String] as? String) ?? "Unknown",
            windowTitle: (info[kCGWindowName as String] as? String) ?? "",
            bounds: Self.windowBounds(from: info) ?? .zero,
            thumbnail: nil
        )
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let alreadyFrontmost = frontmostPID == target.ownerPID
        let activated = activateWindow(target)
        if activated {
            traceInput(
                "click activation pid=\(target.ownerPID) window=\(target.id) alreadyFrontmost=\(alreadyFrontmost)"
            )
        }
        return activated
    }

    private func postExternalSystemClick(at point: CGPoint) -> Bool {
        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e",
            "tell application \"System Events\" to click at {\(x), \(y)}"
        ]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let succeeded = task.terminationReason == .exit && task.terminationStatus == 0
            if !succeeded {
                traceInput("click backend=mission-control-system-events status=\(task.terminationStatus) fallback=hid")
            }
            return succeeded
        } catch {
            traceInput("click backend=mission-control-system-events-failed error=\(error.localizedDescription) fallback=hid")
            return false
        }
    }

    private func prepareMouseEvent(
        _ event: CGEvent?,
        clickState: Int64,
        targetPID: pid_t?,
        targetWindowID: CGWindowID?,
        pressure: Double,
        eventNumber: Int64? = nil
    ) {
        guard let event else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        if let eventNumber {
            event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        }
        if let targetPID {
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
        }
        if let targetWindowID {
            let windowID = Int64(targetWindowID)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        }
    }

    private func nextMouseEventNumber() -> Int64 {
        mouseEventNumber += 1
        return mouseEventNumber
    }

    private func eventSource(targetPID: pid_t?) -> CGEventSource? {
        if targetPID != nil {
            return CGEventSource(stateID: .privateState) ?? CGEventSource(stateID: .hidSystemState)
        }
        return CGEventSource(stateID: .combinedSessionState)
    }

    private func postHIDClickWithCursorRestore(at point: CGPoint) -> Bool {
        let previous = CGEvent(source: nil)?.location
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let source = CGEventSource(stateID: .hidSystemState) ?? CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0

        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let previous {
                CGWarpMouseCursorPosition(previous)
                let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: previous, mouseButton: .left)
                prepareMouseEvent(restore, clickState: 0, targetPID: nil, targetWindowID: nil, pressure: 0)
                postMouseEvent(restore, targetPID: nil)
            }
            CGDisplayShowCursor(CGMainDisplayID())
            restoreFrontmostApplication(previousFrontmost)
        }

        CGWarpMouseCursorPosition(point)
        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        guard down != nil, up != nil else { return false }

        prepareMouseEvent(move, clickState: 0, targetPID: nil, targetWindowID: nil, pressure: 0)
        prepareMouseEvent(down, clickState: 1, targetPID: nil, targetWindowID: nil, pressure: 1.0, eventNumber: nextMouseEventNumber())
        prepareMouseEvent(up, clickState: 1, targetPID: nil, targetWindowID: nil, pressure: 0.0, eventNumber: nextMouseEventNumber())

        postMouseEvent(move, targetPID: nil)
        usleep(20_000)
        postMouseEvent(down, targetPID: nil)
        usleep(65_000)
        postMouseEvent(up, targetPID: nil)
        usleep(20_000)
        return true
    }

    private func postHIDDragWithCursorRestore(
        from start: CGPoint,
        to end: CGPoint,
        duration: Double,
        steps: Int,
        stepDelay: useconds_t
    ) -> Bool {
        let previous = CGEvent(source: nil)?.location
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let source = CGEventSource(stateID: .hidSystemState) ?? CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0

        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let previous {
                CGWarpMouseCursorPosition(previous)
                let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: previous, mouseButton: .left)
                prepareMouseEvent(restore, clickState: 0, targetPID: nil, targetWindowID: nil, pressure: 0)
                postMouseEvent(restore, targetPID: nil)
            }
            CGDisplayShowCursor(CGMainDisplayID())
            restoreFrontmostApplication(previousFrontmost)
        }

        CGWarpMouseCursorPosition(start)
        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
        guard down != nil else { return false }

        prepareMouseEvent(move, clickState: 0, targetPID: nil, targetWindowID: nil, pressure: 0)
        prepareMouseEvent(down, clickState: 1, targetPID: nil, targetWindowID: nil, pressure: 1.0, eventNumber: nextMouseEventNumber())
        postMouseEvent(move, targetPID: nil)
        usleep(20_000)
        postMouseEvent(down, targetPID: nil)
        usleep(60_000)

        let count = max(1, steps)
        for step in 1...count {
            let progress = Double(step) / Double(count)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            let moved = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)
            prepareMouseEvent(moved, clickState: 1, targetPID: nil, targetWindowID: nil, pressure: 1.0, eventNumber: nextMouseEventNumber())
            postMouseEvent(moved, targetPID: nil)
            usleep(stepDelay)
        }

        usleep(useconds_t(max(20_000, duration * 120_000)))
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
        guard up != nil else { return false }
        prepareMouseEvent(up, clickState: 1, targetPID: nil, targetWindowID: nil, pressure: 0.0, eventNumber: nextMouseEventNumber())
        postMouseEvent(up, targetPID: nil)
        usleep(20_000)
        return true
    }

    private func restoreFrontmostApplication(_ application: NSRunningApplication?) {
        guard let application,
              !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier else {
            return
        }
        _ = application.activate()
    }

    private func performAccessibilityClick(at point: CGPoint, targetPID: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let appElement = AXUIElementCreateApplication(targetPID)
        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            appElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        guard result == .success, let hitElement else { return false }

        var candidate: AXUIElement? = hitElement
        for _ in 0..<7 {
            guard let element = candidate else { break }
            if focusAccessibilityElementIfEditable(element, appElement: appElement) {
                return true
            }
            if actionNames(of: element).contains(kAXPressAction as String),
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return true
            }
            candidate = copyAXElementAttribute(kAXParentAttribute, from: element)
        }

        return false
    }

    private func focusAccessibilityElementIfEditable(_ element: AXUIElement, appElement: AXUIElement) -> Bool {
        let role = axString(element, kAXRoleAttribute)?.lowercased() ?? ""
        let subrole = axString(element, kAXSubroleAttribute)?.lowercased() ?? ""
        let editable = role.contains("textfield") ||
            role.contains("textarea") ||
            role.contains("combobox") ||
            role.contains("searchfield") ||
            subrole.contains("search")
        guard editable else { return false }

        let appFocusResult = AXUIElementSetAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, element)
        let elementFocusResult = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var pressed = false
        if actionNames(of: element).contains(kAXPressAction as String) {
            pressed = AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        return pressed || appFocusResult == .success || elementFocusResult == .success
    }

    private func postMouseEvent(_ event: CGEvent?, targetPID: pid_t?) {
        markSynthetic(event)
        if let targetPID {
            event?.postToPid(targetPID)
        } else {
            event?.post(tap: .cghidEventTap)
        }
    }

    private func markSynthetic(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: AgentInputSyntheticMarker.value)
    }

    private func traceInput(_ message: String) {
        TraceLog.append(message, filename: "input-actions.log")
    }

    private func runAppleScript(_ script: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil { return false }
        if result?.booleanValue == false { return false }
        return true
    }

    private static let browserSearchFieldJavaScript = """
    (() => {
      const visible = el => {
        const r = el.getBoundingClientRect();
        const s = getComputedStyle(el);
        return r.width > 80 && r.height > 16 && s.visibility !== 'hidden' && s.display !== 'none';
      };
      const score = el => {
        const text = [el.type, el.role, el.name, el.id, el.placeholder, el.ariaLabel, el.getAttribute('aria-label'), el.getAttribute('title')]
          .filter(Boolean).join(' ').toLowerCase();
        let value = 0;
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') value += 10;
        if (el.type === 'search') value += 40;
        if (text.includes('search')) value += 35;
        if (text.includes('query')) value += 12;
        if (el.isContentEditable) value += 8;
        const r = el.getBoundingClientRect();
        value += Math.min(20, r.width / 40);
        value -= Math.max(0, r.top - 220) / 30;
        return value;
      };
      const candidates = [...document.querySelectorAll('input, textarea, [contenteditable="true"], [role="searchbox"], [role="combobox"], [aria-label], [placeholder]')]
        .filter(visible)
        .sort((a, b) => score(b) - score(a));
      const target = candidates[0];
      if (!target || score(target) < 20) return false;
      target.focus();
      target.click();
      return true;
    })()
    """.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")

    private static func flags(for modifiers: [String]) -> CGEventFlags {
        var flags = CGEventFlags()
        for modifier in modifiers.map({ $0.lowercased() }) {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "function", "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        let normalized = key.lowercased()
        if let char = normalized.first, normalized.count == 1 {
            return letterAndNumberCodes[char]
        }
        return namedCodes[normalized]
    }

    private static let letterAndNumberCodes: [Character: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
        "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
        "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
        "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
        "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z), "0": CGKeyCode(kVK_ANSI_0),
        "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
        "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5), "6": CGKeyCode(kVK_ANSI_6),
        "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
        "-": CGKeyCode(kVK_ANSI_Minus), "=": CGKeyCode(kVK_ANSI_Equal),
        "[": CGKeyCode(kVK_ANSI_LeftBracket), "]": CGKeyCode(kVK_ANSI_RightBracket),
        "\\": CGKeyCode(kVK_ANSI_Backslash), ";": CGKeyCode(kVK_ANSI_Semicolon),
        "'": CGKeyCode(kVK_ANSI_Quote), ",": CGKeyCode(kVK_ANSI_Comma),
        ".": CGKeyCode(kVK_ANSI_Period), "/": CGKeyCode(kVK_ANSI_Slash),
        "`": CGKeyCode(kVK_ANSI_Grave)
    ]

    private static let namedCodes: [String: CGKeyCode] = [
        "space": CGKeyCode(kVK_Space), "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
        "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape), "tab": CGKeyCode(kVK_Tab),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
        "forward_delete": CGKeyCode(kVK_ForwardDelete),
        "page_up": CGKeyCode(kVK_PageUp), "page_down": CGKeyCode(kVK_PageDown),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12)
    ]
}
