import Foundation
import Vision
import CoreImage
import ImageIO

actor ScreenshotSpriteAnalyzer {
    static let shared = ScreenshotSpriteAnalyzer()

    private let catalog = SpriteCatalog.all
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var cachedReferences: [ReferenceFeature]?

    // Fortnite's Collection grid is fixed inside the 16:9 game viewport.
    // These values are normalized to that viewport, not to the outer screenshot,
    // so screenshots with black letterboxing still line up correctly.
    private let firstColumnCenter: CGFloat = 0.118
    private let columnStep: CGFloat = 0.080
    private let firstRowTop: CGFloat = 0.232
    private let rowStep: CGFloat = 0.180
    private let cardWidth: CGFloat = 0.079
    private let cardHeight: CGFloat = 0.166

    func analyze(
        url: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [DetectedSprite] {
        try Task.checkCancellation()
        onProgress(0.02, "Opening screenshot…")
        let screenshot = try loadImage(at: url)
        return try await analyze(image: screenshot, onProgress: onProgress)
    }

    func analyze(
        image screenshot: CGImage,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [DetectedSprite] {
        try Task.checkCancellation()
        let viewport = contentViewport(in: screenshot)

        onProgress(0.03, "Confirming the Fortnite Collection screen…")
        guard try isCollectionScreen(screenshot, viewport: viewport) else {
            onProgress(1.0, "Collection grid not visible; ignoring this frame.")
            return []
        }

        var cards: [CardFeature] = []
        onProgress(0.08, "Reading levels from the visible Sprite cards…")

        for slot in 0..<12 {
            try Task.checkCancellation()
            let rect = cardRect(for: slot, viewport: viewport)
            guard let card = cropTopLeft(screenshot, to: rect) else { continue }

            let progress = 0.08 + (Double(slot + 1) / 12.0) * 0.38
            guard let level = try recognizedLevel(in: card) else {
                if slot.isMultiple(of: 3) {
                    onProgress(progress, "Checking visible card levels…")
                }
                continue
            }

            guard let artwork = artworkCrop(from: card),
                  let feature = try featurePrint(for: artwork) else {
                continue
            }

            cards.append(CardFeature(slot: slot, level: level, feature: feature))
            onProgress(progress, "Found card · Lvl \(level)")
        }

        guard !cards.isEmpty else {
            onProgress(1.0, "No owned Sprite cards with readable levels were found.")
            return []
        }

        onProgress(0.50, "Matching card artwork to the Sprite catalog…")
        let references = try referenceFeatures(onProgress: onProgress)
        guard !references.isEmpty else {
            throw ScreenshotAnalysisError.missingReferenceArtwork
        }

        let scoreMatrix = try cards.map { card in
            try references.map { reference in
                try featureDistance(card.feature, reference.feature)
            }
        }

        let assignments = chooseAssignments(
            cards: cards,
            references: references,
            scores: scoreMatrix
        )

        let results = cards.enumerated().compactMap { cardIndex, card -> DetectedSprite? in
            guard let referenceIndex = assignments[cardIndex],
                  references.indices.contains(referenceIndex) else { return nil }

            let reference = references[referenceIndex]
            let item = reference.item
            return DetectedSprite(
                name: item.name,
                rarity: item.rarity,
                owned: true,
                level: card.level,
                mastered: card.level == 5,
                timestamp: 0,
                observations: 1,
                catalogIndex: reference.catalogIndex,
                gridSlot: card.slot
            )
        }

        // A screenshot can never legitimately contain the same catalog entry in
        // two grid slots. Keep the first match if Vision produced a duplicate.
        var seen = Set<String>()
        let unique = results.filter { seen.insert($0.name).inserted }
        onProgress(1.0, "Matched \(unique.count) visible Sprite card\(unique.count == 1 ? "" : "s").")
        return unique
    }

    private func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: true
              ] as CFDictionary) else {
            throw ScreenshotAnalysisError.unreadableImage
        }
        return image
    }

    private func cardRect(for slot: Int, viewport: CGRect) -> CGRect {
        let column = slot % 3
        let row = slot / 3
        let centerX = viewport.minX + viewport.width * (
            firstColumnCenter + CGFloat(column) * columnStep
        )
        let top = viewport.minY + viewport.height * (
            firstRowTop + CGFloat(row) * rowStep
        )
        let width = viewport.width * cardWidth
        let height = viewport.height * cardHeight

        return CGRect(
            x: centerX - width / 2,
            y: top,
            width: width,
            height: height
        )
    }

    private func isCollectionScreen(_ screenshot: CGImage, viewport: CGRect) throws -> Bool {
        let headerRect = CGRect(
            x: viewport.minX + viewport.width * 0.03,
            y: viewport.minY + viewport.height * 0.02,
            width: viewport.width * 0.68,
            height: viewport.height * 0.30
        )
        guard let header = cropTopLeft(screenshot, to: headerRect) else { return false }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.035
        request.customWords = ["SPRITES", "COLLECTION", "REWARDS"]

        let handler = VNImageRequestHandler(cgImage: header, options: [:])
        try handler.perform([request])

        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string.uppercased() }
            .joined(separator: " ")
            .replacingOccurrences(of: "0", with: "O")

        // Live capture runs while the user plays. Refusing to scan frames that
        // don't contain the Collection heading prevents unrelated Fortnite HUD
        // text from ever changing the saved profile.
        return text.contains("COLLECTION")
    }

    private func recognizedLevel(in card: CGImage) throws -> Int? {
        let width = CGFloat(card.width)
        let height = CGFloat(card.height)
        let levelRect = CGRect(
            x: width * 0.01,
            y: height * 0.70,
            width: width * 0.68,
            height: height * 0.29
        )
        guard let levelImage = cropTopLeft(card, to: levelRect) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.10
        request.customWords = (1...5).flatMap { ["Lvl \($0)", "Level \($0)"] }

        let handler = VNImageRequestHandler(cgImage: levelImage, options: [:])
        try handler.perform([request])

        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) {
                if let level = parseLevel(candidate.string) {
                    return level
                }
            }
        }
        return nil
    }

    private func parseLevel(_ value: String) -> Int? {
        var text = value.uppercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "|" }
            .replacingOccurrences(of: "LVI", with: "LVL")
            .replacingOccurrences(of: "LV|", with: "LVL")
            .replacingOccurrences(of: "LEVEI", with: "LEVEL")

        // The italic Fortnite font occasionally turns the final digit into a
        // letter. Only apply these substitutions after a level prefix exists.
        guard text.contains("LVL") || text.contains("LEVEL") || text.contains("LV") else {
            return nil
        }

        text = text
            .replacingOccurrences(of: "LVLS", with: "LVL5")
            .replacingOccurrences(of: "LEVELS", with: "LEVEL5")

        for level in 1...5 {
            if text.contains("LVL\(level)")
                || text.contains("LEVEL\(level)")
                || text.contains("LV\(level)") {
                return level
            }
        }
        return nil
    }

    private func artworkCrop(from card: CGImage) -> CGImage? {
        let width = CGFloat(card.width)
        let height = CGFloat(card.height)
        return cropTopLeft(card, to: CGRect(
            x: width * 0.07,
            y: height * 0.11,
            width: width * 0.86,
            height: height * 0.66
        ))
    }

    private func featurePrint(for image: CGImage) throws -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    private func referenceFeatures(
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) throws -> [ReferenceFeature] {
        if let cachedReferences {
            return cachedReferences
        }

        var references: [ReferenceFeature] = []
        references.reserveCapacity(catalog.count)

        for (index, item) in catalog.enumerated() {
            try Task.checkCancellation()
            guard let url = resourceURL(named: item.imageAssetName),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCache: true
                  ] as CFDictionary),
                  let preparedImage = referenceArtworkImage(from: image),
                  let feature = try featurePrint(for: preparedImage) else {
                continue
            }

            references.append(ReferenceFeature(item: item, catalogIndex: index, feature: feature))

            if index.isMultiple(of: 12) || index == catalog.count - 1 {
                let fraction = Double(index + 1) / Double(max(catalog.count, 1))
                onProgress(0.50 + fraction * 0.34, "Comparing against \(index + 1)/\(catalog.count) Sprite artworks…")
            }
        }

        cachedReferences = references
        return references
    }


    private func referenceArtworkImage(from image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let background = CIImage(
            color: CIColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1)
        ).cropped(to: source.extent)
        let composited = source.composited(over: background)
        return ciContext.createCGImage(composited, from: source.extent)
    }

    private func resourceURL(named assetName: String) -> URL? {
        Bundle.module.url(forResource: assetName, withExtension: "png")
            ?? Bundle.module.url(
                forResource: assetName,
                withExtension: "png",
                subdirectory: "SpriteImages"
            )
            ?? Bundle.module.url(
                forResource: assetName,
                withExtension: "png",
                subdirectory: "Resources/SpriteImages"
            )
    }

    private func featureDistance(
        _ lhs: VNFeaturePrintObservation,
        _ rhs: VNFeaturePrintObservation
    ) throws -> Float {
        var distance: Float = 0
        try lhs.computeDistance(&distance, to: rhs)
        return distance
    }

    private func chooseAssignments(
        cards: [CardFeature],
        references: [ReferenceFeature],
        scores: [[Float]]
    ) -> [Int?] {
        let independent = scores.map { row -> Int? in
            row.enumerated().min(by: { $0.element < $1.element })?.offset
        }

        guard cards.count >= 2,
              references.count == catalog.count,
              let highestSlot = cards.map(\.slot).max() else {
            return independent
        }

        let independentMean: Float = scores.enumerated().reduce(Float(0)) { partial, pair in
            let (cardIndex, row) = pair
            guard let referenceIndex = independent[cardIndex] else { return partial }
            return partial + row[referenceIndex]
        } / Float(cards.count)

        let maximumStart = references.count - 1 - highestSlot
        guard maximumStart >= 0 else { return independent }

        var sequenceScores: [(start: Int, mean: Float)] = []
        sequenceScores.reserveCapacity(maximumStart + 1)

        for start in 0...maximumStart {
            var total: Float = 0
            var valid = true
            for (cardIndex, card) in cards.enumerated() {
                let referenceIndex = start + card.slot
                guard scores[cardIndex].indices.contains(referenceIndex) else {
                    valid = false
                    break
                }
                total += scores[cardIndex][referenceIndex]
            }
            if valid {
                sequenceScores.append((start, total / Float(cards.count)))
            }
        }

        let ranked = sequenceScores.sorted { $0.mean < $1.mean }
        guard let best = ranked.first else { return independent }
        let second = ranked.dropFirst().first?.mean ?? .greatestFiniteMagnitude

        // When the game is sorted by Type, visible grid slots are contiguous in
        // the built-in catalog. Use that sequence only when it stays close to
        // Vision's independent optimum and wins clearly over other starts. This
        // prevents a different Fortnite sort mode from forcing bad identities.
        let nearIndependent = best.mean <= independentMean * 1.45 + 0.35
        let clearWinner = second == .greatestFiniteMagnitude
            || second - best.mean >= max(0.18, best.mean * 0.025)

        guard nearIndependent, clearWinner else { return independent }
        return cards.map { best.start + $0.slot }
    }

    private func cropTopLeft(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(imageBounds)
        guard clipped.width >= 2, clipped.height >= 2 else { return nil }

        // CIImage uses a bottom-left origin. The incoming rectangles use the
        // visual top-left origin because that is how the Fortnite UI is laid out.
        let ciRect = CGRect(
            x: clipped.minX,
            y: CGFloat(image.height) - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
        let source = CIImage(cgImage: image)
        return ciContext.createCGImage(source.cropped(to: ciRect), from: ciRect)
    }

    private func contentViewport(in image: CGImage) -> CGRect {
        let sampleWidth = 256
        let sampleHeight = max(96, Int(
            (CGFloat(image.height) / CGFloat(max(image.width, 1))) * CGFloat(sampleWidth)
        ))
        let bytesPerRow = sampleWidth * 4
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        let drewImage = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .low
            context.translateBy(x: 0, y: CGFloat(sampleHeight))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }

        guard drewImage else {
            return CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }

        func rowIsActive(_ y: Int) -> Bool {
            var active = 0
            for x in 0..<sampleWidth {
                let offset = y * bytesPerRow + x * 4
                let maximum = max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2]))
                if maximum > 16 { active += 1 }
            }
            return Double(active) / Double(sampleWidth) > 0.08
        }

        func columnIsActive(_ x: Int) -> Bool {
            var active = 0
            for y in 0..<sampleHeight {
                let offset = y * bytesPerRow + x * 4
                let maximum = max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2]))
                if maximum > 16 { active += 1 }
            }
            return Double(active) / Double(sampleHeight) > 0.08
        }

        guard let top = (0..<sampleHeight).first(where: rowIsActive),
              let bottom = (0..<sampleHeight).last(where: rowIsActive),
              let left = (0..<sampleWidth).first(where: columnIsActive),
              let right = (0..<sampleWidth).last(where: columnIsActive) else {
            return CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }

        let normalized = CGRect(
            x: CGFloat(left) / CGFloat(sampleWidth),
            y: CGFloat(top) / CGFloat(sampleHeight),
            width: CGFloat(right - left + 1) / CGFloat(sampleWidth),
            height: CGFloat(bottom - top + 1) / CGFloat(sampleHeight)
        )

        guard normalized.width > 0.60, normalized.height > 0.60 else {
            return CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }

        return CGRect(
            x: normalized.minX * CGFloat(image.width),
            y: normalized.minY * CGFloat(image.height),
            width: normalized.width * CGFloat(image.width),
            height: normalized.height * CGFloat(image.height)
        )
    }
}

private struct CardFeature {
    let slot: Int
    let level: Int
    let feature: VNFeaturePrintObservation
}

private struct ReferenceFeature {
    let item: SpriteItem
    let catalogIndex: Int
    let feature: VNFeaturePrintObservation
}

private enum ScreenshotAnalysisError: LocalizedError {
    case unreadableImage
    case missingReferenceArtwork

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "That screenshot could not be opened as an image."
        case .missingReferenceArtwork:
            return "The built-in Sprite artwork could not be loaded for screenshot matching."
        }
    }
}
