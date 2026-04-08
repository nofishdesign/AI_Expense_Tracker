import Foundation
import SwiftData

enum CloudVendor: String, Codable, CaseIterable, Identifiable {
    case openai
    case kimi
    case minimax
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openai: return "OpenAI"
        case .kimi: return "Kimi"
        case .minimax: return "MiniMax"
        case .custom: return "自定义"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com"
        case .kimi: return "https://api.moonshot.cn"
        case .minimax: return "https://api.minimax.chat"
        case .custom: return ""
        }
    }

    var defaultAPIPath: String {
        switch self {
        case .openai, .kimi:
            return "/v1/chat/completions"
        case .minimax:
            return "/v1/text/chatcompletion_v2"
        case .custom:
            return "/v1/chat/completions"
        }
    }

    var defaultEndpoint: String {
        "\(defaultBaseURL)\(defaultAPIPath)"
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-5.4"
        case .kimi: return "moonshot-v1-8k"
        case .minimax: return "abab6.5s-chat"
        case .custom: return "gpt-5.4"
        }
    }
}

struct CloudModelRuntimeConfig: Sendable {
    var name: String
    var vendor: CloudVendor
    var endpoint: String
    var baseURL: String
    var apiPath: String
    var model: String
    var apiKey: String
    var customHeaders: [String: String]
}

@Model
final class CloudModelConfig {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var vendorRaw: String
    var endpoint: String
    var baseURL: String
    var apiPath: String
    var modelName: String
    var apiKey: String
    var customHeadersJSON: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastTestAt: Date?
    var lastLatencyMs: Int?
    var lastTestOK: Bool
    var lastTestMessage: String

    init(
        id: UUID = UUID(),
        displayName: String,
        vendor: CloudVendor,
        endpoint: String,
        baseURL: String = "",
        apiPath: String = "",
        modelName: String,
        apiKey: String = "",
        customHeadersJSON: String = "{}",
        isEnabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastTestAt: Date? = nil,
        lastLatencyMs: Int? = nil,
        lastTestOK: Bool = false,
        lastTestMessage: String = "未测速"
    ) {
        self.id = id
        self.displayName = displayName
        self.vendorRaw = vendor.rawValue
        self.baseURL = baseURL
        self.apiPath = apiPath
        self.endpoint = endpoint
        self.modelName = modelName
        self.apiKey = apiKey
        self.customHeadersJSON = customHeadersJSON
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastTestAt = lastTestAt
        self.lastLatencyMs = lastLatencyMs
        self.lastTestOK = lastTestOK
        self.lastTestMessage = lastTestMessage
    }
}

extension CloudModelConfig {
    var vendor: CloudVendor {
        get { CloudVendor(rawValue: vendorRaw) ?? .custom }
        set { vendorRaw = newValue.rawValue }
    }

    var runtime: CloudModelRuntimeConfig {
        let mergedEndpoint: String
        if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = apiPath.trimmingCharacters(in: .whitespacesAndNewlines)

            if path.isEmpty, let parsed = URL(string: trimmedBase), !parsed.path.isEmpty, parsed.path != "/" {
                mergedEndpoint = trimmedBase
            } else {
                let effectivePath = path.isEmpty ? vendor.defaultAPIPath : path
                if effectivePath.hasPrefix("/") {
                    mergedEndpoint = "\(trimmedBase)\(effectivePath)"
                } else {
                    mergedEndpoint = "\(trimmedBase)/\(effectivePath)"
                }
            }
        } else {
            mergedEndpoint = endpoint
        }

        return CloudModelRuntimeConfig(
            name: displayName,
            vendor: vendor,
            endpoint: mergedEndpoint,
            baseURL: baseURL,
            apiPath: apiPath,
            model: modelName,
            apiKey: apiKey,
            customHeaders: (try? JSONDecoder().decode([String: String].self, from: Data(customHeadersJSON.utf8))) ?? [:]
        )
    }
}
