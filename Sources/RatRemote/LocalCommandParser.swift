import Foundation

enum LocalCommandParser {
    static func actions(for text: String) -> [RemoteAction] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }

        if ["fullscreen", "full screen", "go fullscreen", "make fullscreen"].contains(normalized) {
            return [RemoteAction(type: .keyPress, text: nil, key: "f", modifiers: ["control", "command"], url: nil, x: nil, y: nil, amount: nil)]
        }

        if ["escape", "press escape", "esc"].contains(normalized) {
            return [keyAction("escape")]
        }

        if let exactAction = exactAction(for: normalized) {
            return [exactAction]
        }

        if let actions = newWindowActions(from: normalized) {
            return actions
        }

        if let target = openTarget(from: normalized) {
            if let url = siteURL(for: target) {
                return [RemoteAction(type: .openURL, text: nil, key: nil, modifiers: nil, url: url, x: nil, y: nil, amount: nil)]
            }
            if let appName = appName(for: target) {
                return [RemoteAction(type: .openApplication, text: appName, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)]
            }
        }

        if normalized.hasPrefix("type ") {
            let content = String(normalized.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return [RemoteAction(type: .pasteText, text: content, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)]
        }

        if let scrollAction = scrollAction(from: normalized) {
            return [scrollAction]
        }

        if let keyAction = keyPressAction(from: normalized) {
            return [keyAction]
        }

        return []
    }

    private static func exactAction(for text: String) -> RemoteAction? {
        switch text {
        case "click", "left click", "select":
            RemoteAction(type: .click, text: nil, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil)
        case "copy":
            keyAction("c", modifiers: ["command"])
        case "paste":
            keyAction("v", modifiers: ["command"])
        case "cut":
            keyAction("x", modifiers: ["command"])
        case "undo":
            keyAction("z", modifiers: ["command"])
        case "redo":
            keyAction("z", modifiers: ["command", "shift"])
        case "select all":
            keyAction("a", modifiers: ["command"])
        case "save":
            keyAction("s", modifiers: ["command"])
        case "close", "close window", "close tab":
            keyAction("w", modifiers: ["command"])
        case "quit", "quit app", "quit application":
            keyAction("q", modifiers: ["command"])
        case "new tab":
            keyAction("t", modifiers: ["command"])
        case "next tab":
            keyAction("tab", modifiers: ["control"])
        case "previous tab", "prev tab":
            keyAction("tab", modifiers: ["control", "shift"])
        case "go back", "back":
            keyAction("left", modifiers: ["command"])
        case "go forward", "forward":
            keyAction("right", modifiers: ["command"])
        case "page up":
            keyAction("page_up")
        case "page down":
            keyAction("page_down")
        default:
            nil
        }
    }

    private static func newWindowActions(from text: String) -> [RemoteAction]? {
        let bareNewWindowPhrases = [
            "new window",
            "open new window",
            "create new window",
            "make new window",
            "launch new window",
            "new app window",
            "open a new window",
            "create a new window",
            "make a new window",
            "launch a new window"
        ]
        if bareNewWindowPhrases.contains(text) {
            return [keyAction("n", modifiers: ["command"])]
        }

        let appTargetPatterns = [
            #"^(?:open|create|make|launch)\s+(?:a\s+)?new\s+(.+?)\s+window$"#,
            #"^new\s+(.+?)\s+window$"#,
            #"^(?:open|create|make|launch)\s+(?:a\s+)?new\s+window\s+(?:in|for|with)\s+(.+)$"#,
            #"^new\s+window\s+(?:in|for|with)\s+(.+)$"#
        ]

        for pattern in appTargetPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let targetRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            let target = String(text[targetRange])
                .replacingOccurrences(of: #"^(the\s+)?"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let appName = appName(for: target) else { continue }
            return [
                RemoteAction(type: .openApplication, text: appName, key: nil, modifiers: nil, url: nil, x: nil, y: nil, amount: nil),
                keyAction("n", modifiers: ["command"])
            ]
        }

        return nil
    }

    private static func scrollAction(from text: String) -> RemoteAction? {
        let amount = scrollAmount(from: text)
        if ["scroll up", "move up"].contains(text) || text.hasPrefix("scroll up ") {
            return scroll(dx: 0, dy: amount)
        }
        if ["scroll down", "move down"].contains(text) || text.hasPrefix("scroll down ") {
            return scroll(dx: 0, dy: -amount)
        }
        if ["scroll left", "move left"].contains(text) || text.hasPrefix("scroll left ") {
            return scroll(dx: -amount, dy: 0)
        }
        if ["scroll right", "move right"].contains(text) || text.hasPrefix("scroll right ") {
            return scroll(dx: amount, dy: 0)
        }
        return nil
    }

    private static func keyPressAction(from text: String) -> RemoteAction? {
        let prefixes = ["press ", "hit ", "tap ", "send ", "click "]
        let phrase = prefixes.first(where: { text.hasPrefix($0) }).map {
            String(text.dropFirst($0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? text

        let words = phrase.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        let modifierWords = Set(["command", "cmd", "control", "ctrl", "option", "alt", "shift"])
        guard words.contains(where: { modifierWords.contains($0) }) || prefixes.contains(where: { text.hasPrefix($0) }) else {
            return nil
        }

        let modifiers = words.dropLast().compactMap { modifierName(for: $0) }
        let keyWords = words.drop { modifierWords.contains($0) }
        let keyPhrase = keyWords.joined(separator: " ")
        guard let key = canonicalKeyName(for: keyPhrase.isEmpty ? words.last ?? "" : keyPhrase) else { return nil }
        return keyAction(key, modifiers: modifiers)
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\.,!?]+$"#, with: "", options: .regularExpression)
    }

    private static func keyAction(_ key: String, modifiers: [String] = []) -> RemoteAction {
        RemoteAction(type: .keyPress, text: nil, key: key, modifiers: modifiers.isEmpty ? nil : modifiers, url: nil, x: nil, y: nil, amount: nil)
    }

    private static func scroll(dx: Double, dy: Double) -> RemoteAction {
        RemoteAction(type: .scroll, text: nil, key: nil, modifiers: nil, url: nil, x: dx, y: dy, amount: nil)
    }

    private static func scrollAmount(from text: String) -> Double {
        if text.contains("a lot") || text.contains("far") { return 120 }
        if text.contains("little") || text.contains("small") { return 20 }
        return 60
    }

    private static func modifierName(for word: String) -> String? {
        switch word {
        case "command", "cmd": "command"
        case "control", "ctrl": "control"
        case "option", "alt": "option"
        case "shift": "shift"
        default: nil
        }
    }

    static func canonicalKeyName(for phrase: String) -> String? {
        let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count == 1 { return normalized }
        switch normalized {
        case "space", "space bar", "spacebar": return "space"
        case "return", "enter": return "return"
        case "escape", "esc": return "escape"
        case "tab": return "tab"
        case "left", "left arrow": return "left"
        case "right", "right arrow": return "right"
        case "up", "up arrow": return "up"
        case "down", "down arrow": return "down"
        case "delete", "backspace": return "delete"
        case "forward delete": return "forward_delete"
        case "page up": return "page_up"
        case "page down": return "page_down"
        case "home": return "home"
        case "end": return "end"
        default: return nil
        }
    }

    private static func openTarget(from text: String) -> String? {
        let prefixes = [
            "open ",
            "launch ",
            "start ",
            "go to ",
            "show me ",
            "bring up "
        ]
        for prefix in prefixes where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func siteURL(for target: String) -> String? {
        let sites: [String: String] = [
            "youtube": "https://www.youtube.com",
            "you tube": "https://www.youtube.com",
            "chatgpt": "https://chatgpt.com",
            "chat gpt": "https://chatgpt.com",
            "google": "https://www.google.com",
            "gmail": "https://mail.google.com",
            "calendar": "https://calendar.google.com",
            "github": "https://github.com",
            "git hub": "https://github.com",
            "linear": "https://linear.app",
            "notion": "https://www.notion.so",
            "reddit": "https://www.reddit.com",
            "x": "https://x.com",
            "twitter": "https://x.com"
        ]
        if let url = sites[target] {
            return url
        }
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            return target
        }
        if target.contains(".") && !target.contains(" ") {
            return "https://\(target)"
        }
        return nil
    }

    private static func appName(for target: String) -> String? {
        let target = canonicalAppTarget(for: target)
        let apps: [String: String] = [
            "safari": "Safari",
            "chrome": "Google Chrome",
            "google chrome": "Google Chrome",
            "chatgpt app": "ChatGPT",
            "chat gpt app": "ChatGPT",
            "chatgpt desktop": "ChatGPT",
            "settings": "System Settings",
            "system settings": "System Settings",
            "preferences": "System Settings",
            "system preferences": "System Settings",
            "code": "Visual Studio Code",
            "vs code": "Visual Studio Code",
            "visual studio code": "Visual Studio Code",
            "cursor": "Cursor",
            "terminal": "Terminal",
            "iterm": "iTerm",
            "iterm2": "iTerm",
            "finder": "Finder",
            "mail": "Mail",
            "messages": "Messages",
            "notes": "Notes",
            "reminders": "Reminders",
            "calendar app": "Calendar",
            "music": "Music",
            "spotify": "Spotify",
            "slack": "Slack",
            "discord": "Discord",
            "zoom": "zoom.us",
            "preview": "Preview",
            "photos": "Photos",
            "calculator": "Calculator",
            "activity monitor": "Activity Monitor",
            "textedit": "TextEdit",
            "text edit": "TextEdit",
            "xcode": "Xcode",
            "docker": "Docker",
            "raycast": "Raycast",
            "obsidian": "Obsidian",
            "notion app": "Notion",
            "figma": "Figma",
            "codex": "Codex",
            "ghostty": "Ghostty",
            "rat remote": "RatRemote",
            "ratremote": "RatRemote",
            "rat": "RatRemote",
            "iphone mirroring": "iPhone Mirroring",
            "iphone mirror": "iPhone Mirroring",
            "phone mirroring": "iPhone Mirroring",
            "phone mirror": "iPhone Mirroring"
        ]
        return apps[target]
    }

    private static func canonicalAppTarget(for target: String) -> String {
        let aliases: [String: String] = [
            "code x": "codex",
            "codecs app": "codex",
            "codeex": "codex",
            "codics": "codex",
            "codec": "codex",
            "codecs": "codex",
            "codex app": "codex",
            "kodak": "codex",
            "kodak app": "codex",
            "kodex app": "codex",
            "kodex": "codex",
            "kodyx": "codex",
            "ghost": "ghostty",
            "ghost t": "ghostty",
            "ghost tea": "ghostty",
            "ghost tee": "ghostty",
            "ghosty": "ghostty",
            "ghosty app": "ghostty",
            "ghostty app": "ghostty",
            "ghostyy": "ghostty"
        ]
        return aliases[target] ?? target
    }
}
