import AppKit
import SwiftUI

@main
struct RatRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            MainView(
                coordinator: services.coordinator,
                store: services.settingsStore
            )
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(
                coordinator: services.coordinator,
                store: services.settingsStore
            )
        }
    }
}

@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()
    let settingsStore = SettingsStore()
    lazy var coordinator = RemoteCoordinator(settingsStore: settingsStore)

    private init() {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = AppServices.shared
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        services.coordinator.start()
        installStatusItem()
        configureMainWindows()
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.coordinator.stop()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Rat"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start/Stop Listening", action: #selector(toggleRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show RatRemote", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit RatRemote", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleRecording() {
        services.coordinator.toggleRecording()
    }

    @objc private func showMainWindow() {
        configureMainWindows()
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureMainWindows() {
        for window in NSApp.windows {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
