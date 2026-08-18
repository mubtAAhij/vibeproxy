import Foundation
import Combine
import AppKit
import Yams

/// A fixed-capacity circular buffer that overwrites the oldest element when full.
///
/// When `count` reaches capacity, appending a new element overwrites the element at `head`,
/// and both `head` and `tail` advance. This ensures the buffer always contains the most
/// recent `capacity` elements, with older elements being discarded.
private struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private var tail = 0
    private(set) var count = 0
    
    init(capacity: Int) {
        let safeCapacity = max(1, capacity)
        storage = Array(repeating: nil, count: safeCapacity)
    }
    
    mutating func append(_ element: Element) {
        let capacity = storage.count
        storage[tail] = element
        
        if count == capacity {
            head = (head + 1) % capacity
        } else {
            count += 1
        }
        
        tail = (tail + 1) % capacity
    }
    
    func elements() -> [Element] {
        let capacity = storage.count
        guard count > 0 else { return [] }
        
        var result: [Element] = []
        result.reserveCapacity(count)
        
        for index in 0..<count {
            let storageIndex = (head + index) % capacity
            if let value = storage[storageIndex] {
                result.append(value)
            }
        }
        
        return result
    }
}

class ServerManager: ObservableObject {
    private var process: Process?
    private var activeAuthProcess: Process?
    @Published private(set) var isRunning = false
    private(set) var port = 8317
    @Published private(set) var customProviders: [CustomProviderDefinition] = []
    @Published private(set) var customProviderCredentials: [String: [CustomProviderCredential]] = [:]
    @Published private(set) var configErrorMessage: String?

    /// Provider enabled states - when disabled, models are excluded via oauth-excluded-models
    @Published var enabledProviders: [String: Bool] = [:] {
        didSet {
            UserDefaults.standard.set(enabledProviders, forKey: "enabledProviders")
        }
    }

    /// Vercel AI Gateway configuration for Claude requests
    @Published var vercelGatewayEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(vercelGatewayEnabled, forKey: "vercelGatewayEnabled")
            onVercelConfigChanged?()
        }
    }
    @Published var vercelApiKey: String = "" {
        didSet {
            UserDefaults.standard.set(vercelApiKey, forKey: "vercelApiKey")
            onVercelConfigChanged?()
        }
    }
    var onVercelConfigChanged: (() -> Void)?

    /// Helper class to capture output text across closures
    private class OutputCapture {
        var text = ""
    }
    private var logBuffer: RingBuffer<String>
    private let maxLogLines = 1000
    private let processQueue = DispatchQueue(label: "io.automaze.vibeproxy.server-process", qos: .userInitiated)
    private let credentialMutationQueue = DispatchQueue(label: "io.automaze.vibeproxy.credential-mutations", qos: .userInitiated)
    private let configInputStateQueue = DispatchQueue(label: "io.automaze.vibeproxy.config-input-state", qos: .userInitiated)
    private let configResolutionQueue = DispatchQueue(label: "io.automaze.vibeproxy.config-resolution", qos: .userInitiated)
    private lazy var zaiAPIKeyStore = ZAIAPIKeyStore(directoryURL: authDirectoryURL())
    private lazy var customProviderCredentialStore = CustomProviderCredentialStore(directoryURL: authDirectoryURL())
    private var activeConfigPath = ""
    private var isRestartingForConfigUpdate = false
    private var isResolvingConfigUpdate = false
    private var hasPendingConfigUpdate = false
    private var observedConfigInputsFingerprint = ""
    
    private enum Timing {
        static let readinessCheckDelay: TimeInterval = 1.0
        static let gracefulTerminationTimeout: TimeInterval = 2.0
        static let terminationPollInterval: TimeInterval = 0.05
        /// Delay before sending newline to accept Gemini's default project choice
        static let geminiDefaultProjectAcceptDelay: TimeInterval = 3.0
        /// Delay before sending newline to keep Codex login waiting for browser callback
        static let codexCallbackKeepaliveDelay: TimeInterval = 12.0
        /// Delay before sending Qwen email after OAuth completion (conservative to allow for network/user interaction)
        static let qwenEmailSubmissionDelay: TimeInterval = 10.0
    }
    
    private enum CustomProviderConstants {
        static let userConfigFilename = "config.yaml"
        static let mergedConfigFilename = "merged-config.yaml"
    }

    private struct LoadedBaseConfig {
        let root: [String: Any]
        let isUserConfig: Bool
    }

    private struct ConfigResolutionFailure: Error {
        let message: String
    }

    private struct CustomProviderCredentialKey: Hashable {
        let providerID: String
        let apiKey: String
    }
    
    var onLogUpdate: (([String]) -> Void)?

    init() {
        logBuffer = RingBuffer(capacity: maxLogLines)
        if let saved = UserDefaults.standard.dictionary(forKey: "enabledProviders") as? [String: Bool] {
            enabledProviders = saved
        }
        vercelGatewayEnabled = UserDefaults.standard.bool(forKey: "vercelGatewayEnabled")
        vercelApiKey = UserDefaults.standard.string(forKey: "vercelApiKey") ?? ""
        reloadCustomProviders()
        markObservedConfigInputsCurrent()
    }

    /// Check if a provider is enabled (defaults to true if not set)
    func isProviderEnabled(_ providerKey: String) -> Bool {
        isProviderEnabled(providerKey, baseConfigRoot: nil, enabledProviderStates: enabledProviders)
    }

    private func isProviderEnabled(_ providerKey: String, baseConfigRoot: [String: Any]?) -> Bool {
        isProviderEnabled(providerKey, baseConfigRoot: baseConfigRoot, enabledProviderStates: enabledProviders)
    }

    private func isProviderEnabled(
        _ providerKey: String,
        baseConfigRoot: [String: Any]?,
        enabledProviderStates: [String: Bool]
    ) -> Bool {
        let userEnabled = enabledProviderStates[providerKey] ?? true
        guard userEnabled else {
            return false
        }
        return providerConfigLockReason(providerKey, baseConfigRoot: baseConfigRoot) == nil
    }

    func providerConfigLockReason(_ providerKey: String) -> String? {
        providerConfigLockReason(providerKey, baseConfigRoot: nil)
    }

    private func providerConfigLockReason(_ providerKey: String, baseConfigRoot: [String: Any]?) -> String? {
        guard let oauthProviderKey = ProviderCatalog.oauthProviderKeys[providerKey] else {
            return nil
        }
        let root: [String: Any]
        if let baseConfigRoot {
            root = baseConfigRoot
        } else {
            guard case .success(let baseConfig) = loadBaseConfigRoot() else {
                return nil
            }
            root = baseConfig.root
        }
        guard ConfigComposer.isOAuthProviderWildcardExcluded(oauthProviderKey, in: root) else {
            return nil
        }
        return String(format: String(localized: "server-manager.oauth-provider.disabled-in-config", defaultValue: "Disabled in config via oauth-excluded-models. Remove the '*' exclusion for %@ to enable it here.", comment: "Message explaining provider remains disabled due to oauth-excluded-models config"), "\(oauthProviderKey)")
    }

    func isProviderToggleLocked(_ providerKey: String) -> Bool {
        providerConfigLockReason(providerKey) != nil
    }

    /// Set provider enabled state and regenerate config (hot reload - no restart needed)
    func setProviderEnabled(_ providerKey: String, enabled: Bool) {
        enabledProviders[providerKey] = enabled
        if enabled, let lockReason = providerConfigLockReason(providerKey) {
            addLog(String(format: String(localized: "server-manager.provider.remains-disabled-with-reason", defaultValue: "⚠️ %@ remains disabled: %@", comment: "Warning message when provider stays disabled with reason"), "\(providerKey)", "\(lockReason)"))
        } else {
            addLog(enabled ? String(format: String(localized: "server-manager.provider.enabled", defaultValue: "✓ Enabled provider: %@", comment: "Success message when provider is enabled"), "\(providerKey)") : String(format: String(localized: "server-manager.provider.disabled", defaultValue: "⚠️ Disabled provider: %@", comment: "Warning message when provider is disabled"), "\(providerKey)"))
        }
        reloadCustomProviders()
        requestConfigUpdate()
    }
    
    deinit {
        // Ensure cleanup on deallocation
        terminateActiveAuthProcessIfNeeded(reason: "deinit cleanup")
        stop()
        killOrphanedProcesses()
    }
    
    func start(completion: @escaping (Bool) -> Void) {
        guard !isRunning else {
            completion(true)
            return
        }

        // Clean up any orphaned processes from previous crashes
        killOrphanedProcesses()

        // Use bundled binary from app bundle
        guard let resourcePath = Bundle.main.resourcePath else {
            addLog(String(localized: "server-manager.error.resource-path-not-found", defaultValue: "❌ Error: Could not find resource path", comment: "Error message when bundled resource path cannot be found"))
            completion(false)
            return
        }
        
        let bundledPath = (resourcePath as NSString).appendingPathComponent("cli-proxy-api-plus")
        guard FileManager.default.fileExists(atPath: bundledPath) else {
            addLog(String(format: String(localized: "server-manager.error.binary-not-found-at-path", defaultValue: "❌ Error: cli-proxy-api-plus binary not found at %@", comment: "Error message when cli-proxy-api-plus binary is missing at expected path"), "\(bundledPath)"))
            completion(false)
            return
        }
        
        // Use config path (merged with Z.AI if keys exist)
        let configPath = getConfigPath()
        guard !configPath.isEmpty && FileManager.default.fileExists(atPath: configPath) else {
            addLog(String(format: String(localized: "server-manager.error.prefixed-config-error", defaultValue: "❌ Error: %@", comment: "Prefixed error message for configuration resolution failures"), "\(configErrorMessage ?? String(localized: "server-manager.error.active-config-path-unresolved", defaultValue: "Could not resolve active config path", comment: "Fallback config resolution error when active config path cannot be resolved"))"))
            completion(false)
            return
        }
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: bundledPath)
        process?.arguments = ["-config", configPath]
        
        // Setup pipes for output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process?.standardOutput = outputPipe
        process?.standardError = errorPipe
        
        // Handle output
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                self?.addLog(output)
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                self?.addLog(String(format: String(localized: "server-manager.warning.output", defaultValue: "⚠️ %@", comment: "Warning output message emitted by server startup checks"), "\(output)"))
            }
        }
        
        // Handle termination
        process?.terminationHandler = { [weak self] process in
            // Clear pipe handlers to prevent memory leaks
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.activeConfigPath = ""
                self?.addLog(String(format: String(localized: "server-manager.server.stopped-with-code", defaultValue: "Server stopped with code: %d", comment: "Message when server process exits with termination status code"), process.terminationStatus))
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
            }
        }
        
        do {
            try process?.run()
            DispatchQueue.main.async {
                self.isRunning = true
                self.activeConfigPath = configPath
            }
            addLog(String(format: String(localized: "server-manager.server.started-on-port", defaultValue: "✓ Server started on port %d", comment: "Success message when server starts and reports port"), port))
            
            // Wait a bit to ensure it started successfully
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.readinessCheckDelay) { [weak self] in
                guard let self = self else { return }
                if let process = self.process, process.isRunning {
                    NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                    completion(true)
                } else {
                    self.addLog(String(localized: "server-manager.warning.server-exited-before-ready", defaultValue: "⚠️ Server exited before becoming ready", comment: "Warning message when server exits before readiness check succeeds"))
                    completion(false)
                }
            }
        } catch {
            addLog(String(format: String(localized: "server-manager.error.failed-to-start-server", defaultValue: "❌ Failed to start server: %@", comment: "Error message when server startup throws an error"), "\(error.localizedDescription)"))
            completion(false)
        }
    }
    
    func stop(completion: (() -> Void)? = nil) {
        guard let process = process else {
            DispatchQueue.main.async {
                self.isRunning = false
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                completion?()
            }
            return
        }
        
        let pid = process.processIdentifier
        addLog(String(format: String(localized: "server-manager.server.stopping-with-pid", defaultValue: "Stopping server (PID: %d)...", comment: "Message when stopping server process with pid"), pid))
        processQueue.async { [weak self] in
            guard let self = self else { return }
            
            // First try graceful termination (SIGTERM)
            process.terminate()
            
            // Wait up to configured interval for graceful termination
            let deadline = Date().addingTimeInterval(Timing.gracefulTerminationTimeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: Timing.terminationPollInterval)
            }
            
            // If still running, force kill (SIGKILL)
            if process.isRunning {
                self.addLog(String(localized: "server-manager.warning.force-killing-server", defaultValue: "⚠️ Server didn't stop gracefully, force killing...", comment: "Warning message when graceful shutdown fails and force kill is used"))
                kill(pid, SIGKILL)
            }
            
            process.waitUntilExit()
            
            DispatchQueue.main.async {
                self.process = nil
                self.isRunning = false
                self.activeConfigPath = ""
                self.addLog(String(localized: "server-manager.server.stopped", defaultValue: "✓ Server stopped", comment: "Success message when server stops"))
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                completion?()
            }
        }
    }
    
    func runAuthCommand(_ command: AuthCommand, completion: @escaping (Bool, String) -> Void) {
        terminateActiveAuthProcessIfNeeded(reason: "starting a new auth attempt")
        cleanupStaleAuthProcesses()

        // Use bundled binary from app bundle
        guard let resourcePath = Bundle.main.resourcePath else {
            completion(false, String(localized: "server-manager.error.resource-path-unresolved", defaultValue: "Could not find resource path", comment: "Error text when resource path cannot be located"))
            return
        }
        
        let bundledPath = (resourcePath as NSString).appendingPathComponent("cli-proxy-api-plus")
        guard FileManager.default.fileExists(atPath: bundledPath) else {
            completion(false, String(format: String(localized: "server-manager.error.binary-not-found", defaultValue: "Binary not found at %@", comment: "Error text when server binary is not found at path"), "\(bundledPath)"))
            return
        }
        
        let authProcess = Process()
        authProcess.executableURL = URL(fileURLWithPath: bundledPath)
        
        let configPath = getConfigPath()
        guard !configPath.isEmpty else {
            completion(false, configErrorMessage ?? String(localized: "server-manager.error.config-path-unresolved", defaultValue: "Could not resolve config path", comment: "Error text when config path cannot be resolved"))
            return
        }
        
        var qwenEmail: String?
        
        switch command {
        case .claudeLogin:
            authProcess.arguments = ["--config", configPath, "-claude-login"]
        case .codexLogin:
            authProcess.arguments = ["--config", configPath, "-codex-login"]
        case .copilotLogin:
            authProcess.arguments = ["--config", configPath, "-github-copilot-login"]
        case .geminiLogin:
            authProcess.arguments = ["--config", configPath, "-login"]
        case .kimiLogin:
            authProcess.arguments = ["--config", configPath, "-kimi-login"]
        case .qwenLogin(let email):
            authProcess.arguments = ["--config", configPath, "-qwen-login"]
            qwenEmail = email
        case .antigravityLogin:
            authProcess.arguments = ["--config", configPath, "-antigravity-login"]
        }
        
        // Create pipes for output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        authProcess.standardOutput = outputPipe
        authProcess.standardError = errorPipe
        authProcess.standardInput = inputPipe
        
        // For Copilot, we need to capture the device code from output
        let capture = OutputCapture()
        
        if case .copilotLogin = command {
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    capture.text += str
                    NSLog("[Auth] Copilot output: %@", str)
                }
            }
        }
        
        // For Gemini login, automatically send newline to accept default project
        if case .geminiLogin = command {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Timing.geminiDefaultProjectAcceptDelay) {
                // Send newline after 3 seconds to accept default project choice
                if authProcess.isRunning {
                    if let data = "\n".data(using: .utf8) {
                        try? inputPipe.fileHandleForWriting.write(contentsOf: data)
                        NSLog("[Auth] Sent newline to accept default project")
                    }
                }
            }
        }

        // For Codex login, avoid blocking on the manual callback prompt after configured delay
        if case .codexLogin = command {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Timing.codexCallbackKeepaliveDelay) {
                // Send newline before the prompt to keep waiting for browser callback.
                if authProcess.isRunning {
                    if let data = "\n".data(using: .utf8) {
                        try? inputPipe.fileHandleForWriting.write(contentsOf: data)
                        NSLog("[Auth] Sent newline to keep Codex login waiting for callback")
                    }
                }
            }
        }
        
        // For Qwen login, automatically send email after OAuth completes
        // NOTE: Delay chosen to ensure OAuth browser flow completes before submitting email.
        // This is a conservative estimate - OAuth typically completes in 5-8 seconds, but network
        // conditions and user interaction time can vary. Future improvement: monitor authProcess
        // output or termination handler to detect OAuth completion signal and submit immediately.
        if let email = qwenEmail {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Timing.qwenEmailSubmissionDelay) {
                // Send email after OAuth completion
                if authProcess.isRunning {
                    if let data = "\(email)\n".data(using: .utf8) {
                        try? inputPipe.fileHandleForWriting.write(contentsOf: data)
                        NSLog("[Auth] Sent Qwen email: %@", email)
                    }
                }
            }
        }
        
        // Set environment to inherit from parent
        authProcess.environment = ProcessInfo.processInfo.environment

        authProcess.terminationHandler = { [weak self] process in
            let exitCode = process.terminationStatus
            NSLog("[Auth] Process terminated with exit code: %d", exitCode)
            self?.clearActiveAuthProcess(process)

            if exitCode == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
                }
            }
        }
        
        do {
            NSLog("[Auth] Starting process: %@ with args: %@", bundledPath, authProcess.arguments?.joined(separator: " ") ?? "none")
            activeAuthProcess = authProcess
            try authProcess.run()
            addLog(String(format: String(localized: "server-manager.authentication-process.started-with-pid", defaultValue: "✓ Authentication process started (PID: %d) - browser should open shortly", comment: "Success message when authentication helper process starts"), authProcess.processIdentifier))
            NSLog("[Auth] Process started with PID: %d", authProcess.processIdentifier)
            
            // Wait briefly to check if process crashes immediately or to capture output
            let waitTime: TimeInterval = (command == .copilotLogin) ? 2.0 : 1.0
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitTime) {
                if authProcess.isRunning {
                    // Process is still running - check for Copilot device code
                    NSLog("[Auth] Process running after wait, returning success")
                    
                    // For Copilot, try to extract the device code from output
                    if case .copilotLogin = command {
                        // Extract code from output like "enter the code: XXXX-XXXX"
                        if let codeRange = capture.text.range(of: "enter the code: "),
                           let endRange = capture.text[codeRange.upperBound...].range(of: "\n") {
                            let code = String(capture.text[codeRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                            // Copy code to clipboard
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            completion(true, String(format: String(localized: "server-manager.auth.github.browser-opened-with-code", defaultValue: "🌐 Browser opened for GitHub authentication.\n\n📋 Code copied to clipboard:\n\n%@\n\nJust paste it in the browser!\n\nThe app will automatically detect when you're authenticated.", comment: "Instructions shown when GitHub auth browser opens and device code is copied"), "\(code)"))
                            return
                        } else if capture.text.contains("enter the code:") {
                            // Try simpler extraction
                            let lines = capture.text.components(separatedBy: "\n")
                            for line in lines {
                                if line.contains("enter the code:") {
                                    let parts = line.components(separatedBy: "enter the code:")
                                    if parts.count > 1 {
                                        let code = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                                        // Copy code to clipboard
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(code, forType: .string)
                                        completion(true, String(format: String(localized: "server-manager.auth.github.browser-opened-with-code", defaultValue: "🌐 Browser opened for GitHub authentication.\n\n📋 Code copied to clipboard:\n\n%@\n\nJust paste it in the browser!\n\nThe app will automatically detect when you're authenticated.", comment: "Instructions shown when GitHub auth browser opens and device code is copied"), "\(code)"))
                                        return
                                    }
                                }
                            }
                        }
                        // Fallback if we couldn't extract the code
                        completion(true, String(localized: "server-manager.auth.github.browser-opened-check-device-code", defaultValue: "🌐 Browser opened for GitHub authentication.\n\nCheck your terminal or the opened browser for the device code.\n\nThe app will automatically detect when you're authenticated.", comment: "Instructions shown when GitHub auth starts without clipboard code copy"))
                        return
                    }
                    
                    completion(true, String(localized: "server-manager.auth.browser-opened.generic", defaultValue: "🌐 Browser opened for authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect when you're authenticated.", comment: "Generic instructions shown when authentication browser opens"))
                } else {
                    // Process died quickly - check for error
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    var output = String(data: outputData, encoding: .utf8) ?? ""
                    if output.isEmpty { output = capture.text }
                    let error = String(data: errorData, encoding: .utf8) ?? ""
                    
                    NSLog("[Auth] Process died quickly - output: %@", output.isEmpty ? "(empty)" : String(output.prefix(200)))
                    
                    if output.contains("Opening browser") || output.contains("Attempting to open URL") {
                        // Browser opened but process finished (probably success)
                        NSLog("[Auth] Browser opened, process completed")
                        completion(true, String(localized: "server-manager.auth.browser-opened.generic", defaultValue: "🌐 Browser opened for authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect when you're authenticated.", comment: "Generic instructions shown when authentication browser opens"))
                    } else {
                        // Real error
                        NSLog("[Auth] Process failed")
                        let message = error.isEmpty ? (output.isEmpty ? String(localized: "server-manager.auth.error.process-failed-unexpectedly", defaultValue: "Authentication process failed unexpectedly", comment: "Error text when authentication process exits unexpectedly") : output) : error
                        completion(false, message)
                    }
                }
            }
        } catch {
            clearActiveAuthProcess(authProcess)
            NSLog("[Auth] Failed to start: %@", error.localizedDescription)
            completion(false, String(format: String(localized: "server-manager.auth.error.failed-to-start-process", defaultValue: "Failed to start auth process: %@", comment: "Error text when authentication process cannot be started"), "\(error.localizedDescription)"))
        }
    }

    private func terminateActiveAuthProcessIfNeeded(reason: String) {
        guard let authProcess = activeAuthProcess else {
            return
        }

        if authProcess.isRunning {
            addLog(String(format: String(localized: "server-manager.auth.warning.terminating-previous-process-before-retry", defaultValue: "⚠️ Terminating previous auth process (%d) before retry: %@", comment: "Warning text when previous auth process is terminated before retry"), authProcess.processIdentifier, "\(reason)"))
            authProcess.terminate()

            let deadline = Date().addingTimeInterval(Timing.gracefulTerminationTimeout)
            while authProcess.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: Timing.terminationPollInterval)
            }

            if authProcess.isRunning {
                kill(authProcess.processIdentifier, SIGKILL)
            }
        }

        activeAuthProcess = nil
    }

    private func clearActiveAuthProcess(_ process: Process) {
        if activeAuthProcess === process {
            activeAuthProcess = nil
        }
    }

    private func cleanupStaleAuthProcesses() {
        let backendPID = process?.processIdentifier
        let patterns = [
            "cli-proxy-api-plus.*-claude-login",
            "cli-proxy-api-plus.*-codex-login",
            "cli-proxy-api-plus.*-github-copilot-login",
            "cli-proxy-api-plus.*-qwen-login",
            "cli-proxy-api-plus.*-antigravity-login",
            "cli-proxy-api-plus.* -login"
        ]

        for pattern in patterns {
            let checkTask = Process()
            checkTask.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            checkTask.arguments = ["-f", pattern]

            let outputPipe = Pipe()
            checkTask.standardOutput = outputPipe
            checkTask.standardError = Pipe()

            do {
                try checkTask.run()
                checkTask.waitUntilExit()
                guard checkTask.terminationStatus == 0 else {
                    continue
                }

                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let pids = output.components(separatedBy: .newlines).compactMap { Int32($0) }

                for pid in pids {
                    if pid == backendPID {
                        continue
                    }
                    kill(pid, SIGKILL)
                    addLog(String(format: String(localized: "server-manager.auth.warning.cleaned-stale-listener-process", defaultValue: "⚠️ Cleaned up stale auth listener process: %d", comment: "Warning text when stale authentication listener process is cleaned up"), pid))
                }
            } catch {
                // best-effort cleanup only
            }
        }
    }
    
    private func addLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let logLine = "[\(timestamp)] \(message)"
            
            self.logBuffer.append(logLine)
            self.onLogUpdate?(self.logBuffer.elements())
        }
    }
    
    /// Saves a Z.AI API key to the auth directory
    func saveZaiApiKey(_ apiKey: String, completion: @escaping (Bool, String) -> Void) {
        credentialMutationQueue.async { [weak self] in
            guard let self else { return }

            do {
                let filePath = try self.zaiAPIKeyStore.save(apiKey: apiKey)
                self.addLog(String(format: String(localized: "server-manager.zai-api-key.saved-to-file", defaultValue: "✓ Z.AI API key saved to %@", comment: "Success text when Z.AI API key is saved to a file"), "\(filePath.lastPathComponent)"))
                self.refreshAuthBackedConfiguration()
                DispatchQueue.main.async {
                    completion(true, "API key saved successfully")
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
    
    func saveCustomProviderAPIKey(providerID: String, apiKey: String, completion: @escaping (Bool, String) -> Void) {
        credentialMutationQueue.async { [weak self] in
            guard let self else { return }

            do {
                let baseConfig: LoadedBaseConfig
                switch self.loadBaseConfigRoot() {
                case .success(let loadedBaseConfig):
                    baseConfig = loadedBaseConfig
                case .failure(let error):
                    DispatchQueue.main.async {
                        completion(false, error.message)
                    }
                    return
                }

                let customProviders = ConfigComposer.parseCustomProviders(
                    from: baseConfig.root,
                    reservedProviderIDs: ProviderCatalog.reservedCustomProviderKeys
                )
                guard let provider = customProviders.first(where: { $0.id == providerID }) else {
                    DispatchQueue.main.async {
                        completion(false, String(format: String(localized: "server-manager.custom-provider.error.not-defined-in-config", defaultValue: "Custom provider '%@' is not defined in config.yaml.", comment: "Error text when custom provider id is not present in config file"), "\(providerID)"))
                    }
                    return
                }

                if provider.inlineAPIKeys.contains(apiKey) {
                    self.addLog(String(format: String(localized: "server-manager.custom-provider.api-key.already-exists-in-config", defaultValue: "✓ API key for custom provider %@ already exists in config", comment: "Message when custom provider API key already exists in config"), "\(providerID)"))
                    DispatchQueue.main.async {
                        completion(true, String(localized: "server-manager.api-key.already-exists-in-config", defaultValue: "API key already exists in config", comment: "Title text when API key is already present in config"))
                    }
                    return
                }

                let saveResult = try self.customProviderCredentialStore.save(providerID: providerID, apiKey: apiKey)
                switch saveResult {
                case .created(let record):
                    self.addLog(String(format: String(localized: "server-manager.custom-provider.api-key.saved", defaultValue: "✓ Saved API key for custom provider: %@", comment: "Success text when custom provider API key is saved"), "\(record.providerID)"))
                case .alreadyPresent(let record):
                    self.addLog(String(format: String(localized: "server-manager.custom-provider.key.already-present", defaultValue: "✓ Custom provider key already present: %@", comment: "Message when custom provider key label is already present"), "\(record.label)"))
                case .reenabled(let record):
                    self.addLog(String(format: String(localized: "server-manager.custom-provider.key.reenabled", defaultValue: "✓ Re-enabled custom provider key: %@", comment: "Success text when existing custom provider key is re-enabled"), "\(record.label)"))
                }
                self.refreshAuthBackedConfiguration()
                DispatchQueue.main.async {
                    switch saveResult {
                    case .created:
                        completion(true, "API key saved successfully")
                    case .alreadyPresent:
                        completion(true, "API key already exists")
                    case .reenabled:
                        completion(true, "API key was already stored and has been re-enabled")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    func refreshAuthBackedConfiguration() {
        markObservedConfigInputsCurrent()
        reloadCustomProviders()
        requestConfigUpdate()
    }

    func handleObservedConfigInputsChanged() {
        guard markObservedConfigInputsChanged() else {
            return
        }
        reloadCustomProviders()
        requestConfigUpdate()
    }
    
    @discardableResult
    func deleteCustomProviderCredential(_ credential: CustomProviderCredential) -> Bool {
        do {
            let deletedCount = try customProviderCredentialStore.delete(
                providerID: credential.providerID,
                apiKey: credential.apiKey
            )
            addLog(String(format: String(localized: "server-manager.custom-provider.key.removed", defaultValue: "✓ Removed custom provider key: %@", comment: "Success message when a custom provider key is removed"), "\(credential.label)"))
            if deletedCount > 1 {
                addLog(String(format: String(localized: "server-manager.custom-provider.duplicate-credentials.removed-count", defaultValue: "✓ Removed %d duplicate credential files for %@", comment: "Success message showing number of duplicate credential files removed for a provider"), deletedCount, "\(credential.providerID)"))
            }
            markObservedConfigInputsCurrent()
            reloadCustomProviders()
            requestConfigUpdate()
            return true
        } catch {
            NSLog("[ServerManager] Failed to delete custom provider credential: %@", error.localizedDescription)
            return false
        }
    }
    
    @discardableResult
    func toggleCustomProviderCredentialDisabled(_ credential: CustomProviderCredential) -> Bool {
        do {
            try customProviderCredentialStore.setDisabled(
                providerID: credential.providerID,
                apiKey: credential.apiKey,
                isDisabled: !credential.isDisabled
            )
            addLog(
                credential.isDisabled
                    ? String(format: String(localized: "server-manager.custom-provider.key.enabled", defaultValue: "✓ Enabled custom provider key: %@", comment: "Success message when a custom provider key is enabled"), "\(credential.label)")
                    : String(format: String(localized: "server-manager.custom-provider.key.disabled", defaultValue: "⚠️ Disabled custom provider key: %@", comment: "Warning message when a custom provider key is disabled"), "\(credential.label)")
            )
            markObservedConfigInputsCurrent()
            reloadCustomProviders()
            requestConfigUpdate()
            return true
        } catch {
            NSLog("[ServerManager] Failed to toggle custom provider credential: %@", error.localizedDescription)
            return false
        }
    }
    
    func reloadCustomProviders() {
        switch loadBaseConfigRoot() {
        case .success(let config):
            clearConfigError()
            let providers = ConfigComposer.parseCustomProviders(
                from: config.root,
                reservedProviderIDs: ProviderCatalog.reservedCustomProviderKeys
            )
            let credentialRecords = loadCustomProviderCredentialRecords()
            let credentials = logicalCustomProviderCredentials(from: credentialRecords, providers: providers)

            DispatchQueue.main.async {
                self.customProviders = providers
                self.customProviderCredentials = credentials
            }
        case .failure(let error):
            publishConfigError(error.message)
            DispatchQueue.main.async {
                self.customProviders = []
                self.customProviderCredentials = [:]
            }
        }
    }
    
    /// Returns the config path to use, merging the base config with provider state and API-key auth files.
    func getConfigPath() -> String {
        switch resolveConfigPath() {
        case .success(let path):
            clearConfigError()
            return path
        case .failure(let error):
            publishConfigError(error.message)
            return ""
        }
    }

    private func resolveConfigPath() -> Result<String, ConfigResolutionFailure> {
        resolveConfigPath(enabledProviderStates: enabledProviders)
    }

    private func resolveConfigPath(
        enabledProviderStates: [String: Bool]
    ) -> Result<String, ConfigResolutionFailure> {
        guard bundledConfigPath() != nil else {
            return .failure(ConfigResolutionFailure(message: String(localized: "server-manager.config.error.bundled-config-not-found", defaultValue: "Could not locate the bundled config.yaml in the app bundle.", comment: "Error when bundled config.yaml cannot be found in app bundle")))
        }
        let baseConfigResult = loadBaseConfigRoot()
        guard case .success(let baseConfig) = baseConfigResult else {
            if case .failure(let error) = baseConfigResult {
                return .failure(error)
            }
            return .failure(ConfigResolutionFailure(message: String(localized: "server-manager.config.error.base-configuration-load-failed", defaultValue: "Could not load the base configuration.", comment: "Error when base configuration cannot be loaded")))
        }
        
        let authDir = authDirectoryURL()
        let zaiApiKeys = loadZaiAPIKeys()
        let customAuthRecords = loadCustomProviderCredentialRecords()
        let managedCustomProviders = ConfigComposer.parseCustomProviders(
            from: baseConfig.root,
            reservedProviderIDs: ProviderCatalog.reservedCustomProviderKeys
        )
        let disabledProviders = ProviderCatalog.oauthProviderKeys.compactMap { serviceKey, oauthKey in
            isProviderEnabled(
                serviceKey,
                baseConfigRoot: baseConfig.root,
                enabledProviderStates: enabledProviderStates
            ) ? nil : oauthKey
        }
        let disabledCustomProviderIDs = Set(managedCustomProviders.map { $0.id }).filter {
            !isProviderEnabled(
                $0,
                baseConfigRoot: baseConfig.root,
                enabledProviderStates: enabledProviderStates
            )
        }
        var mergedRoot = ConfigComposer.composeRuntimeConfig(
            baseRoot: baseConfig.root,
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: disabledCustomProviderIDs,
            disabledOAuthProviderKeys: disabledProviders,
            zaiAPIKeys: zaiApiKeys,
            customProviderAuthRecords: customAuthRecords.map {
                ConfigProviderAuthRecord(
                    providerID: $0.providerID,
                    apiKey: $0.apiKey,
                    isDisabled: $0.isDisabled
                )
            },
            includeManagedZAIProvider: isProviderEnabled(
                ProviderCatalog.managedZAIProviderName,
                baseConfigRoot: baseConfig.root,
                enabledProviderStates: enabledProviderStates
            ),
            managedZAIProviderName: ProviderCatalog.managedZAIProviderName
        )
        
        let mergedConfigPath = authDir.appendingPathComponent(CustomProviderConstants.mergedConfigFilename)
        if mergedRoot["api-keys"] == nil,
           case .success(let existingRuntimeRoot) = loadYAMLDictionary(atPath: mergedConfigPath.path) {
            mergedRoot = ConfigComposer.preservingRuntimeEditableTopLevelKeys(
                in: mergedRoot,
                from: existingRuntimeRoot
            )
        }

        do {
            try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
            let mergedContent = try Yams.dump(object: mergedRoot)
            try mergedContent.write(to: mergedConfigPath, atomically: true, encoding: String.Encoding.utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mergedConfigPath.path)
            return .success(mergedConfigPath.path)
        } catch {
            return .failure(
                ConfigResolutionFailure(
                    message: String(format: String(localized: "server-manager.config.error.write-merged-config-failed", defaultValue: "Failed to write merged config to %@: %@", comment: "Error when writing merged config to disk fails"), "\(mergedConfigPath.path)", "\(error.localizedDescription)")
                )
            )
        }
    }
    
    func getLogs() -> [String] {
        return logBuffer.elements()
    }
    
    /// Kill any orphaned cli-proxy-api-plus processes that might be running
    private func killOrphanedProcesses() {
        // First check if any processes exist using pgrep
        let checkTask = Process()
        checkTask.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        checkTask.arguments = ["-f", "cli-proxy-api-plus"]
        
        let outputPipe = Pipe()
        checkTask.standardOutput = outputPipe
        checkTask.standardError = Pipe() // Suppress errors
        
        do {
            try checkTask.run()
            checkTask.waitUntilExit()
            
            // If pgrep found processes (exit code 0), kill them
            if checkTask.terminationStatus == 0 {
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let pids = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                
                if !pids.isEmpty {
                    addLog(String(format: String(localized: "server-manager.process.warning.orphaned-processes-found", defaultValue: "⚠️ Found orphaned server process(es): %@", comment: "Warning listing orphaned server process ids"), "\(pids.joined(separator: ", "))"))
                    
                    // Now kill them
                    let killTask = Process()
                    killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                    killTask.arguments = ["-9", "-f", "cli-proxy-api-plus"]
                    
                    try killTask.run()
                    killTask.waitUntilExit()
                    
                    // Wait a moment for cleanup
                    Thread.sleep(forTimeInterval: 0.5)
                    addLog(String(localized: "server-manager.process.cleanup.orphaned-processes-success", defaultValue: "✓ Cleaned up orphaned processes", comment: "Success message after orphaned processes are cleaned up"))
                }
            }
            // Exit code 1 means no processes found - this is fine, no need to log
        } catch {
            // Silently fail - this is not critical
        }
    }
    
    private func bundledConfigPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else {
            return nil
        }
        return (resourcePath as NSString).appendingPathComponent("config.yaml")
    }
    
    private func authDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
    }
    
    private func loadBaseConfigRoot() -> Result<LoadedBaseConfig, ConfigResolutionFailure> {
        guard let bundledConfigPath = bundledConfigPath() else {
            return .failure(ConfigResolutionFailure(message: String(localized: "server-manager.config.error.bundled-config-not-found", defaultValue: "Could not locate the bundled config.yaml in the app bundle.", comment: "Error when bundled config.yaml cannot be found in app bundle")))
        }
        let bundledRootResult = loadYAMLDictionary(atPath: bundledConfigPath)
        guard case .success(let bundledRoot) = bundledRootResult else {
            if case .failure(let error) = bundledRootResult {
                return .failure(error)
            }
            return .failure(ConfigResolutionFailure(message: String(format: String(localized: "server-manager.config.error.load-bundled-config-at-path-failed", defaultValue: "Could not load the bundled config at %@.", comment: "Error when loading bundled config at path fails"), "\(bundledConfigPath)")))
        }
        
        let userConfigPath = authDirectoryURL()
            .appendingPathComponent(CustomProviderConstants.userConfigFilename)
            .path
        guard FileManager.default.fileExists(atPath: userConfigPath) else {
            return validatedLoadedBaseConfig(root: bundledRoot, isUserConfig: false)
        }
        
        let userRootResult = loadYAMLDictionary(atPath: userConfigPath)
        guard case .success(let userRoot) = userRootResult else {
            if case .failure(let error) = userRootResult {
                return .failure(error)
            }
            return .failure(ConfigResolutionFailure(message: String(format: String(localized: "server-manager.config.error.load-user-config-at-path-failed", defaultValue: "Could not load the user config at %@.", comment: "Error when loading user config at path fails"), "\(userConfigPath)")))
        }
        
        let mergedRoot = ConfigComposer.composeAdditiveBaseConfig(
            bundledRoot: bundledRoot,
            userRoot: userRoot
        )
        
        return validatedLoadedBaseConfig(root: mergedRoot, isUserConfig: true)
    }
    
    private func loadYAMLDictionary(atPath path: String) -> Result<[String: Any], ConfigResolutionFailure> {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            guard let loaded = try Yams.load(yaml: content) else {
                return .success([:])
            }
            guard let dictionary = ConfigComposer.stringKeyedDictionary(loaded) else {
                return .failure(ConfigResolutionFailure(message: String(format: String(localized: "server-manager.config.error.root-must-be-yaml-mapping", defaultValue: "Config at %@ must be a YAML mapping at the root.", comment: "Error when config root is not a YAML mapping"), "\(path)")))
            }
            return .success(dictionary)
        } catch {
            return .failure(ConfigResolutionFailure(message: String(format: String(localized: "server-manager.config.error.parse-yaml-failed", defaultValue: "Failed to parse YAML at %@: %@", comment: "Error when parsing YAML file fails"), "\(path)", "\(error.localizedDescription)")))
        }
    }

    private func validatedLoadedBaseConfig(
        root: [String: Any],
        isUserConfig: Bool
    ) -> Result<LoadedBaseConfig, ConfigResolutionFailure> {
        let validationErrors = ConfigComposer.validateCustomProviders(
            in: root,
            reservedProviderIDs: ProviderCatalog.reservedCustomProviderKeys
        )
        guard validationErrors.isEmpty else {
            return .failure(
                ConfigResolutionFailure(
                    message: String(format: String(localized: "server-manager.custom-provider.error.invalid-configuration", defaultValue: "Invalid custom provider configuration. %@", comment: "Error describing invalid custom provider configuration with validation details"), "\(validationErrors.joined(separator: " "))")
                )
            )
        }
        return .success(LoadedBaseConfig(root: root, isUserConfig: isUserConfig))
    }

    private func currentObservedConfigInputsFingerprint() -> String {
        ConfigInputFingerprint.compute(
            in: authDirectoryURL(),
            userConfigFilename: CustomProviderConstants.userConfigFilename
        )
    }

    private func markObservedConfigInputsCurrent() {
        let fingerprint = currentObservedConfigInputsFingerprint()
        configInputStateQueue.sync {
            observedConfigInputsFingerprint = fingerprint
        }
    }

    private func markObservedConfigInputsChanged() -> Bool {
        let fingerprint = currentObservedConfigInputsFingerprint()
        return configInputStateQueue.sync {
            guard fingerprint != observedConfigInputsFingerprint else {
                return false
            }
            observedConfigInputsFingerprint = fingerprint
            return true
        }
    }
    
    private func loadZaiAPIKeys() -> [String] {
        let loadResult = zaiAPIKeyStore.loadActiveAPIKeys()
        for issue in loadResult.issues {
            NSLog("[ServerManager] Ignoring Z.AI API key file at %@: %@", issue.filePath.path, issue.message)
        }
        return loadResult.apiKeys
    }
    
    private func loadCustomProviderCredentialRecords() -> [CustomProviderCredentialRecord] {
        let loadResult = customProviderCredentialStore.loadAll()
        for issue in loadResult.issues {
            NSLog("[ServerManager] Ignoring custom provider credential file at %@: %@", issue.filePath.path, issue.message)
        }
        return loadResult.records
    }

    private func logicalCustomProviderCredentials(
        from records: [CustomProviderCredentialRecord],
        providers: [CustomProviderDefinition]
    ) -> [String: [CustomProviderCredential]] {
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let groupedRecords = Dictionary(
            grouping: records.filter { providersByID[$0.providerID] != nil },
            by: { CustomProviderCredentialKey(providerID: $0.providerID, apiKey: $0.apiKey) }
        )

        let logicalCredentials = groupedRecords.compactMapValues { groupedRecords -> CustomProviderCredential? in
            guard let sampleRecord = groupedRecords.first,
                  let provider = providersByID[sampleRecord.providerID],
                  !provider.inlineAPIKeys.contains(sampleRecord.apiKey) else {
                return nil
            }

            let preferredRecord = groupedRecords.sorted { lhs, rhs in
                if lhs.isDisabled != rhs.isDisabled {
                    return !lhs.isDisabled
                }

                let labelComparison = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
                if labelComparison != .orderedSame {
                    return labelComparison == .orderedAscending
                }

                return lhs.filePath.lastPathComponent < rhs.filePath.lastPathComponent
            }.first!

            return CustomProviderCredential(
                providerID: sampleRecord.providerID,
                apiKey: sampleRecord.apiKey,
                label: preferredRecord.label,
                isDisabled: groupedRecords.allSatisfy { $0.isDisabled }
            )
        }

        return Dictionary(grouping: logicalCredentials.values, by: \.providerID).mapValues { credentials in
            credentials.sorted { lhs, rhs in
                if lhs.isDisabled != rhs.isDisabled {
                    return !lhs.isDisabled
                }

                let labelComparison = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
                if labelComparison != .orderedSame {
                    return labelComparison == .orderedAscending
                }

                return lhs.id < rhs.id
            }
        }
    }
    
    private func publishConfigError(_ message: String) {
        let update = {
            let shouldLog = self.configErrorMessage != message
            self.configErrorMessage = message
            if shouldLog {
                self.addLog(String(format: String(localized: "server-manager.error.prefixed-message", defaultValue: "❌ %@", comment: "Generic prefixed error message wrapper"), "\(message)"))
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func clearConfigError() {
        let update = {
            self.configErrorMessage = nil
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func requestConfigUpdate() {
        let update: () -> Void = { [weak self] in
            self?.beginConfigUpdateEvaluation()
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func beginConfigUpdateEvaluation() {
        assert(Thread.isMainThread, "beginConfigUpdateEvaluation must run on the main thread")

        guard !isRestartingForConfigUpdate else {
            hasPendingConfigUpdate = true
            return
        }

        guard !isResolvingConfigUpdate else {
            hasPendingConfigUpdate = true
            return
        }

        let enabledProviderSnapshot = enabledProviders
        hasPendingConfigUpdate = false
        isResolvingConfigUpdate = true

        configResolutionQueue.async { [weak self] in
            guard let self else {
                return
            }

            let result = self.resolveConfigPath(enabledProviderStates: enabledProviderSnapshot)
            DispatchQueue.main.async { [weak self] in
                self?.finishConfigUpdateResolution(result)
            }
        }
    }

    private func finishConfigUpdateResolution(_ result: Result<String, ConfigResolutionFailure>) {
        assert(Thread.isMainThread, "finishConfigUpdateResolution must run on the main thread")

        isResolvingConfigUpdate = false

        guard !hasPendingConfigUpdate else {
            requestConfigUpdate()
            return
        }

        let configPath: String
        switch result {
        case .success(let resolvedPath):
            clearConfigError()
            configPath = resolvedPath
        case .failure(let error):
            publishConfigError(error.message)
            return
        }

        let shouldRestart = isRunning && !activeConfigPath.isEmpty && activeConfigPath != configPath
        if shouldRestart {
            isRestartingForConfigUpdate = true
            hasPendingConfigUpdate = false
            addLog(String(localized: "server-manager.config.path-changed-restarting-server", defaultValue: "Config path changed; restarting server", comment: "Status message when config path changes and server is restarted"))
            stop { [weak self] in
                self?.start { [weak self] _ in
                    self?.finishConfigUpdateRestart()
                }
            }
            return
        }
        
        if isRunning {
            addLog(String(localized: "server-manager.config.updated-hot-reload", defaultValue: "Config updated (hot reload)", comment: "Status message when config updates are applied via hot reload"))
        }
    }
    
    private func finishConfigUpdateRestart() {
        isRestartingForConfigUpdate = false
        guard hasPendingConfigUpdate else {
            return
        }
        hasPendingConfigUpdate = false
        requestConfigUpdate()
    }
}

enum AuthCommand: Equatable {
    case claudeLogin
    case codexLogin
    case copilotLogin
    case geminiLogin
    case kimiLogin
    case qwenLogin(email: String)
    case antigravityLogin
}
