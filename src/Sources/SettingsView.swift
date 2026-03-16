import SwiftUI
import ServiceManagement

/// A single account row with remove button
struct AccountRowView: View {
    let account: AuthAccount
    let removeColor: Color
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.isExpired ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
            Text(account.displayName)
                .font(.caption)
                .foregroundColor(account.isExpired ? .orange : .secondary)
            if account.isExpired {
                Text(String(localized: "settings.account.expired", defaultValue: "(expired)", comment: "Label indicating an account's authentication has expired"))
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            Button(action: onRemove) {
                HStack(spacing: 2) {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption)
                    Text(String(localized: "settings.account.remove-button", defaultValue: "Remove", comment: "Button to remove an account from the service"))
                        .font(.caption)
                }
                .foregroundColor(removeColor)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.leading, 28)
    }
}

/// Vercel AI Gateway controls shown in Claude expanded section
struct VercelGatewayControls: View {
    @ObservedObject var serverManager: ServerManager
    @State private var showingSaved = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $serverManager.vercelGatewayEnabled) {
                Text(String(localized: "settings.vercel.toggle", defaultValue: "Use Vercel AI Gateway", comment: "Toggle to enable Vercel AI Gateway for Claude requests"))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help(String(localized: "settings.vercel.help", defaultValue: "Route Claude requests through Vercel AI Gateway for safer access to your Claude Max subscription", comment: "Help text explaining the Vercel AI Gateway feature"))
            
            if serverManager.vercelGatewayEnabled {
                HStack(spacing: 8) {
                    Text(String(localized: "settings.vercel.api-key-label", defaultValue: "Vercel API key", comment: "Label for the Vercel API key input field"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("", text: $serverManager.vercelApiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .font(.caption)
                    
                    if showingSaved {
                        Text(String(localized: "settings.vercel.saved", defaultValue: "Saved", comment: "Confirmation message when Vercel API key is saved"))
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Button(String(localized: "settings.vercel.save-button", defaultValue: "Save", comment: "Button to save the Vercel API key")) {
                            showingSaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showingSaved = false
                            }
                        }
                        .controlSize(.small)
                        .disabled(serverManager.vercelApiKey.isEmpty)
                    }
                }
            }
        }
        .padding(.leading, 28)
        .padding(.top, 4)
    }
}

/// A row displaying a service with its connected accounts and add button
struct ServiceRow<ExtraContent: View>: View {
    let serviceType: ServiceType
    let iconName: String
    let accounts: [AuthAccount]
    let isAuthenticating: Bool
    let helpText: String?
    let isEnabled: Bool
    let customTitle: String?
    let onConnect: () -> Void
    let onDisconnect: (AuthAccount) -> Void
    let onToggleEnabled: (Bool) -> Void
    var onExpandChange: ((Bool) -> Void)? = nil
    @ViewBuilder var extraContent: () -> ExtraContent

    @State private var isExpanded = false
    @State private var accountToRemove: AuthAccount?
    @State private var showingRemoveConfirmation = false

    private var activeCount: Int { accounts.filter { !$0.isExpired }.count }
    private var expiredCount: Int { accounts.filter { $0.isExpired }.count }
    private let removeColor = Color(red: 0xeb/255, green: 0x0f/255, blue: 0x0f/255)
    
    private var displayTitle: String {
        customTitle ?? serviceType.displayName
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row
            HStack {
                // Enable/disable toggle
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggleEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(isEnabled ? String(localized: "settings.provider.disable-help", defaultValue: "Disable this provider", comment: "Tooltip for toggle to disable a provider") : String(localized: "settings.provider.enable-help", defaultValue: "Enable this provider", comment: "Tooltip for toggle to enable a provider"))

                if let nsImage = IconCatalog.shared.image(named: iconName, resizedTo: NSSize(width: 20, height: 20), template: true) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 20, height: 20)
                        .opacity(isEnabled ? 1.0 : 0.4)
                }
                Text(displayTitle)
                    .fontWeight(.medium)
                    .foregroundColor(isEnabled ? .primary : .secondary)
                Spacer()
                if isAuthenticating {
                    ProgressView()
                        .controlSize(.small)
                } else if isEnabled {
                    Button(String(localized: "settings.provider.add-account-button", defaultValue: "Add Account", comment: "Button to add a new account to a provider")) {
                        onConnect()
                    }
                    .controlSize(.small)
                }
            }
            
            // Account display (only shown when enabled)
            if isEnabled {
                if !accounts.isEmpty {
                    // Collapsible summary
                    HStack(spacing: 4) {
                        Text(String(format: NSLocalizedString("settings.provider.account-count", comment: "Count of connected accounts for a provider"), accounts.count))
                            .font(.caption)
                            .foregroundColor(.green)

                        if accounts.count > 1 {
                            Text(String(localized: "settings.provider.round-robin-info", defaultValue: "• Round-robin w/ auto-failover", comment: "Information about load balancing strategy when multiple accounts are connected"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    }

                    // Expanded accounts list
                    if isExpanded {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(accounts) { account in
                                AccountRowView(account: account, removeColor: removeColor) {
                                    accountToRemove = account
                                    showingRemoveConfirmation = true
                                }
                            }
                            extraContent()
                        }
                        .padding(.top, 4)
                    }
                } else {
                    Text(String(localized: "settings.provider.no-accounts", defaultValue: "No connected accounts", comment: "Message shown when no accounts are connected to a provider"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 4)
        .help(helpText ?? "")
        .onAppear {
            if accounts.contains(where: { $0.isExpired }) {
                isExpanded = true
            }
        }
        .onChange(of: accounts) { _, newAccounts in
            if newAccounts.contains(where: { $0.isExpired }) {
                isExpanded = true
            }
        }
        .onChange(of: isExpanded) { _, newValue in
            onExpandChange?(newValue)
        }
        .alert(String(localized: "settings.remove-account.title", defaultValue: "Remove Account", comment: "Alert title when confirming account removal"), isPresented: $showingRemoveConfirmation) {
            Button(String(localized: "settings.remove-account.cancel-button", defaultValue: "Cancel", comment: "Button to cancel account removal"), role: .cancel) {
                accountToRemove = nil
            }
            Button(String(localized: "settings.remove-account.remove-button", defaultValue: "Remove", comment: "Button to confirm account removal"), role: .destructive) {
                if let account = accountToRemove {
                    onDisconnect(account)
                }
                accountToRemove = nil
            }
        } message: {
            if let account = accountToRemove {
                Text(String(format: NSLocalizedString("settings.remove-account.message", comment: "Confirmation message when removing an account from a service"), account.displayName, serviceType.displayName))
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var serverManager: ServerManager
    @StateObject private var authManager = AuthManager()
    @State private var launchAtLogin = false
    @State private var authenticatingService: ServiceType? = nil
    @State private var showingAuthResult = false
    @State private var authResultMessage = ""
    @State private var authResultSuccess = false
    @State private var fileMonitor: DispatchSourceFileSystemObject?
    @State private var showingQwenEmailPrompt = false
    @State private var qwenEmail = ""
    @State private var showingZaiApiKeyPrompt = false
    @State private var zaiApiKey = ""
    @State private var pendingRefresh: DispatchWorkItem?
    @State private var expandedRowCount = 0
    
    private enum Timing {
        static let serverRestartDelay: TimeInterval = 0.3
        static let refreshDebounce: TimeInterval = 0.5
    }

    private var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return "v\(version)"
        }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        Text(String(localized: "settings.server-status.label", defaultValue: "Server status", comment: "Label for the server status section"))
                        Spacer()
                        Button(action: {
                            if serverManager.isRunning {
                                serverManager.stop()
                            } else {
                                serverManager.start { _ in }
                            }
                        }) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(serverManager.isRunning ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(serverManager.isRunning ? String(localized: "settings.server-status.running", defaultValue: "Running", comment: "Server status indicator when running") : String(localized: "settings.server-status.stopped", defaultValue: "Stopped", comment: "Server status indicator when stopped"))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Toggle(String(localized: "settings.launch-at-login", defaultValue: "Launch at login", comment: "Toggle to enable launching the app at login"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            toggleLaunchAtLogin(newValue)
                        }

                    HStack {
                        Text(String(localized: "settings.auth-files.label", defaultValue: "Auth files", comment: "Label for the authentication files section"))
                        Spacer()
                        Button(String(localized: "settings.auth-files.open-button", defaultValue: "Open Folder", comment: "Button to open the authentication files folder")) {
                            openAuthFolder()
                        }
                    }
                }

                Section(String(localized: "settings.services.section-title", defaultValue: "Services", comment: "Section title for the services list")) {
                    ServiceRow(
                        serviceType: .antigravity,
                        iconName: "icon-antigravity.png",
                        accounts: authManager.accounts(for: .antigravity),
                        isAuthenticating: authenticatingService == .antigravity,
                        helpText: String(localized: "settings.antigravity.help", defaultValue: "Antigravity provides OAuth-based access to various AI models including Gemini and Claude. One login gives you access to multiple AI services.", comment: "Help text explaining the Antigravity service"),
                        isEnabled: serverManager.isProviderEnabled("antigravity"),
                        customTitle: nil,
                        onConnect: { connectService(.antigravity) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("antigravity", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .claude,
                        iconName: "icon-claude.png",
                        accounts: authManager.accounts(for: .claude),
                        isAuthenticating: authenticatingService == .claude,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled("claude"),
                        customTitle: serverManager.vercelGatewayEnabled && !serverManager.vercelApiKey.isEmpty ? String(localized: "settings.claude.title-via-vercel", defaultValue: "Claude Code (via Vercel)", comment: "Custom title for Claude service when using Vercel AI Gateway") : nil,
                        onConnect: { connectService(.claude) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("claude", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) {
                        VercelGatewayControls(serverManager: serverManager)
                    }

                    ServiceRow(
                        serviceType: .codex,
                        iconName: "icon-codex.png",
                        accounts: authManager.accounts(for: .codex),
                        isAuthenticating: authenticatingService == .codex,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled("codex"),
                        customTitle: nil,
                        onConnect: { connectService(.codex) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("codex", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .gemini,
                        iconName: "icon-gemini.png",
                        accounts: authManager.accounts(for: .gemini),
                        isAuthenticating: authenticatingService == .gemini,
                        helpText: String(localized: "settings.gemini.help", defaultValue: "⚠️ Note: If you're an existing Gemini user with multiple projects, authentication will use your default project. Set your desired project as default in Google AI Studio before connecting.", comment: "Help text explaining Gemini project selection"),
                        isEnabled: serverManager.isProviderEnabled("gemini"),
                        customTitle: nil,
                        onConnect: { connectService(.gemini) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("gemini", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .copilot,
                        iconName: "icon-copilot.png",
                        accounts: authManager.accounts(for: .copilot),
                        isAuthenticating: authenticatingService == .copilot,
                        helpText: String(localized: "settings.copilot.help", defaultValue: "GitHub Copilot provides access to Claude, GPT, Gemini and other models via your Copilot subscription.", comment: "Help text explaining the GitHub Copilot service"),
                        isEnabled: serverManager.isProviderEnabled("github-copilot"),
                        customTitle: nil,
                        onConnect: { connectService(.copilot) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("github-copilot", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .qwen,
                        iconName: "icon-qwen.png",
                        accounts: authManager.accounts(for: .qwen),
                        isAuthenticating: authenticatingService == .qwen,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled("qwen"),
                        customTitle: nil,
                        onConnect: { showingQwenEmailPrompt = true },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("qwen", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .zai,
                        iconName: "icon-zai.png",
                        accounts: authManager.accounts(for: .zai),
                        isAuthenticating: authenticatingService == .zai,
                        helpText: String(localized: "settings.zai.help", defaultValue: "Z.AI GLM provides access to GLM-4.7 and other models via API key. Get your key at https://z.ai/manage-apikey/apikey-list", comment: "Help text explaining the Z.AI service and where to get API keys"),
                        isEnabled: serverManager.isProviderEnabled("zai"),
                        customTitle: nil,
                        onConnect: { showingZaiApiKeyPrompt = true },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("zai", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(expandedRowCount == 0)

            Spacer()
                .frame(height: 6)

            // Footer
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text(String(format: NSLocalizedString("settings.footer.attribution", comment: "Attribution text for the app footer"), appVersion))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Link("CLIProxyAPIPlus", destination: URL(string: "https://github.com/router-for-me/CLIProxyAPIPlus")!)
                        .font(.caption)
                        .underline()
                        .foregroundColor(.secondary)
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    Text("|")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("License: MIT")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Text("© 2026")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Link("Automaze, Ltd.", destination: URL(string: "https://automaze.io")!)
                        .font(.caption)
                        .underline()
                        .foregroundColor(.secondary)
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    Text(String(localized: "settings.footer.rights", defaultValue: "All rights reserved.", comment: "Copyright rights statement in footer"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Link(String(localized: "settings.footer.report-issue", defaultValue: "Report an issue", comment: "Link text to report an issue on GitHub"), destination: URL(string: "https://github.com/automazeio/vibeproxy/issues")!)
                    .font(.caption)
                    .padding(.top, 6)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
            }
            .padding(.bottom, 12)
        }
        .frame(width: 480, height: 740)
        .sheet(isPresented: $showingQwenEmailPrompt) {
            VStack(spacing: 16) {
                Text(String(localized: "settings.qwen.prompt-title", defaultValue: "Qwen Account Email", comment: "Title for the Qwen email prompt dialog"))
                    .font(.headline)
                Text(String(localized: "settings.qwen.prompt-message", defaultValue: "Enter your Qwen account email address", comment: "Instructions for entering Qwen account email"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(String(localized: "settings.qwen.email-placeholder", defaultValue: "your.email@example.com", comment: "Placeholder text for the Qwen email input field"), text: $qwenEmail)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                HStack(spacing: 12) {
                    Button(String(localized: "settings.qwen.cancel-button", defaultValue: "Cancel", comment: "Button to cancel the Qwen email prompt")) {
                        showingQwenEmailPrompt = false
                        qwenEmail = ""
                    }
                    Button(String(localized: "settings.qwen.continue-button", defaultValue: "Continue", comment: "Button to continue with Qwen authentication after entering email")) {
                        showingQwenEmailPrompt = false
                        startQwenAuth(email: qwenEmail)
                    }
                    .disabled(qwenEmail.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 350)
        }
        .sheet(isPresented: $showingZaiApiKeyPrompt) {
            VStack(spacing: 16) {
                Text(String(localized: "settings.zai.prompt-title", defaultValue: "Z.AI API Key", comment: "Title for the Z.AI API key prompt dialog"))
                    .font(.headline)
                Text(String(localized: "settings.zai.prompt-message", defaultValue: "Enter your Z.AI API key from https://z.ai/manage-apikey/apikey-list", comment: "Instructions for entering Z.AI API key with URL"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("", text: $zaiApiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                HStack(spacing: 12) {
                    Button(String(localized: "settings.zai.cancel-button", defaultValue: "Cancel", comment: "Button to cancel the Z.AI API key prompt")) {
                        showingZaiApiKeyPrompt = false
                        zaiApiKey = ""
                    }
                    Button(String(localized: "settings.zai.add-key-button", defaultValue: "Add Key", comment: "Button to add the Z.AI API key")) {
                        showingZaiApiKeyPrompt = false
                        startZaiAuth(apiKey: zaiApiKey)
                    }
                    .disabled(zaiApiKey.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 400)
        }
        .onAppear {
            authManager.checkAuthStatus()
            checkLaunchAtLogin()
            startMonitoringAuthDirectory()
        }
        .onDisappear {
            stopMonitoringAuthDirectory()
        }
        .alert(String(localized: "settings.auth-result.title", defaultValue: "Authentication Result", comment: "Title for the authentication result alert dialog"), isPresented: $showingAuthResult) {
            Button(String(localized: "settings.auth-result.ok-button", defaultValue: "OK", comment: "Button to dismiss the authentication result alert"), role: .cancel) { }
        } message: {
            Text(authResultMessage)
        }
    }

    // MARK: - Actions
    
    private func openAuthFolder() {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
        NSWorkspace.shared.open(authDir)
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[SettingsView] Failed to toggle launch at login: %@", error.localizedDescription)
            }
        }
    }

    private func checkLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
    
    private func connectService(_ serviceType: ServiceType) {
        authenticatingService = serviceType
        NSLog("[SettingsView] Starting %@ authentication", serviceType.displayName)
        
        let command: AuthCommand
        switch serviceType {
        case .claude: command = .claudeLogin
        case .codex: command = .codexLogin
        case .copilot: command = .copilotLogin
        case .gemini: command = .geminiLogin
        case .qwen:
            authenticatingService = nil
            return // handled separately with email prompt
        case .antigravity: command = .antigravityLogin
        case .zai:
            authenticatingService = nil
            return // handled separately with API key prompt
        }
        
        serverManager.runAuthCommand(command) { success, output in
            NSLog("[SettingsView] Auth completed - success: %d, output: %@", success, output)
            DispatchQueue.main.async {
                self.authenticatingService = nil
                
                if success {
                    self.authResultSuccess = true
                    // For Copilot, use the output which contains the device code
                    if serviceType == .copilot && (output.contains("Code copied") || output.contains("code:")) {
                        self.authResultMessage = output
                    } else {
                        self.authResultMessage = self.successMessage(for: serviceType)
                    }
                    self.showingAuthResult = true
                } else {
                    self.authResultSuccess = false
                    let fallbackMessage = String(localized: "settings.auth-result.no-output", defaultValue: "No output from authentication process", comment: "Fallback message when authentication fails with no output")
                    self.authResultMessage = String(format: NSLocalizedString("settings.auth-result.auth-failed", comment: "Generic authentication failure message with details"), output.isEmpty ? fallbackMessage : output)
                    self.showingAuthResult = true
                }
            }
        }
    }
    
    private func successMessage(for serviceType: ServiceType) -> String {
        switch serviceType {
        case .claude:
            return String(localized: "settings.auth-result.claude-success", defaultValue: "🌐 Browser opened for Claude Code authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials.", comment: "Success message for Claude Code authentication")
        case .codex:
            return String(localized: "settings.auth-result.codex-success", defaultValue: "🌐 Browser opened for Codex authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials.", comment: "Success message for Codex authentication")
        case .copilot:
            return String(localized: "settings.auth-result.copilot-success", defaultValue: "🌐 GitHub Copilot authentication started!\n\nPlease visit github.com/login/device and enter the code shown.\n\nThe app will automatically detect your credentials.", comment: "Success message for GitHub Copilot authentication")
        case .gemini:
            return String(localized: "settings.auth-result.gemini-success", defaultValue: "🌐 Browser opened for Gemini authentication.\n\nPlease complete the login in your browser.\n\n⚠️ Note: If you have multiple projects, the default project will be used.", comment: "Success message for Gemini authentication")
        case .qwen:
            return String(localized: "settings.auth-result.qwen-success", defaultValue: "🌐 Browser opened for Qwen authentication.\n\nPlease complete the login in your browser.", comment: "Success message for Qwen authentication")
        case .antigravity:
            return String(localized: "settings.auth-result.antigravity-success", defaultValue: "🌐 Browser opened for Antigravity authentication.\n\nPlease complete the login in your browser.", comment: "Success message for Antigravity authentication")
        case .zai:
            return String(localized: "settings.auth-result.zai-success", defaultValue: "✓ Z.AI API key added successfully.\n\nYou can now use GLM models through the proxy.", comment: "Success message for Z.AI API key addition")
        }
    }
    
    private func startQwenAuth(email: String) {
        authenticatingService = .qwen
        NSLog("[SettingsView] Starting Qwen authentication")
        
        serverManager.runAuthCommand(.qwenLogin(email: email)) { success, output in
            NSLog("[SettingsView] Auth completed - success: %d, output: %@", success, output)
            DispatchQueue.main.async {
                self.authenticatingService = nil
                self.qwenEmail = ""
                
                if success {
                    self.authResultSuccess = true
                    self.authResultMessage = self.successMessage(for: .qwen)
                    self.showingAuthResult = true
                } else {
                    self.authResultSuccess = false
                    let fallbackMessage = String(localized: "settings.auth-result.qwen-no-output", defaultValue: "No output", comment: "Fallback message when Qwen authentication fails with no output")
                    self.authResultMessage = String(format: NSLocalizedString("settings.auth-result.qwen-failed", comment: "Qwen authentication failure message with details"), output.isEmpty ? fallbackMessage : output)
                    self.showingAuthResult = true
                }
            }
        }
    }
    
    private func startZaiAuth(apiKey: String) {
        authenticatingService = .zai
        NSLog("[SettingsView] Adding Z.AI API key")
        
        serverManager.saveZaiApiKey(apiKey) { success, output in
            NSLog("[SettingsView] Z.AI key save completed - success: %d, output: %@", success, output)
            DispatchQueue.main.async {
                self.authenticatingService = nil
                self.zaiApiKey = ""
                
                if success {
                    self.authResultSuccess = true
                    self.authResultMessage = self.successMessage(for: .zai)
                    self.showingAuthResult = true
                    self.authManager.checkAuthStatus()
                } else {
                    self.authResultSuccess = false
                    let fallbackMessage = String(localized: "settings.auth-result.zai-unknown-error", defaultValue: "Unknown error", comment: "Fallback message when Z.AI API key save fails with no details")
                    self.authResultMessage = String(format: NSLocalizedString("settings.auth-result.zai-failed", comment: "Z.AI API key save failure message with details"), output.isEmpty ? fallbackMessage : output)
                    self.showingAuthResult = true
                }
            }
        }
    }
    
    private func disconnectAccount(_ account: AuthAccount) {
        let wasRunning = serverManager.isRunning
        
        // Stop server, delete file, restart
        let cleanup = {
            if self.authManager.deleteAccount(account) {
                self.authResultSuccess = true
                self.authResultMessage = String(format: NSLocalizedString("settings.account.removed-success", comment: "Success message when an account is removed from a service"), account.displayName, account.type.displayName)
            } else {
                self.authResultSuccess = false
                self.authResultMessage = String(localized: "settings.account.removed-failed", defaultValue: "Failed to remove account", comment: "Error message when account removal fails")
            }
            self.showingAuthResult = true
            
            if wasRunning {
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.serverRestartDelay) {
                    self.serverManager.start { _ in }
                }
            }
        }
        
        if wasRunning {
            serverManager.stop { cleanup() }
        } else {
            cleanup()
        }
    }
    
    // MARK: - File Monitoring
    
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
        
        source.setEventHandler { [self] in
            // Debounce rapid file changes to prevent UI flashing
            pendingRefresh?.cancel()
            let workItem = DispatchWorkItem {
                NSLog("[FileMonitor] Auth directory changed - refreshing status")
                authManager.checkAuthStatus()
            }
            pendingRefresh = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.refreshDebounce, execute: workItem)
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        fileMonitor = source
    }
    
    private func stopMonitoringAuthDirectory() {
        pendingRefresh?.cancel()
        fileMonitor?.cancel()
        fileMonitor = nil
    }
}
