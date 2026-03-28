import Foundation
import SwiftData

enum SeedDataService {
    @MainActor
    static func seedIfNeeded(context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<Category>())
        guard existing.isEmpty else { return }

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

        if (try? context.fetch(FetchDescriptor<AppSettings>()).isEmpty) ?? true {
            context.insert(AppSettings())
        }

        try context.save()
    }
}
