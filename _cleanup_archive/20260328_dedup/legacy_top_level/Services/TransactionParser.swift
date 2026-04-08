import Foundation

struct TransactionParser {
    func parse(text: String, occurredAt defaultDate: Date) -> ParseDraft {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "￥", with: "¥")
            .lowercased()

        let amount = extractAmount(in: normalized) ?? 0
        let merchant = extractMerchant(in: normalized)
        let channel = extractChannel(in: normalized)
        let category = inferCategory(in: normalized)
        let date = extractDate(in: normalized) ?? defaultDate

        let amountScore = amount > 0 ? 0.45 : 0.0
        let merchantScore = merchant == "未识别商户" ? 0.05 : 0.25
        let channelScore = channel == .unknown ? 0.05 : 0.15
        let dateScore = 0.1
        let confidence = min(1.0, amountScore + merchantScore + channelScore + dateScore)

        return ParseDraft(
            amountCNY: amount,
            occurredAt: date,
            merchant: merchant,
            channel: channel,
            suggestedCategoryName: category,
            confidence: confidence,
            fieldConfidence: [
                "amount": amount > 0 ? 0.9 : 0.1,
                "merchant": merchant == "未识别商户" ? 0.2 : 0.85,
                "channel": channel == .unknown ? 0.25 : 0.8,
                "date": 0.75
            ]
        )
    }

    private func extractAmount(in text: String) -> Double? {
        let patterns = [
            #"(?:(?:¥|rmb|cny)\s?)(\d+(?:\.\d{1,2})?)"#,
            #"(\d+(?:\.\d{1,2})?)\s?(?:元|块|rmb|cny)"#,
            #"(?:支付|付款|消费|支出|实付)\s?(\d+(?:\.\d{1,2})?)"#
        ]

        for pattern in patterns {
            if let value = firstMatch(for: pattern, in: text), let amount = Double(value) {
                return amount
            }
        }
        return nil
    }

    private func extractMerchant(in text: String) -> String {
        let candidates = [
            "瑞幸", "luckin", "星巴克", "starbucks", "美团", "饿了么",
            "滴滴", "地铁", "公交", "麦当劳", "肯德基", "便利蜂",
            "京东", "淘宝", "拼多多", "盒马", "7-11", "全家", "罗森"
        ]

        if let found = candidates.first(where: { text.contains($0.lowercased()) || text.contains($0) }) {
            return found
        }
        return "未识别商户"
    }

    private func extractChannel(in text: String) -> PaymentChannel {
        if text.contains("微信") || text.contains("wechat") { return .wechat }
        if text.contains("支付宝") || text.contains("alipay") { return .alipay }
        if text.contains("银行卡") || text.contains("信用卡") || text.contains("借记卡") { return .bankCard }
        if text.contains("现金") { return .cash }
        return .unknown
    }

    private func inferCategory(in text: String) -> String {
        let mapping: [(String, [String])] = [
            ("餐饮", ["咖啡", "奶茶", "外卖", "餐", "麦当劳", "肯德基", "瑞幸", "星巴克"]),
            ("交通", ["地铁", "公交", "打车", "滴滴", "加油", "停车"]),
            ("日用", ["超市", "便利店", "日用品", "生活用品"]),
            ("娱乐", ["电影", "游戏", "演出", "ktv", "娱乐"]),
            ("医疗", ["医院", "药店", "门诊", "体检"]),
            ("通讯", ["话费", "流量", "宽带", "通信"]),
            ("学习", ["课程", "书店", "培训", "学习"]),
            ("住房", ["房租", "物业", "水电", "燃气"])
        ]

        for (category, keywords) in mapping {
            if keywords.contains(where: { text.contains($0.lowercased()) || text.contains($0) }) {
                return category
            }
        }
        return "其他"
    }

    private func extractDate(in text: String) -> Date? {
        if let parts = captureGroups(for: #"(20\d{2})[-/](\d{1,2})[-/](\d{1,2})"#, in: text),
           let year = Int(parts[safe: 0] ?? ""),
           let month = Int(parts[safe: 1] ?? ""),
           let day = Int(parts[safe: 2] ?? "") {
            return date(year: year, month: month, day: day)
        }

        if let parts = captureGroups(for: #"(\d{1,2})月(\d{1,2})日"#, in: text),
           let month = Int(parts[safe: 0] ?? ""),
           let day = Int(parts[safe: 1] ?? "") {
            let year = Calendar.current.component(.year, from: .now)
            return date(year: year, month: month, day: day)
        }
        return nil
    }

    private func firstMatch(for pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        let captureRange = result.numberOfRanges > 1 ? result.range(at: 1) : result.range
        guard let swiftRange = Range(captureRange, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func captureGroups(for pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range), result.numberOfRanges > 1 else {
            return nil
        }
        return (1..<result.numberOfRanges).compactMap { index in
            guard let swiftRange = Range(result.range(at: index), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func date(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
