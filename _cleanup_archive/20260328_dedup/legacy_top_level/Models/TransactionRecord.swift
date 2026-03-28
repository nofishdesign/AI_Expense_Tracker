import Foundation
import SwiftData

@Model
final class TransactionRecord {
    @Attribute(.unique) var id: UUID
    var amountCNY: Double
    var occurredAt: Date
    var merchant: String
    var channelRaw: String
    var categoryID: UUID?
    var note: String
    var sourceTypeRaw: String
    var rawText: String
    var confidence: Double
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        amountCNY: Double,
        occurredAt: Date,
        merchant: String,
        channel: PaymentChannel,
        categoryID: UUID?,
        note: String = "",
        sourceType: InputSourceType,
        rawText: String,
        confidence: Double,
        status: TransactionStatus,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.amountCNY = amountCNY
        self.occurredAt = occurredAt
        self.merchant = merchant
        self.channelRaw = channel.rawValue
        self.categoryID = categoryID
        self.note = note
        self.sourceTypeRaw = sourceType.rawValue
        self.rawText = rawText
        self.confidence = confidence
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension TransactionRecord {
    var channel: PaymentChannel {
        get { PaymentChannel(rawValue: channelRaw) ?? .unknown }
        set { channelRaw = newValue.rawValue }
    }

    var sourceType: InputSourceType {
        get { InputSourceType(rawValue: sourceTypeRaw) ?? .text }
        set { sourceTypeRaw = newValue.rawValue }
    }

    var status: TransactionStatus {
        get { TransactionStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }
}
