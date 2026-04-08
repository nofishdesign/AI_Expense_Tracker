import Foundation
import SwiftData

enum SeedDataService {
    private static let defaultTestingBaseURL = "https://open.xingyungept.cn/v1"
    private static let defaultTestingModelName = "gpt-5.4"

    @MainActor
    static func seedIfNeeded(context: ModelContext) throws {
        let existingCategories = try context.fetch(FetchDescriptor<Category>())
        if existingCategories.isEmpty {
            let presets: [(String, String, [String])] = [
                ("餐饮", "fork.knife", ["咖啡", "奶茶", "外卖", "餐", "饭", "麦当劳", "肯德基", "瑞幸"]),
                ("交通", "car", ["地铁", "公交", "滴滴", "打车", "加油", "停车"]),
                ("日用", "basket", ["超市", "便利店", "日用品", "生活"]),
                ("娱乐", "gamecontroller", ["电影", "游戏", "演出", "ktv", "娱乐"]),
                ("医疗", "cross.case", ["医院", "药店", "门诊", "体检"]),
                ("住房", "house", ["房租", "物业", "水电", "燃气"]),
                ("通讯", "antenna.radiowaves.left.and.right", ["话费", "流量", "宽带"]),
                ("学习", "book", ["课程", "书店", "培训", "学习"]),
                ("其他", "square.grid.2x2", [])
            ]

            for (index, item) in presets.enumerated() {
                let category = Category(
                    name: item.0,
                    symbol: item.1,
                    isSystem: true,
                    isEnabled: true,
                    order: index,
                    keywords: item.2
                )
                context.insert(category)
            }
        }

        if (try? context.fetch(FetchDescriptor<AppSettings>()).isEmpty) ?? true {
            context.insert(AppSettings())
        }

        // Seed a default cloud model shell without credentials.
        // API Key should be entered manually in Settings.
        let settings: AppSettings
        if let existing = try? context.fetch(FetchDescriptor<AppSettings>()).first {
            settings = existing
        } else {
            let created = AppSettings()
            context.insert(created)
            settings = created
        }

        if let models = try? context.fetch(FetchDescriptor<CloudModelConfig>()) {
            if models.isEmpty {
                let defaultModel = CloudModelConfig(
                    displayName: "OPEN AI",
                    vendor: .openai,
                    endpoint: defaultTestingBaseURL,
                    baseURL: defaultTestingBaseURL,
                    apiPath: "",
                    modelName: defaultTestingModelName,
                    apiKey: "",
                    customHeadersJSON: "{}"
                )
                context.insert(defaultModel)
                settings.selectedCloudModelID = defaultModel.id
                settings.updatedAt = .now
            } else if let openAIModel = models.first(where: { $0.vendor == .openai && $0.displayName.uppercased().contains("OPEN") }) {
                if openAIModel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    openAIModel.baseURL = defaultTestingBaseURL
                    openAIModel.endpoint = defaultTestingBaseURL
                }
                openAIModel.modelName = defaultTestingModelName
                openAIModel.updatedAt = .now
                if settings.selectedCloudModelID == nil {
                    settings.selectedCloudModelID = openAIModel.id
                }
            }
        }

        // Migrate old OpenAI defaults to GPT-5.4 for OpenAI-compatible gateways.
        if let models = try? context.fetch(FetchDescriptor<CloudModelConfig>()) {
            for model in models where model.vendor == .openai {
                if model.modelName == "gpt-4o-mini" {
                    model.modelName = CloudVendor.openai.defaultModel
                    model.updatedAt = .now
                }
            }
        }

        // Migration: remove legacy seeded vendor presets to avoid accidental use of stale URL/API.
        if let models = try? context.fetch(FetchDescriptor<CloudModelConfig>()) {
            let legacyNames = Set(["OpenAI 默认", "Kimi 默认", "MiniMax 默认"])
            var removedIDs: Set<UUID> = []
            for model in models where legacyNames.contains(model.displayName) {
                removedIDs.insert(model.id)
                context.delete(model)
            }
            if let settings = try? context.fetch(FetchDescriptor<AppSettings>()).first,
               let selected = settings.selectedCloudModelID,
               removedIDs.contains(selected) {
                settings.selectedCloudModelID = nil
                settings.updatedAt = .now
            }
        }

        // Keep sync credentials empty by default; user enters them manually.
        if let settings = try? context.fetch(FetchDescriptor<AppSettings>()).first {
            if settings.lastSyncMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settings.lastSyncMessage = "未同步"
            }
            settings.updatedAt = .now
        }

        try context.save()
    }
}
