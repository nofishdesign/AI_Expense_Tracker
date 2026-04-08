import Foundation
import SwiftData

enum LedgerIntakeError: Error, LocalizedError {
    case emptyInput
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "输入内容为空，无法识别。"
        case .persistenceFailed(let message): return message
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

        let settings = settings(in: context)
        let localDraft = try await localProvider.extract(from: normalizedInput)
        var draft = localDraft
        var engine: RecognitionEngine = .local
        var engineDetail: String?

        if settings.cloudEnabled {
            guard let selected = selectedCloudConfig(in: context) else {
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
        let category = classifier.classify(
            draft: draft,
            categories: categories,
            preferences: preferences,
            rawText: rawText
        )

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
        let status: TransactionStatus
        if forceConfirmed {
            status = .confirmed
        } else {
            let settings = settings(in: context)
            status = form.confidence >= settings.autoConfirmThreshold ? .confirmed : .draft
        }

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

        do {
            try context.save()
            return transaction
        } catch {
            // Candidate is analytics-only. If this write fails, keep core transaction save path available.
            context.delete(candidate)
            do {
                try context.save()
                return transaction
            } catch let fallbackError {
                context.delete(transaction)
                let primary = describe(error)
                let secondary = describe(fallbackError)
                throw LedgerIntakeError.persistenceFailed("保存失败：\(primary)；降级重试失败：\(secondary)")
            }
        }
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

    private func settings(in context: ModelContext) -> AppSettings {
        if let existing = primarySettings(in: context) {
            return existing
        }

        let defaults = AppSettings()
        context.insert(defaults)
        try? context.save()
        return defaults
    }

    private func primarySettings(in context: ModelContext) -> AppSettings? {
        let descriptor = FetchDescriptor<AppSettings>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        guard let all = try? context.fetch(descriptor), !all.isEmpty else {
            return nil
        }

        let primary = all[0]
        if all.count > 1 {
            for redundant in all.dropFirst() {
                context.delete(redundant)
            }
            try? context.save()
        }
        return primary
    }

    private func selectedCloudConfig(in context: ModelContext) -> CloudModelConfig? {
        guard let settings = primarySettings(in: context) else { return nil }
        guard var allModels = try? context.fetch(FetchDescriptor<CloudModelConfig>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )) else {
            return nil
        }

        func isUsable(_ model: CloudModelConfig) -> Bool {
            model.isEnabled && !model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if let selectedID = settings.selectedCloudModelID {
            let descriptor = FetchDescriptor<CloudModelConfig>(
                predicate: #Predicate { $0.id == selectedID }
            )
            if let selected = try? context.fetch(descriptor).first {
                if isUsable(selected) {
                    return selected
                }
            }
        }

        if settings.selectedCloudModelID == nil, let firstUsable = allModels.first(where: isUsable) {
            settings.selectedCloudModelID = firstUsable.id
            settings.updatedAt = .now
            try? context.save()
            return firstUsable
        }

        if allModels.first(where: isUsable) == nil {
            let legacyKey = settings.cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let legacyEndpoint = settings.cloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let legacyModelName = settings.cloudModelName.trimmingCharacters(in: .whitespacesAndNewlines)

            if !legacyKey.isEmpty, !legacyEndpoint.isEmpty {
                if let existingLegacy = allModels.first(where: { $0.displayName == "Legacy 云端模型" }) {
                    if existingLegacy.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        existingLegacy.apiKey = legacyKey
                    }
                    if existingLegacy.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        existingLegacy.baseURL = legacyEndpoint
                        existingLegacy.endpoint = legacyEndpoint
                    }
                    if existingLegacy.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        existingLegacy.modelName = legacyModelName.isEmpty ? CloudVendor.custom.defaultModel : legacyModelName
                    }
                    existingLegacy.updatedAt = .now
                    settings.selectedCloudModelID = existingLegacy.id
                    settings.updatedAt = .now
                    try? context.save()
                    return existingLegacy
                }

                let migrated = CloudModelConfig(
                    displayName: "Legacy 云端模型",
                    vendor: .custom,
                    endpoint: legacyEndpoint,
                    baseURL: legacyEndpoint,
                    apiPath: "",
                    modelName: legacyModelName.isEmpty ? CloudVendor.custom.defaultModel : legacyModelName,
                    apiKey: legacyKey,
                    customHeadersJSON: "{}"
                )
                context.insert(migrated)
                settings.selectedCloudModelID = migrated.id
                settings.updatedAt = .now
                try? context.save()
                allModels.insert(migrated, at: 0)
                return migrated
            }
        }

        return allModels.first(where: isUsable) ?? allModels.first
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "\(nsError.domain)#\(nsError.code)"
        }
        return "\(message) [\(nsError.domain)#\(nsError.code)]"
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

struct SyncSummary {
    var pulledInserted: Int
    var pulledUpdated: Int
    var pulledDeleted: Int
    var pushedUpserts: Int
    var pushedDeletes: Int
    var message: String
}

enum SupabaseSyncError: Error, LocalizedError {
    case settingsMissing
    case syncDisabled
    case invalidURL
    case missingCredentials
    case httpError(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .settingsMissing:
            return "同步配置不存在。"
        case .syncDisabled:
            return "同步未开启。"
        case .invalidURL:
            return "Supabase URL 无效。"
        case .missingCredentials:
            return "请填写 Supabase URL、Anon Key 和同步码。"
        case .httpError(let status, let message):
            return "同步失败（HTTP \(status)）：\(message)"
        case .invalidResponse:
            return "同步响应格式异常。"
        }
    }
}

@MainActor
final class SupabaseSyncService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func sync(in context: ModelContext, trigger: String = "manual") async throws -> SyncSummary {
        guard let settings = try? context.fetch(FetchDescriptor<AppSettings>()).first else {
            throw SupabaseSyncError.settingsMissing
        }
        guard settings.syncEnabled else {
            throw SupabaseSyncError.syncDisabled
        }

        let config = try config(from: settings)
        let remoteRecords = try await fetchRemoteRecords(config: config)
        let pullSummary = try applyRemoteRecords(remoteRecords, in: context)

        let localRecords = try context.fetch(FetchDescriptor<TransactionRecord>())
        let pushedUpserts = try await upsertLocalRecords(localRecords, config: config)

        let remoteActiveIDs = Set(remoteRecords.filter { $0.deletedAt == nil }.map(\.id))
        let localIDs = Set(localRecords.map(\.id))
        let pendingDeleteIDs = remoteActiveIDs.subtracting(localIDs)
        let pushedDeletes = try await softDeleteRemoteRecords(ids: pendingDeleteIDs, config: config)

        let message = "同步完成：拉取 +\(pullSummary.inserted)/~\(pullSummary.updated)/-\(pullSummary.deleted)，上推 \(pushedUpserts)，删除 \(pushedDeletes)"
        settings.lastSyncAt = .now
        settings.lastSyncMessage = message
        settings.updatedAt = .now
        try? context.save()

        _ = trigger // keep hook for future diagnostics
        return SyncSummary(
            pulledInserted: pullSummary.inserted,
            pulledUpdated: pullSummary.updated,
            pulledDeleted: pullSummary.deleted,
            pushedUpserts: pushedUpserts,
            pushedDeletes: pushedDeletes,
            message: message
        )
    }

    private func config(from settings: AppSettings) throws -> SyncConfig {
        let baseURL = settings.supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let anonKey = settings.supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerCode = settings.syncOwnerCode.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURL.isEmpty, !anonKey.isEmpty, !ownerCode.isEmpty else {
            throw SupabaseSyncError.missingCredentials
        }
        guard URL(string: baseURL) != nil else {
            throw SupabaseSyncError.invalidURL
        }

        return SyncConfig(baseURL: baseURL, anonKey: anonKey, ownerCode: ownerCode)
    }

    private func applyRemoteRecords(
        _ remoteRecords: [SupabaseLedgerRecord],
        in context: ModelContext
    ) throws -> (inserted: Int, updated: Int, deleted: Int) {
        let localRecords = try context.fetch(FetchDescriptor<TransactionRecord>())
        var localMap = Dictionary(uniqueKeysWithValues: localRecords.map { ($0.id, $0) })

        var inserted = 0
        var updated = 0
        var deleted = 0

        for remote in remoteRecords {
            if remote.deletedAt != nil {
                if let local = localMap[remote.id] {
                    context.delete(local)
                    localMap[remote.id] = nil
                    deleted += 1
                }
                continue
            }

            if let local = localMap[remote.id] {
                if remote.updatedAt.timeIntervalSince(local.updatedAt) > 0.5 {
                    local.amountCNY = remote.amountCNY
                    local.occurredAt = remote.occurredAt
                    local.merchant = remote.merchant
                    local.channel = PaymentChannel(rawValue: remote.channelRaw) ?? .unknown
                    local.categoryID = remote.categoryID
                    local.note = remote.note
                    local.sourceType = InputSourceType(rawValue: remote.sourceTypeRaw) ?? .text
                    local.rawText = remote.rawText
                    local.confidence = remote.confidence
                    local.status = TransactionStatus(rawValue: remote.statusRaw) ?? .confirmed
                    local.createdAt = remote.createdAt
                    local.updatedAt = remote.updatedAt
                    updated += 1
                }
            } else {
                let created = TransactionRecord(
                    id: remote.id,
                    amountCNY: remote.amountCNY,
                    occurredAt: remote.occurredAt,
                    merchant: remote.merchant,
                    channel: PaymentChannel(rawValue: remote.channelRaw) ?? .unknown,
                    categoryID: remote.categoryID,
                    note: remote.note,
                    sourceType: InputSourceType(rawValue: remote.sourceTypeRaw) ?? .text,
                    rawText: remote.rawText,
                    confidence: remote.confidence,
                    status: TransactionStatus(rawValue: remote.statusRaw) ?? .confirmed,
                    createdAt: remote.createdAt,
                    updatedAt: remote.updatedAt
                )
                context.insert(created)
                localMap[remote.id] = created
                inserted += 1
            }
        }

        if inserted + updated + deleted > 0 {
            try context.save()
        }

        return (inserted, updated, deleted)
    }

    private func fetchRemoteRecords(config: SyncConfig) async throws -> [SupabaseLedgerRecord] {
        let select = "id,owner_code,amount_cny,occurred_at,merchant,channel,category_id,note,source_type,raw_text,confidence,status,created_at,updated_at,deleted_at"
        let endpoint = try recordsEndpoint(
            baseURL: config.baseURL,
            queryItems: [
                URLQueryItem(name: "owner_code", value: "eq.\(config.ownerCode)"),
                URLQueryItem(name: "select", value: select),
                URLQueryItem(name: "order", value: "updated_at.asc")
            ]
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        applyBaseHeaders(to: &request, anonKey: config.anonKey)

        let data = try await perform(request)
        guard !data.isEmpty else { return [] }
        return try supabaseJSONDecoder.decode([SupabaseLedgerRecord].self, from: data)
    }

    private func upsertLocalRecords(
        _ localRecords: [TransactionRecord],
        config: SyncConfig
    ) async throws -> Int {
        guard !localRecords.isEmpty else { return 0 }

        let payload = localRecords.map {
            SupabaseLedgerRecord(
                id: $0.id,
                ownerCode: config.ownerCode,
                amountCNY: $0.amountCNY,
                occurredAt: $0.occurredAt,
                merchant: $0.merchant,
                channelRaw: $0.channel.rawValue,
                categoryID: $0.categoryID,
                note: $0.note,
                sourceTypeRaw: $0.sourceType.rawValue,
                rawText: $0.rawText,
                confidence: $0.confidence,
                statusRaw: $0.status.rawValue,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                deletedAt: nil
            )
        }

        let endpoint = try recordsEndpoint(
            baseURL: config.baseURL,
            queryItems: [
                URLQueryItem(name: "on_conflict", value: "id")
            ]
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        applyBaseHeaders(to: &request, anonKey: config.anonKey)
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try supabaseJSONEncoder.encode(payload)

        _ = try await perform(request)
        return payload.count
    }

    private func softDeleteRemoteRecords(ids: Set<UUID>, config: SyncConfig) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let now = Date()
        let body = SoftDeletePayload(
            deletedAt: now,
            updatedAt: now
        )
        let bodyData = try supabaseJSONEncoder.encode(body)

        for id in ids {
            let endpoint = try recordsEndpoint(
                baseURL: config.baseURL,
                queryItems: [
                    URLQueryItem(name: "owner_code", value: "eq.\(config.ownerCode)"),
                    URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")
                ]
            )
            var request = URLRequest(url: endpoint)
            request.httpMethod = "PATCH"
            applyBaseHeaders(to: &request, anonKey: config.anonKey)
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = bodyData
            _ = try await perform(request)
        }
        return ids.count
    }

    private func recordsEndpoint(baseURL: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: baseURL) else {
            throw SupabaseSyncError.invalidURL
        }
        let prefix = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = "\(prefix)/rest/v1/ledger_records"
        components.queryItems = queryItems

        guard let url = components.url else {
            throw SupabaseSyncError.invalidURL
        }
        return url
    }

    private func applyBaseHeaders(to request: inout URLRequest, anonKey: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseSyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw SupabaseSyncError.httpError(status: http.statusCode, message: message)
        }
        return data
    }

    private struct SyncConfig {
        let baseURL: String
        let anonKey: String
        let ownerCode: String
    }

    private struct SoftDeletePayload: Codable {
        var deletedAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case deletedAt = "deleted_at"
            case updatedAt = "updated_at"
        }
    }

    private struct SupabaseLedgerRecord: Codable {
        var id: UUID
        var ownerCode: String
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
        var deletedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case ownerCode = "owner_code"
            case amountCNY = "amount_cny"
            case occurredAt = "occurred_at"
            case merchant
            case channelRaw = "channel"
            case categoryID = "category_id"
            case note
            case sourceTypeRaw = "source_type"
            case rawText = "raw_text"
            case confidence
            case statusRaw = "status"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case deletedAt = "deleted_at"
        }
    }

}

private let supabaseISO8601WithFractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let supabaseISO8601PlainFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private let supabaseJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, enc in
        var container = enc.singleValueContainer()
        try container.encode(supabaseISO8601WithFractionalFormatter.string(from: date))
    }
    return encoder
}()

private let supabaseJSONDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { dec in
        let container = try dec.singleValueContainer()
        let raw = try container.decode(String.self)
        if let date = supabaseISO8601WithFractionalFormatter.date(from: raw) ?? supabaseISO8601PlainFormatter.date(from: raw) {
            return date
        }
        throw SupabaseSyncError.invalidResponse
    }
    return decoder
}()
