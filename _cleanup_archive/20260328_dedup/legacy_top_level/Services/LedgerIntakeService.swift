import Foundation
import SwiftData

enum LedgerIntakeError: Error, LocalizedError {
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "输入内容为空，无法识别。"
        }
    }
}

@MainActor
final class LedgerIntakeService {
    private let localProvider: RecognitionProvider
    private let cloudProvider: CloudProvider
    private let classifier = CategoryClassifier()
    private let defaultThreshold: Double = 0.8

    init(
        localProvider: RecognitionProvider = LocalRecognitionProvider(),
        cloudProvider: CloudProvider = MockCloudProvider()
    ) {
        self.localProvider = localProvider
        self.cloudProvider = cloudProvider
    }

    func ingest(
        input: RecognitionInput,
        in context: ModelContext
    ) async throws -> TransactionRecord {
        let trimmed = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LedgerIntakeError.emptyInput }

        var draft = try await localProvider.extract(from: input)
        let settings = try settings(in: context)
        if settings.cloudEnabled && draft.confidence < settings.autoConfirmThreshold {
            if let cloudDraft = try await cloudProvider.extract(from: input.text), cloudDraft.confidence > draft.confidence {
                draft = cloudDraft
            }
        }

        let categories = try context.fetch(FetchDescriptor<Category>(
            sortBy: [SortDescriptor(\.order, order: .forward)]
        ))
        let preferences = try context.fetch(FetchDescriptor<UserPreference>())
        let category = classifier.classify(draft: draft, categories: categories, preferences: preferences)

        let candidate = ParseCandidate(
            sourceType: input.source,
            rawText: input.text,
            extractedAmountCNY: draft.amountCNY,
            occurredAt: draft.occurredAt,
            merchant: draft.merchant,
            channel: draft.channel,
            suggestedCategoryName: category?.name ?? draft.suggestedCategoryName,
            confidence: draft.confidence,
            fieldConfidenceJSON: encodeFieldConfidence(draft.fieldConfidence)
        )
        context.insert(candidate)

        let status: TransactionStatus = draft.confidence >= settings.autoConfirmThreshold ? .confirmed : .draft
        let transaction = TransactionRecord(
            amountCNY: draft.amountCNY,
            occurredAt: draft.occurredAt,
            merchant: draft.merchant,
            channel: draft.channel,
            categoryID: category?.id,
            sourceType: input.source,
            rawText: input.text,
            confidence: draft.confidence,
            status: status
        )
        context.insert(transaction)
        try context.save()
        return transaction
    }

    func markConfirmedAndLearn(transaction: TransactionRecord, in context: ModelContext) throws {
        transaction.status = .confirmed
        transaction.updatedAt = .now
        let merchantKey = transaction.merchant.lowercased()

        let descriptor = FetchDescriptor<UserPreference>(
            predicate: #Predicate { $0.merchantKey == merchantKey }
        )

        if let existing = try context.fetch(descriptor).first {
            existing.preferredCategoryID = transaction.categoryID
            existing.preferredChannelRaw = transaction.channel.rawValue
            existing.useCount += 1
            existing.updatedAt = .now
        } else {
            let pref = UserPreference(
                merchantKey: merchantKey,
                preferredCategoryID: transaction.categoryID,
                preferredChannel: transaction.channel
            )
            context.insert(pref)
        }
        try context.save()
    }

    private func settings(in context: ModelContext) throws -> AppSettings {
        if let existing = try context.fetch(FetchDescriptor<AppSettings>()).first {
            return existing
        }
        let defaults = AppSettings()
        context.insert(defaults)
        try context.save()
        return defaults
    }

    private func encodeFieldConfidence(_ confidence: [String: Double]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: confidence, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
