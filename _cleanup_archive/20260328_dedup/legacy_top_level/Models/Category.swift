import Foundation
import SwiftData

@Model
final class Category {
    @Attribute(.unique) var id: UUID
    var name: String
    var symbol: String
    var isSystem: Bool
    var isEnabled: Bool
    var order: Int
    var keywordsCSV: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String,
        isSystem: Bool,
        isEnabled: Bool = true,
        order: Int,
        keywords: [String],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.isSystem = isSystem
        self.isEnabled = isEnabled
        self.order = order
        self.keywordsCSV = keywords.joined(separator: ",")
        self.createdAt = createdAt
    }
}

extension Category {
    var keywords: [String] {
        get {
            keywordsCSV
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }
        set {
            keywordsCSV = newValue.joined(separator: ",")
        }
    }
}
