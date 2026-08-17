import Cocoa
import SwiftUI
import WebKit
import UserNotifications
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    weak var settingsWindow: NSWindow?
    var serverManager: ServerManager!
    var thinkingProxy: ThinkingProxy!
    private let notificationCenter = UNUserNotificationCenter.current()
    private var notificationPermissionGranted = false
    private let updaterController: SPUStandardUpdaterController
    private var authFileMonitor: DispatchSourceFileSystemObject?
    private var userConfigFileMonitor: DispatchSourceFileSystemObject?
    private var configInputPoller: DispatchSourceTimer?
    private var pendingAuthRefresh: DispatchWorkItem?
    private var polledConfigInputsFingerprint = ""
    
    override init() {
        self.updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup standard Edit menu for keyboard shortcuts (Cmd+C/V/X/A)
        setupMainMenu()
        
        // Setup menu bar
        setupMenuBar()

        // Initialize managers
        serverManager = ServerManager()
        thinkingProxy = ThinkingProxy()

        // Sync Vercel AI Gateway config from ServerManager to ThinkingProxy
        syncVercelConfig()
        serverManager.onVercelConfigChanged = { [weak self] in
            self?.syncVercelConfig()
        }
        
        // Warm commonly used icons to avoid first-use disk hits
        preloadIcons()
        
        configureNotifications()

        // Start server automatically
        startServer()

        // Register for notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuBarStatus),
            name: .serverStatusChanged,
            object: nil
        )

        // Monitor auth directory for credential file changes (app-lifetime scope)
        startMonitoringAuthDirectory()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAuthDirectoryChanged),
            name: .authDirectoryChanged,
            object: nil
        )
    }
    
    private func preloadIcons() {
        let statusIconSize = NSSize(width: 18, height: 18)
        let serviceIconSize = NSSize(width: 20, height: 20)
        
        let iconsToPreload = [
            ("icon-active.png", statusIconSize),
            ("icon-inactive.png", statusIconSize),
            ("icon-codex.png", serviceIconSize),
            ("icon-claude.png", serviceIconSize),
            ("icon-gemini.png", serviceIconSize)
        ]
        
        for (name, size) in iconsToPreload {
            if IconCatalog.shared.image(named: name, resizedTo: size, template: true) == nil {
                NSLog("[IconPreload] Warning: Failed to preload icon '%@'", name)
            }
        }
    }
    
    private func configureNotifications() {
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error = error {
                NSLog("[Notifications] Authorization failed: %@", error.localizedDescription)
            }
            DispatchQueue.main.async {
                self?.notificationPermissionGranted = granted
                if !granted {
                    NSLog("[Notifications] Authorization not granted; notifications will be suppressed")
                }
            }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: String(localized: "app.menu.about-vibeproxy", defaultValue: "About VibeProxy", comment: "Application menu item title for About dialog"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: String(localized: "app.menu.quit-vibeproxy", defaultValue: "Quit VibeProxy", comment: "Application menu item title to quit app with app name"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        // Edit menu (for Cmd+C/V/X/A to work)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "app.menu.edit", defaultValue: "Edit", comment: "Top-level Edit menu title"))
        editMenu.addItem(NSMenuItem(title: String(localized: "app.menu.edit.undo", defaultValue: "Undo", comment: "Edit menu item title for Undo action"), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: String(localized: "app.menu.edit.redo", defaultValue: "Redo", comment: "Edit menu item title for Redo action"), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: String(localized: "app.menu.edit.cut", defaultValue: "Cut", comment: "Edit menu item title for Cut action"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: String(localized: "app.menu.edit.copy", defaultValue: "Copy", comment: "Edit menu item title for Copy action"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: String(localized: "app.menu.edit.paste", defaultValue: "Paste", comment: "Edit menu item title for Paste action"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: String(localized: "app.menu.edit.select-all", defaultValue: "Select All", comment: "Edit menu item title for Select All action"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        NSApplication.shared.mainMenu = mainMenu
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.toolTip = "VibeProxy"
            if let icon = IconCatalog.shared.image(named: "icon-inactive.png", resizedTo: NSSize(width: 18, height: 18), template: true) {
                button.image = icon
            } else {
                let fallback = NSImage(systemSymbolName: "network.slash", accessibilityDescription: "VibeProxy")
                fallback?.isTemplate = true
                button.image = fallback
                NSLog("[MenuBar] Failed to load inactive icon from bundle; using fallback system icon")
            }
        }

        menu = NSMenu()

        // Server Status
        menu.addItem(NSMenuItem(title: String(localized: "app.status-item.server-stopped", defaultValue: "Server: Stopped", comment: "Status item title when server is stopped"), action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Main Actions
        menu.addItem(NSMenuItem(title: String(localized: "app.status-item.open-settings", defaultValue: "Open Settings", comment: "Status menu item title to open settings window"), action: #selector(openSettings), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())

        // Server Control
        let startStopItem = NSMenuItem(title: String(localized: "app.status-item.start-server", defaultValue: "Start Server", comment: "Status menu item title to start backend server"), action: #selector(toggleServer), keyEquivalent: "")
        startStopItem.tag = 100
        menu.addItem(startStopItem)

        menu.addItem(NSMenuItem.separator())

        // Copy URL
        let copyURLItem = NSMenuItem(title: String(localized: "app.status-item.copy-server-url", defaultValue: "Copy Server URL", comment: "Status menu item title to copy server URL to clipboard"), action: #selector(copyServerURL), keyEquivalent: "c")
        copyURLItem.isEnabled = false
        copyURLItem.tag = 102
        menu.addItem(copyURLItem)

        // Open Dashboard
        let dashboardItem = NSMenuItem(title: String(localized: "app.status-item.open-dashboard", defaultValue: "Open Dashboard", comment: "Status menu item title to open dashboard in browser"), action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.isEnabled = false
        dashboardItem.tag = 103
        menu.addItem(dashboardItem)

        menu.addItem(NSMenuItem.separator())

        // Check for Updates
        let checkForUpdatesItem = NSMenuItem(title: String(localized: "app.status-item.check-for-updates", defaultValue: "Check for Updates...", comment: "Status menu item title to check for app updates"), action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "u")
        checkForUpdatesItem.target = updaterController
        menu.addItem(checkForUpdatesItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: String(localized: "app.status-item.quit", defaultValue: "Quit", comment: "Status menu item title to quit app"), action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }



    @objc func openSettings() {
        if settingsWindow == nil {
            createSettingsWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func createSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeProxy"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let contentView = SettingsView(serverManager: serverManager)
        window.contentView = NSHostingView(rootView: contentView)

        settingsWindow = window
    }
    
    func windowDidClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
        }
    }

    @objc func toggleServer() {
        if serverManager.isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func startServer() {
        // Start the thinking proxy first (port 8317)
        thinkingProxy.start()
        
        // Poll for thinking proxy readiness with timeout
        pollForProxyReadiness(attempts: 0, maxAttempts: 60, intervalMs: 50)
    }
    
    private func pollForProxyReadiness(attempts: Int, maxAttempts: Int, intervalMs: Int) {
        // Check if proxy is running
        if thinkingProxy.isRunning {
            // Success - proceed to start backend
            serverManager.start { [weak self] success in
                DispatchQueue.main.async {
                    if success {
                        self?.updateMenuBarStatus()
                        // User always connects to 8317 (thinking proxy)
                        self?.showNotification(title: String(localized: "app.notification.server-started.title", defaultValue: "Server Started", comment: "Notification title shown when server starts successfully"), body: String(localized: "app.notification.server-started.body", defaultValue: "VibeProxy is now running", comment: "Notification body shown when server starts successfully"))
                    } else {
                        // Backend failed - stop the proxy to keep state consistent
                        self?.thinkingProxy.stop()
                        self?.showNotification(title: String(localized: "app.notification.server-failed.title", defaultValue: "Server Failed", comment: "Notification title shown when server fails to start"), body: String(localized: "app.notification.server-failed.body", defaultValue: "Could not start backend server on port 8318", comment: "Notification body shown when backend server fails to start on default port"))
                    }
                }
            }
            return
        }
        
        // Check if we've exceeded timeout
        if attempts >= maxAttempts {
            DispatchQueue.main.async { [weak self] in
                // Clean up partially initialized proxy
                self?.thinkingProxy.stop()
                self?.showNotification(title: String(localized: "app.notification.server-failed.title", defaultValue: "Server Failed", comment: "Notification title shown when server fails to start"), body: String(localized: "app.notification.server-failed-thinking-proxy-timeout.body", defaultValue: "Could not start thinking proxy on port 8317 (timeout)", comment: "Notification body shown when thinking proxy startup times out"))
            }
            return
        }
        
        // Schedule next poll
        let interval = Double(intervalMs) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.pollForProxyReadiness(attempts: attempts + 1, maxAttempts: maxAttempts, intervalMs: intervalMs)
        }
    }

    func stopServer() {
        // Stop the thinking proxy first to stop accepting new requests
        thinkingProxy.stop()
        
        // Then stop CLIProxyAPI backend
        serverManager.stop()
        
        updateMenuBarStatus()
    }

    @objc func copyServerURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("http://localhost:\(thinkingProxy.proxyPort)", forType: .string)
        showNotification(title: String(localized: "app.notification.copied.title", defaultValue: "Copied", comment: "Notification title shown after copying server URL"), body: String(localized: "app.notification.server-url-copied.body", defaultValue: "Server URL copied to clipboard", comment: "Notification body shown after copying server URL to clipboard"))
    }

    @objc func openDashboard() {
        if let url = URL(string: "http://localhost:8318/management.html") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func handleAuthDirectoryChanged() {
        NSLog("[AppDelegate] Auth directory changed notification received — refreshing settings")
        serverManager.handleObservedConfigInputsChanged()
        // Re-open settings window if it exists so the user sees the new account
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func updateMenuBarStatus() {
        // Update status items
        if let serverStatus = menu.item(at: 0) {
            serverStatus.title = serverManager.isRunning ? String(format: String(localized: "app.status-item.server-running-port", defaultValue: "Server: Running (port %d)", comment: "Status item title when server is running with active port"), thinkingProxy.proxyPort) : String(localized: "app.status-item.server-stopped", defaultValue: "Server: Stopped", comment: "Status item title when server is stopped")
        }

        // Update button states
        if let startStopItem = menu.item(withTag: 100) {
            startStopItem.title = serverManager.isRunning ? String(localized: "app.status-item.stop-server", defaultValue: "Stop Server", comment: "Status menu item title to stop backend server") : String(localized: "app.status-item.start-server", defaultValue: "Start Server", comment: "Status menu item title to start backend server")
        }

        if let copyURLItem = menu.item(withTag: 102) {
            copyURLItem.isEnabled = serverManager.isRunning
        }

        if let dashboardItem = menu.item(withTag: 103) {
            dashboardItem.isEnabled = serverManager.isRunning
        }

        // Update icon based on server status
        if let button = statusItem.button {
            let iconName = serverManager.isRunning ? "icon-active.png" : "icon-inactive.png"
            let fallbackSymbol = serverManager.isRunning ? "network" : "network.slash"
            
            if let icon = IconCatalog.shared.image(named: iconName, resizedTo: NSSize(width: 18, height: 18), template: true) {
                button.image = icon
                NSLog("[MenuBar] Loaded %@ icon from cache", serverManager.isRunning ? "active" : "inactive")
            } else {
                let fallback = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: serverManager.isRunning ? "Running" : "Stopped")
                fallback?.isTemplate = true
                button.image = fallback
                NSLog("[MenuBar] Failed to load %@ icon; using fallback", serverManager.isRunning ? "active" : "inactive")
            }
        }
    }

    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "io.automaze.vibeproxy.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { error in
            if let error = error {
                NSLog("[Notifications] Failed to deliver notification '%@': %@", title, error.localizedDescription)
            }
        }
    }

    @objc func quit() {
        // Stop server and wait for cleanup before quitting
        if serverManager.isRunning {
            thinkingProxy.stop()
            serverManager.stop()
        }
        // Give a moment for cleanup to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .serverStatusChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .authDirectoryChanged, object: nil)
        pendingAuthRefresh?.cancel()
        authFileMonitor?.cancel()
        authFileMonitor = nil
        // Final cleanup - stop server if still running
        if serverManager.isRunning {
            thinkingProxy.stop()
            serverManager.stop()
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If server is running, stop it first
        if serverManager.isRunning {
            thinkingProxy.stop()
            serverManager.stop()
            // Give server time to stop (up to 3 seconds total with the improved stop method)
            return .terminateNow
        }
        return .terminateNow
    }
    
    // MARK: - Auth Directory Monitoring

    private func startMonitoringAuthDirectory() {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
        try? FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)

        let fileDescriptor = open(authDir.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.refreshUserConfigFileMonitor()
            self?.pendingAuthRefresh?.cancel()
            let workItem = DispatchWorkItem {
                self?.postObservedConfigInputsChanged(reason: "Auth directory changed")
            }
            self?.pendingAuthRefresh = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        authFileMonitor = source
        refreshUserConfigFileMonitor()
        startPollingConfigInputs()
    }

    private func refreshUserConfigFileMonitor() {
        userConfigFileMonitor?.cancel()
        userConfigFileMonitor = nil

        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
            .appendingPathComponent("config.yaml")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return
        }

        let fileDescriptor = open(configURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self?.refreshUserConfigFileMonitor()
            }
            self?.pendingAuthRefresh?.cancel()
            let workItem = DispatchWorkItem {
                self?.postObservedConfigInputsChanged(reason: "User config changed")
            }
            self?.pendingAuthRefresh = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        userConfigFileMonitor = source
    }

    private func startPollingConfigInputs() {
        configInputPoller?.cancel()
        polledConfigInputsFingerprint = currentConfigInputsFingerprint()

        let poller = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        poller.schedule(deadline: .now() + 1, repeating: 1)
        poller.setEventHandler { [weak self] in
            guard let self else { return }
            let currentFingerprint = self.currentConfigInputsFingerprint()
            guard currentFingerprint != self.polledConfigInputsFingerprint else {
                return
            }
            self.polledConfigInputsFingerprint = currentFingerprint
            self.postObservedConfigInputsChanged(reason: "Config input fingerprint changed during poll")
        }
        poller.resume()
        configInputPoller = poller
    }

    private func postObservedConfigInputsChanged(reason: String) {
        polledConfigInputsFingerprint = currentConfigInputsFingerprint()
        NSLog("[AppDelegate] %@ — posting notification", reason)
        NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
    }

    private func currentConfigInputsFingerprint() -> String {
        ConfigInputFingerprint.compute(
            in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api"),
            userConfigFilename: "config.yaml"
        )
    }

    // MARK: - Vercel Config Sync

    private func syncVercelConfig() {
        thinkingProxy.vercelConfig = VercelGatewayConfig(
            enabled: serverManager.vercelGatewayEnabled,
            apiKey: serverManager.vercelApiKey
        )
    }

    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
