import Foundation

#if canImport(Vision)
import Vision
import CoreGraphics
import ImageIO

/// On-device OCR via the Vision framework. Recognizes text in an image file and
/// returns it joined by newlines. No network, no API keys.
public struct VisionOCR: TextRecognizing {
    public enum OCRError: Error, Sendable {
        case cannotLoadImage(String)
    }

    public init() {}

    /// Recognize text in the image at `url`. Returns "" if the image has no text.
    public func recognizeText(in url: URL) async throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRError.cannotLoadImage(url.path)
        }
        return try await recognizeText(in: cgImage)
    }

    /// Recognize text in an already-decoded image.
    public func recognizeText(in cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
#endif
