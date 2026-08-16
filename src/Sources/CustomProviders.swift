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
            modelSummary = String(localized: "custom-provider.help.model-aliases.none-configured", defaultValue: "No model aliases configured yet.", bundle: .main, comment: "Summary text when no model aliases are configured for a custom provider")
        } else {
            modelSummary = String(format: String(localized: "custom-provider.help.model-aliases.list", defaultValue: "Models: %@.", bundle: .main, comment: "Summary text listing model aliases for a custom provider"), modelAliases.joined(separator: ", "))
        }
        
        return String(format: String(localized: "custom-provider.help.base-url-and-model-summary", defaultValue: "OpenAI-compatible provider at %@. %@", bundle: .main, comment: "Help text describing provider base URL followed by model summary"), baseURL, modelSummary)
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
