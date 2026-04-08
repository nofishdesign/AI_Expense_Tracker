import Foundation
import SwiftData

@Model
final class ParseCandidate {
    @Attribute(.unique) var id: UUID
    var sourceTypeRaw: String
    var rawText: String
    var extractedAmountCNY: Double
    var occurredAt: Date
    var merchant: String
    var channelRaw: String
    var suggestedCategoryName: String
    var confidence: Double
    var fieldConfidenceJSON: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sourceType: InputSourceType,
        rawText: String,
        extractedAmountCNY: Double,
        occurredAt: Date,
        merchant: String,
        channel: PaymentChannel,
        suggestedCategoryName: String,
        confidence: Double,
        fieldConfidenceJSON: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceTypeRaw = sourceType.rawValue
        self.rawText = rawText
        self.extractedAmountCNY = extractedAmountCNY
        self.occurredAt = occurredAt
        self.merchant = merchant
        self.channelRaw = channel.rawValue
        self.suggestedCategoryName = suggestedCategoryName
        self.confidence = confidence
        self.fieldConfidenceJSON = fieldConfidenceJSON
        self.createdAt = createdAt
    }
}
