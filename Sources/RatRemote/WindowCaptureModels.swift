import AppKit
import CoreGraphics
import Foundation

struct WindowCaptureTarget: Identifiable {
    let id: CGWindowID
    let ownerPID: pid_t
    let appName: String
    let windowTitle: String
    let bounds: CGRect
    let thumbnail: NSImage?

    var displayTitle: String {
        if windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return appName
        }
        return "\(appName) - \(windowTitle)"
    }

    var shortTitle: String {
        windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? appName : windowTitle
    }

    var isIPhoneMirroring: Bool {
        let normalized = "\(appName) \(windowTitle)".lowercased()
        return normalized.contains("iphone mirroring") ||
            normalized.contains("iphone mirror")
    }

    var prefersScrollBasedSwipes: Bool {
        isIPhoneMirroring
    }
}

struct ScreenCaptureContext {
    let imageBase64: String
    let frame: CGRect
    let title: String
    let isWindowScoped: Bool
}
