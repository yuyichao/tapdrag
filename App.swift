// Menu bar item, permission flow and login item for tapdrag.app.

import AppKit
import ServiceManagement

final class AppController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var deviceManager: DeviceManager?
    private var permissionTimer: Timer?
    private let settingsWindow = SettingsWindowController()

    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }

    func start() {
        statusItem.button?.image = NSImage(systemSymbolName: "hand.tap",
                                           accessibilityDescription: "tapdrag")
        menu.delegate = self
        menu.autoenablesItems = false // honor the isEnabled values set in menuNeedsUpdate
        statusItem.menu = menu

        // The Settings window writes UserDefaults; apply changes immediately.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            config.load(from: .standard)
        }

        if CGPreflightPostEventAccess() {
            activate()
        } else {
            _ = CGRequestPostEventAccess()
            log("waiting for the \(permissionName) permission")
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard CGPreflightPostEventAccess() else { return }
                timer.invalidate()
                self?.activate()
            }
        }
        updateIcon()
    }

    /// Runs once the permission is granted.
    private func activate() {
        installEventTap()
        let dm = DeviceManager()
        deviceManager = dm
        if enabled { dm.start() }

        // Devices go stale across sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.enabled else { return }
            log("wake: restarting devices")
            self.deviceManager?.restart()
        }
        FileHandle.standardError.write("tapdrag running (\(dm.count) device(s))\n".data(using: .utf8)!)
        updateIcon()
    }

    private func updateIcon() {
        statusItem.button?.appearsDisabled = !(enabled && deviceManager != nil)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if let dm = deviceManager {
            status = enabled ? "Running (\(dm.count) trackpad\(dm.count == 1 ? "" : "s"))" : "Paused"
        } else {
            status = "Waiting for \(permissionName) permission"
        }
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        if deviceManager == nil {
            menu.addItem(item("Open \(permissionName) Settings…", #selector(openPermissionSettings)))
        }
        menu.addItem(.separator())

        let enabledItem = item("Enabled", #selector(toggleEnabled))
        enabledItem.state = enabled ? .on : .off
        enabledItem.isEnabled = deviceManager != nil
        menu.addItem(enabledItem)

        let login = SMAppService.mainApp.status
        let loginItem = item(login == .requiresApproval ? "Start at Login (needs approval…)" : "Start at Login",
                             #selector(toggleLoginItem))
        loginItem.state = login == .enabled ? .on : .off
        menu.addItem(loginItem)

        let restart = item("Restart Touch Devices", #selector(restartDevices))
        restart.toolTip = "Use after connecting a Magic Trackpad"
        restart.isEnabled = deviceManager != nil && enabled
        menu.addItem(restart)
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())

        let debugItem = item("Debug Logging", #selector(toggleDebugLogging))
        debugItem.state = logFile != nil ? .on : .off
        menu.addItem(debugItem)
        menu.addItem(item("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit tapdrag", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleEnabled() {
        guard let dm = deviceManager else { return }
        enabled.toggle()
        if enabled {
            dm.start()
        } else {
            dm.stop()
            engine.reset()
        }
        log(enabled ? "enabled" : "paused")
        updateIcon()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func restartDevices() {
        guard enabled else { return }
        deviceManager?.restart()
    }

    @objc private func toggleDebugLogging() {
        if let file = logFile {
            log("debug logging off")
            try? file.close()
            logFile = nil
            return
        }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: logURL) else { return }
        file.seekToEndOfFile()
        logFile = file
        log(String(format: "debug logging on (tapTime %.2f, dragTimeout %.2f, moveThreshold %.3f)",
                   config.tapTime, config.dragTimeout, config.moveThreshold))
    }

    @objc private func showLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        NSWorkspace.shared.open(logURL)
    }

    @objc private func quit() {
        engine.reset()
        NSApp.terminate(nil)
    }
}
