import Foundation
import UIKit

enum RecognitionEngine: String {
    case local
    case cloud

    var title: String {
        switch self {
        case .local: return "本地识别"
        case .cloud: return "云端识别"
        }
    }
}

struct RecognitionInput {
    var source: InputSourceType
    var text: String
    var image: UIImage?
    var occurredAt: Date
}

struct ParseDraft {
    var amountCNY: Double
    var occurredAt: Date
    var merchant: String
    var channel: PaymentChannel
    var suggestedCategoryName: String
    var confidence: Double
    var fieldConfidence: [String: Double]
}

struct RecognizedTransactionForm {
    var sourceType: InputSourceType
    var rawText: String
    var amountCNY: Double
    var occurredAt: Date
    var merchant: String
    var channel: PaymentChannel
    var categoryID: UUID?
    var categoryName: String
    var confidence: Double
    var note: String
    var engine: RecognitionEngine
    var engineDetail: String?
}
