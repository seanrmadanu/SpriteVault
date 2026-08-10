import Foundation
import AVFoundation
import Vision
import CoreImage

struct DetectedSprite: Hashable {
    let name: String
    let mastered: Bool
    let timestamp: Double
}

actor VideoSpriteAnalyzer {
    private let catalogNames = SpriteCatalog.all.map(\.name)

    func analyze(url: URL, onProgress: @escaping @Sendable (Double, String) -> Void) async throws -> [DetectedSprite] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = max(CMTimeGetSeconds(duration), 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)

        // Sample about every 0.8 sec, capped so a long recording stays practical.
        let interval = max(0.8, seconds / 420.0)
        let times = stride(from: 0.0, through: seconds, by: interval).map {
            NSValue(time: CMTime(seconds: $0, preferredTimescale: 600))
        }

        var found: [String: DetectedSprite] = [:]

        for (index, value) in times.enumerated() {
            try Task.checkCancellation()
            let time = value.timeValue
            let cgImage = try await generator.image(at: time).image
            let text = try recognizeText(in: cgImage)
            let upper = text.uppercased()
            let isMastered = upper.contains("LEVEL 5") || upper.contains("LVL 5") || upper.contains("LEVEL: 5") || upper.contains("MASTERED")

            for name in catalogNames where matches(name: name, in: text) {
                let key = normalize(name)
                let candidate = DetectedSprite(name: name, mastered: isMastered, timestamp: CMTimeGetSeconds(time))
                if let old = found[key] {
                    if candidate.mastered && !old.mastered { found[key] = candidate }
                } else {
                    found[key] = candidate
                }
            }

            let progress = Double(index + 1) / Double(max(times.count, 1))
            onProgress(progress, text.split(separator: "\n").prefix(2).joined(separator: " · "))
        }

        return found.values.sorted { $0.timestamp < $1.timestamp }
    }

    private func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.012

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func matches(name: String, in text: String) -> Bool {
        let n = normalize(name)
        let t = normalize(text)
        if t.contains(n) { return true }

        // OCR often drops punctuation / one character. Require strong token overlap.
        let tokens = name.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return false }
        let hitCount = tokens.filter { token in
            let clean = token.replacingOccurrences(of: ".", with: "")
            return clean.count >= 3 && t.contains(clean)
        }.count
        return hitCount == tokens.count
    }

    private func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
}
