import Foundation
import UIKit

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
