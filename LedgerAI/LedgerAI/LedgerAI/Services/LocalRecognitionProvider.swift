import Foundation

struct LocalRecognitionProvider: RecognitionProvider {
    private let parser = TransactionParser()

    func extract(from input: RecognitionInput) async throws -> ParseDraft {
        parser.parse(text: input.text, occurredAt: input.occurredAt)
    }
}

struct MockCloudProvider: CloudProvider {
    func extract(from text: String, config: CloudModelRuntimeConfig) async throws -> ParseDraft? {
        let parser = TransactionParser()
        let draft = parser.parse(text: text, occurredAt: .now)
        guard draft.confidence < 0.8 else { return nil }

        var improved = draft
        improved.confidence = min(0.85, draft.confidence + 0.2)
        if improved.merchant == "未识别商户", text.contains("支付") {
            improved.merchant = "云端识别商户"
        }
        return improved
    }

    func testConnection(config: CloudModelRuntimeConfig) async throws -> Int {
        50
    }
}
