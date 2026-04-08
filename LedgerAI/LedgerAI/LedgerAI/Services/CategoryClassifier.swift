import Foundation
import SwiftData

struct CategoryClassifier {
    func classify(
        draft: ParseDraft,
        categories: [Category],
        preferences: [UserPreference],
        rawText: String = ""
    ) -> Category? {
        let enabledCategories = categories.filter(\.isEnabled)
        guard !enabledCategories.isEmpty else { return nil }

        let normalizedMerchant = normalize(draft.merchant)
        let normalizedRawText = normalize(rawText)
        let normalizedSuggested = normalize(draft.suggestedCategoryName)
        let searchableText = [normalizedMerchant, normalizedRawText, normalizedSuggested]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // 1) User preference is the highest priority.
        if !isUnknownMerchant(normalizedMerchant),
           let preferred = preferences
            .sorted(by: { $0.useCount > $1.useCount })
            .first(where: { preference in
                guard preference.preferredCategoryID != nil else { return false }
                let key = normalize(preference.merchantKey)
                guard key.count >= 2 else { return false }
                return normalizedMerchant == key || normalizedMerchant.contains(key) || searchableText.contains(key)
           }),
           let category = enabledCategories.first(where: { $0.id == preferred.preferredCategoryID }) {
            return category
        }

        // 2) Merchant/entity strong routing first (higher precision than raw OCR noise).
        if let merchantDirect = merchantStrongCategoryName(from: normalizedMerchant),
           let category = resolveCategory(named: merchantDirect, in: enabledCategories) {
            return category
        }

        if let merchantSceneDirect = directCategoryName(from: normalizedMerchant),
           let category = resolveCategory(named: merchantSceneDirect, in: enabledCategories) {
            return category
        }

        // 3) Global scene routing from merged searchable text.
        if let directCategoryName = directCategoryName(from: searchableText),
           let category = resolveCategory(named: directCategoryName, in: enabledCategories) {
            return category
        }

        // 4) Suggested category name with alias bridge (e.g. 数码 -> 日用).
        let suggestedCandidates = mappedCategoryCandidates(from: normalizedSuggested)
        for candidate in suggestedCandidates {
            if let category = enabledCategories.first(where: { normalize($0.name) == candidate }) {
                return category
            }
        }

        // 5) Local weighted scoring from merchant + rawText + suggestedCategory.
        var best: (category: Category, score: Int)?
        for category in enabledCategories where normalize(category.name) != normalize("其他") {
            let categoryName = normalize(category.name)
            var score = 0

            if suggestedCandidates.contains(categoryName) {
                score += 14
            }
            if !categoryName.isEmpty, searchableText.contains(categoryName) {
                score += 10
            }

            for keyword in category.keywords {
                let normalizedKeyword = normalize(keyword)
                guard normalizedKeyword.count >= 2 else { continue }
                if normalizedMerchant.contains(normalizedKeyword) {
                    score += 12 + min(4, normalizedKeyword.count / 3)
                } else if searchableText.contains(normalizedKeyword) {
                    score += 8 + min(4, normalizedKeyword.count / 3)
                }
            }

            for hint in builtinHints(for: categoryName) {
                let normalizedHint = normalize(hint)
                if normalizedMerchant.contains(normalizedHint) {
                    score += 10
                } else if searchableText.contains(normalizedHint) {
                    score += 6
                }
            }

            switch draft.channel {
            case .wechat, .alipay:
                if categoryName == "餐饮" || categoryName == "交通" || categoryName == "日用" {
                    score += 1
                }
            case .bankCard:
                if categoryName == "住房" || categoryName == "学习" {
                    score += 1
                }
            case .cash, .unknown:
                break
            }

            if score > (best?.score ?? 0) {
                best = (category, score)
            }
        }

        if let best, best.score >= 6 {
            return best.category
        }

        return enabledCategories.first(where: { normalize($0.name) == normalize("其他") }) ?? enabledCategories.first
    }

    private func resolveCategory(named categoryName: String, in categories: [Category]) -> Category? {
        let candidates = mappedCategoryCandidates(from: normalize(categoryName))
        for candidate in candidates {
            if let category = categories.first(where: { normalize($0.name) == candidate }) {
                return category
            }
        }
        return nil
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(
                of: #"[^\p{Han}a-z0-9]+"#,
                with: "",
                options: .regularExpression
            )
    }

    private func isUnknownMerchant(_ normalizedMerchant: String) -> Bool {
        normalizedMerchant.isEmpty || normalizedMerchant == normalize("未识别商户")
    }

    private func mappedCategoryCandidates(from normalizedSuggested: String) -> [String] {
        guard !normalizedSuggested.isEmpty else { return [] }

        let aliases: [String: [String]] = [
            "数码": ["日用", "通讯"],
            "美妆": ["日用"],
            "食品": ["餐饮"],
            "购物": ["日用"],
            "订阅": ["娱乐", "通讯"],
            "服饰": ["日用"],
            "母婴": ["日用"],
            "宠物": ["日用"],
            "办公": ["日用", "学习"]
        ]

        var result: [String] = []
        var seen = Set<String>()
        func append(_ item: String) {
            guard !item.isEmpty, !seen.contains(item) else { return }
            seen.insert(item)
            result.append(item)
        }

        append(normalizedSuggested)
        for alias in aliases[normalizedSuggested] ?? [] {
            append(normalize(alias))
        }
        return result
    }

    private func builtinHints(for normalizedCategoryName: String) -> [String] {
        switch normalizedCategoryName {
        case "餐饮":
            return ["买菜", "菜", "咖啡", "奶茶", "可乐", "雪碧", "芬达", "外卖", "餐", "饭", "早餐", "午餐", "晚餐", "夜宵", "瑞幸", "星巴克", "麦当劳", "肯德基", "海底捞", "火锅", "烧烤", "零食", "水果", "蔬菜", "猪肉", "鸡肉", "牛肉", "海鲜"]
        case "交通":
            return ["打车", "滴滴", "地铁", "公交", "机票", "高铁", "火车", "停车", "加油", "过路费"]
        case "日用":
            return ["超市", "便利店", "日用品", "生活用品", "购物", "商超", "盒马", "河马", "山姆", "沃尔玛", "永辉", "胖东来", "开市客", "costco", "手机", "电脑", "平板", "衣服", "鞋", "化妆品", "猫粮", "狗粮"]
        case "娱乐":
            return ["电影", "游戏", "手柄", "演出", "门票", "会员", "订阅", "腾讯视频", "爱奇艺", "优酷", "网易云", "qq音乐", "篮球", "足球", "羽毛球", "网球", "健身", "运动"]
        case "医疗":
            return ["医院", "药店", "门诊", "体检", "挂号", "药费"]
        case "住房":
            return ["订酒店", "酒店", "住宿", "房费", "民宿", "宾馆", "房租", "物业", "水费", "电费", "燃气", "家政"]
        case "通讯":
            return ["话费", "流量", "宽带", "通信", "网费"]
        case "学习":
            return ["课程", "培训", "书店", "书", "教材", "考试"]
        default:
            return []
        }
    }

    private func directCategoryName(from searchableText: String) -> String? {
        let rules: [(String, [String])] = [
            ("交通", ["机票", "高铁", "火车", "动车", "车票", "打车", "滴滴", "地铁", "公交", "停车", "加油", "过路费"]),
            ("住房", ["订酒店", "酒店", "住宿", "房费", "民宿", "宾馆", "房租", "物业"]),
            ("餐饮", ["买菜", "菜", "外卖", "早餐", "午餐", "晚餐", "夜宵", "奶茶", "咖啡", "可乐", "雪碧", "芬达", "水果", "蔬菜", "猪肉", "鸡肉", "牛肉", "海鲜", "海底捞", "餐", "饭"]),
            ("娱乐", ["会员", "订阅", "篮球", "足球", "羽毛球", "网球", "健身", "运动", "电影", "游戏", "手柄", "门票", "演出"]),
            ("医疗", ["医院", "药店", "门诊", "体检", "挂号", "药费"]),
            ("通讯", ["话费", "流量", "宽带", "网费"]),
            ("学习", ["课程", "培训", "书店", "教材", "考试"]),
            ("购物", ["购物", "商超", "盒马", "河马", "山姆", "沃尔玛", "永辉", "胖东来", "开市客", "costco"]),
            ("日用", ["衣服", "裤子", "鞋", "外套", "包包", "超市", "便利店", "日用品", "化妆品", "护肤", "猫粮", "狗粮"])
        ]

        for (category, hints) in rules {
            if hints.contains(where: { searchableText.contains(normalize($0)) }) {
                return category
            }
        }
        return nil
    }

    private func merchantStrongCategoryName(from normalizedText: String) -> String? {
        guard !normalizedText.isEmpty else { return nil }
        let rules: [(String, [String])] = [
            ("餐饮", ["麦当劳", "肯德基", "瑞幸", "星巴克", "喜茶", "奈雪", "蜜雪冰城", "海底捞", "外卖"]),
            ("交通", ["滴滴", "12306", "国航", "东航", "南航", "春秋航空", "携程", "飞猪", "同程", "去哪儿"]),
            ("住房", ["丽思卡尔顿", "万豪", "希尔顿", "洲际", "亚朵", "全季", "汉庭", "如家", "酒店", "民宿"]),
            ("日用", ["盒马", "河马", "山姆", "山母", "沃尔玛", "永辉", "胖东来", "开市客", "costco", "淘宝", "天猫", "京东", "拼多多", "抖音"]),
            ("娱乐", ["steam", "epic", "playstation", "xbox", "switch", "腾讯视频", "爱奇艺", "优酷", "网易云", "qq音乐"]),
            ("通讯", ["中国移动", "中国联通", "中国电信", "话费", "宽带", "流量"]),
            ("医疗", ["医院", "药店", "门诊", "体检", "挂号"]),
            ("学习", ["书店", "课程", "培训", "教材", "考试"])
        ]
        for (category, hints) in rules {
            if hints.contains(where: { normalizedText.contains(normalize($0)) }) {
                return category
            }
        }
        return nil
    }
}
