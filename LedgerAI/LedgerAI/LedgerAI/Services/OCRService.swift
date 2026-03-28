import Foundation
import UIKit
@preconcurrency import Vision

enum OCRService {
    static func recognizeText(from image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }

        var recognizedText = ""
        let request = VNRecognizeTextRequest { request, _ in
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            recognizedText = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return recognizedText
    }
}
