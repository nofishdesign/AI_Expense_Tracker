import Foundation

enum CloudProviderError: Error, LocalizedError {
    case invalidEndpoint
    case badStatusCode(Int, String?)
    case invalidResponse(String?)
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "云端 endpoint 配置无效。"
        case .badStatusCode(let code, let detail):
            if let detail, !detail.isEmpty {
                return "云端识别请求失败（HTTP \(code)）：\(detail)"
            }
            return "云端识别请求失败（HTTP \(code)）。"
        case .invalidResponse(let detail):
            if let detail, !detail.isEmpty {
                return "云端识别返回格式无效：\(detail)"
            }
            return "云端识别返回格式无效。"
        case .upstream(let message):
            return "云端返回错误：\(message)"
        }
    }
}

struct OpenAICompatibleCloudProvider: CloudProvider {
    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct ResponseFormat: Encodable {
            let type: String
        }
        let model: String
        let temperature: Double
        let messages: [Message]
        let response_format: ResponseFormat?
        let stream: Bool?
        let max_completion_tokens: Int?
    }

    private struct CloudResult: Decodable {
        let amount: Double?
        let merchant: String?
        let channel: String?
        let occurredAt: String?
        let category: String?
        let confidence: Double?
    }

    func extract(from text: String, config: CloudModelRuntimeConfig) async throws -> ParseDraft? {
        guard !config.apiKey.isEmpty else {
            throw CloudProviderError.upstream("API Key 为空")
        }
        guard let url = buildURL(from: config) else {
            throw CloudProviderError.invalidEndpoint
        }

        let prompt = """
        你是消费支付信息抽取器。请仅返回 JSON，不要解释。
        从以下 OCR 文本提取：amount(数字), merchant(字符串), channel(wechat/alipay/bankCard/cash/unknown), occurredAt(ISO8601 可空), category(可空), confidence(0-1)。
        文本:
        \(text)
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in config.customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let models = modelCandidates(from: config)
        let (result, content) = try await requestWithModelFallback(
            baseRequest: request,
            models: models,
            prompt: prompt
        )

        let channel = PaymentChannel(rawValue: (result.channel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? .unknown
        let occurredAt = parseDate(result.occurredAt) ?? .now
        let confidence = min(1, max(0, result.confidence ?? 0.85))
        let amount = result.amount ?? parseAmountFallback(from: content) ?? parseAmountFallback(from: text) ?? 0
        guard amount > 0 else {
            throw CloudProviderError.invalidResponse("金额缺失，原始片段：\(content.prefix(120))")
        }
        return ParseDraft(
            amountCNY: amount,
            occurredAt: occurredAt,
            merchant: (result.merchant ?? "").isEmpty ? "未识别商户" : (result.merchant ?? "未识别商户"),
            channel: channel,
            suggestedCategoryName: result.category ?? "其他",
            confidence: confidence,
            fieldConfidence: [
                "amount": confidence,
                "merchant": confidence,
                "channel": confidence,
                "date": confidence
            ]
        )
    }

    private enum RequestVariant: CaseIterable {
        case strictJSON
        case plainJSONPromptOnly
    }

    private func requestWithModelFallback(
        baseRequest: URLRequest,
        models: [String],
        prompt: String
    ) async throws -> (CloudResult, String) {
        var lastError: CloudProviderError?
        for (index, model) in models.enumerated() {
            for variant in RequestVariant.allCases {
                var request = baseRequest
                let responseFormat: RequestBody.ResponseFormat? = (variant == .strictJSON) ? .init(type: "json_object") : nil
                let body = RequestBody(
                    model: model,
                    temperature: 0,
                    messages: [
                        .init(role: "system", content: "You extract payment information from OCR text. Return JSON only."),
                        .init(role: "user", content: prompt)
                    ],
                    response_format: responseFormat,
                    stream: false,
                    max_completion_tokens: 512
                )
                request.httpBody = try JSONEncoder().encode(body)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudProviderError.invalidResponse("非 HTTP 响应")
                }

                if (200..<300).contains(http.statusCode) {
                    do {
                        let content = try extractMessageContent(from: data)
                        let result = try decodeCloudResult(from: content)
                        let hasAmount = (result.amount != nil) || (parseAmountFallback(from: content) != nil)
                        if hasAmount {
                            return (result, content)
                        }
                        lastError = .invalidResponse("返回缺少金额字段")
                        continue
                    } catch let cloudError as CloudProviderError {
                        lastError = cloudError
                        continue
                    } catch {
                        lastError = .invalidResponse(error.localizedDescription)
                        continue
                    }
                }

                let snippet = responseSnippet(data)
                if isModelNotFound(data: data, statusCode: http.statusCode),
                   index < models.count - 1 {
                    break
                }
                let requestURL = request.url?.absoluteString ?? ""
                let detail: String
                if requestURL.isEmpty {
                    detail = snippet ?? ""
                } else {
                    let s = snippet ?? ""
                    detail = s.isEmpty ? "url=\(requestURL)" : "\(s) | url=\(requestURL)"
                }
                lastError = .badStatusCode(http.statusCode, detail.isEmpty ? nil : detail)
            }
        }

        if let lastError {
            throw lastError
        }
        throw CloudProviderError.invalidResponse("云端请求失败")
    }

    private func modelCandidates(from config: CloudModelRuntimeConfig) -> [String] {
        let preferred = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        if !preferred.isEmpty {
            candidates.append(preferred)
        }

        if config.vendor == .openai || config.vendor == .custom {
            candidates.append(contentsOf: ["gpt-5.4", "gpt-4.1", "gpt-4o-mini"])
        }

        var unique: [String] = []
        for model in candidates where !model.isEmpty {
            if !unique.contains(model) {
                unique.append(model)
            }
        }
        return unique
    }

    private func isModelNotFound(data: Data, statusCode: Int) -> Bool {
        guard statusCode == 400 || statusCode == 404 || statusCode == 422 || statusCode == 503 else {
            return false
        }
        guard let raw = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return raw.contains("model_not_found") || raw.contains("no model") || raw.contains("模型") && raw.contains("不可用")
    }

    func testConnection(config: CloudModelRuntimeConfig) async throws -> Int {
        let start = Date()
        let pingText = "测试云端模型连通性，返回金额8.00，商户测试"
        _ = try await extract(from: pingText, config: config)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return max(elapsed, 1)
    }

    private func buildURL(from config: CloudModelRuntimeConfig) -> URL? {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            return normalizeOpenAICompatibleURL(base)
        }

        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return nil }
        return normalizeOpenAICompatibleURL(endpoint)
    }

    private func normalizeOpenAICompatibleURL(_ raw: String) -> URL? {
        guard let parsed = URL(string: raw) else { return nil }
        let path = parsed.path.trimmingCharacters(in: .whitespacesAndNewlines)

        if path.hasSuffix("/chat/completions") || path.hasSuffix("/responses") {
            return parsed
        }

        var result = parsed
        if path.isEmpty || path == "/" {
            result.append(path: "v1/chat/completions")
            return result
        }

        if path == "/v1" || path == "v1" {
            result.append(path: "chat/completions")
            return result
        }

        if path.hasSuffix("/v1/") {
            result.append(path: "chat/completions")
            return result
        }

        return parsed
    }

    private func extractMessageContent(from data: Data) throws -> String {
        if let raw = String(data: data, encoding: .utf8),
           looksLikeSSE(raw) {
            if let sseContent = extractFromSSE(raw),
               !sseContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return cleanup(sseContent)
            }
            throw CloudProviderError.invalidResponse("流式响应中没有可用文本内容")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            if let raw = String(data: data, encoding: .utf8),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return cleanup(raw)
            }
            throw CloudProviderError.invalidResponse("响应非 JSON：\(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw CloudProviderError.invalidResponse(responseSnippet(data))
        }

        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            throw CloudProviderError.upstream(message)
        }

        if let choices = root["choices"] as? [[String: Any]], let first = choices.first {
            if let message = first["message"] as? [String: Any] {
                if let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return cleanup(content)
                }
                if let contentArray = message["content"] as? [[String: Any]] {
                    let texts = contentArray.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !texts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return cleanup(texts)
                    }
                }
            }
            if let text = first["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return cleanup(text)
            }
        }

        if let objectType = root["object"] as? String,
           objectType == "chat.completion.chunk" {
            if let choices = root["choices"] as? [[String: Any]] {
                for choice in choices {
                    if let delta = choice["delta"] as? [String: Any],
                       let content = extractContentText(from: delta["content"]),
                       !content.isEmpty {
                        return cleanup(content)
                    }
                }
            }
            throw CloudProviderError.invalidResponse("chunk 响应无内容")
        }

        if let outputText = root["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanup(outputText)
        }

        // OpenAI Responses API style: output[].content[].text
        if let output = root["output"] as? [[String: Any]] {
            var collected: [String] = []
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for part in content {
                        if let text = part["text"] as? String, !text.isEmpty {
                            collected.append(text)
                        }
                    }
                }
            }
            let merged = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !merged.isEmpty {
                return cleanup(merged)
            }
        }

        let fallback = responseSnippet(data)
        throw CloudProviderError.invalidResponse(fallback)
    }

    private func looksLikeSSE(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("data:") || raw.contains("\ndata:")
    }

    private func extractFromSSE(_ raw: String) -> String? {
        var mergedParts: [String] = []
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            var payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" || payload.isEmpty {
                continue
            }

            // Sometimes gateways prefix extra spaces or "data: " repeatedly.
            while payload.hasPrefix("data:") {
                payload = String(payload.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let data = payload.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let choices = object["choices"] as? [[String: Any]] {
                    for choice in choices {
                        if let delta = choice["delta"] as? [String: Any],
                           let content = extractContentText(from: delta["content"]),
                           !content.isEmpty {
                            mergedParts.append(content)
                        } else if let message = choice["message"] as? [String: Any],
                                  let content = extractContentText(from: message["content"]),
                                  !content.isEmpty {
                            mergedParts.append(content)
                        } else if let text = choice["text"] as? String, !text.isEmpty {
                            mergedParts.append(text)
                        }
                    }
                }

                if let outputText = object["output_text"] as? String, !outputText.isEmpty {
                    mergedParts.append(outputText)
                }
            } else {
                // Some providers may stream plain text chunks after data:
                mergedParts.append(payload)
            }
        }

        if mergedParts.isEmpty { return nil }
        return mergedParts.joined()
    }

    private func extractContentText(from any: Any?) -> String? {
        if let text = any as? String {
            return text
        }
        if let array = any as? [[String: Any]] {
            let texts = array.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                return nil
            }
            let merged = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return merged.isEmpty ? nil : merged
        }
        return nil
    }

    private func decodeCloudResult(from content: String) throws -> CloudResult {
        let cleaned = cleanup(content)
        if let data = cleaned.data(using: .utf8),
           let direct = try? JSONDecoder().decode(CloudResult.self, from: data) {
            return direct
        }

        if let jsonText = firstJSONObject(in: cleaned),
           let data = jsonText.data(using: .utf8),
           let embedded = try? JSONDecoder().decode(CloudResult.self, from: data) {
            return embedded
        }

        throw CloudProviderError.invalidResponse("无法从返回内容提取 JSON：\(cleaned.prefix(120))")
    }

    private func cleanup(_ text: String) -> String {
        text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    end = idx
                    break
                }
            }
            idx = text.index(after: idx)
        }
        guard let end else { return nil }
        return String(text[start...end])
    }

    private func parseAmountFallback(from text: String) -> Double? {
        let pattern = #"(?:¥|￥)?\s*([0-9]+(?:\.[0-9]{1,2})?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = text as NSString
        let range = NSRange(location: 0, length: full.length)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        let value = full.substring(with: match.range(at: 1))
        return Double(value)
    }

    private func responseSnippet(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return String(raw.prefix(180))
    }

    private func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: text) { return date }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
