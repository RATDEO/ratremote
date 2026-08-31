import Carbon.HIToolbox
import CoreGraphics

struct SystemShortcutKeyEvent: Equatable {
    let keyCode: CGKeyCode
    let isKeyDown: Bool
    let flags: CGEventFlags
}

enum SystemShortcutEventSequence {
    static func appleScriptSource(keyCode: CGKeyCode, flags: CGEventFlags) -> String {
        var modifiers: [String] = []
        if flags.contains(.maskControl) { modifiers.append("control down") }
        if flags.contains(.maskShift) { modifiers.append("shift down") }
        if flags.contains(.maskAlternate) { modifiers.append("option down") }
        if flags.contains(.maskCommand) { modifiers.append("command down") }

        var source = "tell application \"System Events\" to key code \(keyCode)"
        if !modifiers.isEmpty {
            source += " using \(modifiers.joined(separator: " and "))"
        }
        return source
    }

    static func make(keyCode: CGKeyCode, flags: CGEventFlags) -> [SystemShortcutKeyEvent] {
        let modifiers: [(flag: CGEventFlags, keyCode: CGKeyCode)] = [
            (.maskControl, CGKeyCode(kVK_Control)),
            (.maskShift, CGKeyCode(kVK_Shift)),
            (.maskAlternate, CGKeyCode(kVK_Option)),
            (.maskCommand, CGKeyCode(kVK_Command))
        ]

        var events: [SystemShortcutKeyEvent] = []
        var activeFlags = CGEventFlags()
        let activeModifiers = modifiers.filter { flags.contains($0.flag) }

        for modifier in activeModifiers {
            activeFlags.insert(modifier.flag)
            events.append(
                SystemShortcutKeyEvent(
                    keyCode: modifier.keyCode,
                    isKeyDown: true,
                    flags: activeFlags
                )
            )
        }

        events.append(SystemShortcutKeyEvent(keyCode: keyCode, isKeyDown: true, flags: flags))
        events.append(SystemShortcutKeyEvent(keyCode: keyCode, isKeyDown: false, flags: flags))

        for modifier in activeModifiers.reversed() {
            activeFlags.remove(modifier.flag)
            events.append(
                SystemShortcutKeyEvent(
                    keyCode: modifier.keyCode,
                    isKeyDown: false,
                    flags: activeFlags
                )
            )
        }
        return events
    }
}
