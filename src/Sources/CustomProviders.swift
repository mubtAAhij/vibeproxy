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
            modelSummary = String(localized: "custom-providers.help.no-model-aliases", defaultValue: "No model aliases configured yet.", bundle: .main, comment: "Help text shown when a custom provider has no model aliases")
        } else {
            modelSummary = String(format: String(localized: "custom-providers.help.models-list", defaultValue: "Models: %@.", comment: "Help text listing model aliases for a custom provider"), "\(modelAliases.joined(separator: ", "))")
        }
        
        return String(format: String(localized: "custom-providers.help.provider-summary", defaultValue: "OpenAI-compatible provider at %@. %@", comment: "Help text summarizing custom provider URL and model aliases"), "\(baseURL)", "\(modelSummary)")
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
