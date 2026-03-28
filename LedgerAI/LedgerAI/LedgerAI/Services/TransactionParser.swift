import Foundation

struct TransactionParser {
    func parse(text: String, occurredAt defaultDate: Date) -> ParseDraft {
        let raw = text
            .replacingOccurrences(of: "￥", with: "¥")
        let lines = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalized = raw
            .replacingOccurrences(of: "\n", with: " ")
            .lowercased()

        let amount = extractAmount(in: normalized, lines: lines) ?? 0
        let merchant = extractMerchant(in: normalized, lines: lines)
        let channel = extractChannel(in: normalized)
        let category = inferCategory(in: normalized)
        let date = extractDate(in: normalized) ?? extractDate(in: raw) ?? defaultDate

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

    private func extractAmount(in text: String, lines: [String]) -> Double? {
        if let screenshotAmount = extractStructuredAmount(from: lines) {
            return screenshotAmount
        }

        let patterns = [
            #"(?:(?:¥|rmb|cny)\s?)(\d+(?:\.\d{1,2})?)"#,
            #"(\d+(?:\.\d{1,2})?)\s?(?:元|块|rmb|cny)"#,
            #"(?:支付|付款|消费|支出|实付|花了|用了|花费)\s?(\d+(?:\.\d{1,2})?)"#
        ]

        for pattern in patterns {
            if let value = firstMatch(for: pattern, in: text), let amount = Double(value) {
                return amount
            }
        }

        // Spoken Chinese number amount, e.g. "花了二百三十一元"
        if let chineseAmount = firstMatch(for: #"(?:支付|付款|消费|支出|花了|用了|花费)?\s*([零〇一二两三四五六七八九十百千万亿点]+)\s*(?:元|块)"#, in: text),
           let value = parseChineseNumber(chineseAmount) {
            return value
        }

        // Alipay/receipt OCR often contains standalone amount like "8.00".
        // Fallback: collect decimal numbers and pick a plausible payment amount.
        let fallbackPattern = #"\b(\d{1,6}(?:\.\d{1,2})?)\b"#
        guard let regex = try? NSRegularExpression(pattern: fallbackPattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        let candidates: [(value: Double, score: Int)] = matches.compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            guard let value = Double(String(text[r])) else { return nil }

            var score = 0
            if value > 0, value < 100000 { score += 1 }
            if value <= 9999 { score += 2 }

            let matchRange = match.range(at: 1)
            let contextStart = max(0, matchRange.location - 28)
            let contextLen = min(text.utf16.count - contextStart, matchRange.length + 56)
            let contextRange = NSRange(location: contextStart, length: contextLen)
            if let cr = Range(contextRange, in: text) {
                let context = String(text[cr])
                let positiveHints = ["交易成功", "支付成功", "实付", "支付", "付款", "金额", "账单详情"]
                let negativeHints = ["积分", "折扣", "优惠", "余额", "尾号", "手续费"]
                if positiveHints.contains(where: { context.contains($0) }) { score += 4 }
                if negativeHints.contains(where: { context.contains($0) }) { score -= 3 }
            }
            return (value, score)
        }
        let plausible = candidates
            .filter { $0.value > 0 && $0.value < 100000 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.value < rhs.value }
                return lhs.score > rhs.score
            }
        return plausible.first?.value
    }

    private func extractAmountValue(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    private func extractStructuredAmount(from lines: [String]) -> Double? {
        guard !lines.isEmpty else { return nil }

        let standalonePattern = #"^(?:¥\s*)?([1-9]\d{0,5}(?:\.\d{1,2})?)$"#
        if let successIndex = lines.firstIndex(where: { $0.contains("交易成功") || $0.contains("支付成功") }) {
            let start = max(0, successIndex - 2)
            let end = min(lines.count - 1, successIndex + 1)
            for index in start...end {
                if let value = firstMatch(for: standalonePattern, in: lines[index]),
                   let amount = Double(value) {
                    return amount
                }
            }
        }

        for line in lines {
            if let value = firstMatch(for: standalonePattern, in: line),
               let amount = Double(value) {
                return amount
            }
        }
        return nil
    }

    private func extractMerchant(in text: String, lines: [String]) -> String {
        if let structured = extractStructuredMerchant(from: lines) {
            return structured
        }

        let candidates = [
            "瑞幸", "luckin", "星巴克", "starbucks", "美团", "饿了么",
            "滴滴", "地铁", "公交", "麦当劳", "肯德基", "便利蜂",
            "京东", "淘宝", "拼多多", "盒马", "7-11", "全家", "罗森"
        ]

        if let found = candidates.first(where: { text.contains($0.lowercased()) || text.contains($0) }) {
            return found
        }

        if let inferred = extractSubjectFromSpokenText(in: text) {
            return inferred
        }

        return "未识别商户"
    }

    private func extractStructuredMerchant(from lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }

        // Prefer Alipay item-description style names because they are often
        // closer to what users want for bookkeeping than payee legal entities.
        if let goods = extractLabeledValue(for: ["商品说明"], in: lines),
           let cleaned = cleanStructuredMerchant(goods) {
            return cleaned
        }
        if let payee = extractLabeledValue(for: ["收款方全称", "收款方", "交易对方"], in: lines),
           let cleaned = cleanStructuredMerchant(payee) {
            return cleaned
        }
        if let merchant = extractLabeledValue(for: ["商户名称", "商户", "商家名称", "商家"], in: lines),
           let cleaned = cleanStructuredMerchant(merchant) {
            return cleaned
        }

        let directPatterns: [String] = [
            #"^扫码付款[_\-]\s*(.+)$"#,
            #"^扫码支付[_\-]\s*(.+)$"#,
            #"^向\s*(.+?)\s*(?:付款|支付)$"#
        ]
        for line in lines {
            for pattern in directPatterns {
                guard let value = firstMatch(for: pattern, in: line),
                      let cleaned = cleanStructuredMerchant(value) else { continue }
                return cleaned
            }
        }

        if let amountIndex = lines.firstIndex(where: { extractAmountValue($0) != nil }), amountIndex > 0 {
            let candidate = lines[amountIndex - 1]
            if let cleaned = cleanStructuredMerchant(candidate) {
                return cleaned
            }
        }
        return nil
    }

    private func cleanStructuredMerchant(_ value: String) -> String? {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let matched = firstMatch(for: #"(?:扫码付款|扫码支付|支付给)[_\-\s]*(.+)$"#, in: result) {
            result = matched
        }
        if result.contains("_"), let last = result.split(separator: "_").last {
            result = String(last)
        }
        if result.contains("-"), let last = result.split(separator: "-").last,
           (result.hasPrefix("扫码付款") || result.hasPrefix("扫码支付")) {
            result = String(last)
        }

        let junkWords = [
            "交易成功", "账单详情", "全部账单", "支付宝", "微信", "更多",
            "收单机构", "清算机构", "账单管理", "账单分类", "标签", "支付方式"
        ]
        if junkWords.contains(where: { result.contains($0) }) {
            return nil
        }

        result = result
            .replacingOccurrences(of: "扫码付款", with: "")
            .replacingOccurrences(of: "扫码支付", with: "")
            .replacingOccurrences(of: "支付给", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.count < 2 { return nil }
        if result.count > 24 { result = String(result.prefix(24)) }
        return result
    }

    private func extractLabeledValue(for labels: [String], in lines: [String]) -> String? {
        guard !labels.isEmpty else { return nil }

        for (index, line) in lines.enumerated() {
            let compact = line.replacingOccurrences(of: " ", with: "")
            for label in labels {
                guard compact.hasPrefix(label) else { continue }

                let remainder = compact
                    .dropFirst(label.count)
                    .drop(while: { $0 == ":" || $0 == "：" })
                let inline = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inline.isEmpty {
                    return inline
                }

                if index + 1 < lines.count {
                    let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if isLikelyValueLine(next) {
                        return next
                    }
                }
            }
        }
        return nil
    }

    private func isLikelyValueLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        if line.contains("：") || line.contains(":") { return false }
        let labelHints = [
            "支付时间", "交易时间", "付款方式", "收单机构", "清算机构",
            "账单分类", "账单管理", "标签", "备注", "计入收支"
        ]
        if labelHints.contains(where: { line.contains($0) }) { return false }
        return true
    }

    private func extractSubjectFromSpokenText(in text: String) -> String? {
        let patterns = [
            #"(?:我)?(?:买了|买|购买了|购买|吃了|点了|喝了)\s*([\p{Han}A-Za-z0-9·]{1,24}?)(?:花了|用了|消费|支付|付款|支出|共|总共|\d)"#,
            #"(?:我在|在)\s*([\p{Han}A-Za-z0-9·]{2,24}?)(?:消费了|消费|付款了|付款|支付了|支付|花了|用了)"#,
            #"(?:今天|刚刚|刚才)?(?:在)?([\p{Han}A-Za-z0-9·]{2,24}?)(?:消费了|消费|付款了|付款|支付了|支付)"#,
            #"([\p{Han}A-Za-z0-9·]{2,24}?)(?:花费了|花了|用了|消费了|支付了|付款了)\s*(?:\d+(?:\.\d{1,3})?|[零〇一二两三四五六七八九十百千万亿点]+)\s*(?:元|块|rmb|cny)?"#
        ]

        for pattern in patterns {
            guard let raw = firstMatch(for: pattern, in: text) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleaned = cleanExtractedSubject(trimmed), !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    private func cleanExtractedSubject(_ value: String) -> String? {
        var result = value
        let banWords = [
            "今天", "刚刚", "刚才", "我在", "我", "在", "花了", "用了", "消费", "支付", "付款",
            "支出", "总共", "共", "买了", "买", "购买", "购买了", "吃了", "点了", "喝了",
            "元", "块"
        ]
        banWords.forEach { word in
            result = result.replacingOccurrences(of: word, with: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.count < 2 { return nil }
        if result.count > 16 { return String(result.prefix(16)) }
        return result
    }

    private func parseChineseNumber(_ raw: String) -> Double? {
        let s = raw
            .replacingOccurrences(of: "〇", with: "零")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if s.contains("点") {
            let parts = s.split(separator: "点", maxSplits: 1).map(String.init)
            guard let integerPart = parseChineseInteger(parts[0]) else { return nil }
            let decimalMap: [Character: Int] = [
                "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
            ]
            var decimal = 0.0
            if parts.count > 1 {
                let chars = Array(parts[1])
                for (i, c) in chars.enumerated() {
                    guard let digit = decimalMap[c] else { continue }
                    decimal += Double(digit) / pow(10.0, Double(i + 1))
                }
            }
            return Double(integerPart) + decimal
        }

        if let value = parseChineseInteger(s) {
            return Double(value)
        }
        return nil
    }

    private func parseChineseInteger(_ raw: String) -> Int? {
        let digitMap: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let unitMap: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
        let sectionUnitMap: [Character: Int] = ["万": 10000, "亿": 100000000]

        var total = 0
        var section = 0
        var number = 0
        var hasAny = false

        for c in raw {
            if let digit = digitMap[c] {
                number = digit
                hasAny = true
                continue
            }
            if let unit = unitMap[c] {
                hasAny = true
                let n = number == 0 ? 1 : number
                section += n * unit
                number = 0
                continue
            }
            if let sectionUnit = sectionUnitMap[c] {
                hasAny = true
                section += number
                total += section * sectionUnit
                section = 0
                number = 0
                continue
            }
        }

        if !hasAny { return nil }
        return total + section + number
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
