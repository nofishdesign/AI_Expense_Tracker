import Foundation

enum PaymentTextSanitizer {
    static func paymentOnlyText(from raw: String, source: InputSourceType) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "￥", with: "¥")

        let lines = normalized
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard source == .screenshot else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let keywords = [
            "支付", "付款", "实付", "金额", "收款方", "商户", "交易时间", "支付时间", "创建时间",
            "订单", "交易号", "订单号", "支付宝", "alipay", "微信", "银行卡", "付款方式", "转账",
            "二维码", "账单", "商品说明", "成功", "已支付"
        ]
        let anchorKeywords = [
            "账单详情", "交易成功", "支付成功", "商品说明", "收款方", "支付时间", "交易时间", "付款方式"
        ]

        let amountPattern = #"(?:(?:¥|rmb|cny)\s?\d+(?:\.\d{1,2})?)|(?:\d+(?:\.\d{1,2})?\s?(?:元|块))"#
        let standaloneAmountPattern = #"^(?:¥\s*)?\d+(?:\.\d{1,2})?$"#
        let regex = try? NSRegularExpression(pattern: amountPattern, options: .caseInsensitive)
        let standaloneRegex = try? NSRegularExpression(pattern: standaloneAmountPattern, options: .caseInsensitive)

        var includeIndexes = Set<Int>()
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            if anchorKeywords.contains(where: { lower.contains($0.lowercased()) }) {
                includeIndexes.insert(index)
                includeIndexes.insert(index - 1)
                includeIndexes.insert(index + 1)
            }
        }

        let filtered = lines.enumerated().compactMap { index, line -> String? in
            let lower = line.lowercased()
            let hasKeyword = keywords.contains(where: { lower.contains($0.lowercased()) })
            let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            let hasAmount = regex?.firstMatch(in: lower, options: [], range: range) != nil
            let hasStandaloneAmount = standaloneRegex?.firstMatch(in: lower, options: [], range: range) != nil
            let includedByAnchor = includeIndexes.contains(index)
            return (hasKeyword || hasAmount || hasStandaloneAmount || includedByAnchor) ? line : nil
        }

        if filtered.isEmpty {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return filtered.joined(separator: "\n")
    }
}
