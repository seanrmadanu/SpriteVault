import Foundation
import Vision
import CoreImage
import ImageIO
import CoreGraphics

actor ScreenshotSpriteAnalyzer {
    static let shared = ScreenshotSpriteAnalyzer()

    private let catalog = SpriteCatalog.all
    private lazy var catalogByLongestName = catalog.sorted { $0.name.count > $1.name.count }
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var cachedReferences: [ReferenceFeature]?

    // Normalized to the visible 16:9 Fortnite viewport. Letterboxing is removed
    // first by contentViewport(in:), so capture-card and Remote Play windows can
    // have arbitrary outer sizes without changing these values.
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
        return try await analyzeFrame(image: screenshot, onProgress: onProgress).detections
    }

    func analyze(
        image screenshot: CGImage,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [DetectedSprite] {
        try await analyzeFrame(image: screenshot, onProgress: onProgress).detections
    }

    /// Live capture gets richer metadata than a media import. In addition to
    /// unlocked Sprite detections, this reports how many catalog positions were
    /// visible and which slots looked locked. That lets the session UI separate
    /// "collection 85/117" from "scan coverage 96/117".
    func analyzeFrame(
        image screenshot: CGImage,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> SpriteFrameAnalysis {
        try Task.checkCancellation()
        let viewport = contentViewport(in: screenshot)

        onProgress(0.03, "Checking for Sprites → Collection…")
        guard try isCollectionScreen(screenshot, viewport: viewport) else {
            onProgress(1.0, "Waiting for the Fortnite Sprites Collection screen…")
            return SpriteFrameAnalysis(
                detections: [],
                isCollectionScreen: false,
                visibleSlots: 0,
                inferredPageStart: nil,
                lockedSlots: [],
                selectedSpriteName: nil
            )
        }

        // The right panel gives an exact identity for the selected Sprite and is
        // particularly valuable for a Sprite that was lost in a past match,
        // because Fortnite keeps it visible but greys out its grid card.
        let detail = try recognizedRightPanel(in: screenshot, viewport: viewport)

        var cards: [CardFeature] = []
        var selectionCandidates: [(slot: Int, score: Double)] = []
        var readableSlots = Set<Int>()
        onProgress(0.08, "Reading the visible Sprite cards…")

        for slot in 0..<12 {
            try Task.checkCancellation()
            let rect = cardRect(for: slot, viewport: viewport)
            guard let card = cropTopLeft(screenshot, to: rect) else { continue }
            selectionCandidates.append((slot, selectionScore(in: card)))

            let progress = 0.08 + (Double(slot + 1) / 12.0) * 0.36
            guard let level = try recognizedLevel(in: card) else {
                if slot.isMultiple(of: 3) {
                    onProgress(progress, "Waiting for a stable grid; checking levels…")
                }
                continue
            }

            guard let artwork = artworkCrop(from: card),
                  let feature = try featurePrint(for: artwork) else {
                continue
            }

            readableSlots.insert(slot)
            cards.append(CardFeature(slot: slot, level: level, feature: feature))
            onProgress(progress, "Found visible card · Lvl \(level)")
        }

        var detections: [DetectedSprite] = []

        if !cards.isEmpty {
            onProgress(0.48, "Matching card artwork to the Sprite catalog…")
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

            detections = cards.enumerated().compactMap { cardIndex, card -> DetectedSprite? in
                guard let referenceIndex = assignments[cardIndex],
                      references.indices.contains(referenceIndex) else { return nil }

                let reference = references[referenceIndex]
                return DetectedSprite(
                    name: reference.item.name,
                    rarity: reference.item.rarity,
                    status: .collected,
                    level: card.level,
                    mastered: card.level == 5,
                    timestamp: 0,
                    observations: 1,
                    catalogIndex: reference.catalogIndex,
                    gridSlot: card.slot
                )
            }
        }

        var selectedSpriteName: String?
        if let detail,
           let selectedSlot = bestSelectedSlot(selectionCandidates) {
            selectedSpriteName = detail.item.name
            readableSlots.insert(selectedSlot)

            let catalogIndex = catalog.firstIndex(where: {
                normalize($0.name) == normalize(detail.item.name)
            })
            let selectedDetection = DetectedSprite(
                name: detail.item.name,
                rarity: detail.item.rarity,
                status: detail.isLost ? .lost : .collected,
                level: detail.level,
                mastered: detail.mastered || detail.level == 5,
                timestamp: 0,
                observations: 1,
                catalogIndex: catalogIndex,
                gridSlot: selectedSlot
            )

            // The right-side title is stronger evidence than artwork matching.
            // Replace an uncertain visual match occupying the selected card.
            detections.removeAll { $0.gridSlot == selectedSlot || normalize($0.name) == normalize(detail.item.name) }
            detections.append(selectedDetection)
        }

        // A screenshot cannot legitimately contain the same catalog identity in
        // two slots. Right-panel detections were appended last, so prefer them.
        var byName: [String: DetectedSprite] = [:]
        for detection in detections {
            byName[normalize(detection.name)] = detection
        }
        let unique = Array(byName.values).sorted {
            ($0.gridSlot ?? Int.max) < ($1.gridSlot ?? Int.max)
        }

        let pageStart = inferredPageStart(from: unique)
        let visibleSlots: Int
        if let pageStart {
            visibleSlots = max(0, min(12, catalog.count - pageStart))
        } else {
            visibleSlots = 12
        }

        let identifiedSlots = Set(unique.compactMap(\.gridSlot))
        let lockedSlots = Set(0..<visibleSlots).subtracting(identifiedSlots)

        if unique.isEmpty {
            onProgress(1.0, "Collection visible, but no unlocked Sprite details were readable yet.")
        } else {
            onProgress(1.0, "Matched \(unique.count) unlocked Sprite\(unique.count == 1 ? "" : "s") in this stable view.")
        }

        return SpriteFrameAnalysis(
            detections: unique,
            isCollectionScreen: true,
            visibleSlots: visibleSlots,
            inferredPageStart: pageStart,
            lockedSlots: lockedSlots,
            selectedSpriteName: selectedSpriteName
        )
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
            y: viewport.minY + viewport.height * 0.045,
            width: viewport.width * 0.66,
            height: viewport.height * 0.245
        )
        guard let header = cropTopLeft(screenshot, to: headerRect) else { return false }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.032
        request.customWords = ["SPRITES", "COLLECTION", "REWARDS"]

        let handler = VNImageRequestHandler(cgImage: header, options: [:])
        try handler.perform([request])

        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(2).first?.string.uppercased() }
            .joined(separator: " ")
            .replacingOccurrences(of: "0", with: "O")

        // Require both the top navigation tab and the Collection section. That
        // keeps unrelated Fortnite menus from ever being allowed to mutate data.
        return text.contains("SPRITES") && text.contains("COLLECTION")
    }

    private func recognizedRightPanel(in screenshot: CGImage, viewport: CGRect) throws -> DetailPanelMatch? {
        let rect = CGRect(
            x: viewport.minX + viewport.width * 0.60,
            y: viewport.minY + viewport.height * 0.43,
            width: viewport.width * 0.36,
            height: viewport.height * 0.34
        )
        guard let panel = cropTopLeft(screenshot, to: rect) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.025
        request.customWords = catalog.flatMap { [$0.name, "\($0.name) Sprite"] }
            + ["SPRITE MASTERED", "LOST IN PAST MATCH"]
            + (1...5).flatMap { ["Lvl \($0)", "Level \($0)"] }

        let handler = VNImageRequestHandler(cgImage: panel, options: [:])
        try handler.perform([request])

        let strings = (request.results ?? []).flatMap { observation in
            observation.topCandidates(3).map(\.string)
        }
        guard !strings.isEmpty else { return nil }

        let canonical = strings.map(canonicalOCRText)
        let joined = canonical.joined(separator: " ")
        let isLost = joined.contains("lostinpastmatch") || (joined.contains("lost") && joined.contains("pastmatch"))
        let mastered = joined.contains("spritemastered") || (joined.contains("sprite") && joined.contains("mastered"))

        let matchedItem = catalogByLongestName.first { item in
            let key = normalize(item.name)
            return canonical.contains(where: { line in
                line.contains(key + "sprite") || line == key || line.contains(key)
            })
        }
        guard let item = matchedItem else { return nil }

        var level: Int?
        if mastered {
            level = 5
        } else {
            for string in strings {
                if let parsed = parseLevel(string) {
                    level = parsed
                    break
                }
            }
        }

        return DetailPanelMatch(item: item, level: level, mastered: mastered, isLost: isLost)
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
        if let cachedReferences { return cachedReferences }

        var references: [ReferenceFeature] = []
        references.reserveCapacity(catalog.count)

        for (index, item) in catalog.enumerated() {
            try Task.checkCancellation()
            guard let url = ResourceLocator.spriteImageURL(named: item.imageAssetName),
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

        let nearIndependent = best.mean <= independentMean * 1.45 + 0.35
        let clearWinner = second == .greatestFiniteMagnitude
            || second - best.mean >= max(0.18, best.mean * 0.025)

        guard nearIndependent, clearWinner else { return independent }
        return cards.map { best.start + $0.slot }
    }

    private func inferredPageStart(from detections: [DetectedSprite]) -> Int? {
        let candidates = detections.compactMap { detection -> Int? in
            guard let catalogIndex = detection.catalogIndex,
                  let gridSlot = detection.gridSlot else { return nil }
            let start = catalogIndex - gridSlot
            return start >= 0 ? start : nil
        }
        guard !candidates.isEmpty else { return nil }

        let grouped = Dictionary(grouping: candidates, by: { $0 })
            .mapValues(\.count)
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
        guard let best = grouped.first else { return nil }
        // A single exact right-panel anchor is allowed. With several visual
        // matches, require at least half of them to agree on the same page start.
        if candidates.count == 1 { return best.key }
        return best.value * 2 >= candidates.count ? best.key : nil
    }

    private func bestSelectedSlot(_ candidates: [(slot: Int, score: Double)]) -> Int? {
        guard let best = candidates.max(by: { $0.score < $1.score }),
              best.score >= 0.18 else { return nil }
        let second = candidates
            .filter { $0.slot != best.slot }
            .map(\.score)
            .max() ?? 0
        // The selected card is normally much brighter because of Fortnite's
        // white focus treatment. Avoid forcing a right-panel identity onto a
        // slot when the focus highlight is ambiguous.
        guard best.score >= second + 0.035 || best.score >= 0.30 else { return nil }
        return best.slot
    }

    private func selectionScore(in image: CGImage) -> Double {
        guard let pixels = downsampleRGBA(image, width: 24, height: 24) else { return 0 }
        var brightNeutral = 0
        var sampled = 0
        for y in 0..<24 {
            for x in 0..<24 {
                // Focus on the border and lower label region where selected
                // Fortnite cards become white/near-white.
                let border = x < 3 || x >= 21 || y < 3 || y >= 20
                guard border else { continue }
                let i = (y * 24 + x) * 4
                let r = Int(pixels[i])
                let g = Int(pixels[i + 1])
                let b = Int(pixels[i + 2])
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                if maxC > 205 && maxC - minC < 42 { brightNeutral += 1 }
                sampled += 1
            }
        }
        return sampled > 0 ? Double(brightNeutral) / Double(sampled) : 0
    }

    private func downsampleRGBA(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }

    private func cropTopLeft(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(imageBounds)
        guard clipped.width >= 2, clipped.height >= 2 else { return nil }

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
            ) else { return false }

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

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private func canonicalOCRText(_ value: String) -> String {
        var text = normalize(value)
            .replacingOccurrences(of: "lootin", with: "")
            .replacingOccurrences(of: "spr1te", with: "sprite")
            .replacingOccurrences(of: "sprlte", with: "sprite")
            .replacingOccurrences(of: "sprtte", with: "sprite")
            .replacingOccurrences(of: "h0lofoil", with: "holofoil")
            .replacingOccurrences(of: "gummv", with: "gummy")
            .replacingOccurrences(of: "summy", with: "gummy")
            .replacingOccurrences(of: "galaky", with: "galaxy")
        if text.hasPrefix("ofoil") { text = "hol" + text }
        return text
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

private struct DetailPanelMatch {
    let item: SpriteItem
    let level: Int?
    let mastered: Bool
    let isLost: Bool
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
