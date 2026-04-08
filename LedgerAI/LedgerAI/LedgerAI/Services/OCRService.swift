import Foundation
import ImageIO
@preconcurrency import Vision

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum OCRService {
    static func recognizeText(from image: PlatformImage) async -> String {
        guard let cgImage = cgImage(from: image) else { return "" }
        let orientation: CGImagePropertyOrientation
#if canImport(UIKit)
        orientation = CGImagePropertyOrientation(image.imageOrientation)
#else
        orientation = .up
#endif

        let primary = recognizeLines(
            from: cgImage,
            orientation: orientation,
            level: .accurate
        )
        if primary.count >= 3 {
            return primary.joined(separator: "\n")
        }

        let fallback = recognizeLines(
            from: cgImage,
            orientation: orientation,
            level: .fast
        )
        return mergedLines(primary: primary, fallback: fallback).joined(separator: "\n")
    }

    private static func cgImage(from image: PlatformImage) -> CGImage? {
#if canImport(UIKit)
        return image.cgImage
#elseif canImport(AppKit)
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        guard let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data) else {
            return nil
        }
        return rep.cgImage
#else
        return nil
#endif
    }

    private static func recognizeLines(
        from cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        level: VNRequestTextRecognitionLevel
    ) -> [String] {
        var tokens: [OCRToken] = []
        let request = VNRecognizeTextRequest { request, _ in
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            tokens = observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRToken(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    box: observation.boundingBox
                )
            }
        }
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.minimumTextHeight = 0.01
        request.customWords = [
            "账单详情", "交易成功", "支付成功", "商品说明", "收款方", "收款方全称",
            "商户名称", "交易对方", "支付时间", "交易时间", "付款方式",
            "支付宝", "微信支付", "盒马", "山姆", "麦当劳", "肯德基"
        ]
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation,
            options: [:]
        )
        try? handler.perform([request])
        return assembledLines(from: tokens)
    }

    private static func assembledLines(from tokens: [OCRToken]) -> [String] {
        let sorted = tokens.sorted { lhs, rhs in
            let yDiff = abs(lhs.box.midY - rhs.box.midY)
            if yDiff > 0.018 {
                return lhs.box.midY > rhs.box.midY
            }
            return lhs.box.minX < rhs.box.minX
        }

        var rows: [OCRRow] = []
        for token in sorted where !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if var last = rows.last {
                let threshold = max(0.012, min(0.04, token.box.height * 0.7))
                if abs(last.midY - token.box.midY) <= threshold {
                    last.tokens.append(token)
                    last.midY = (last.midY * CGFloat(last.tokens.count - 1) + token.box.midY) / CGFloat(last.tokens.count)
                    rows[rows.count - 1] = last
                    continue
                }
            }
            rows.append(OCRRow(midY: token.box.midY, tokens: [token]))
        }

        return rows.compactMap { row in
            let line = row.tokens
                .sorted { $0.box.minX < $1.box.minX }
                .map { $0.text }
                .joined(separator: " ")
            return normalizeLine(line)
        }
    }

    private static func normalizeLine(_ raw: String) -> String {
        var line = raw
            .replacingOccurrences(of: "￥", with: "¥")
            .replacingOccurrences(of: #"(?<=\d)\s+(?=\d)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if line.contains("¥") {
            line = line.replacingOccurrences(of: #"¥\s+"#, with: "¥", options: .regularExpression)
        }
        return line
    }

    private static func mergedLines(primary: [String], fallback: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for line in (primary + fallback) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                merged.append(trimmed)
            }
        }
        return merged
    }
}

private struct OCRToken {
    let text: String
    let confidence: Float
    let box: CGRect
}

private struct OCRRow {
    var midY: CGFloat
    var tokens: [OCRToken]
}

#if canImport(UIKit)
private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
#endif
