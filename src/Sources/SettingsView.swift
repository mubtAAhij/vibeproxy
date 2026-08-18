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
                Text(String(
                    localized: "settings.provider.status.expired",
                    defaultValue: "(expired)",
                    comment: "Status text shown next to an expired account/provider"
                ))
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            if account.isDisabled {
                Text(String(
                    localized: "settings.provider.status.disabled",
                    defaultValue: "(disabled)",
                    comment: "Status text shown next to a disabled account/provider"
                ))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if showDisableToggle {
                let canDisable = account.isDisabled || !isLastEnabled
                Button(action: onToggleDisabled) {
                    Text(account.isDisabled ? String(
                        localized: "settings.provider.action.enable",
                        defaultValue: "Enable",
                        comment: "Button label to enable a provider"
                    ) : String(
                        localized: "settings.provider.action.disable",
                        defaultValue: "Disable",
                        comment: "Button label to disable a provider"
                    ))
                        .font(.caption)
                        .foregroundColor(account.isDisabled ? .green : (canDisable ? .orange : .secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canDisable)
                .help(!canDisable ? String(
                    localized: "settings.provider.validation.one-account-required",
                    defaultValue: "At least one account must remain enabled",
                    comment: "Validation message when disabling would leave no enabled accounts"
                ) : "")
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
                    Text(String(
                        localized: "settings.account.action.remove",
                        defaultValue: "Remove",
                        comment: "Destructive button label to remove an account"
                    ))
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
                Text(String(
                    localized: "settings.gateway.toggle.title",
                    defaultValue: "Use Vercel AI Gateway",
                    comment: "Toggle title for enabling Vercel AI Gateway routing"
                ))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help(String(
                localized: "settings.gateway.toggle.description",
                defaultValue: "Route Claude requests through Vercel AI Gateway for safer access to your Claude Max subscription",
                comment: "Description text explaining Vercel AI Gateway routing"
            ))
            
            if serverManager.vercelGatewayEnabled {
                HStack(spacing: 8) {
                    Text(String(
                        localized: "settings.gateway.api-key.label",
                        defaultValue: "Vercel API key",
                        comment: "Label for the Vercel API key input field"
                    ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("", text: $serverManager.vercelApiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .font(.caption)
                    
                    if showingSaved {
                        Text(String(
                            localized: "settings.gateway.api-key.saved",
                            defaultValue: "Saved",
                            comment: "Status text shown after API key is saved"
                        ))
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Button(String(
                            localized: "settings.gateway.api-key.save",
                            defaultValue: "Save",
                            comment: "Button label to save API key"
                        )) {
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
                .help(toggleHelpText ?? (isEnabled ? String(
                    localized: "settings.provider.toggle.disable-help",
                    defaultValue: "Disable this provider",
                    comment: "Help text for provider toggle when provider is currently enabled"
                ) : String(
                    localized: "settings.provider.toggle.enable-help",
                    defaultValue: "Enable this provider",
                    comment: "Help text for provider toggle when provider is currently disabled"
                )))

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
                    Button(String(
                        localized: "settings.account.action.add",
                        defaultValue: "Add Account",
                        comment: "Button title to add a new account"
                    )) {
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
                        Text("\(accounts.count) connected account\(accounts.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.green)

                        if enabledCount > 1 {
                            Text(String(
                                localized: "settings.account.behavior.round-robin-auto-failover",
                                defaultValue: "• Round-robin w/ auto-failover",
                                comment: "Bullet point describing account routing behavior"
                            ))
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
                    Text(String(
                        localized: "settings.account.empty-state.title",
                        defaultValue: "No connected accounts",
                        comment: "Empty-state message shown when no accounts are connected"
                    ))
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
        .alert(String(
            localized: "settings.account.remove.confirm.title",
            defaultValue: "Remove Account",
            comment: "Confirmation dialog title for removing an account"
        ), isPresented: $showingRemoveConfirmation) {
            Button(String(
                localized: "settings.account.remove.confirm.cancel",
                defaultValue: "Cancel",
                comment: "Cancel button label in remove account confirmation dialog"
            ), role: .cancel) {
                accountToRemove = nil
            }
            Button(String(
                localized: "settings.account.action.remove",
                defaultValue: "Remove",
                comment: "Destructive confirmation button label to remove account"
            ), role: .destructive) {
                if let account = accountToRemove {
                    onDisconnect(account)
                }
                accountToRemove = nil
            }
        } message: {
            if let account = accountToRemove {
                Text(String(format: String(
                    localized: "settings.account-removal.confirmation",
                    defaultValue: "Are you sure you want to remove %@ from %@?",
                    bundle: .main,
                    comment: "Confirmation message asking whether to remove an account from a service"
                ), account.displayName, serviceType.displayName))
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
                Text(String(
                    localized: "settings.credential.disabled-indicator",
                    defaultValue: "(disabled)",
                    bundle: .main,
                    comment: "Status label shown for disabled credentials"
                ))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if showDisableToggle {
                let canDisable = credential.isDisabled || !isLastEnabled
                Button(action: onToggleDisabled) {
                    Text(credential.isDisabled ? String(
                        localized: "settings.credential.action.enable",
                        defaultValue: "Enable",
                        bundle: .main,
                        comment: "Button title to enable a disabled credential"
                    ) : String(
                        localized: "settings.credential.action.disable",
                        defaultValue: "Disable",
                        bundle: .main,
                        comment: "Button title to disable an enabled credential"
                    ))
                        .font(.caption)
                        .foregroundColor(credential.isDisabled ? .green : (canDisable ? .orange : .secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canDisable)
                .help(!canDisable ? String(
                    localized: "settings.credential.disable.minimum-enabled-required",
                    defaultValue: "At least one API key must remain enabled",
                    bundle: .main,
                    comment: "Help text explaining that at least one API key must stay enabled"
                ) : "")
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
                    Text(String(
                        localized: "settings.credential.action.remove",
                        defaultValue: "Remove",
                        bundle: .main,
                        comment: "Button title to remove a credential"
                    ))
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
            return String(
                localized: "settings.provider.summary.no-configured-api-keys",
                defaultValue: "No configured API keys",
                bundle: .main,
                comment: "Summary shown when a provider has no configured API keys"
            )
        }
        if provider.inlineKeyCount > 0 && !credentials.isEmpty {
            return "\(totalConfiguredKeyCount) API keys • \(provider.inlineKeyCount) in config • \(credentials.count) added here"
        }
        if provider.inlineKeyCount > 0 {
            return "\(totalConfiguredKeyCount) API key\(totalConfiguredKeyCount == 1 ? "" : "s") from config"
        }
        return "\(totalConfiguredKeyCount) API key\(totalConfiguredKeyCount == 1 ? "" : "s") added here"
    }

    private var poolingStatusText: String? {
        guard totalEnabledKeyCount > 1 else {
            return nil
        }
        return "• Pooled across available keys"
    }

    private var endpointSummaryText: String {
        "Endpoint: \(provider.baseURL)"
    }

    private var modelSummaryText: String? {
        guard !provider.modelAliases.isEmpty else {
            return nil
        }
        return "Models: \(provider.modelAliases.joined(separator: ", "))"
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
                .help(isEnabled ? String(
                    localized: "settings.provider.toggle.help.disable",
                    defaultValue: "Disable this provider",
                    bundle: .main,
                    comment: "Help text for disabling a provider"
                ) : String(
                    localized: "settings.provider.toggle.help.enable",
                    defaultValue: "Enable this provider",
                    bundle: .main,
                    comment: "Help text for enabling a provider"
                ))
                
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
                    Button(String(
                        localized: "settings.provider.action.add-api-key",
                        defaultValue: "Add API Key",
                        bundle: .main,
                        comment: "Button title to add an API key"
                    )) {
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
                                Text("Using \(provider.inlineKeyCount) API key\(provider.inlineKeyCount == 1 ? "" : "s") from ~/.cli-proxy-api/config.yaml")
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
                    Text(String(
                        localized: "settings.provider.summary.no-configured-api-keys",
                        defaultValue: "No configured API keys",
                        bundle: .main,
                        comment: "Summary shown when a provider has no configured API keys"
                    ))
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
        .alert(String(
            localized: "settings.provider.remove-api-key.title",
            defaultValue: "Remove API Key",
            bundle: .main,
            comment: "Alert title for removing an API key"
        ), isPresented: $showingRemoveConfirmation) {
            Button(String(
                localized: "settings.common.cancel",
                defaultValue: "Cancel",
                bundle: .main,
                comment: "Cancel button title"
            ), role: .cancel) {
                credentialToRemove = nil
            }
            Button("Remove", role: .destructive) {
                if let credential = credentialToRemove {
                    onDisconnect(credential)
                }
                credentialToRemove = nil
            }
        } message: {
            if let credential = credentialToRemove {
                Text(String(format: String(
                    localized: "settings.provider.credential-removal.confirmation",
                    defaultValue: "Are you sure you want to remove %@ from %@?",
                    bundle: .main,
                    comment: "Confirmation message asking whether to remove a credential from a provider"
                ), credential.label, provider.title))
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
            return "v\(version)"
        }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        Text(String(
                            localized: "settings.server.status.title",
                            defaultValue: "Server status",
                            bundle: .main,
                            comment: "Label for current server status"
                        ))
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
                                Text(serverManager.isRunning ? String(
                                    localized: "settings.server.status.running",
                                    defaultValue: "Running",
                                    bundle: .main,
                                    comment: "Status text when server is running"
                                ) : String(
                                    localized: "settings.server.status.stopped",
                                    defaultValue: "Stopped",
                                    bundle: .main,
                                    comment: "Status text when server is stopped"
                                ))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let configErrorMessage = serverManager.configErrorMessage {
                    Section(String(
                        localized: "settings.server.configuration-error.title",
                        defaultValue: "Configuration Error",
                        bundle: .main,
                        comment: "Section title for server configuration errors"
                    )) {
                        Text(configErrorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Toggle(String(
                        localized: "settings.app.launch-at-login",
                        defaultValue: "Launch at login",
                        bundle: .main,
                        comment: "Toggle title for launching the app at login"
                    ), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            toggleLaunchAtLogin(newValue)
                        }

                    HStack {
                        Text(String(
                            localized: "settings.providers.auth-files.title",
                            defaultValue: "Auth files",
                            comment: "Title for auth files setting section"
                        ))
                        Spacer()
                        Button(String(
                            localized: "settings.providers.auth-files.open-folder",
                            defaultValue: "Open Folder",
                            comment: "Button title to open auth files folder"
                        )) {
                            openAuthFolder()
                        }
                    }
                }

                Section(String(
                    localized: "settings.services.title",
                    defaultValue: "Services",
                    comment: "Title for services section in settings"
                )) {
                    ServiceRow(
                        serviceType: .antigravity,
                        iconName: "icon-antigravity.png",
                        iconSystemName: nil,
                        accounts: authManager.accounts(for: .antigravity),
                        isAuthenticating: authenticatingService == .antigravity,
                        helpText: "Antigravity provides OAuth-based access to various AI models including Gemini and Claude. One login gives you access to multiple AI services.",
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
                        customTitle: serverManager.vercelGatewayEnabled && !serverManager.vercelApiKey.isEmpty ? "Claude Code (via Vercel)" : nil,
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
                        helpText: String(
                            localized: "settings.gemini.note.default-project",
                            defaultValue: "⚠️ Note: If you're an existing Gemini user with multiple projects, authentication will use your default project. Set your desired project as default in Google AI Studio before connecting.",
                            comment: "Informational note about Gemini default project behavior"
                        ),
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
                        helpText: String(
                            localized: "settings.kimi.description.browser-auth",
                            defaultValue: "Kimi uses browser-based account authentication so you can route requests through your Kimi subscription instead of an API key.",
                            comment: "Description for Kimi authentication method"
                        ),
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
                        helpText: String(
                            localized: "settings.copilot.description.subscription-model-access",
                            defaultValue: "GitHub Copilot provides access to Claude, GPT, Gemini and other models via your Copilot subscription.",
                            comment: "Description for GitHub Copilot provider"
                        ),
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
                        helpText: String(
                            localized: "settings.zai-glm.description.api-key",
                            defaultValue: "Z.AI GLM provides access to GLM-4.7 and other models via API key. Get your key at https://z.ai/manage-apikey/apikey-list",
                            comment: "Description for Z.AI GLM provider and key location"
                        ),
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
                    Section(String(
                        localized: "settings.custom-providers.title",
                        defaultValue: "Custom Providers",
                        comment: "Title for custom providers section"
                    )) {
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
                    Text(String(format: String(
                        localized: "settings.about.vibeproxy-thanks",
                        defaultValue: "VibeProxy %@ was made possible thanks to",
                        comment: "About text thanking contributors with app version"
                    ), "\(appVersion)"))
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
                    Text(String(
                        localized: "settings.about.license-mit",
                        defaultValue: "License: MIT",
                        comment: "License label in about section"
                    ))
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
                    Text(String(
                        localized: "settings.about.all-rights-reserved",
                        defaultValue: "All rights reserved.",
                        comment: "Copyright notice in about section"
                    ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Link(String(
                    localized: "settings.about.report-issue",
                    defaultValue: "Report an issue",
                    comment: "Link title to report an issue"
                ), destination: URL(string: "https://github.com/automazeio/vibeproxy/issues")!)
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
                Text(String(
                    localized: "settings.qwen.email-dialog.title",
                    defaultValue: "Qwen Account Email",
                    comment: "Dialog title requesting Qwen account email"
                ))
                    .font(.headline)
                Text(String(
                    localized: "settings.qwen.email-dialog.prompt",
                    defaultValue: "Enter your Qwen account email address",
                    comment: "Prompt text for Qwen email input"
                ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("your.email@example.com", text: $qwenEmail)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                HStack(spacing: 12) {
                    Button(String(
                        localized: "common.actions.cancel",
                        defaultValue: "Cancel",
                        comment: "Cancel button label in dialog"
                    )) {
                        showingQwenEmailPrompt = false
                        qwenEmail = ""
                    }
                    Button(String(
                        localized: "common.actions.continue",
                        defaultValue: "Continue",
                        comment: "Continue button label in dialog"
                    )) {
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
                Text(String(
                    localized: "settings.zai.api-key-dialog.title",
                    defaultValue: "Z.AI API Key",
                    comment: "Dialog title requesting Z.AI API key"
                ))
                    .font(.headline)
                Text(String(
                    localized: "settings.zai.api-key-dialog.prompt",
                    defaultValue: "Enter your Z.AI API key from https://z.ai/manage-apikey/apikey-list",
                    comment: "Prompt text for Z.AI API key input"
                ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("", text: $zaiApiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                HStack(spacing: 12) {
                    Button(String(
                        localized: "common.actions.cancel",
                        defaultValue: "Cancel",
                        comment: "Cancel button label in API key dialog"
                    )) {
                        showingZaiApiKeyPrompt = false
                        zaiApiKey = ""
                    }
                    Button(String(
                        localized: "settings.zai.api-key-dialog.add-key",
                        defaultValue: "Add Key",
                        comment: "Confirmation button to add API key"
                    )) {
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
                Text(String(format: String(
                    localized: "settings.custom-provider.api-key-dialog.title",
                    defaultValue: "%@ API Key",
                    comment: "Dialog title for adding an API key to a custom provider"
                ), "\(provider.title)"))
                    .font(.headline)
                Text(String(format: String(
                    localized: "settings.custom-provider.api-key-dialog.prompt",
                    defaultValue: "Enter an API key for %@",
                    comment: "Prompt text for entering custom provider API key"
                ), "\(provider.title)"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("", text: $customProviderApiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                HStack(spacing: 12) {
                    Button(String(
                        localized: "common.actions.cancel",
                        defaultValue: "Cancel",
                        comment: "Cancel button label in custom provider API key dialog"
                    )) {
                        selectedCustomProvider = nil
                        customProviderApiKey = ""
                    }
                    Button(String(
                        localized: "settings.custom-provider.api-key-dialog.add-key",
                        defaultValue: "Add Key",
                        comment: "Confirmation button to add custom provider API key"
                    )) {
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
        .alert(String(
            localized: "settings.authentication.result.title",
            defaultValue: "Authentication Result",
            comment: "Title for authentication result alert"
        ), isPresented: $showingAuthResult) {
            Button(String(
                localized: "common.actions.ok",
                defaultValue: "OK",
                comment: "OK button label in alert"
            ), role: .cancel) { }
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
                ? String(format: String(
                    localized: "settings.authentication.account-enabled",
                    defaultValue: "✓ Enabled %@",
                    comment: "Success message indicating account was enabled"
                ), "\(account.displayName)")
                : String(format: String(
                    localized: "settings.authentication.account-disabled",
                    defaultValue: "✓ Disabled %@",
                    comment: "Success message indicating account was disabled"
                ), "\(account.displayName)")
            showingAuthResult = true
        } else {
            authResultSuccess = false
            authResultMessage = String(format: String(
                localized: "settings.authentication.account-update-failed",
                defaultValue: "Failed to update %@. Please try again.",
                comment: "Error message when updating account state fails"
            ), "\(account.displayName)")
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
                    if serviceType == .copilot && (output.contains("Code copied") || output.contains("code:")) {
                        self.authResultMessage = output
                    } else {
                        self.authResultMessage = self.successMessage(for: serviceType)
                    }
                    self.showingAuthResult = true
                } else {
                    self.authResultSuccess = false
                    let detail = output.isEmpty ? String(
                        localized: "settings.authentication.failed.no-output-details",
                        defaultValue: "No output from authentication process",
                        comment: "Fallback detail when authentication process returns no output"
                    ) : output
                    self.authResultMessage = String(format: String(
                        localized: "settings.authentication.failed.with-details",
                        defaultValue: "Authentication failed. Please check if the browser opened and try again.\n\nDetails: %@",
                        comment: "Authentication failure message with output details"
                    ), detail)
                    self.showingAuthResult = true
                }
            }
        }
    }
    
    private func successMessage(for serviceType: ServiceType) -> String {
        switch serviceType {
        case .claude:
            return String(
                localized: "settings.authentication.status.claude-code-browser-opened",
                defaultValue: "🌐 Browser opened for Claude Code authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials.",
                comment: "Status message shown when Claude Code authentication starts in browser"
            )
        case .codex:
            return String(
                localized: "settings.authentication.status.codex-browser-opened",
                defaultValue: "🌐 Browser opened for Codex authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials.",
                comment: "Status message shown when Codex authentication starts in browser"
            )
        case .copilot:
            return String(
                localized: "settings.authentication.status.copilot-device-auth-started",
                defaultValue: "🌐 GitHub Copilot authentication started!\n\nPlease visit github.com/login/device and enter the code shown.\n\nThe app will automatically detect your credentials.",
                comment: "Status message shown when GitHub Copilot device authentication starts"
            )
        case .gemini:
            return String(
                localized: "settings.authentication.status.gemini-browser-opened",
                defaultValue: "🌐 Browser opened for Gemini authentication.\n\nPlease complete the login in your browser.\n\n⚠️ Note: If you have multiple projects, the default project will be used.",
                comment: "Status message shown when Gemini authentication starts in browser"
            )
        case .kimi:
            return String(
                localized: "settings.authentication.status.kimi-browser-opened",
                defaultValue: "🌐 Browser opened for Kimi authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your Kimi account.",
                comment: "Status message shown when Kimi authentication starts in browser"
            )
        case .qwen:
            return String(
                localized: "settings.authentication.status.qwen-browser-opened",
                defaultValue: "🌐 Browser opened for Qwen authentication.\n\nPlease complete the login in your browser.",
                comment: "Status message shown when Qwen authentication starts in browser"
            )
        case .antigravity:
            return String(
                localized: "settings.authentication.status.antigravity-browser-opened",
                defaultValue: "🌐 Browser opened for Antigravity authentication.\n\nPlease complete the login in your browser.",
                comment: "Status message shown when Antigravity authentication starts in browser"
            )
        case .zai:
            return String(
                localized: "settings.zai.api-key-added.success",
                defaultValue: "✓ Z.AI API key added successfully.\n\nYou can now use GLM models through the proxy.",
                comment: "Success message after adding Z.AI API key"
            )
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
                    let detail = output.isEmpty ? String(
                        localized: "settings.authentication.failed.no-output",
                        defaultValue: "No output",
                        comment: "Fallback detail when compact authentication output is empty"
                    ) : output
                    self.authResultMessage = String(format: String(
                        localized: "settings.authentication.failed.compact-with-details",
                        defaultValue: "Authentication failed.\n\nDetails: %@",
                        comment: "Authentication failure message with compact output details"
                    ), detail)
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
                    let detail = output.isEmpty ? String(
                        localized: "settings.api-key.error.unknown",
                        defaultValue: "Unknown error",
                        comment: "Fallback detail when API key save failure has no output"
                    ) : output
                    self.authResultMessage = String(format: String(
                        localized: "settings.api-key.save-failed.with-details",
                        defaultValue: "Failed to save API key.\n\nDetails: %@",
                        comment: "Error message when saving API key fails with details"
                    ), detail)
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
                    case "API key saved successfully":
                        self.authResultMessage = String(format: String(
                            localized: "settings.custom-provider.api-key-added.success",
                            defaultValue: "✓ %@ API key added successfully.\n\nYou can now use this provider through the proxy.",
                            comment: "Success message after adding API key for a custom provider"
                        ), "\(provider.title)")
                    case "API key already exists in config":
                        self.authResultMessage = String(format: String(
                            localized: "settings.custom-provider.api-key-already-present.config-file",
                            defaultValue: "✓ %@ already has this API key in ~/.cli-proxy-api/config.yaml.",
                            comment: "Message indicating API key already exists in config file for provider"
                        ), "\(provider.title)")
                    case "API key already exists":
                        self.authResultMessage = String(format: String(
                            localized: "settings.custom-provider.api-key-already-stored",
                            defaultValue: "✓ %@ already has this API key stored.",
                            comment: "Message indicating API key was already stored for provider"
                        ), "\(provider.title)")
                    case "API key was already stored and has been re-enabled":
                        self.authResultMessage = String(format: String(
                            localized: "settings.custom-provider.api-key-reenabled",
                            defaultValue: "✓ %@ already had this API key stored, and it has been re-enabled.",
                            comment: "Message indicating existing API key was re-enabled for provider"
                        ), "\(provider.title)")
                    default:
                        self.authResultMessage = output
                    }
                    self.showingAuthResult = true
                } else {
                    self.authResultSuccess = false
                    let detail = output.isEmpty ? String(
                        localized: "settings.custom-provider.api-key-save-failed.unknown-error",
                        defaultValue: "Unknown error",
                        comment: "Fallback detail when custom provider API key save failure has no output"
                    ) : output
                    self.authResultMessage = String(format: String(
                        localized: "settings.custom-provider.api-key-save-failed.with-details",
                        defaultValue: "Failed to save API key for %@.\n\nDetails: %@",
                        comment: "Error message when saving provider API key fails with details"
                    ), provider.title, detail)
                    self.showingAuthResult = true
                }
            }
        }
    }
    
    private func toggleCustomProviderCredential(provider: CustomProviderDefinition, credential: CustomProviderCredential) {
        if serverManager.toggleCustomProviderCredentialDisabled(credential) {
            authResultSuccess = true
            authResultMessage = credential.isDisabled
                ? String(format: String(
                    localized: "settings.custom-provider.credential.enabled",
                    defaultValue: "✓ Enabled %@ for %@",
                    comment: "Success message when enabling a provider credential"
                ), "\(credential.label)", "\(provider.title)")
                : String(format: String(
                    localized: "settings.custom-provider.credential.disabled",
                    defaultValue: "✓ Disabled %@ for %@",
                    comment: "Success message when disabling a provider credential"
                ), "\(credential.label)", "\(provider.title)")
        } else {
            authResultSuccess = false
            authResultMessage = String(format: String(
                localized: "settings.custom-provider.credential.update-failed",
                defaultValue: "Failed to update %@ for %@. Please try again.",
                comment: "Error message when updating provider credential fails"
            ), "\(credential.label)", "\(provider.title)")
        }
        showingAuthResult = true
    }
    
    private func disconnectCustomProviderCredential(provider: CustomProviderDefinition, credential: CustomProviderCredential) {
        if serverManager.deleteCustomProviderCredential(credential) {
            authResultSuccess = true
            authResultMessage = String(format: String(
                localized: "settings.custom-provider.credential.removed",
                defaultValue: "✓ Removed %@ from %@",
                comment: "Success message when removing provider credential"
            ), "\(credential.label)", "\(provider.title)")
        } else {
            authResultSuccess = false
            authResultMessage = String(format: String(
                localized: "settings.custom-provider.credential.remove-failed",
                defaultValue: "Failed to remove %@ from %@",
                comment: "Error message when removing provider credential fails"
            ), "\(credential.label)", "\(provider.title)")
        }
        showingAuthResult = true
    }
    
    private func disconnectAccount(_ account: AuthAccount) {
        let wasRunning = serverManager.isRunning
        
        // Stop server, delete file, restart
        let cleanup = {
            if self.authManager.deleteAccount(account) {
                self.authResultSuccess = true
                self.authResultMessage = String(format: String(
                    localized: "settings.account.removed.from-provider",
                    defaultValue: "✓ Removed %@ from %@",
                    comment: "Success message when removing account from provider"
                ), "\(account.displayName)", "\(account.type.displayName)")
            } else {
                self.authResultSuccess = false
                self.authResultMessage = String(
                    localized: "settings.account.remove-failed",
                    defaultValue: "Failed to remove account",
                    comment: "Error message when account removal fails"
                )
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
