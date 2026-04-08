import Foundation

enum PaymentTextSanitizer {
    static func paymentOnlyText(from raw: String, source: InputSourceType) -> String {
        let normalized = normalizeRawText(raw)
        let trimmedNormalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNormalized.isEmpty else { return "" }

        let lines = trimmedNormalized
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard source == .screenshot else {
            return trimmedNormalized
        }

        let profile = detectScreenshotProfile(in: trimmedNormalized)
        let rule = profileRule(for: profile)

        let amountPattern = #"(?:(?:¥|rmb|cny)\s?[+-]?[\d,，]+(?:\.\d{1,2})?)|(?:[+-]?[\d,，]+(?:\.\d{1,2})?\s?(?:元|块))"#
        let standaloneAmountPattern = #"^[+-]?(?:¥\s*)?\d+(?:\.\d{1,2})?$"#
        let regex = try? NSRegularExpression(pattern: amountPattern, options: .caseInsensitive)
        let standaloneRegex = try? NSRegularExpression(pattern: standaloneAmountPattern, options: .caseInsensitive)

        var includeIndexes = Set<Int>()
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            if rule.anchorKeywords.contains(where: { lower.contains($0.lowercased()) }) {
                includeRange(center: index, radius: 2, upperBound: lines.count, set: &includeIndexes)
            }

            let lineRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            let hasAmount = regex?.firstMatch(in: lower, options: [], range: lineRange) != nil
                || standaloneRegex?.firstMatch(in: lower, options: [], range: lineRange) != nil
            if hasAmount {
                includeRange(center: index, radius: 1, upperBound: lines.count, set: &includeIndexes)
            }
        }

        let filtered = lines.enumerated().compactMap { index, line -> String? in
            let lower = line.lowercased()
            let hasKeyword = rule.keywords.contains(where: { lower.contains($0.lowercased()) })
            let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            let hasAmount = regex?.firstMatch(in: lower, options: [], range: range) != nil
            let hasStandaloneAmount = standaloneRegex?.firstMatch(in: lower, options: [], range: range) != nil
            let includedByAnchor = includeIndexes.contains(index)
            let nearAnchor = includeIndexes.contains(index - 1) || includeIndexes.contains(index + 1)
            let likelyMerchantOrItem = nearAnchor && isLikelyMerchantOrItemLine(line)
            return (hasKeyword || hasAmount || hasStandaloneAmount || includedByAnchor || likelyMerchantOrItem) ? line : nil
        }

        let deduplicated = deduplicatedLines(filtered)
        if deduplicated.isEmpty {
            return trimmedNormalized
        }
        return deduplicated.joined(separator: "\n")
    }

    private static func detectScreenshotProfile(in text: String) -> ScreenshotProfile {
        let lower = text.lowercased()
        let wechatHints = [
            "微信", "wechat", "财付通", "商家小程序", "交易单号", "商户单号", "当前状态", "对订单有疑惑", "发起群收款"
        ]
        let alipayHints = [
            "支付宝", "alipay", "账单详情", "收款方", "商品说明", "扫码付款", "账单管理", "计入收支"
        ]

        let wechatScore = wechatHints.filter { lower.contains($0.lowercased()) }.count
        let alipayScore = alipayHints.filter { lower.contains($0.lowercased()) }.count

        if wechatScore >= max(2, alipayScore + 1) { return .wechat }
        if alipayScore >= max(2, wechatScore + 1) { return .alipay }
        return .generic
    }

    private static func profileRule(for profile: ScreenshotProfile) -> ScreenshotRule {
        let commonKeywords = [
            "支付", "付款", "实付", "金额", "商户", "交易时间", "支付时间", "创建时间",
            "订单", "交易号", "订单号", "银行卡", "付款方式", "转账",
            "账单", "商品", "项目", "摘要", "用途", "成功", "已支付",
            "总计", "合计", "订单金额", "支付金额", "交易金额", "实付款", "收款账户", "交易对方"
        ]
        let commonAnchors = [
            "账单详情", "交易成功", "支付成功", "支付时间", "交易时间",
            "付款方式", "支付金额", "订单金额", "实付款", "合计", "当前状态"
        ]

        switch profile {
        case .wechat:
            return ScreenshotRule(
                keywords: commonKeywords + [
                    "微信", "wechat", "财付通", "当前状态", "商品", "商户全称",
                    "收单机构", "支付方式", "交易单号", "商户单号", "商家小程序", "本服务由财付通提供"
                ],
                anchorKeywords: commonAnchors + [
                    "当前状态", "商品", "商户全称", "交易单号", "商户单号", "商家小程序"
                ]
            )
        case .alipay:
            return ScreenshotRule(
                keywords: commonKeywords + [
                    "支付宝", "alipay", "收款方", "商品说明", "商品名称", "二维码", "收单机构", "清算机构", "账单管理", "计入收支"
                ],
                anchorKeywords: commonAnchors + [
                    "商品说明", "收款方", "交易对方", "收单机构", "清算机构"
                ]
            )
        case .generic:
            return ScreenshotRule(
                keywords: commonKeywords + [
                    "支付宝", "alipay", "微信", "wechat", "收款方", "商品说明", "商品名称", "二维码",
                    "收单机构", "清算机构", "当前状态", "商户全称", "交易单号", "商户单号"
                ],
                anchorKeywords: commonAnchors + [
                    "商品说明", "收款方", "交易对方", "商户全称", "交易单号", "商户单号"
                ]
            )
        }
    }

    private static func normalizeRawText(_ raw: String) -> String {
        let halfWidth = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        let normalized = halfWidth
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "￥", with: "¥")

        return normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { normalizeOCRLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func normalizeOCRLine(_ line: String) -> String {
        var normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return normalized }

        normalized = normalized
            .replacingOccurrences(of: #"(?<=\d)\s+(?=\d)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=¥)\s+(?=\d)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        if isMostlyNumericLine(normalized) {
            normalized = normalized
                .replacingOccurrences(of: "O", with: "0")
                .replacingOccurrences(of: "o", with: "0")
                .replacingOccurrences(of: "l", with: "1")
                .replacingOccurrences(of: "I", with: "1")
        }
        return normalized
    }

    private static func isMostlyNumericLine(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let numberLike = text.filter { "0123456789¥.,:：- /".contains($0) }.count
        return Double(numberLike) / Double(text.count) > 0.7
    }

    private static func includeRange(center: Int, radius: Int, upperBound: Int, set: inout Set<Int>) {
        guard upperBound > 0 else { return }
        let start = max(0, center - radius)
        let end = min(upperBound - 1, center + radius)
        guard start <= end else { return }
        for idx in start...end {
            set.insert(idx)
        }
    }

    private static func isLikelyMerchantOrItemLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count >= 2 && trimmed.count <= 28 else { return false }
        guard !isLikelyIdentifierLine(trimmed) else { return false }
        guard !isMostlyNumericContent(trimmed) else { return false }

        let rejectKeywords = [
            "交易成功", "支付成功", "账单详情", "付款方式", "支付时间", "交易时间",
            "订单号", "交易号", "收单机构", "清算机构", "账单分类", "标签", "支付宝", "微信"
        ]
        if rejectKeywords.contains(where: { trimmed.contains($0) }) {
            return false
        }

        if trimmed.contains("：") || trimmed.contains(":") {
            return false
        }

        if trimmed.range(of: #"^(?:¥\s*)?\d+(?:\.\d{1,2})?$"#, options: .regularExpression) != nil {
            return false
        }
        if trimmed.range(of: #"\d{2}:\d{2}"#, options: .regularExpression) != nil {
            return false
        }
        if trimmed.range(of: #"20\d{2}[-/年]\d{1,2}[-/月]\d{1,2}"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    private static func isLikelyIdentifierLine(_ raw: String) -> Bool {
        let compact = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        if compact.range(of: #"^\d{10,}$"#, options: .regularExpression) != nil {
            return true
        }
        if compact.range(of: #"[A-Za-z]*\d{10,}[A-Za-z]*"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func isMostlyNumericContent(_ raw: String) -> Bool {
        let compact = raw.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return false }
        let numberLike = compact.filter { "0123456789+-().:：".contains($0) }.count
        return Double(numberLike) / Double(compact.count) > 0.8
    }

    private static func deduplicatedLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                output.append(trimmed)
            }
        }
        return output
    }
}

private enum ScreenshotProfile {
    case wechat
    case alipay
    case generic
}

private struct ScreenshotRule {
    let keywords: [String]
    let anchorKeywords: [String]
}
