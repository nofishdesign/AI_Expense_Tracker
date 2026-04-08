import Foundation

struct TransactionParser {
    func parse(text: String, occurredAt defaultDate: Date) -> ParseDraft {
        let raw = normalizeCommonSpeechTerms(in: text)
            .replacingOccurrences(of: "￥", with: "¥")
        let spokenNormalizedRaw = normalizeSpokenAmountPhrases(in: raw)
        let lines = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedForAmount = spokenNormalizedRaw
            .replacingOccurrences(of: "\n", with: " ")
            .lowercased()
        let normalizedForEntity = raw
            .replacingOccurrences(of: "\n", with: " ")
            .lowercased()
        let statementProvider = detectStatementProvider(in: normalizedForEntity, lines: lines)

        let amount = extractAmount(in: normalizedForAmount, lines: lines, provider: statementProvider) ?? 0
        let merchant = extractMerchant(in: normalizedForEntity, lines: lines, provider: statementProvider)
        let channel = extractChannel(in: normalizedForEntity, lines: lines, provider: statementProvider)
        let category = inferCategory(in: normalizedForEntity)
        let date = extractDate(in: normalizedForEntity) ?? extractDate(in: raw) ?? defaultDate

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

    private func extractAmount(in text: String, lines: [String], provider: StatementProvider) -> Double? {
        if let screenshotAmount = extractStructuredAmount(from: lines, provider: provider) {
            return screenshotAmount
        }

        if let largeUnitAmount = extractLargeUnitAmount(in: text) {
            return largeUnitAmount
        }

        if let spokenAmount = extractSpokenAmount(in: text) {
            return spokenAmount
        }

        let groupedNumberPattern = #"[+-]?(?:\d{1,3}(?:[,\s，]\d{3})+|\d+)(?:\.\d{1,2})?"#
        let patterns = [
            #"(?:(?:¥|rmb|cny)\s?)(\#(groupedNumberPattern))"#,
            #"(\#(groupedNumberPattern))\s?(?:元|块|rmb|cny)"#,
            #"(?:支付|付款|消费|支出|实付|花了|用了|花费)\s?(\#(groupedNumberPattern))"#
        ]

        for pattern in patterns {
            if let value = firstMatch(for: pattern, in: text),
               let amount = parseAmountToken(value) {
                return abs(amount)
            }
        }

        // Spoken Chinese number amount, e.g. "花了二百三十一元"
        if let chineseAmount = firstMatch(for: #"(?:支付|付款|消费|支出|花了|用了|花费)?\s*([零〇一二两三四五六七八九十百千万亿点]+)\s*(?:元|块)"#, in: text),
           let value = parseChineseNumber(chineseAmount) {
            return value
        }

        // Spoken amount without explicit currency unit, e.g. "肯德基三十一", "麦当劳十五".
        if let implicitChineseAmount = extractImplicitChineseAmount(in: text) {
            return implicitChineseAmount
        }

        // Alipay/receipt OCR often contains standalone amount like "8.00".
        // Fallback: collect decimal numbers and pick a plausible payment amount.
        let fallbackPattern = #"(?<!\d)([+-]?(?:\d{1,3}(?:[,\s，]\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: fallbackPattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        let candidates: [(value: Double, score: Int)] = matches.compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            guard let value = parseAmountToken(String(text[r])) else { return nil }

            var score = 0
            let absValue = abs(value)
            if absValue > 0, absValue < 100_000_000 { score += 1 }
            if absValue <= 9_999 { score += 2 }
            else if absValue <= 1_000_000 { score += 1 }

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
                if provider == .wechat, ["交易单号", "商户单号", "当前状态", "商户全称"].contains(where: { context.contains($0) }) {
                    score += 2
                }
            }
            return (absValue, score)
        }
        let plausible = candidates
            .filter { $0.value > 0 && $0.value < 100_000_000 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.value < rhs.value }
                return lhs.score > rhs.score
            }
        return plausible.first?.value
    }

    private func extractImplicitChineseAmount(in text: String) -> Double? {
        let patterns = [
            #"(?:花了|用了|消费|支付|付款|支出|共|总共)?\s*([零〇一二两三四五六七八九十百千万亿点]{2,12})(?:$|[\s，,。；;])"#,
            #"[\p{Han}A-Za-z]{2,20}\s*([零〇一二两三四五六七八九十百千万亿点]{2,12})(?:$|[\s，,。；;])"#
        ]

        for pattern in patterns {
            guard let token = firstMatch(for: pattern, in: text) else { continue }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["一点", "一些", "一点点"].contains(trimmed) { continue }
            guard let value = parseChineseNumber(trimmed) else { continue }
            if value > 0 && value < 100_000_000 {
                return value
            }
        }
        return nil
    }

    private func extractLargeUnitAmount(in text: String) -> Double? {
        let unitPatterns: [(String, Double)] = [
            (#"(?:花了|用了|消费|支付|付款|支出|共|总共|实付)?\s*(\d+(?:\.\d{1,2})?)\s*万(?:元|块|rmb|cny)?"#, 10_000),
            (#"(?:花了|用了|消费|支付|付款|支出|共|总共|实付)?\s*(\d+(?:\.\d{1,2})?)\s*千(?:元|块|rmb|cny)?"#, 1_000)
        ]
        for (pattern, multiplier) in unitPatterns {
            if let raw = firstMatch(for: pattern, in: text),
               let base = Double(raw) {
                return base * multiplier
            }
        }

        if let colloquial = parseColloquialChineseAmount(in: text) {
            return colloquial
        }
        return nil
    }

    private func extractSpokenAmount(in text: String) -> Double? {
        if let parts = captureGroups(for: #"(\d{1,9})\s*(?:元|块)\s*(\d{1,2})\s*(?:角|毛)(?:\s*(\d{1,2})\s*分)?"#, in: text),
           let yuan = Double(parts[safe: 0] ?? ""),
           let jiao = Double(parts[safe: 1] ?? "") {
            let fen = Double(parts[safe: 2] ?? "") ?? 0
            return yuan + min(jiao, 9) / 10 + min(fen, 9) / 100
        }

        if let parts = captureGroups(for: #"(\d{1,9})\s*(?:元|块)\s*(\d{1,2})\s*分"#, in: text),
           let yuan = Double(parts[safe: 0] ?? ""),
           let fen = Double(parts[safe: 1] ?? "") {
            return yuan + min(fen, 99) / 100
        }

        if let parts = captureGroups(for: #"(\d{1,9})\s*(?:元|块)\s*(\d)(?=$|[\s，,。])"#, in: text),
           let yuan = Double(parts[safe: 0] ?? ""),
           let jiao = Double(parts[safe: 1] ?? "") {
            return yuan + jiao / 10
        }

        if let parts = captureGroups(for: #"([零〇一二两三四五六七八九十百千万亿点]+)\s*(?:元|块)\s*([零〇一二两三四五六七八九十])\s*(?:角|毛)?(?:\s*([零〇一二两三四五六七八九十])\s*分)?"#, in: text),
           let yuan = parseChineseNumber(parts[safe: 0] ?? ""),
           let jiaoDigit = chineseSingleDigit(parts[safe: 1] ?? "") {
            let fenDigit = chineseSingleDigit(parts[safe: 2] ?? "") ?? 0
            return yuan + Double(jiaoDigit) / 10 + Double(fenDigit) / 100
        }

        return nil
    }

    private func parseColloquialChineseAmount(in text: String) -> Double? {
        if let parts = captureGroups(for: #"([一二两三四五六七八九])万([一二两三四五六七八九])千([一二两三四五六七八九])?"#, in: text),
           let w = chineseSingleDigit(parts[safe: 0] ?? ""),
           let k = chineseSingleDigit(parts[safe: 1] ?? "") {
            let h = chineseSingleDigit(parts[safe: 2] ?? "") ?? 0
            return Double(w * 10_000 + k * 1_000 + h * 100)
        }

        // "两万三" -> 23000, "三千八" -> 3800
        if let parts = captureGroups(for: #"([一二两三四五六七八九])万([一二两三四五六七八九])(?!(?:千|百|十))"#, in: text),
           let w = chineseSingleDigit(parts[safe: 0] ?? ""),
           let k = chineseSingleDigit(parts[safe: 1] ?? "") {
            return Double(w * 10_000 + k * 1_000)
        }
        if let parts = captureGroups(for: #"([一二两三四五六七八九])千([一二两三四五六七八九])(?!(?:百|十))"#, in: text),
           let k = chineseSingleDigit(parts[safe: 0] ?? ""),
           let h = chineseSingleDigit(parts[safe: 1] ?? "") {
            return Double(k * 1_000 + h * 100)
        }

        if let parts = captureGroups(for: #"(\d{1,4})万(\d)(?!\d)"#, in: text),
           let w = Int(parts[safe: 0] ?? ""),
           let k = Int(parts[safe: 1] ?? "") {
            return Double(w * 10_000 + k * 1_000)
        }
        if let parts = captureGroups(for: #"(\d{1,4})千(\d)(?!\d)"#, in: text),
           let k = Int(parts[safe: 0] ?? ""),
           let h = Int(parts[safe: 1] ?? "") {
            return Double(k * 1_000 + h * 100)
        }

        return nil
    }

    private func extractAmountValue(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: "块", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    private func extractStructuredAmount(from lines: [String], provider: StatementProvider) -> Double? {
        guard !lines.isEmpty else { return nil }

        if provider == .wechat, let topAmount = extractWeChatTopAmount(from: lines) {
            return topAmount
        }

        if let labeled = extractLabeledAmount(from: lines, provider: provider) {
            return labeled
        }

        if let successIndex = lines.firstIndex(where: { $0.contains("交易成功") || $0.contains("支付成功") }) {
            let start = max(0, successIndex - 2)
            let end = min(lines.count - 1, successIndex + 2)
            for index in start...end {
                if let amount = extractStandaloneAmount(from: lines[index]) {
                    return amount
                }
            }
        }

        var candidates: [(amount: Double, score: Int, index: Int)] = []
        for (index, line) in lines.enumerated() {
            guard let amount = extractStandaloneAmount(from: line) else { continue }

            var score = 0
            if line.contains("¥") { score += 2 }
            if index < 4 { score += 1 }
            let contextStart = max(0, index - 2)
            let contextEnd = min(lines.count - 1, index + 2)
            if contextStart <= contextEnd {
                for i in contextStart...contextEnd {
                    let context = lines[i]
                    if context.contains("交易成功") || context.contains("支付成功") {
                        score += 4
                    }
                    if context.contains("实付") || context.contains("支付金额") || context.contains("交易金额")
                        || context.contains("订单金额") || context.contains("合计") || context.contains("总计") {
                        score += 3
                    }
                    if context.contains("优惠") || context.contains("折扣") || context.contains("积分")
                        || context.contains("余额") || context.contains("手续费") {
                        score -= 2
                    }
                }
            }
            candidates.append((amount: amount, score: score, index: index))
        }

        return candidates
            .filter { $0.amount > 0 && $0.amount < 100_000_000 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
            .first?.amount
    }

    private func extractWeChatTopAmount(from lines: [String]) -> Double? {
        let maxScan = min(lines.count, 6)
        guard maxScan > 0 else { return nil }
        for index in 0..<maxScan {
            let line = lines[index]
            if let amount = extractStandaloneAmount(from: line) {
                return amount
            }

            if let signed = firstMatch(for: #"^[+-]\s*(\d{1,9}(?:\.\d{1,2})?)$"#, in: line),
               let value = extractAmountValue(signed) {
                return abs(value)
            }
        }
        return nil
    }

    private func extractLabeledAmount(from lines: [String], provider: StatementProvider) -> Double? {
        let labels = amountLabels(for: provider)
        let escaped = labels
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let inlinePattern = #"(?:\#(escaped))\s*[:：]?\s*(?:¥\s*)?([+-]?\d{1,8}(?:[,\s，]\d{3})*(?:\.\d{1,2})?)"#

        for (index, line) in lines.enumerated() {
            if let parts = captureGroups(for: inlinePattern, in: line),
               let value = parts[safe: 1],
               let amount = extractAmountValue(value) {
                return abs(amount)
            }

            let compact = line.replacingOccurrences(of: " ", with: "")
            if labels.contains(where: { compact == $0 || compact == "\($0):" || compact == "\($0)：" }) {
                if index + 1 < lines.count, let nextAmount = extractStandaloneAmount(from: lines[index + 1]) {
                    return nextAmount
                }
            }
        }
        return nil
    }

    private func extractStandaloneAmount(from line: String) -> Double? {
        let patterns = [
            #"^[+-]?(?:¥\s*)?([1-9]\d{0,8}(?:[,\s，]\d{3})*(?:\.\d{1,2})?)$"#,
            #"^[+-]?(?:¥\s*)?([1-9]\d{0,8}(?:\.\d{1,2})?)\s*(?:元|块)$"#,
            #"^[+-]\s*(\d{1,9}(?:\.\d{1,2})?)$"#
        ]
        for pattern in patterns {
            if let value = firstMatch(for: pattern, in: line),
               let amount = extractAmountValue(value) {
                return abs(amount)
            }
        }
        return nil
    }

    private func amountLabels(for provider: StatementProvider) -> [String] {
        switch provider {
        case .wechat:
            return ["金额", "支付金额", "实付", "实付款", "实际支付", "合计", "总计", "总金额"]
        case .alipay:
            return ["实付", "实付款", "支付金额", "付款金额", "交易金额", "订单金额", "金额", "合计", "总计", "总金额"]
        case .unknown:
            return ["实付", "实付款", "支付金额", "付款金额", "交易金额", "订单金额", "金额", "合计", "总计", "总金额"]
        }
    }

    private func extractMerchant(in text: String, lines: [String], provider: StatementProvider) -> String {
        if let structured = extractStructuredMerchant(from: lines, provider: provider) {
            return structured
        }

        if let spokenItem = extractSubjectFromSpokenText(in: text) {
            return spokenItem
        }

        if let merchantName = extractKnownMerchantOrBrand(in: text) {
            return merchantName
        }

        if let productName = extractKnownProductOrScene(in: text) {
            return productName
        }

        return "未识别商户"
    }

    private func extractKnownMerchantOrBrand(in text: String) -> String? {
        let aliases: [(String, String)] = [
            ("丽思卡尔顿", "丽思卡尔顿"), ("万豪", "万豪"), ("希尔顿", "希尔顿"), ("洲际", "洲际"),
            ("亚朵", "亚朵"), ("全季", "全季"), ("汉庭", "汉庭"), ("如家", "如家"),
            ("国航", "国航"), ("东航", "东航"), ("南航", "南航"), ("春秋航空", "春秋航空"),
            ("厦门航空", "厦门航空"), ("深圳航空", "深圳航空"), ("吉祥航空", "吉祥航空"),
            ("携程", "携程"), ("飞猪", "飞猪"), ("同程", "同程旅行"), ("去哪儿", "去哪儿"),
            ("滴滴", "滴滴"), ("曹操出行", "曹操出行"), ("美团打车", "美团打车"),
            ("铁路12306", "12306"), ("12306", "12306"),
            ("瑞幸", "瑞幸"), ("luckin", "瑞幸"), ("星巴克", "星巴克"), ("starbucks", "星巴克"),
            ("蜜雪冰城", "蜜雪冰城"), ("喜茶", "喜茶"), ("奈雪", "奈雪"),
            ("麦当劳", "麦当劳"), ("肯德基", "肯德基"), ("汉堡王", "汉堡王"), ("海底捞", "海底捞"),
            ("美团", "美团"), ("饿了么", "饿了么"),
            ("淘宝", "淘宝"), ("天猫", "天猫"), ("京东", "京东"), ("拼多多", "拼多多"), ("抖音", "抖音"),
            ("盒马", "盒马"), ("河马", "盒马"), ("山姆", "山姆"), ("山母", "山姆"), ("胖东来", "胖东来"), ("开市客", "开市客"), ("costco", "开市客"), ("沃尔玛", "沃尔玛"), ("永辉", "永辉"),
            ("7-11", "7-11"), ("全家", "全家"), ("罗森", "罗森"),
            ("中国移动", "中国移动"), ("中国联通", "中国联通"), ("中国电信", "中国电信"),
            ("国家电网", "电费"), ("自来水", "水费"), ("燃气", "燃气费"),
            ("apple", "Apple"), ("mac mini", "Mac mini"), ("macbook", "MacBook"), ("ipad", "iPad"), ("iphone", "iPhone"),
            ("chatgpt", "ChatGPT"), ("claude", "Claude"), ("gemini", "Gemini"),
            ("b站", "B站"), ("哔哩哔哩", "B站"), ("腾讯视频", "腾讯视频"), ("爱奇艺", "爱奇艺"), ("优酷", "优酷"), ("网易云", "网易云音乐"), ("qq音乐", "QQ音乐"),
            ("steam", "Steam"), ("epic", "Epic"), ("xbox", "Xbox"), ("playstation", "PlayStation"), ("switch", "Nintendo Switch"),
            ("nike", "Nike"), ("adidas", "Adidas"), ("安踏", "安踏"), ("李宁", "李宁"), ("优衣库", "优衣库"), ("zara", "ZARA"), ("hm", "H&M"),
            ("雅诗兰黛", "雅诗兰黛"), ("兰蔻", "兰蔻"), ("欧莱雅", "欧莱雅"), ("资生堂", "资生堂"), ("海蓝之谜", "海蓝之谜"),
            ("小米", "小米"), ("华为", "华为"), ("荣耀", "荣耀"), ("oppo", "OPPO"), ("vivo", "vivo"), ("联想", "联想"), ("戴尔", "Dell"), ("惠普", "HP"),
            ("顺丰", "顺丰"), ("京东快递", "京东快递"), ("中通", "中通"), ("圆通", "圆通"), ("韵达", "韵达"), ("极兔", "极兔")
        ]
        for (key, value) in aliases.sorted(by: { $0.0.count > $1.0.count }) {
            if text.contains(key.lowercased()) || text.contains(key) {
                return value
            }
        }
        return nil
    }

    private func extractKnownProductOrScene(in text: String) -> String? {
        let keywords = [
            "酒店", "住宿", "房费", "机票", "航班", "高铁票", "火车票", "车票",
            "打车", "地铁", "公交", "停车费", "加油",
            "外卖", "早餐", "午餐", "晚餐", "夜宵", "奶茶", "咖啡", "可乐", "雪碧", "芬达",
            "买菜", "超市", "日用品", "水果", "零食", "购物", "商超", "盒马", "山姆", "胖东来", "开市客",
            "电影票", "演出票", "门票", "健身", "课程", "培训",
            "挂号", "药费", "体检",
            "话费", "网费", "宽带",
            "房租", "物业", "水费", "电费", "燃气费",
            "手机", "电脑", "平板", "耳机", "键盘", "鼠标", "显示器", "充电器", "mac mini", "macbook", "iphone", "ipad", "airpods",
            "口红", "粉底", "面膜", "精华", "乳液", "防晒", "香水", "眼影",
            "牛奶", "面包", "鸡蛋", "蔬菜", "猪肉", "鸡肉", "鱼", "水果拼盘",
            "快餐", "火锅", "烧烤", "中餐", "西餐", "甜品", "饮料", "矿泉水",
            "ai会员", "ai 会员", "会员", "订阅", "token", "tokens", "pro", "plus",
            "游戏", "游戏手柄", "手柄", "点卡", "月卡", "季卡", "年卡", "手办",
            "衣服", "裤子", "鞋", "外套", "羽绒服", "裙子", "帽子", "包包",
            "护肤品", "化妆品", "洗面奶", "卸妆水", "爽肤水", "身体乳",
            "纸巾", "洗衣液", "牙膏", "牙刷", "洗发水", "沐浴露",
            "猫粮", "狗粮", "猫砂", "宠物用品", "玩具", "尿不湿", "奶粉", "婴儿车", "辅食",
            "办公用品", "打印纸", "墨盒", "订书机", "笔记本", "文具",
            "快递费", "运费", "服务费", "手续费"
        ]
        for keyword in keywords.sorted(by: { $0.count > $1.count }) {
            if text.contains(keyword.lowercased()) || text.contains(keyword) {
                switch keyword {
                case "ai会员", "ai 会员", "会员", "订阅": return "AI会员"
                case "tokens": return "token"
                case "pro", "plus": return "会员订阅"
                case "mac mini": return "Mac mini"
                case "macbook": return "MacBook"
                case "iphone": return "iPhone"
                case "ipad": return "iPad"
                case "airpods": return "AirPods"
                default: return keyword
                }
            }
        }
        return nil
    }

    private func extractStructuredMerchant(from lines: [String], provider: StatementProvider) -> String? {
        guard !lines.isEmpty else { return nil }

        if provider == .wechat,
           let wechatHeadline = extractWeChatHeadlineMerchant(from: lines),
           let cleaned = cleanStructuredMerchant(wechatHeadline) {
            return cleaned
        }

        // Prefer Alipay item-description style names because they are often
        // closer to what users want for bookkeeping than payee legal entities.
        if let goods = extractLabeledValue(for: ["商品说明", "商品名称", "商品", "项目名称", "项目", "摘要", "用途"], in: lines),
           let cleaned = cleanStructuredMerchant(goods) {
            return cleaned
        }
        if let payee = extractLabeledValue(for: ["收款方全称", "收款方", "交易对方", "商户全称"], in: lines),
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

        if let nearAmount = extractMerchantNearAmountLine(from: lines) {
            return nearAmount
        }

        if let amountIndex = lines.firstIndex(where: { extractAmountValue($0) != nil }), amountIndex > 0 {
            let candidate = lines[amountIndex - 1]
            if let cleaned = cleanStructuredMerchant(candidate) {
                return cleaned
            }
        }
        return nil
    }

    private func extractWeChatHeadlineMerchant(from lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        let maxScan = min(lines.count, 8)
        guard maxScan > 0 else { return nil }

        let amountIndex = lines.firstIndex(where: { extractStandaloneAmount(from: $0) != nil })
        let end = min((amountIndex ?? maxScan) - 1, maxScan - 1)
        guard end >= 0 else { return nil }

        for index in stride(from: end, through: 0, by: -1) {
            let line = lines[index]
            if isLikelyTopMerchantLine(line) {
                return line
            }
        }
        return nil
    }

    private func isLikelyTopMerchantLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count >= 2 && trimmed.count <= 32 else { return false }
        guard !isLikelyIdentifierLine(trimmed) else { return false }
        guard !isMostlyNumericLine(trimmed) else { return false }
        guard extractStandaloneAmount(from: trimmed) == nil else { return false }

        let rejectKeywords = [
            "微信", "支付", "当前状态", "支付成功", "交易成功", "支付时间",
            "交易单号", "商户单号", "商家小程序", "账单服务", "财付通"
        ]
        if rejectKeywords.contains(where: { trimmed.contains($0) }) { return false }
        if trimmed.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return false }
        if trimmed.range(of: #"\d{2}:\d{2}"#, options: .regularExpression) != nil { return false }

        let hasTextCore = trimmed.range(of: #"[A-Za-z\p{Han}]"#, options: .regularExpression) != nil
        return hasTextCore
    }

    private func extractMerchantNearAmountLine(from lines: [String]) -> String? {
        let amountIndexes = lines.enumerated().compactMap { index, line -> Int? in
            extractStandaloneAmount(from: line) != nil ? index : nil
        }
        guard !amountIndexes.isEmpty else { return nil }

        for amountIndex in amountIndexes {
            let candidates = [amountIndex - 1, amountIndex - 2, amountIndex + 1, amountIndex + 2]
            for index in candidates where lines.indices.contains(index) {
                let line = lines[index]
                guard isLikelyMerchantLine(line), let cleaned = cleanStructuredMerchant(line) else { continue }
                return cleaned
            }
        }
        return nil
    }

    private func isLikelyMerchantLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count >= 2 && trimmed.count <= 28 else { return false }
        if extractStandaloneAmount(from: trimmed) != nil { return false }
        if isLikelyIdentifierLine(trimmed) || isMostlyNumericLine(trimmed) { return false }

        let rejectKeywords = [
            "交易成功", "支付成功", "账单详情", "全部账单", "更多", "支付方式",
            "支付时间", "交易时间", "订单号", "交易号", "交易单号", "商户单号",
            "收单机构", "清算机构", "标签", "账单分类", "本服务由财付通提供"
        ]
        if rejectKeywords.contains(where: { trimmed.contains($0) }) { return false }
        if trimmed.contains("：") || trimmed.contains(":") { return false }
        if trimmed.range(of: #"20\d{2}[-/年]\d{1,2}[-/月]\d{1,2}"#, options: .regularExpression) != nil {
            return false
        }
        if trimmed.range(of: #"\d{2}:\d{2}"#, options: .regularExpression) != nil {
            return false
        }
        return true
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

        result = result
            .replacingOccurrences(
                of: #"^(?:商品说明|商品名称|商品|项目名称|项目|摘要|用途|收款方(?:全称)?|交易对方|商户(?:全称|名称)?|商家(?:名称)?)\s*[:：]?\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let junkWords = [
            "交易成功", "账单详情", "全部账单", "支付宝", "微信", "更多",
            "收单机构", "清算机构", "账单管理", "账单分类", "标签", "支付方式",
            "支付时间", "交易时间", "订单号", "交易号", "交易单号", "商户单号", "当前状态"
        ]
        if junkWords.contains(where: { result.contains($0) }) {
            return nil
        }
        if result.contains("¥") { return nil }
        if isLikelyIdentifierLine(result) || isMostlyNumericLine(result) { return nil }

        result = result
            .replacingOccurrences(of: "扫码付款", with: "")
            .replacingOccurrences(of: "扫码支付", with: "")
            .replacingOccurrences(of: "支付给", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.count < 2 { return nil }
        if result.count > 28 { result = String(result.prefix(28)) }
        return result
    }

    private func extractLabeledValue(for labels: [String], in lines: [String]) -> String? {
        guard !labels.isEmpty else { return nil }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            for label in labels {
                let escaped = NSRegularExpression.escapedPattern(for: label)
                let inlinePattern = #"^\s*\#(escaped)\s*[:：]?\s*(.+?)\s*$"#
                if let inline = firstMatch(for: inlinePattern, in: trimmed)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !inline.isEmpty {
                    return inline
                }

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
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= 40 else { return false }
        if extractStandaloneAmount(from: trimmed) != nil { return false }
        if isLikelyIdentifierLine(trimmed) || isMostlyNumericLine(trimmed) { return false }
        if line.contains("：") || line.contains(":") { return false }
        let labelHints = [
            "支付时间", "交易时间", "付款方式", "收单机构", "清算机构",
            "账单分类", "账单管理", "标签", "备注", "计入收支", "交易成功", "支付成功", "账单详情"
        ]
        if labelHints.contains(where: { trimmed.contains($0) }) { return false }
        if trimmed.range(of: #"20\d{2}[-/年]\d{1,2}[-/月]\d{1,2}"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    private func isLikelyIdentifierLine(_ raw: String) -> Bool {
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

    private func isMostlyNumericLine(_ raw: String) -> Bool {
        let compact = raw.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return false }
        let numberLikeCount = compact.filter { "0123456789+-().:：".contains($0) }.count
        return Double(numberLikeCount) / Double(compact.count) > 0.8
    }

    private func extractSubjectFromSpokenText(in text: String) -> String? {
        let patterns = [
            #"(?:我)?(?:买了|买|购买了|购买|吃了|点了|喝了)\s*([\p{Han}A-Za-z0-9·._\-/ ]{1,30}?)(?:[，,、\s]{0,4})(?:花了|用了|消费|支付|付款|支出|共|总共|\d)"#,
            #"(?:我)?(?:订了|预订了|定了|住了|入住了)\s*([\p{Han}A-Za-z0-9·._\-/ ]{1,30}?)(?:[，,、\s]{0,4})(?:花了|用了|消费|支付|付款|支出|共|总共|\d)"#,
            #"(?:我)?(?:买了|订了|定了|出了|下单了)\s*(机票|酒店|高铁票|火车票|车票|门票|课程|保险)(?:[，,、\s]{0,4})(?:花了|用了|消费|支付|付款|支出|共|总共|\d)"#,
            #"(?:我在|在)\s*([\p{Han}A-Za-z0-9·._\-/ ]{2,30}?)(?:消费了|消费|付款了|付款|支付了|支付|花了|用了)"#,
            #"(?:今天|刚刚|刚才)?(?:在)?([\p{Han}A-Za-z0-9·._\-/ ]{2,30}?)(?:消费了|消费|付款了|付款|支付了|支付)"#,
            #"([\p{Han}A-Za-z0-9·._\-/ ]{2,30}?)(?:[，,、\s]{0,4})(?:花费了|花了|用了|消费了|支付了|付款了)\s*(?:\d+(?:\.\d{1,2})?|[零〇一二两三四五六七八九十百千万亿点]+)\s*(?:元|块|rmb|cny)?"#,
            #"(?:我)?(?:充了|充值了|开了|开通了|订了|订阅了)\s*([\p{Han}A-Za-z0-9·._\-/ ]{1,30}?)(?:会员|套餐|pro|plus|年卡|月卡)?(?:[，,、\s]{0,4})(?:花了|用了|消费|支付|付款|支出|共|总共|\d|$)"#,
            #"(?:我)?(?:买了|买|购买了|下单了|入手了)\s*(?:\d+(?:\.\d{1,2})?\s*(?:元|块|rmb|cny)\s*)?([\p{Han}A-Za-z0-9·._\-/ ]{1,30}?)(?:[，,、\s]{0,4})(?:$|花了|用了|消费|支付|付款|支出)"#,
            #"^\s*([\p{Han}A-Za-z0-9·._\-/ ]{1,30}?)\s*(?:¥\s*)?\d+(?:\.\d{1,2})?\s*(?:元|块|rmb|cny)?\s*$"#,
            #"(?:\d+(?:\.\d{1,2})?\s*(?:元|块|rmb|cny)\s*)([\p{Han}A-Za-z0-9·._\-/ ]{1,30}?)(?:$|[，,。])"#
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
            "元", "块", "订了", "预订", "定了", "住了", "入住", "出了", "下单"
        ]
        banWords.forEach { word in
            result = result.replacingOccurrences(of: word, with: "")
        }
        result = result
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "  ", with: " ")

        if let leadingMeasure = firstMatch(for: #"^(?:[一二两三四五六七八九十百千\d]+)(?:只|个|份|瓶|斤|件|条|碗|盒|包|杯|串|根|张)"#, in: result) {
            result = result.replacingOccurrences(of: leadingMeasure, with: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.count < 2 { return nil }
        if result.count > 16 { return String(result.prefix(16)) }
        return result
    }

    private func normalizeSpokenAmountPhrases(in text: String) -> String {
        var result = text
        let lower = text.lowercased()
        if let amount = extractSpokenAmount(in: lower) {
            let replacement = String(format: " %.2f元 ", amount)
            result += replacement
        }
        return result
    }

    private func normalizeCommonSpeechTerms(in text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            ("河马", "盒马"),
            ("山母", "山姆"),
            ("盒马鲜生", "盒马"),
            ("胖东來", "胖东来"),
            ("开市克", "开市客"),
            ("海底牢", "海底捞"),
            ("饿了吗", "饿了么")
        ]
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    private func parseAmountToken(_ token: String) -> Double? {
        let normalized = token
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }

    private func chineseSingleDigit(_ raw: String) -> Int? {
        guard let c = raw.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        let map: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        return map[c]
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

    private func detectStatementProvider(in text: String, lines: [String]) -> StatementProvider {
        let joined = (text + " " + lines.joined(separator: " ")).lowercased()
        let wechatHints = [
            "微信", "wechat", "财付通", "商家小程序", "交易单号", "商户单号", "当前状态", "在此商户的交易", "发起群收款"
        ]
        let alipayHints = [
            "支付宝", "alipay", "账单详情", "收款方", "商品说明", "扫码付款", "账单管理", "计入收支"
        ]
        let wechatScore = wechatHints.filter { joined.contains($0.lowercased()) }.count
        let alipayScore = alipayHints.filter { joined.contains($0.lowercased()) }.count

        if wechatScore >= max(2, alipayScore + 1) { return .wechat }
        if alipayScore >= max(2, wechatScore + 1) { return .alipay }
        return .unknown
    }

    private func extractChannel(in text: String, lines: [String], provider: StatementProvider) -> PaymentChannel {
        if provider == .wechat { return .wechat }
        if provider == .alipay { return .alipay }
        if text.contains("微信") || text.contains("wechat") { return .wechat }
        if text.contains("支付宝") || text.contains("alipay") { return .alipay }
        let joined = lines.joined(separator: " ").lowercased()
        if joined.contains("交易单号") || joined.contains("商户单号") || joined.contains("商家小程序") {
            return .wechat
        }
        if joined.contains("收款方") || joined.contains("商品说明") || joined.contains("账单详情") {
            return .alipay
        }
        if text.contains("银行卡") || text.contains("信用卡") || text.contains("借记卡") { return .bankCard }
        if text.contains("现金") { return .cash }
        return .unknown
    }

    private func inferCategory(in text: String) -> String {
        let mapping: [(String, [String])] = [
            ("餐饮", ["咖啡", "奶茶", "可乐", "雪碧", "芬达", "外卖", "餐", "麦当劳", "肯德基", "瑞幸", "星巴克", "海底捞", "喜茶", "奈雪", "蜜雪冰城", "火锅", "烧烤", "早餐", "午餐", "晚餐", "买菜"]),
            ("交通", ["地铁", "公交", "打车", "滴滴", "加油", "停车"]),
            ("日用", ["超市", "便利店", "日用品", "生活用品", "购物", "商超", "盒马", "山姆", "胖东来", "开市客", "costco", "沃尔玛", "永辉"]),
            ("娱乐", ["电影", "游戏", "手柄", "演出", "ktv", "娱乐"]),
            ("医疗", ["医院", "药店", "门诊", "体检"]),
            ("通讯", ["话费", "流量", "宽带", "通信"]),
            ("学习", ["课程", "书店", "培训", "学习"]),
            ("住房", ["房租", "物业", "水电", "燃气"]),
            ("数码", ["手机", "电脑", "平板", "耳机", "鼠标", "键盘", "显示器", "笔记本", "ipad", "iphone", "mac mini", "macbook", "airpods", "token"]),
            ("美妆", ["口红", "粉底", "面膜", "精华", "乳液", "防晒", "香水", "眼影", "护肤", "彩妆", "化妆品"]),
            ("食品", ["牛奶", "面包", "鸡蛋", "蔬菜", "猪肉", "鸡肉", "水果", "零食", "饮料", "矿泉水"]),
            ("订阅", ["会员", "订阅", "chatgpt", "claude", "gemini", "plus", "pro", "ai会员", "ai 会员", "腾讯视频", "爱奇艺", "优酷", "网易云", "qq音乐"]),
            ("服饰", ["衣服", "裤子", "鞋", "外套", "羽绒服", "裙子", "帽子", "包包", "nike", "adidas", "优衣库", "zara"]),
            ("母婴", ["奶粉", "尿不湿", "婴儿车", "辅食", "母婴"]),
            ("宠物", ["猫粮", "狗粮", "猫砂", "宠物"]),
            ("办公", ["办公用品", "打印纸", "墨盒", "文具", "快递费", "运费"])
        ]

        for (category, keywords) in mapping {
            if keywords.contains(where: { text.contains($0.lowercased()) || text.contains($0) }) {
                return category
            }
        }
        return "其他"
    }

    private func extractDate(in text: String) -> Date? {
        if let parts = captureGroups(for: #"(20\d{2})年(\d{1,2})月(\d{1,2})日"#, in: text),
           let year = Int(parts[safe: 0] ?? ""),
           let month = Int(parts[safe: 1] ?? ""),
           let day = Int(parts[safe: 2] ?? "") {
            return date(year: year, month: month, day: day)
        }

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

private enum StatementProvider {
    case wechat
    case alipay
    case unknown
}
