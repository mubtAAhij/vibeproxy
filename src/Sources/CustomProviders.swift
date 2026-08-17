import Foundation

struct CustomProviderDefinition: Identifiable, Equatable {
    let id: String
    let title: String
    let baseURL: String
    let helpText: String?
    let iconSystemName: String?
    let modelAliases: [String]
    let inlineAPIKeys: [String]

    var inlineKeyCount: Int {
        inlineAPIKeys.count
    }
    
    var effectiveHelpText: String {
        if let helpText, !helpText.isEmpty {
            return helpText
        }
        
        let modelSummary: String
        if modelAliases.isEmpty {
            modelSummary = String(localized: "custom-provider.model-summary.none-configured", defaultValue: "No model aliases configured yet.", bundle: .main, comment: "Summary shown when no model aliases are configured")
        } else {
            modelSummary = String(format: String(localized: "custom-provider.model-summary.models-list", defaultValue: "Models: %@.", bundle: .main, comment: "Summary listing configured model aliases"), modelAliases.joined(separator: ", "))
        }
        
        return String(format: String(localized: "custom-provider.help-text.openai-compatible", defaultValue: "OpenAI-compatible provider at %@. %@", bundle: .main, comment: "Help text describing custom provider endpoint and model summary"), baseURL, modelSummary)
    }
    
    var effectiveIconSystemName: String {
        if let iconSystemName, !iconSystemName.isEmpty {
            return iconSystemName
        }
        return "server.rack"
    }
    
    static func defaultTitle(for id: String) -> String {
        let spaced = id.replacingOccurrences(
            of: "[^A-Za-z0-9]+",
            with: " ",
            options: .regularExpression
        )
        let collapsed = spaced
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
        return collapsed.isEmpty ? id : collapsed
    }
}

struct CustomProviderCredential: Identifiable, Equatable {
    let providerID: String
    let apiKey: String
    let label: String
    let isDisabled: Bool

    var id: String {
        "\(providerID)|\(apiKey)"
    }
}
