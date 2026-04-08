import Combine
import Foundation
import SwiftData

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var source: InputSourceType = .text
    @Published var textInput: String = ""
    @Published var selectedImage: PlatformImage?
    @Published var isProcessing: Bool = false
    @Published var resultMessage: String = ""
    @Published var lastRecordID: UUID?
    @Published var hasPendingForm: Bool = false

    @Published var formRawText: String = ""
    @Published var formAmount: Double = 0
    @Published var formOccurredAt: Date = .now
    @Published var formMerchant: String = ""
    @Published var formChannel: PaymentChannel = .unknown
    @Published var formCategoryID: UUID?
    @Published var formCategoryName: String = ""
    @Published var formConfidence: Double = 0
    @Published var formNote: String = ""
    @Published var formEngineTitle: String = ""
    @Published var formEngine: RecognitionEngine = .local
    @Published var formEngineDetail: String = ""

    private let intakeService: LedgerIntakeService

    init(intakeService: LedgerIntakeService) {
        self.intakeService = intakeService
    }

    convenience init() {
        self.init(intakeService: LedgerIntakeService())
    }

    func recognize(modelContext: ModelContext) async {
        isProcessing = true
        defer { isProcessing = false }

        var recognizedText = textInput
        if source == .screenshot, let image = selectedImage {
            let ocrText = await OCRService.recognizeText(from: image)
            if !ocrText.isEmpty {
                recognizedText = ocrText
            }
        }

        do {
            let form = try await intakeService.recognize(
                input: RecognitionInput(
                    source: source,
                    text: recognizedText,
                    image: selectedImage,
                    occurredAt: .now
                ),
                in: modelContext
            )
            formRawText = form.rawText
            formAmount = form.amountCNY
            formOccurredAt = form.occurredAt
            formMerchant = form.merchant
            formChannel = form.channel
            formCategoryID = form.categoryID
            formCategoryName = form.categoryName
            formConfidence = form.confidence
            formNote = ""
            formEngine = form.engine
            formEngineTitle = form.engine.title
            formEngineDetail = form.engineDetail ?? ""
            hasPendingForm = true
            let detailSuffix = formEngineDetail.isEmpty ? "" : "，\(formEngineDetail)"
            resultMessage = "识别完成（\(form.engine.title)\(detailSuffix)），请确认表单后保存（置信度 \(Int(form.confidence * 100))%）"
        } catch {
            resultMessage = error.localizedDescription
        }
    }

    func saveCurrentForm(modelContext: ModelContext) -> Bool {
        guard hasPendingForm else {
            resultMessage = "暂无可保存的识别结果。"
            return false
        }

        do {
            let trimmedMerchant = formMerchant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedMerchant.isEmpty else {
                resultMessage = "商户不能为空。"
                return false
            }
            guard formAmount > 0 else {
                resultMessage = "金额必须大于 0。"
                return false
            }

            let record = try intakeService.save(
                form: RecognizedTransactionForm(
                    sourceType: source,
                    rawText: formRawText,
                    amountCNY: formAmount,
                    occurredAt: formOccurredAt,
                    merchant: trimmedMerchant,
                    channel: formChannel,
                    categoryID: formCategoryID,
                    categoryName: formCategoryName,
                    confidence: formConfidence,
                    note: formNote,
                    engine: formEngine,
                    engineDetail: formEngineDetail.isEmpty ? nil : formEngineDetail
                ),
                in: modelContext,
                forceConfirmed: true
            )
            lastRecordID = record.id
            resultMessage = "已保存并入账。"
            clearForm()
            return true
        } catch {
            resultMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func clearInput() {
        textInput = ""
        selectedImage = nil
        resultMessage = ""
        clearForm()
    }

    func resetRecognitionResult() {
        if hasPendingForm {
            clearForm()
            resultMessage = "输入已变更，请重新识别。"
        }
    }

    private func clearForm() {
        hasPendingForm = false
        formRawText = ""
        formAmount = 0
        formOccurredAt = .now
        formMerchant = ""
        formChannel = .unknown
        formCategoryID = nil
        formCategoryName = ""
        formConfidence = 0
        formNote = ""
        formEngine = .local
        formEngineTitle = ""
        formEngineDetail = ""
    }
}
