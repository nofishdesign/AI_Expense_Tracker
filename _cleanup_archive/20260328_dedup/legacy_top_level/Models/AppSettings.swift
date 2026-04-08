import Foundation
import SwiftData

@Model
final class AppSettings {
    @Attribute(.unique) var id: UUID
    var cloudProviderName: String
    var cloudModelName: String
    var cloudEndpoint: String
    var cloudEnabled: Bool
    var autoConfirmThreshold: Double
    var localeIdentifier: String
    var currencyCode: String
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        cloudProviderName: String = "MockProvider",
        cloudModelName: String = "default",
        cloudEndpoint: String = "",
        cloudEnabled: Bool = false,
        autoConfirmThreshold: Double = 0.8,
        localeIdentifier: String = "zh_CN",
        currencyCode: String = "CNY",
        updatedAt: Date = .now
    ) {
        self.id = id
        self.cloudProviderName = cloudProviderName
        self.cloudModelName = cloudModelName
        self.cloudEndpoint = cloudEndpoint
        self.cloudEnabled = cloudEnabled
        self.autoConfirmThreshold = autoConfirmThreshold
        self.localeIdentifier = localeIdentifier
        self.currencyCode = currencyCode
        self.updatedAt = updatedAt
    }
}
