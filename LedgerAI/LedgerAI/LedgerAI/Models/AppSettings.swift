import Foundation
import SwiftData

@Model
final class AppSettings {
    @Attribute(.unique) var id: UUID
    var cloudProviderName: String
    var cloudModelName: String
    var cloudEndpoint: String
    var cloudAPIKey: String
    var selectedCloudModelID: UUID?
    var cloudEnabled: Bool
    var autoConfirmThreshold: Double
    var localeIdentifier: String
    var currencyCode: String
    var manualEntryEnabled: Bool
    var syncEnabled: Bool
    var supabaseURL: String
    var supabaseAnonKey: String
    var syncOwnerCode: String
    var lastSyncAt: Date?
    var lastSyncMessage: String
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        cloudProviderName: String = "MockProvider",
        cloudModelName: String = "gpt-5.4",
        cloudEndpoint: String = "https://api.openai.com/v1/chat/completions",
        cloudAPIKey: String = "",
        selectedCloudModelID: UUID? = nil,
        cloudEnabled: Bool = false,
        autoConfirmThreshold: Double = 0.8,
        localeIdentifier: String = "zh_CN",
        currencyCode: String = "CNY",
        manualEntryEnabled: Bool = false,
        syncEnabled: Bool = false,
        supabaseURL: String = "",
        supabaseAnonKey: String = "",
        syncOwnerCode: String = "",
        lastSyncAt: Date? = nil,
        lastSyncMessage: String = "未同步",
        updatedAt: Date = .now
    ) {
        self.id = id
        self.cloudProviderName = cloudProviderName
        self.cloudModelName = cloudModelName
        self.cloudEndpoint = cloudEndpoint
        self.cloudAPIKey = cloudAPIKey
        self.selectedCloudModelID = selectedCloudModelID
        self.cloudEnabled = cloudEnabled
        self.autoConfirmThreshold = autoConfirmThreshold
        self.localeIdentifier = localeIdentifier
        self.currencyCode = currencyCode
        self.manualEntryEnabled = manualEntryEnabled
        self.syncEnabled = syncEnabled
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.syncOwnerCode = syncOwnerCode
        self.lastSyncAt = lastSyncAt
        self.lastSyncMessage = lastSyncMessage
        self.updatedAt = updatedAt
    }
}
