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

    init(
        localProvider: RecognitionProvider,
        cloudProvider: CloudProvider
    ) {
        self.localProvider = localProvider
        self.cloudProvider = cloudProvider
    }

    convenience init() {
        self.init(
            localProvider: LocalRecognitionProvider(),
            cloudProvider: OpenAICompatibleCloudProvider()
        )
    }

    func ingest(
        input: RecognitionInput,
        in context: ModelContext
    ) async throws -> TransactionRecord {
        let form = try await recognize(input: input, in: context)
        return try save(form: form, in: context)
    }

    func recognize(
        input: RecognitionInput,
        in context: ModelContext
    ) async throws -> RecognizedTransactionForm {
        let paymentOnly = PaymentTextSanitizer.paymentOnlyText(from: input.text, source: input.source)
        let trimmed = paymentOnly.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LedgerIntakeError.emptyInput }

        var normalizedInput = input
        normalizedInput.text = trimmed

        let settings = try settings(in: context)
        let localDraft = try await localProvider.extract(from: normalizedInput)
        var draft = localDraft
        var engine: RecognitionEngine = .local
        var engineDetail: String?

        if settings.cloudEnabled {
            guard let selected = try selectedCloudConfig(in: context) else {
                engineDetail = "已开启云端优先，但未找到可用模型配置，已回退本地。"
                return try buildForm(
                    input: input,
                    rawText: trimmed,
                    draft: draft,
                    engine: engine,
                    engineDetail: engineDetail,
                    context: context
                )
            }

            if !selected.isEnabled {
                engineDetail = "模型「\(selected.displayName)」已禁用，已回退本地。"
            } else if selected.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engineDetail = "模型「\(selected.displayName)」API Key 为空，已回退本地。"
            } else {
                do {
                    if let cloudDraft = try await cloudProvider.extract(from: trimmed, config: selected.runtime) {
                        draft = mergedDraft(local: localDraft, cloud: cloudDraft)
                        engine = .cloud
                        engineDetail = "模型：\(selected.displayName)（\(selected.modelName)）· 本地兜底"
                    } else {
                        engineDetail = "云端返回空结果，已回退本地。"
                    }
                } catch {
                    engineDetail = "云端失败：\(error.localizedDescription)；已回退本地。"
                }
            }
        }

        return try buildForm(
            input: input,
            rawText: trimmed,
            draft: draft,
            engine: engine,
            engineDetail: engineDetail,
            context: context
        )
    }

    private func buildForm(
        input: RecognitionInput,
        rawText: String,
        draft: ParseDraft,
        engine: RecognitionEngine,
        engineDetail: String?,
        context: ModelContext
    ) throws -> RecognizedTransactionForm {
        let categories = try context.fetch(FetchDescriptor<Category>(
            sortBy: [SortDescriptor(\.order, order: .forward)]
        ))
        let preferences = try context.fetch(FetchDescriptor<UserPreference>())
        let category = classifier.classify(draft: draft, categories: categories, preferences: preferences)

        return RecognizedTransactionForm(
            sourceType: input.source,
            rawText: rawText,
            amountCNY: draft.amountCNY,
            occurredAt: draft.occurredAt,
            merchant: draft.merchant,
            channel: draft.channel,
            categoryID: category?.id,
            categoryName: category?.name ?? draft.suggestedCategoryName,
            confidence: draft.confidence,
            note: "",
            engine: engine,
            engineDetail: engineDetail
        )
    }

    func save(
        form: RecognizedTransactionForm,
        in context: ModelContext,
        forceConfirmed: Bool = false
    ) throws -> TransactionRecord {
        let settings = try settings(in: context)
        let status: TransactionStatus = forceConfirmed
            ? .confirmed
            : (form.confidence >= settings.autoConfirmThreshold ? .confirmed : .draft)

        let candidate = ParseCandidate(
            sourceType: form.sourceType,
            rawText: form.rawText,
            extractedAmountCNY: form.amountCNY,
            occurredAt: form.occurredAt,
            merchant: form.merchant,
            channel: form.channel,
            suggestedCategoryName: form.categoryName,
            confidence: form.confidence,
            fieldConfidenceJSON: "{}"
        )
        context.insert(candidate)

        let transaction = TransactionRecord(
            amountCNY: form.amountCNY,
            occurredAt: form.occurredAt,
            merchant: form.merchant,
            channel: form.channel,
            categoryID: form.categoryID,
            note: form.note,
            sourceType: form.sourceType,
            rawText: form.rawText,
            confidence: form.confidence,
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

    func speedTest(config: CloudModelConfig) async -> (ok: Bool, latencyMs: Int?, message: String) {
        guard !config.apiKey.isEmpty else {
            return (false, nil, "API Key 为空")
        }
        let endpoint = config.runtime.endpoint
        do {
            let latency = try await cloudProvider.testConnection(config: config.runtime)
            return (true, latency, "可用 · \(endpoint)")
        } catch {
            return (false, nil, "\(error.localizedDescription) · \(endpoint)")
        }
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

    private func selectedCloudConfig(in context: ModelContext) throws -> CloudModelConfig? {
        guard let settings = try context.fetch(FetchDescriptor<AppSettings>()).first else { return nil }
        let allModels = try context.fetch(FetchDescriptor<CloudModelConfig>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))

        func isUsable(_ model: CloudModelConfig) -> Bool {
            model.isEnabled && !model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if let selectedID = settings.selectedCloudModelID {
            let descriptor = FetchDescriptor<CloudModelConfig>(
                predicate: #Predicate { $0.id == selectedID }
            )
            if let selected = try context.fetch(descriptor).first {
                if isUsable(selected) {
                    return selected
                }
            }
        }
        return allModels.first(where: isUsable) ?? allModels.first
    }

    private func mergedDraft(local: ParseDraft, cloud: ParseDraft) -> ParseDraft {
        let amount = cloud.amountCNY > 0 ? cloud.amountCNY : local.amountCNY
        let merchant = cloud.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cloud.merchant == "未识别商户"
            ? local.merchant
            : cloud.merchant
        let channel: PaymentChannel = cloud.channel == .unknown ? local.channel : cloud.channel
        let suggestedCategoryName = cloud.suggestedCategoryName == "其他" ? local.suggestedCategoryName : cloud.suggestedCategoryName
        let occurredAt = abs(cloud.occurredAt.timeIntervalSinceNow) < 2 ? local.occurredAt : cloud.occurredAt

        return ParseDraft(
            amountCNY: amount,
            occurredAt: occurredAt,
            merchant: merchant,
            channel: channel,
            suggestedCategoryName: suggestedCategoryName,
            confidence: max(local.confidence, cloud.confidence),
            fieldConfidence: cloud.fieldConfidence.isEmpty ? local.fieldConfidence : cloud.fieldConfidence
        )
    }
}
