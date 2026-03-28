import Foundation
import SwiftData

@Model
final class UserPreference {
    @Attribute(.unique) var id: UUID
    var merchantKey: String
    var preferredCategoryID: UUID?
    var preferredChannelRaw: String
    var useCount: Int
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        merchantKey: String,
        preferredCategoryID: UUID?,
        preferredChannel: PaymentChannel,
        useCount: Int = 1,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.merchantKey = merchantKey
        self.preferredCategoryID = preferredCategoryID
        self.preferredChannelRaw = preferredChannel.rawValue
        self.useCount = useCount
        self.updatedAt = updatedAt
    }
}
