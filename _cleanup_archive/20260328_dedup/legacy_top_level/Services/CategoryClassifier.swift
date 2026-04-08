import Foundation
import SwiftData

struct CategoryClassifier {
    func classify(
        draft: ParseDraft,
        categories: [Category],
        preferences: [UserPreference]
    ) -> Category? {
        let normalizedMerchant = draft.merchant.lowercased()
        if let preferred = preferences.first(where: { $0.merchantKey == normalizedMerchant }),
           let category = categories.first(where: { $0.id == preferred.preferredCategoryID }) {
            return category
        }

        if let byName = categories.first(where: { $0.name == draft.suggestedCategoryName && $0.isEnabled }) {
            return byName
        }

        let raw = draft.merchant.lowercased()
        if let keywordMatched = categories.first(where: { category in
            category.isEnabled && category.keywords.contains(where: { raw.contains($0) })
        }) {
            return keywordMatched
        }

        return categories.first(where: { $0.name == "其他" && $0.isEnabled })
    }
}
