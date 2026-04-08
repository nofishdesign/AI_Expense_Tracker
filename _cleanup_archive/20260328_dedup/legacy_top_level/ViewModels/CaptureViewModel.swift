import Foundation
import SwiftData
import UIKit

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var source: InputSourceType = .text
    @Published var textInput: String = ""
    @Published var selectedImage: UIImage?
    @Published var isProcessing: Bool = false
    @Published var resultMessage: String = ""
    @Published var lastRecordID: UUID?

    private let intakeService: LedgerIntakeService

    init(intakeService: LedgerIntakeService = LedgerIntakeService()) {
        self.intakeService = intakeService
    }

    func ingest(modelContext: ModelContext) async {
        isProcessing = true
        defer { isProcessing = false }

        var recognizedText = textInput
        if source == .screenshot, let image = selectedImage {
            let ocrText = await OCRService.recognizeText(from: image)
            if !ocrText.isEmpty {
                recognizedText = ocrText
                textInput = ocrText
            }
        }

        do {
            let record = try await intakeService.ingest(
                input: RecognitionInput(
                    source: source,
                    text: recognizedText,
                    image: selectedImage,
                    occurredAt: .now
                ),
                in: modelContext
            )
            lastRecordID = record.id
            resultMessage = record.status == .confirmed
                ? "识别成功，已自动入账（置信度 \(Int(record.confidence * 100))%）"
                : "已生成待确认记录（置信度 \(Int(record.confidence * 100))%）"
        } catch {
            resultMessage = error.localizedDescription
        }
    }

    func clear() {
        textInput = ""
        selectedImage = nil
        resultMessage = ""
    }
}
