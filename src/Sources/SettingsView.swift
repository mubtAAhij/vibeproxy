import SwiftUI
import ServiceManagement

/// A single account row with disable toggle and remove button
struct AccountRowView: View {
    let account: AuthAccount
    let removeColor: Color
    let showDisableToggle: Bool
    let isLastEnabled: Bool
    let onToggleDisabled: () -> Void
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.isDisabled ? Color.gray : (account.isExpired ? Color.orange : Color.green))
                .frame(width: 6, height: 6)
            Text(account.displayName)
                .font(.caption)
                .foregroundColor(account.isDisabled ? .secondary.opacity(0.5) : (account.isExpired ? .orange : .secondary))
                .strikethrough(account.isDisabled)
            if account.isExpired && !account.isDisabled {
                Text(String(localized: "settings.accounts.status.expired", defaultValue: "(expired)", comment: "Status suffix for an expired account"))
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            if account.isDisabled {
                Text(String(localized: "settings.accounts.status.disabled", defaultValue: "(disabled)", comment: "Status suffix for a disabled account"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if showDisableToggle {
                let canDisable = account.isDisabled || !isLastEnabled
                Button(action: onToggleDisabled) {
                    Text(account.isDisabled ? String(localized: "settings.accounts.action.enable", defaultValue: "Enable", comment: "Button title to enable an account") : String(localized: "settings.accounts.action.disable", defaultValue: "Disable", comment: "Button title to disable an account"))
                        .font(.caption)
                        .foregroundColor(account.isDisabled ? .green : (canDisable ? .orange : .secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canDisable)
                .help(!canDisable ? String(localized: "settings.accounts.error.at-least-one-enabled-required", defaultValue: "At least one account must remain enabled", comment: "Alert message shown when disabling the last enabled account is blocked") : "")
                .onHover { inside in
                    if canDisable {
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
            Button(action: onRemove) {
                HStack(spacing: 2) {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption)
                    Text(String(localized: "settings.accounts.action.remove", defaultValue: "Remove", comment: "Button title to remove an account"))
                        .font(.caption)
                }
                .foregroundColor(removeColor)
            }
            .buttonStyle(.plain)
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
                Text(String(localized: "settings.vercel-gateway.toggle.use-vercel-ai-gateway", defaultValue: "Use Vercel AI Gateway", comment: "Toggle label to enable routing through Vercel AI Gateway"))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help(String(localized: "settings.vercel-gateway.description.route-claude-through-gateway", defaultValue: "Route Claude requests through Vercel AI Gateway for safer access to your Claude Max subscription", comment: "Description text for Vercel AI Gateway routing option"))
            
            if serverManager.vercelGatewayEnabled {
                HStack(spacing: 8) {
                    Text(String(localized: "settings.vercel-gateway.field.vercel-api-key", defaultValue: "Vercel API key", comment: "Field label for entering Vercel API key"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("", text: $serverManager.vercelApiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .font(.caption)
                    
                    if showingSaved {
                        Text(String(localized: "settings.vercel-gateway.action.saved", defaultValue: "Saved", comment: "Button label indicating Vercel API key has been saved"))
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Button(String(localized: "settings.vercel-gateway.action.save", defaultValue: "Save", comment: "Button label to save Vercel API key")) {
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
    let iconSystemName: String?
    let accounts: [AuthAccount]
    let isAuthenticating: Bool
    let helpText: String?
    let isEnabled: Bool
    let isToggleLocked: Bool
    let toggleHelpText: String?
    let disabledReasonText: String?
    let customTitle: String?
    let onConnect: () -> Void
    let onDisconnect: (AuthAccount) -> Void
    let onToggleDisabled: (AuthAccount) -> Void
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
                .disabled(isToggleLocked)
                .help(toggleHelpText ?? (isEnabled ? String(localized: "settings.provider.action.disable-this-provider", defaultValue: "Disable this provider", comment: "Context menu action to disable a provider") : String(localized: "settings.provider.action.enable-this-provider", defaultValue: "Enable this provider", comment: "Context menu action to enable a provider")))

                if let nsImage = IconCatalog.shared.image(named: iconName, resizedTo: NSSize(width: 20, height: 20), template: true) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 20, height: 20)
                        .opacity(isEnabled ? 1.0 : 0.4)
                } else if let iconSystemName {
                    Image(systemName: iconSystemName)
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
                    Button(String(localized: "settings.accounts.action.add-account", defaultValue: "Add Account", comment: "Button title to add an account")) {
                        onConnect()
                    }
                    .controlSize(.small)
                }
            }
            
            // Account display (only shown when enabled)
            if isEnabled {
                let enabledCount = accounts.filter { !$0.isDisabled }.count
                if !accounts.isEmpty {
                    // Collapsible summary
                    HStack(spacing: 4) {
                        Text(String(format: String(
                            localized: "settings.accounts.summary.connected-account-count",
                            defaultValue: "%d connected account(s)",
                            comment: "Summary text showing number of connected accounts"
                        ), "\(accounts.count)"))
                            .font(.caption)
                            .foregroundColor(.green)

                        if enabledCount > 1 {
                            Text(String(localized: "settings.accounts.feature.round-robin-auto-failover", defaultValue: "• Round-robin w/ auto-failover", comment: "Feature bullet describing round-robin with automatic failover"))
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
                                AccountRowView(account: account, removeColor: removeColor, showDisableToggle: accounts.count > 1 || account.isDisabled, isLastEnabled: !account.isDisabled && enabledCount <= 1, onToggleDisabled: {
                                    onToggleDisabled(account)
                                }) {
                                    accountToRemove = account
                                    showingRemoveConfirmation = true
                                }
                            }
                            extraContent()
                        }
                        .padding(.top, 4)
                    }
                } else {
                    Text(String(localized: "settings.accounts.empty.no-connected-accounts", defaultValue: "No connected accounts", comment: "Empty state label when no accounts are connected"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 28)
                }
            } else if let disabledReasonText, !disabledReasonText.isEmpty {
                Text(disabledReasonText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
        .help(helpText ?? "")
        .onAppear {
            if accounts.contains(where: { $0.isExpired }) {
                isExpanded = true
            }
        }
        .onChange(of: accounts) { newAccounts in
            if newAccounts.contains(where: { $0.isExpired }) {
                isExpanded = true
            }
        }
        .onChange(of: isExpanded) { newValue in
            onExpandChange?(newValue)
        }
        .alert(String(localized: "settings.accounts.confirm-remove.title", defaultValue: "Remove Account", comment: "Confirmation dialog title for removing an account"), isPresented: $showingRemoveConfirmation) {
            Button(String(localized: "settings.accounts.confirm-remove.action.cancel", defaultValue: "Cancel", comment: "Cancel button title in remove account confirmation dialog"), role: .cancel) {
                accountToRemove = nil
            }
            Button(String(localized: "settings.accounts.confirm-remove.action.remove", defaultValue: "Remove", comment: "Destructive button title in remove account confirmation dialog"), role: .destructive) {
                if let account = accountToRemove {
                    onDisconnect(account)
                }
                accountToRemove = nil
            }
        } message: {
            if let account = accountToRemove {
                Text(String(format: String(localized: "settings.accounts.confirm-remove.message", defaultValue: "Are you sure you want to remove %@ from %@?", comment: "Confirmation message asking whether to remove an account from a service"), "\(account.displayName)", "\(serviceType.displayName)"))
            }
        }
    }
}

struct CustomProviderCredentialRowView: View {
    let credential: CustomProviderCredential
    let removeColor: Color
    let showDisableToggle: Bool
    let isLastEnabled: Bool
    let onToggleDisabled: () -> Void
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(credential.isDisabled ? Color.gray : Color.green)
                .frame(width: 6, height: 6)
            Text(credential.label)
                .font(.caption)
                .foregroundColor(credential.isDisabled ? .secondary.opacity(0.5) : .secondary)
                .strikethrough(credential.isDisabled)
            if credential.isDisabled {
                Text(String(localized: "settings.api-keys.status.disabled", defaultValue: "(disabled)", comment: "Status suffix for a disabled API key"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if showDisableToggle {
                let canDisable = credential.isDisabled || !isLastEnabled
                Button(action: onToggleDisabled) {
                    Text(credential.isDisabled ? String(localized: "settings.api-keys.action.enable", defaultValue: "Enable", comment: "Button title to enable an API key") : String(localized: "settings.api-keys.action.disable", defaultValue: "Disable", comment: "Button title to disable an API key"))
                        .font(.caption)
                        .foregroundColor(credential.isDisabled ? .green : (canDisable ? .orange : .secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canDisable)
                .help(!canDisable ? String(localized: "settings.api-keys.error.at-least-one-enabled-required", defaultValue: "At least one API key must remain enabled", comment: "Alert message shown when disabling the last enabled API key is blocked") : "")
                .onHover { inside in
                    if canDisable {
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
            Button(action: onRemove) {
                HStack(spacing: 2) {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption)
                    Text(String(localized: "settings.api-keys.action.remove", defaultValue: "Remove", comment: "Button title to remove an API key"))
                        .font(.caption)
                }
                .foregroundColor(removeColor)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.leading, 28)
    }
}

struct CustomProviderRow: View {
    let provider: CustomProviderDefinition
    let credentials: [CustomProviderCredential]
    let isAuthenticating: Bool
    let isEnabled: Bool
    let onConnect: () -> Void
    let onDisconnect: (CustomProviderCredential) -> Void
    let onToggleDisabled: (CustomProviderCredential) -> Void
    let onToggleEnabled: (Bool) -> Void
    var onExpandChange: ((Bool) -> Void)? = nil
    
    @State private var isExpanded = false
    @State private var credentialToRemove: CustomProviderCredential?
    @State private var showingRemoveConfirmation = false
    
    private var enabledCredentialCount: Int { credentials.filter { !$0.isDisabled }.count }
    private var totalConfiguredKeyCount: Int { credentials.count + provider.inlineKeyCount }
    private var totalEnabledKeyCount: Int { enabledCredentialCount + provider.inlineKeyCount }
    private let removeColor = Color(red: 0xeb/255, green: 0x0f/255, blue: 0x0f/255)
    
    private var summaryText: String {
        if totalConfiguredKeyCount == 0 {
            return String(localized: "settings.api-keys.empty.no-configured-api-keys", defaultValue: "No configured API keys", comment: "Empty state label when no API keys are configured")
        }
        if provider.inlineKeyCount > 0 && !credentials.isEmpty {
            return String(format: String(localized: "settings.api-keys.summary.total-config-added", defaultValue: "%d API keys • %d in config • %d added here", comment: "Summary showing total API keys, keys in config, and keys added in settings"), totalConfiguredKeyCount, provider.inlineKeyCount, credentials.count)
        }
        if provider.inlineKeyCount > 0 {
            return String(format: String(
                localized: "settings.api-keys.summary.from-config",
                defaultValue: "%d API key(s) from config",
                comment: "Summary showing API key count sourced from config"
            ), "\(totalConfiguredKeyCount)")
        }
        return String(format: String(
            localized: "settings.api-keys.summary.added-here",
            defaultValue: "%d API key(s) added here",
            comment: "Summary showing API key count added in settings"
        ), "\(totalConfiguredKeyCount)")
    }

    private var poolingStatusText: String? {
        guard totalEnabledKeyCount > 1 else {
            return nil
        }
        return String(localized: "settings.api-keys.feature.pooled-across-available-keys", defaultValue: "• Pooled across available keys", comment: "Feature bullet describing key pooling behavior")
    }

    private var endpointSummaryText: String {
        String(format: String(localized: "settings.api-keys.endpoint", defaultValue: "Endpoint: %@", comment: "Label showing provider endpoint URL"), "\(provider.baseURL)")
    }

    private var modelSummaryText: String? {
        guard !provider.modelAliases.isEmpty else {
            return nil
        }
        return String(format: String(localized: "settings.api-keys.models", defaultValue: "Models: %@", comment: "Label showing provider model aliases"), "\(provider.modelAliases.joined(separator: ", "))")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggleEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(isEnabled ? String(localized: "settings.api-keys.provider.action.disable-this-provider", defaultValue: "Disable this provider", comment: "Context menu action to disable a custom provider") : String(localized: "settings.api-keys.provider.action.enable-this-provider", defaultValue: "Enable this provider", comment: "Context menu action to enable a custom provider"))
                
                Image(systemName: provider.effectiveIconSystemName)
                    .frame(width: 20, height: 20)
                    .foregroundColor(isEnabled ? .primary : .secondary)
                    .opacity(isEnabled ? 1.0 : 0.4)
                
                Text(provider.title)
                    .fontWeight(.medium)
                    .foregroundColor(isEnabled ? .primary : .secondary)
                
                Spacer()
                
                if isAuthenticating {
                    ProgressView()
                        .controlSize(.small)
                } else if isEnabled {
                    Button(String(localized: "settings.api-keys.action.add-api-key", defaultValue: "Add API Key", comment: "Button title to add a new API key")) {
                        onConnect()
                    }
                    .controlSize(.small)
                }
            }
            
            if isEnabled {
                if totalConfiguredKeyCount > 0 {
                    HStack(spacing: 4) {
                        Text(summaryText)
                            .font(.caption)
                            .foregroundColor(.green)
                        
                        if let poolingStatusText {
                            Text(poolingStatusText)
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
                    
                    if isExpanded {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(endpointSummaryText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 28)

                            if let modelSummaryText {
                                Text(modelSummaryText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 28)
                            }

                            if provider.inlineKeyCount > 0 {
                                Text(String(format: String(
                                    localized: "settings.api-keys.using-from-config-path",
                                    defaultValue: "Using %d API key(s) from ~/.cli-proxy-api/config.yaml",
                                    comment: "Message showing number of API keys sourced from config path"
                                ), "\(provider.inlineKeyCount)"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 28)
                            }
                            
                            ForEach(credentials) { credential in
                                CustomProviderCredentialRowView(
                                    credential: credential,
                                    removeColor: removeColor,
                                    showDisableToggle: totalConfiguredKeyCount > 1,
                                    isLastEnabled: !credential.isDisabled && totalEnabledKeyCount <= 1,
                                    onToggleDisabled: { onToggleDisabled(credential) },
                                    onRemove: {
                                        credentialToRemove = credential
                                        showingRemoveConfirmation = true
                                    }
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                } else {
                    Text(String(localized: "settings.api-keys.empty.no-configured-api-keys", defaultValue: "No configured API keys", comment: "Empty state label when no API keys are configured"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 4)
        .help(provider.effectiveHelpText)
        .onChange(of: isExpanded) { newValue in
            onExpandChange?(newValue)
        }
        .alert(String(localized: "settings.api-keys.confirm-remove.title", defaultValue: "Remove API Key", comment: "Confirmation dialog title for removing an API key"), isPresented: $showingRemoveConfirmation) {
            Button(String(localized: "settings.api-keys.confirm-remove.action.cancel", defaultValue: "Cancel", comment: "Cancel button title in remove API key confirmation dialog"), role: .cancel) {
                credentialToRemove = nil
            }
            Button(String(localized: "settings.api-keys.confirm-remove.action.remove", defaultValue: "Remove", comment: "Destructive button title in remove API key confirmation dialog"), role: .destructive) {
                if let credential = credentialToRemove {
                    onDisconnect(credential)
                }
                credentialToRemove = nil
            }
        } message: {
            if let credential = credentialToRemove {
                Text(String(format: String(localized: "settings.api-keys.confirm-remove.message", defaultValue: "Are you sure you want to remove %@ from %@?", comment: "Confirmation message asking whether to remove an API key from a provider"), "\(credential.label)", "\(provider.title)"))
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var serverManager: ServerManager
    @StateObject private var authManager = AuthManager()
    @State private var launchAtLogin = false
    @State private var authenticatingService: ServiceType? = nil
    @State private var authenticatingCustomProviderID: String? = nil
    @State private var showingAuthResult = false
    @State private var authResultMessage = ""
    @State private var authResultSuccess = false
    @State private var showingQwenEmailPrompt = false
    @State private var qwenEmail = ""
    @State private var showingZaiApiKeyPrompt = false
    @State private var zaiApiKey = ""
    @State private var selectedCustomProvider: CustomProviderDefinition?
    @State private var customProviderApiKey = ""
    @State private var expandedRowCount = 0
    
    private enum Timing {
        static let serverRestartDelay: TimeInterval = 0.3
    }

    private var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return String(format: String(localized: "settings.app.version.prefix-v", defaultValue: "v%@", comment: "App version label prefixed with v"), "\(version)")
        }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        Text(String(localized: "settings.server.status.title", defaultValue: "Server status", comment: "Section title for server status"))
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
                                Text(serverManager.isRunning ? String(localized: "settings.server.status.running", defaultValue: "Running", comment: "Server status label when server is running") : String(localized: "settings.server.status.stopped", defaultValue: "Stopped", comment: "Server status label when server is stopped"))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let configErrorMessage = serverManager.configErrorMessage {
                    Section(String(localized: "settings.server.status.configuration-error", defaultValue: "Configuration Error", comment: "Server status label when configuration has an error")) {
                        Text(configErrorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Toggle(String(localized: "settings.launch-at-login.toggle", defaultValue: "Launch at login", comment: "Toggle label for launch at login setting"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            toggleLaunchAtLogin(newValue)
                        }

                    HStack {
                        Text(String(localized: "settings.auth-files.section-title", defaultValue: "Auth files", comment: "Section title for authentication files controls"))
                        Spacer()
                        Button(String(localized: "settings.auth-files.action.open-folder", defaultValue: "Open Folder", comment: "Button title to open auth files folder")) {
                            openAuthFolder()
                        }
                    }
                }

                Section(String(localized: "settings.services.section-title", defaultValue: "Services", comment: "Section title for connected services")) {
                    ServiceRow(
                        serviceType: .antigravity,
                        iconName: "icon-antigravity.png",
                        iconSystemName: nil,
                        accounts: authManager.accounts(for: .antigravity),
                        isAuthenticating: authenticatingService == .antigravity,
                        helpText: String(localized: "settings.services.antigravity.description", defaultValue: "Antigravity provides OAuth-based access to various AI models including Gemini and Claude. One login gives you access to multiple AI services.", comment: "Description text for Antigravity service"),
                        isEnabled: serverManager.isProviderEnabled("antigravity"),
                        isToggleLocked: serverManager.isProviderToggleLocked("antigravity"),
                        toggleHelpText: serverManager.providerConfigLockReason("antigravity"),
                        disabledReasonText: serverManager.providerConfigLockReason("antigravity"),
                        customTitle: nil,
                        onConnect: { connectService(.antigravity) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("antigravity", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .claude,
                        iconName: "icon-claude.png",
                        iconSystemName: nil,
                        accounts: authManager.accounts(for: .claude),
                        isAuthenticating: authenticatingService == .claude,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled("claude"),
                        isToggleLocked: serverManager.isProviderToggleLocked("claude"),
                        toggleHelpText: serverManager.providerConfigLockReason("claude"),
                        disabledReasonText: serverManager.providerConfigLockReason("claude"),
                        customTitle: serverManager.vercelGatewayEnabled && !serverManager.vercelApiKey.isEmpty ? String(localized: "settings.services.claude-via-vercel.title", defaultValue: "Claude Code (via Vercel)", comment: "Service title for Claude Code routed via Vercel") : nil,
                        onConnect: { connectService(.claude) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("claude", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) {
                        VercelGatewayControls(serverManager: serverManager)
                    }

                    ServiceRow(
                        serviceType: .codex,
                        iconName: "icon-codex.png",
                        iconSystemName: nil,
                        accounts: authManager.accounts(for: .codex),
                        isAuthenticating: authenticatingService == .codex,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled("codex"),
                        isToggleLocked: serverManager.isProviderToggleLocked("codex"),
                        toggleHelpText: serverManager.providerConfigLockReason("codex"),
                        disabledReasonText: serverManager.providerConfigLockReason("codex"),
                        customTitle: nil,
                        onConnect: { connectService(.codex) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("codex", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .gemini,
                        iconName: "icon-gemini.png",
                        iconSystemName: nil,
                        accounts: authManager.accounts(for: .gemini),
                        isAuthenticating: authenticatingService == .gemini,
                        helpText: String(localized: "settings.services.gemini.multi-project-note", defaultValue: "⚠️ Note: If you're an existing Gemini user with multiple projects, authentication will use your default project. Set your desired project as default in Google AI Studio before connecting.", comment: "Warning note for Gemini users with multiple projects"),
                        isEnabled: serverManager.isProviderEnabled("gemini"),
                        isToggleLocked: serverManager.isProviderToggleLocked("gemini"),
                        toggleHelpText: serverManager.providerConfigLockReason("gemini"),
                        disabledReasonText: serverManager.providerConfigLockReason("gemini"),
                        customTitle: nil,
                        onConnect: { connectService(.gemini) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("gemini", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .kimi,
                        iconName: "icon-kimi.png",
                        iconSystemName: "moon.stars.fill",
                        accounts: authManager.accounts(for: .kimi),
                        isAuthenticating: authenticatingService == .kimi,
                        helpText: String(localized: "settings.services.kimi.description", defaultValue: "Kimi uses browser-based account authentication so you can route requests through your Kimi subscription instead of an API key.", comment: "Description text for Kimi service"),
                        isEnabled: serverManager.isProviderEnabled("kimi"),
                        isToggleLocked: serverManager.isProviderToggleLocked("kimi"),
                        toggleHelpText: serverManager.providerConfigLockReason("kimi"),
                        disabledReasonText: serverManager.providerConfigLockReason("kimi"),
                        customTitle: nil,
                        onConnect: { connectService(.kimi) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("kimi", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .copilot,
                        iconName: "icon-copilot.png",
                        iconSystemName: nil,
                        accounts: authManager.accounts(for: .copilot),
                        isAuthenticating: authenticatingService == .copilot,
                        helpText: String(localized: "settings.services.github-copilot.description", defaultValue: "GitHub Copilot provides access to Claude, GPT, Gemini and other models via your Copilot subscription.", comment: "Description text for GitHub Copilot service"),
                        isEnabled: serverManager.isProviderEnabled("github-copilot"),
                        isToggleLocked: serverManager.isProviderToggleLocked("github-copilot"),
                        toggleHelpText: serverManager.providerConfigLockReason("github-copilot"),
                        disabledReasonText: serverManager.providerConfigLockReason("github-copilot"),
                        customTitle: nil,
                        onConnect: { connectService(.copilot) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("github-copilot", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .qwen,
                        iconName: "icon-qwen.png",
                        iconSystemName: nil,
                        accounts: authManager.accounts(for: .qwen),
                        isAuthenticating: authenticatingService == .qwen,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled("qwen"),
                        isToggleLocked: serverManager.isProviderToggleLocked("qwen"),
                        toggleHelpText: serverManager.providerConfigLockReason("qwen"),
                        disabledReasonText: serverManager.providerConfigLockReason("qwen"),
                        customTitle: nil,
                        onConnect: { showingQwenEmailPrompt = true },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("qwen", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .zai,
                        iconName: "icon-zai.png",
                        iconSystemName: nil,
                        accounts: authManager.accounts(for: .zai),
                        isAuthenticating: authenticatingService == .zai,
                        helpText: String(localized: "settings.services.zai-glm.description", defaultValue: "Z.AI GLM provides access to GLM-4.7 and other models via API key. Get your key at https://z.ai/manage-apikey/apikey-list", comment: "Description text for Z.AI GLM service including key management URL"),
                        isEnabled: serverManager.isProviderEnabled("zai"),
                        isToggleLocked: serverManager.isProviderToggleLocked("zai"),
                        toggleHelpText: serverManager.providerConfigLockReason("zai"),
                        disabledReasonText: serverManager.providerConfigLockReason("zai"),
                        customTitle: nil,
                        onConnect: { showingZaiApiKeyPrompt = true },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("zai", enabled: enabled) },
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }
                }
                
                if !serverManager.customProviders.isEmpty {
                    Section(String(localized: "settings.custom-providers.section-title", defaultValue: "Custom Providers", comment: "Section title for custom providers")) {
                        ForEach(serverManager.customProviders) { provider in
                            CustomProviderRow(
                                provider: provider,
                                credentials: serverManager.customProviderCredentials[provider.id] ?? [],
                                isAuthenticating: authenticatingCustomProviderID == provider.id,
                                isEnabled: serverManager.isProviderEnabled(provider.id),
                                onConnect: {
                                    customProviderApiKey = ""
                                    selectedCustomProvider = provider
                                },
                                onDisconnect: { credential in
                                    disconnectCustomProviderCredential(provider: provider, credential: credential)
                                },
                                onToggleDisabled: { credential in
                                    toggleCustomProviderCredential(provider: provider, credential: credential)
                                },
                                onToggleEnabled: { enabled in
                                    serverManager.setProviderEnabled(provider.id, enabled: enabled)
                                },
                                onExpandChange: { expanded in
                                    expandedRowCount += expanded ? 1 : -1
                                }
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(expandedRowCount == 0)

            Spacer()
                .frame(height: 6)

            // Footer
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text(String(format: String(localized: "settings.about.credits.vibeproxy-made-possible-thanks-to", defaultValue: "VibeProxy %@ was made possible thanks to", comment: "Credits heading mentioning app version"), "\(appVersion)"))
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
                    Text(String(localized: "settings.about.license.mit", defaultValue: "License: MIT", comment: "License label in about section"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Text(String(localized: "settings.about.copyright.year-2026", defaultValue: "© 2026", comment: "Copyright year label in about section"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Link("Automaze, Ltd.", destination: URL(string: "https://automaze.io")!)
                        .font(.caption)
                        .underline()
                        .foregroundColor(.secondary)
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    Text(String(localized: "settings.about.copyright.all-rights-reserved", defaultValue: "All rights reserved.", comment: "Copyright notice in about section"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Link(String(localized: "settings.about.action.report-issue", defaultValue: "Report an issue", comment: "Button title to report an issue"), destination: URL(string: "https://github.com/automazeio/vibeproxy/issues")!)
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
                Text(String(localized: "settings.qwen-account-email.title", defaultValue: "Qwen Account Email", comment: "Dialog title for entering Qwen account email"))
                    .font(.headline)
                Text(String(localized: "settings.qwen-account-email.prompt", defaultValue: "Enter your Qwen account email address", comment: "Prompt text for Qwen account email input"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(String(localized: "settings.qwen-account-email.placeholder.email-address", defaultValue: "your.email@example.com", comment: "Placeholder text for Qwen account email input"), text: $qwenEmail)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                HStack(spacing: 12) {
                    Button(String(localized: "settings.qwen-account-email.action.cancel", defaultValue: "Cancel", comment: "Cancel button title in Qwen account email dialog")) {
                        showingQwenEmailPrompt = false
                        qwenEmail = ""
                    }
                    Button(String(localized: "settings.qwen-account-email.action.continue", defaultValue: "Continue", comment: "Continue button title in Qwen account email dialog")) {
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
                Text(String(localized: "settings.zai-api-key.title", defaultValue: "Z.AI API Key", comment: "Dialog title for entering Z.AI API key"))
                    .font(.headline)
                Text(String(localized: "settings.zai-api-key.prompt", defaultValue: "Enter your Z.AI API key from https://z.ai/manage-apikey/apikey-list", comment: "Prompt text for Z.AI API key input"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("", text: $zaiApiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                HStack(spacing: 12) {
                    Button(String(localized: "settings.zai-api-key.action.cancel", defaultValue: "Cancel", comment: "Cancel button title in Z.AI API key dialog")) {
                        showingZaiApiKeyPrompt = false
                        zaiApiKey = ""
                    }
                    Button(String(localized: "settings.zai-api-key.action.add-key", defaultValue: "Add Key", comment: "Add key button title in Z.AI API key dialog")) {
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
        .sheet(item: $selectedCustomProvider, onDismiss: {
            customProviderApiKey = ""
        }) { provider in
            VStack(spacing: 16) {
                Text(String(format: String(localized: "settings.custom-provider-api-key.title", defaultValue: "%@ API Key", comment: "Dialog title for entering custom provider API key"), "\(provider.title)"))
                    .font(.headline)
                Text(String(format: String(localized: "settings.custom-provider-api-key.prompt", defaultValue: "Enter an API key for %@", comment: "Prompt text for custom provider API key input"), "\(provider.title)"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("", text: $customProviderApiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                HStack(spacing: 12) {
                    Button(String(localized: "settings.custom-provider-api-key.action.cancel", defaultValue: "Cancel", comment: "Cancel button title in custom provider API key dialog")) {
                        selectedCustomProvider = nil
                        customProviderApiKey = ""
                    }
                    Button(String(localized: "settings.custom-provider-api-key.action.add-key", defaultValue: "Add Key", comment: "Add key button title in custom provider API key dialog")) {
                        let currentProvider = provider
                        selectedCustomProvider = nil
                        startCustomProviderAuth(provider: currentProvider, apiKey: customProviderApiKey)
                    }
                    .disabled(customProviderApiKey.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
        .onAppear {
            authManager.checkAuthStatus()
            serverManager.reloadCustomProviders()
            checkLaunchAtLogin()
        }
        .onReceive(NotificationCenter.default.publisher(for: .authDirectoryChanged)) { _ in
            authManager.checkAuthStatus()
        }
        .alert(String(localized: "settings.authentication-result.title", defaultValue: "Authentication Result", comment: "Title for authentication result dialog"), isPresented: $showingAuthResult) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(authResultMessage)
        }
    }

    // MARK: - Actions
    
    private func toggleAccountDisabled(_ account: AuthAccount) {
        if authManager.toggleAccountDisabled(account) {
            serverManager.refreshAuthBackedConfiguration()
            authResultSuccess = true
            authResultMessage = account.isDisabled
                ? String(format: String(localized: "settings.authentication-result.enabled-account", defaultValue: "✓ Enabled %@", comment: "Message indicating an account was enabled after authentication"), "\(account.displayName)")
                : String(format: String(localized: "settings.authentication-result.disabled-account", defaultValue: "✓ Disabled %@", comment: "Message indicating an account was disabled"), "\(account.displayName)")
            showingAuthResult = true
        } else {
            authResultSuccess = false
            authResultMessage = String(format: String(localized: "settings.authentication-result.failed-to-update-account", defaultValue: "Failed to update %@. Please try again.", comment: "Error message when updating account enabled state fails"), "\(account.displayName)")
            showingAuthResult = true
        }
    }
    
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
        switch serviceType.connectionAction {
        case .authCommand(let authCommand):
            command = authCommand
        case .promptForQwenEmail:
            authenticatingService = nil
            return // handled separately with email prompt
        case .promptForZAIAPIKey:
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
                    if serviceType == .copilot && (output.contains(String(localized: "settings.authentication.code-copied", defaultValue: "Code copied", comment: "Toast message confirming authentication code was copied")) || output.contains("code:")) {
                        self.authResultMessage = output
                    } else {
                        self.authResultMessage = self.successMessage(for: serviceType)
                    }
                    self.showingAuthResult = true
                } else {
                    self.authResultSuccess = false
                    self.authResultMessage = String(format: String(localized: "settings.authentication.error.failed-browser-check-details", defaultValue: "Authentication failed. Please check if the browser opened and try again.\n\nDetails: %@", comment: "Authentication error with detailed process output"), "\(output.isEmpty ? String(localized: "settings.authentication.error.no-output-from-process", defaultValue: "No output from authentication process", comment: "Fallback detail text when authentication process has no output") : output)")
                    self.showingAuthResult = true
                }
            }
        }
    }
    
    private func successMessage(for serviceType: ServiceType) -> String {
        switch serviceType {
        case .claude:
            return String(localized: "settings.authentication.status.browser-opened.claude", defaultValue: "🌐 Browser opened for Claude Code authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials.", comment: "Status message shown when Claude authentication browser flow starts")
        case .codex:
            return String(localized: "settings.authentication.status.browser-opened.codex", defaultValue: "🌐 Browser opened for Codex authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials.", comment: "Status message shown when Codex authentication browser flow starts")
        case .copilot:
            return String(localized: "settings.authentication.status.github-copilot-device-flow-started", defaultValue: "🌐 GitHub Copilot authentication started!\n\nPlease visit github.com/login/device and enter the code shown.\n\nThe app will automatically detect your credentials.", comment: "Status message shown when GitHub Copilot device authentication starts")
        case .gemini:
            return String(localized: "settings.authentication.status.browser-opened.gemini", defaultValue: "🌐 Browser opened for Gemini authentication.\n\nPlease complete the login in your browser.\n\n⚠️ Note: If you have multiple projects, the default project will be used.", comment: "Status message shown when Gemini authentication browser flow starts")
        case .kimi:
            return String(localized: "settings.authentication.status.browser-opened.kimi", defaultValue: "🌐 Browser opened for Kimi authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your Kimi account.", comment: "Status message shown when Kimi authentication browser flow starts")
        case .qwen:
            return String(localized: "settings.authentication.status.browser-opened.qwen", defaultValue: "🌐 Browser opened for Qwen authentication.\n\nPlease complete the login in your browser.", comment: "Status message shown when Qwen authentication browser flow starts")
        case .antigravity:
            return String(localized: "settings.authentication.status.browser-opened.antigravity", defaultValue: "🌐 Browser opened for Antigravity authentication.\n\nPlease complete the login in your browser.", comment: "Status message shown when Antigravity authentication browser flow starts")
        case .zai:
            return String(localized: "settings.authentication.status.zai-api-key-added-successfully", defaultValue: "✓ Z.AI API key added successfully.\n\nYou can now use GLM models through the proxy.", comment: "Success message shown when Z.AI API key is added")
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
                    self.authResultMessage = String(format: String(localized: "settings.authentication.error.failed-details", defaultValue: "Authentication failed.\n\nDetails: %@", comment: "Authentication failure message with details"), "\(output.isEmpty ? String(localized: "settings.authentication.error.no-output", defaultValue: "No output", comment: "Fallback detail text when authentication output is empty") : output)")
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
                    self.authResultMessage = String(format: String(localized: "settings.api-key.error.failed-to-save-details", defaultValue: "Failed to save API key.\n\nDetails: %@", comment: "API key save error message with details"), "\(output.isEmpty ? String(localized: "settings.api-key.error.unknown-error", defaultValue: "Unknown error", comment: "Fallback detail text when API key save error has no output") : output)")
                    self.showingAuthResult = true
                }
            }
        }
    }
    
    private func startCustomProviderAuth(provider: CustomProviderDefinition, apiKey: String) {
        authenticatingCustomProviderID = provider.id
        NSLog("[SettingsView] Adding API key for custom provider %@", provider.id)
        
        serverManager.saveCustomProviderAPIKey(providerID: provider.id, apiKey: apiKey) { success, output in
            NSLog("[SettingsView] Custom provider key save completed - success: %d, output: %@", success, output)
            DispatchQueue.main.async {
                self.authenticatingCustomProviderID = nil
                self.customProviderApiKey = ""
                
                if success {
                    self.authResultSuccess = true
                    switch output {
                    case String(localized: "settings.api-key.status.saved-successfully", defaultValue: "API key saved successfully", comment: "Status message shown when API key is saved successfully"):
                        self.authResultMessage = String(format: String(localized: "settings.api-key.status.provider-key-added-successfully", defaultValue: "✓ %@ API key added successfully.\n\nYou can now use this provider through the proxy.", comment: "Success message shown when a provider API key is added"), "\(provider.title)")
                    case String(localized: "settings.api-key.error.already-exists-in-config", defaultValue: "API key already exists in config", comment: "Error message shown when API key already exists in config"):
                        self.authResultMessage = String(format: String(localized: "settings.api-key.status.provider-already-has-key-in-config-path", defaultValue: "✓ %@ already has this API key in ~/.cli-proxy-api/config.yaml.", comment: "Status message when provider already has API key in config file"), "\(provider.title)")
                    case String(localized: "settings.api-key.error.already-exists", defaultValue: "API key already exists", comment: "Error title when API key already exists"):
                        self.authResultMessage = String(format: String(localized: "settings.api-key.status.provider-already-has-key-stored", defaultValue: "✓ %@ already has this API key stored.", comment: "Status message when provider already has API key stored"), "\(provider.title)")
                    case String(localized: "settings.api-key.status.already-stored-reenabled", defaultValue: "API key was already stored and has been re-enabled", comment: "Status message when stored API key is re-enabled"):
                        self.authResultMessage = String(format: String(localized: "settings.api-key.status.provider-already-had-key-reenabled", defaultValue: "✓ %@ already had this API key stored, and it has been re-enabled.", comment: "Status message when provider key was already stored and re-enabled"), "\(provider.title)")
                    default:
                        self.authResultMessage = output
                    }
                    self.showingAuthResult = true
                } else {
                    self.authResultSuccess = false
                    self.authResultMessage = String(format: String(localized: "settings.api-key.error.failed-to-save-for-provider-details", defaultValue: "Failed to save API key for %@.\n\nDetails: %@", comment: "Error message when saving API key for provider fails with details"), "\(provider.title)", "\(output.isEmpty ? String(localized: "settings.api-key.error.unknown-error", defaultValue: "Unknown error", comment: "Fallback detail text when API key save fails without output") : output)")
                    self.showingAuthResult = true
                }
            }
        }
    }
    
    private func toggleCustomProviderCredential(provider: CustomProviderDefinition, credential: CustomProviderCredential) {
        if serverManager.toggleCustomProviderCredentialDisabled(credential) {
            authResultSuccess = true
            authResultMessage = credential.isDisabled
                ? String(format: String(localized: "settings.api-key.status.enabled-credential-for-provider", defaultValue: "✓ Enabled %@ for %@", comment: "Status message when credential is enabled for provider"), "\(credential.label)", "\(provider.title)")
                : String(format: String(localized: "settings.api-key.status.disabled-credential-for-provider", defaultValue: "✓ Disabled %@ for %@", comment: "Status message when credential is disabled for provider"), "\(credential.label)", "\(provider.title)")
        } else {
            authResultSuccess = false
            authResultMessage = String(format: String(localized: "settings.api-key.error.failed-to-update-credential-for-provider", defaultValue: "Failed to update %@ for %@. Please try again.", comment: "Error message when updating credential for provider fails"), "\(credential.label)", "\(provider.title)")
        }
        showingAuthResult = true
    }
    
    private func disconnectCustomProviderCredential(provider: CustomProviderDefinition, credential: CustomProviderCredential) {
        if serverManager.deleteCustomProviderCredential(credential) {
            authResultSuccess = true
            authResultMessage = String(format: String(localized: "settings.api-key.status.removed-credential-from-provider", defaultValue: "✓ Removed %@ from %@", comment: "Status message when credential is removed from provider"), "\(credential.label)", "\(provider.title)")
        } else {
            authResultSuccess = false
            authResultMessage = String(format: String(localized: "settings.api-key.error.failed-to-remove-credential-from-provider", defaultValue: "Failed to remove %@ from %@", comment: "Error message when removing credential from provider fails"), "\(credential.label)", "\(provider.title)")
        }
        showingAuthResult = true
    }
    
    private func disconnectAccount(_ account: AuthAccount) {
        let wasRunning = serverManager.isRunning
        
        // Stop server, delete file, restart
        let cleanup = {
            if self.authManager.deleteAccount(account) {
                self.authResultSuccess = true
                self.authResultMessage = String(format: String(localized: "settings.accounts.status.removed-account-from-service", defaultValue: "✓ Removed %@ from %@", comment: "Status message when account is removed from service"), "\(account.displayName)", "\(account.type.displayName)")
            } else {
                self.authResultSuccess = false
                self.authResultMessage = String(localized: "settings.accounts.error.failed-to-remove-account", defaultValue: "Failed to remove account", comment: "Error message when removing account fails")
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
}
