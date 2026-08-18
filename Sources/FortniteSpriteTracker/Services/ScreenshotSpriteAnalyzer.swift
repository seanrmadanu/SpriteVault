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

        // Calibrate the grid from what Fortnite is actually drawing instead of
        // assuming a permanent 3x4 stencil. The level labels are excellent row
        // anchors and move with the cards while scrolling.
        onProgress(0.03, "Calibrating the visible Sprite cards…")
        let headerConfirmed = try isCollectionScreen(screenshot, viewport: viewport)
        let detail = try recognizedRightPanel(in: screenshot, viewport: viewport)
        let grid = try recognizedGridLayout(in: screenshot, viewport: viewport)

        let collectionConfirmed = headerConfirmed || detail != nil || grid.levelsBySlot.count >= 2
        guard collectionConfirmed else {
            onProgress(1.0, "Waiting for the Fortnite Sprites Collection screen…")
            return SpriteFrameAnalysis(
                detections: [],
                isCollectionScreen: false,
                visibleSlots: 0,
                inferredPageStart: nil,
                lockedSlots: [],
                needsHelpSlots: [],
                selectedSpriteName: nil,
                cardAnchors: []
            )
        }

        let cardRects = grid.rects
        var cards: [CardFeature] = []
        var selectionCandidates: [(slot: Int, score: Double)] = []
        var confidentLockedSlots = Set<Int>()
        var needsHelpSlots = Set<Int>()
        onProgress(0.16, grid.isCalibrated ? "Aligned to the visible Sprite rows…" : "Matching the visible Sprite cards…")

        for (slot, rect) in cardRects.enumerated() {
            try Task.checkCancellation()
            guard let card = cropTopLeft(screenshot, to: rect) else { continue }
            selectionCandidates.append((slot, selectionScore(in: card)))

            let level = grid.levelsBySlot[slot]
            // Mastery is permanent state. Level 5 is enough to establish it,
            // but a crown keeps mastery true at Level 1-4 after a Sprite is lost.
            let mastered = (level == 5) || hasMasteryCrown(in: card)
            let visualScore = unlockedVisualScore(in: card)

            guard level != nil || mastered || visualScore >= 0.28 else {
                if visualScore <= 0.10 {
                    confidentLockedSlots.insert(slot)
                } else {
                    needsHelpSlots.insert(slot)
                }
                continue
            }

            guard let artwork = artworkCrop(from: card),
                  let feature = try featurePrint(for: artwork) else {
                needsHelpSlots.insert(slot)
                continue
            }

            cards.append(CardFeature(slot: slot, level: level, mastered: mastered, feature: feature))
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
                    mastered: card.mastered,
                    timestamp: 0,
                    observations: 1,
                    catalogIndex: reference.catalogIndex,
                    gridSlot: card.slot
                )
            }
        }

        var selectedSpriteName: String?
        if let detail {
            // The right panel remains an independent source of truth. Its name
            // can confirm a card even when artwork matching is ambiguous.
            let selectedSlot = bestSelectedSlot(selectionCandidates)
            selectedSpriteName = detail.item.name

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

            if let selectedSlot {
                detections.removeAll {
                    $0.gridSlot == selectedSlot || normalize($0.name) == normalize(detail.item.name)
                }
            } else {
                detections.removeAll { normalize($0.name) == normalize(detail.item.name) }
            }
            detections.append(selectedDetection)
        }

        var byName: [String: DetectedSprite] = [:]
        for detection in detections {
            byName[normalize(detection.name)] = detection
        }
        let unique = Array(byName.values).sorted {
            ($0.gridSlot ?? Int.max) < ($1.gridSlot ?? Int.max)
        }

        let pageStart = inferredPageStart(from: unique)
        let visibleSlots = cardRects.count
        let identifiedSlots = Set(unique.compactMap(\.gridSlot))
        let visibleSlotSet = Set(0..<visibleSlots)
        let unresolvedSlots = visibleSlotSet.subtracting(identifiedSlots)
        let lockedSlots = confidentLockedSlots.intersection(unresolvedSlots)
        needsHelpSlots.formUnion(unresolvedSlots.subtracting(lockedSlots))

        let anchors: [SpriteCardAnchor]
        if grid.isCalibrated {
            anchors = cardRects.enumerated().compactMap { slot, rect in
                guard let card = cropTopLeft(screenshot, to: rect) else { return nil }
                return makeCardAnchor(slot: slot, rect: rect, card: card, image: screenshot)
            }
        } else {
            // Do not draw a guessed stencil. Recognition may still use the old
            // fallback crops, but the overlay waits until geometry is grounded.
            anchors = []
        }

        if unique.isEmpty {
            onProgress(1.0, grid.isCalibrated
                ? "Cards aligned, but no unlocked Sprite details were readable yet."
                : "Collection visible; waiting for enough card anchors to align the overlay.")
        } else {
            onProgress(1.0, "Matched \(unique.count) unlocked Sprite\(unique.count == 1 ? "" : "s") in this stable view.")
        }

        return SpriteFrameAnalysis(
            detections: unique,
            isCollectionScreen: true,
            visibleSlots: visibleSlots,
            inferredPageStart: pageStart,
            lockedSlots: lockedSlots,
            needsHelpSlots: needsHelpSlots,
            selectedSpriteName: selectedSpriteName,
            cardAnchors: anchors
        )
    }

    /// Stronger second pass for one overlay card. This is intentionally only
    /// invoked after a Needs Help card has been hovered for a moment.
    func deepAnalyzeCard(image screenshot: CGImage, slot: Int) async throws -> DetectedSprite? {
        try Task.checkCancellation()

        let viewport = contentViewport(in: screenshot)
        let grid = try recognizedGridLayout(in: screenshot, viewport: viewport)
        guard grid.rects.indices.contains(slot) else { return nil }
        let rect = grid.rects[slot]
        guard let card = cropTopLeft(screenshot, to: rect) else { return nil }

        let level = grid.levelsBySlot[slot]
        let mastered = (level == 5) || hasMasteryCrown(in: card)
        guard level != nil || mastered || unlockedVisualScore(in: card) >= 0.16 else { return nil }

        let width = CGFloat(card.width)
        let height = CGFloat(card.height)
        let cropRects = [
            CGRect(x: width * 0.07, y: height * 0.11, width: width * 0.86, height: height * 0.66),
            CGRect(x: width * 0.04, y: height * 0.08, width: width * 0.92, height: height * 0.70),
            CGRect(x: width * 0.10, y: height * 0.14, width: width * 0.80, height: height * 0.60)
        ]

        let references = try referenceFeatures(onProgress: { _, _ in })
        guard !references.isEmpty else { return nil }
        var bestByReference = Array(repeating: Float.greatestFiniteMagnitude, count: references.count)

        for cropRect in cropRects {
            guard let crop = cropTopLeft(card, to: cropRect),
                  let feature = try featurePrint(for: crop) else { continue }
            for (index, reference) in references.enumerated() {
                let distance = try featureDistance(feature, reference.feature)
                bestByReference[index] = min(bestByReference[index], distance)
            }
        }

        let ranked = bestByReference.enumerated().sorted { $0.element < $1.element }
        guard let best = ranked.first else { return nil }
        let second = ranked.dropFirst().first?.element ?? .greatestFiniteMagnitude
        // Require a real separation on this expensive second pass. The margin
        // scales slightly with the feature distance so near-identical variants
        // do not become false-positive ownership updates.
        let requiredMargin = max(Float(0.08), best.element * 0.012)
        guard second == .greatestFiniteMagnitude || second - best.element >= requiredMargin else { return nil }

        let reference = references[best.offset]
        return DetectedSprite(
            name: reference.item.name,
            rarity: reference.item.rarity,
            status: .collected,
            level: level,
            mastered: mastered,
            timestamp: 0,
            observations: 1,
            catalogIndex: reference.catalogIndex,
            gridSlot: slot
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
        // Deliberately broad. Full-screen, OBS projector, Remote Play, and capture
        // cards can move the detail block a little while keeping the same 16:9 UI.
        let rect = CGRect(
            x: viewport.minX + viewport.width * 0.52,
            y: viewport.minY + viewport.height * 0.31,
            width: viewport.width * 0.46,
            height: viewport.height * 0.50
        )
        guard let rawPanel = cropTopLeft(screenshot, to: rect),
              let panel = preparedTextImage(rawPanel, targetWidth: 980) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.020
        request.customWords = recognitionWords

        let handler = VNImageRequestHandler(cgImage: panel, options: [:])
        try handler.perform([request])

        let strings = (request.results ?? []).flatMap { observation in
            observation.topCandidates(3).map(\.string)
        }
        guard !strings.isEmpty else { return nil }

        let canonical = strings.map(canonicalOCRText)
        let joined = canonical.joined(separator: "")
        let isLost = joined.contains("lostinpastmatch") || (joined.contains("lost") && joined.contains("pastmatch"))
        let mastered = joined.contains("spritemastered") || (joined.contains("sprite") && joined.contains("mastered"))

        // Joining all OCR fragments handles Fortnite titles that wrap onto two
        // rows, while longest-name-first matching prevents variants collapsing
        // into their base Sprite (for example Holofoil Batman -> Batman).
        let item = catalogByLongestName.first { candidate in
            let key = normalize(candidate.name)
            return joined.contains(key + "sprite") || joined.contains(key)
        } ?? bestFuzzyCatalogMatch(in: canonical)

        guard let item else { return nil }

        // Mastery and the current level are independent. A mastered Sprite can
        // be Level 1 after it was lost, so "SPRITE MASTERED" must never force 5.
        var level: Int?
        for string in strings {
            if let parsed = parseLevel(string) {
                level = parsed
                break
            }
        }

        return DetailPanelMatch(item: item, level: level, mastered: mastered, isLost: isLost)
    }

    /// One OCR request for all twelve cards instead of twelve independent Vision
    /// requests. The observations are mapped back onto the regular 3x4 grid.
    /// Finds the rows that Fortnite is actually drawing. We use the level
    /// labels as anchors because they move with the cards while the collection
    /// scrolls. If calibration is not confident we keep the old crops only for
    /// recognition and deliberately return no overlay anchors.
    private func recognizedGridLayout(in screenshot: CGImage, viewport: CGRect) throws -> GridLayout {
        let searchRect = CGRect(
            x: viewport.minX + viewport.width * 0.045,
            y: viewport.minY + viewport.height * 0.16,
            width: viewport.width * 0.30,
            height: viewport.height * 0.78
        )
        guard let rawGrid = cropTopLeft(screenshot, to: searchRect),
              let gridImage = preparedTextImage(rawGrid, targetWidth: 1100) else {
            return fallbackGridLayout(viewport: viewport, observations: [])
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.015
        request.customWords = (1...5).flatMap { ["Lvl \($0)", "Level \($0)"] }

        let handler = VNImageRequestHandler(cgImage: gridImage, options: [:])
        try handler.perform([request])

        var observations: [GridLevelObservation] = []
        for observation in request.results ?? [] {
            guard let level = observation.topCandidates(3).compactMap({ parseLevel($0.string) }).first else {
                continue
            }
            let point = CGPoint(
                x: searchRect.minX + observation.boundingBox.midX * searchRect.width,
                y: searchRect.minY + (1 - observation.boundingBox.midY) * searchRect.height
            )
            observations.append(GridLevelObservation(level: level, point: point))
        }

        let cardWidth = viewport.width * 0.076
        let cardHeight = viewport.height * 0.145
        let defaultRowStep = viewport.height * 0.180
        let rowThreshold = viewport.height * 0.045

        // Cluster OCR anchors into rows. Two labels in a row are enough to trust
        // its geometry; a single isolated OCR result is too easy to misplace.
        var rowGroups: [[GridLevelObservation]] = []
        for observation in observations.sorted(by: { $0.point.y < $1.point.y }) {
            if let index = rowGroups.indices.last,
               let meanY = meanRowY(rowGroups[index]),
               abs(observation.point.y - meanY) <= rowThreshold {
                rowGroups[index].append(observation)
            } else {
                rowGroups.append([observation])
            }
        }

        var rowTops = rowGroups
            .filter { $0.count >= 2 }
            .compactMap { group -> CGFloat? in
                guard let levelY = meanRowY(group) else { return nil }
                // Fortnite's level strip sits close to the bottom of the card.
                return levelY - cardHeight * 0.86
            }
            .sorted()

        // If an entire middle row is locked it may have no Lvl text. Fill only
        // obvious one-row gaps between two grounded rows; never invent rows at
        // the top/bottom of the screen.
        if rowTops.count >= 2 {
            var filled: [CGFloat] = []
            for index in rowTops.indices {
                filled.append(rowTops[index])
                guard index < rowTops.count - 1 else { continue }
                let gap = rowTops[index + 1] - rowTops[index]
                if gap > defaultRowStep * 1.55 && gap < defaultRowStep * 2.45 {
                    filled.append(rowTops[index] + defaultRowStep)
                }
            }
            rowTops = filled.sorted()
        }

        let minimumTop = viewport.minY + viewport.height * 0.235
        let maximumBottom = viewport.maxY - viewport.height * 0.055
        rowTops = rowTops.filter { top in
            top >= minimumTop && top + cardHeight <= maximumBottom
        }

        guard !rowTops.isEmpty else {
            return fallbackGridLayout(viewport: viewport, observations: observations)
        }

        // Horizontal card spacing is stable, but compensate for small window /
        // capture offsets using the OCR labels themselves.
        let expectedCenters = (0..<3).map { column in
            viewport.minX + viewport.width * (firstColumnCenter + CGFloat(column) * columnStep)
        }
        var shifts: [CGFloat] = []
        for observation in observations {
            let estimatedCenter = observation.point.x + cardWidth * 0.30
            if let expected = expectedCenters.min(by: { abs($0 - estimatedCenter) < abs($1 - estimatedCenter) }) {
                shifts.append(estimatedCenter - expected)
            }
        }
        let horizontalShift = median(shifts).map {
            min(max($0, -viewport.width * 0.025), viewport.width * 0.025)
        } ?? 0

        var rects: [CGRect] = []
        rects.reserveCapacity(rowTops.count * 3)
        for top in rowTops {
            for expectedCenter in expectedCenters {
                rects.append(CGRect(
                    x: expectedCenter + horizontalShift - cardWidth / 2,
                    y: top,
                    width: cardWidth,
                    height: cardHeight
                ))
            }
        }

        var levelsBySlot: [Int: Int] = [:]
        for observation in observations {
            guard let slot = nearestSlot(to: observation.point, in: rects) else { continue }
            let expanded = rects[slot].insetBy(dx: -cardWidth * 0.20, dy: -cardHeight * 0.16)
            guard expanded.contains(observation.point) else { continue }
            levelsBySlot[slot] = max(levelsBySlot[slot] ?? 0, observation.level)
        }

        return GridLayout(rects: rects, levelsBySlot: levelsBySlot, isCalibrated: true)
    }

    private func fallbackGridLayout(
        viewport: CGRect,
        observations: [GridLevelObservation]
    ) -> GridLayout {
        let rects = (0..<12).map { cardRect(for: $0, viewport: viewport) }
        var levelsBySlot: [Int: Int] = [:]
        for observation in observations {
            guard let slot = nearestSlot(to: observation.point, in: rects) else { continue }
            levelsBySlot[slot] = max(levelsBySlot[slot] ?? 0, observation.level)
        }
        return GridLayout(rects: rects, levelsBySlot: levelsBySlot, isCalibrated: false)
    }

    private func nearestSlot(to point: CGPoint, in rects: [CGRect]) -> Int? {
        rects.enumerated().min { lhs, rhs in
            distanceSquared(point, CGPoint(x: lhs.element.midX, y: lhs.element.midY))
                < distanceSquared(point, CGPoint(x: rhs.element.midX, y: rhs.element.midY))
        }?.offset
    }

    private func meanRowY(_ observations: [GridLevelObservation]) -> CGFloat? {
        guard !observations.isEmpty else { return nil }
        return observations.reduce(CGFloat(0)) { $0 + $1.point.y } / CGFloat(observations.count)
    }

    private func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
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

    private var recognitionWords: [String] {
        var words = catalog.flatMap { [$0.name, "\($0.name) Sprite"] }
        for item in catalog where item.name.contains("Llama") {
            let alias = item.name.replacingOccurrences(of: "Llama", with: "Lootin' Llama")
            words.append(alias)
            words.append("\(alias) Sprite")
        }
        words += ["SPRITE MASTERED", "LOST IN PAST MATCH"]
        words += SpriteRarity.allCases.map(\.rawValue)
        words += (1...5).flatMap { ["Lvl \($0)", "Level \($0)"] }
        return words
    }

    private func bestFuzzyCatalogMatch(in canonicalLines: [String]) -> SpriteItem? {
        var best: (item: SpriteItem, distance: Int)?
        var secondDistance = Int.max

        for line in canonicalLines {
            let target = line
                .replacingOccurrences(of: "mastered", with: "")
                .replacingOccurrences(of: "sprite", with: "")
            guard target.count >= 4 else { continue }

            let ranked = catalog.map { item in
                (item: item, distance: editDistance(target, normalize(item.name)))
            }.sorted { $0.distance < $1.distance }
            guard let candidate = ranked.first else { continue }
            let runner = ranked.dropFirst().first?.distance ?? Int.max
            if best == nil || candidate.distance < best!.distance {
                best = candidate
                secondDistance = runner
            }
        }

        guard let best else { return nil }
        let allowance = normalize(best.item.name).count >= 10 ? 2 : 1
        guard best.distance <= allowance, secondDistance > best.distance else { return nil }
        return best.item
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous.last ?? 0
    }

    private func preparedTextImage(_ image: CGImage, targetWidth: CGFloat) -> CGImage? {
        let source = CIImage(cgImage: image)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.35,
                kCIInputBrightnessKey: 0.02
            ])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.45])

        let scale = max(1, targetWidth / max(source.extent.width, 1))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    private func unlockedVisualScore(in image: CGImage) -> Double {
        guard let pixels = downsampleRGBA(image, width: 20, height: 20) else { return 0 }
        var visible = 0
        var samples = 0
        for y in 2..<18 {
            for x in 2..<18 {
                let i = (y * 20 + x) * 4
                let r = Int(pixels[i])
                let g = Int(pixels[i + 1])
                let b = Int(pixels[i + 2])
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                if maxC > 78 && (maxC - minC > 22 || maxC > 155) { visible += 1 }
                samples += 1
            }
        }
        return samples > 0 ? Double(visible) / Double(samples) : 0
    }

    /// Fortnite keeps the mastery crown even when a previously mastered Sprite
    /// returns to Level 1 after being lost. Detect the bright gold crown in the
    /// lower-right status area independently from the OCR'd level.
    private func hasMasteryCrown(in image: CGImage) -> Bool {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let crownRegion = CGRect(
            x: width * 0.48,
            y: height * 0.69,
            width: width * 0.50,
            height: height * 0.29
        )
        guard let crop = cropTopLeft(image, to: crownRegion),
              let pixels = downsampleRGBA(crop, width: 36, height: 20) else { return false }

        var gold = 0
        var brightGold = 0
        let sampleCount = 36 * 20
        for index in 0..<sampleCount {
            let i = index * 4
            let r = Int(pixels[i])
            let g = Int(pixels[i + 1])
            let b = Int(pixels[i + 2])
            if r >= 170, g >= 115, b <= 125, r > b + 55, g > b + 25 {
                gold += 1
                if r >= 215, g >= 165, b <= 95 { brightGold += 1 }
            }
        }

        let ratio = Double(gold) / Double(sampleCount)
        let brightRatio = Double(brightGold) / Double(sampleCount)
        return ratio >= 0.035 && brightRatio >= 0.007
    }

    private func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
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
        // A nearest neighbor by itself is not enough evidence. Similar variants
        // can have almost identical feature prints, and the old code would still
        // assign *something*, creating random 👍 cards. Keep the raw nearest
        // candidate for page-sequence scoring, but only expose independent
        // matches when the winner is meaningfully separated from runner-up.
        let nearest = scores.map { row -> Int? in
            row.enumerated().min(by: { $0.element < $1.element })?.offset
        }
        let confidentIndependent = scores.map { confidentNearestIndex(in: $0) }

        guard cards.count >= 2,
              references.count == catalog.count,
              let highestSlot = cards.map(\.slot).max() else {
            return confidentIndependent
        }

        let independentMean: Float = scores.enumerated().reduce(Float(0)) { partial, pair in
            let (cardIndex, row) = pair
            guard let referenceIndex = nearest[cardIndex] else { return partial }
            return partial + row[referenceIndex]
        } / Float(cards.count)

        let maximumStart = references.count - 1 - highestSlot
        guard maximumStart >= 0 else { return confidentIndependent }

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
        guard let best = ranked.first else { return confidentIndependent }
        let second = ranked.dropFirst().first?.mean ?? .greatestFiniteMagnitude

        let nearIndependent = best.mean <= independentMean * 1.45 + 0.35
        let clearWinner = second == .greatestFiniteMagnitude
            || second - best.mean >= max(0.18, best.mean * 0.025)

        guard nearIndependent, clearWinner else { return confidentIndependent }
        return cards.map { best.start + $0.slot }
    }

    private func confidentNearestIndex(in row: [Float]) -> Int? {
        let ranked = row.enumerated().sorted { $0.element < $1.element }
        guard let best = ranked.first else { return nil }
        guard let second = ranked.dropFirst().first else { return best.offset }
        let margin = second.element - best.element
        let requiredMargin = max(Float(0.10), best.element * 0.015)
        return margin >= requiredMargin ? best.offset : nil
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

    private func makeCardAnchor(
        slot: Int,
        rect: CGRect,
        card: CGImage,
        image: CGImage
    ) -> SpriteCardAnchor {
        let imageWidth = max(Double(image.width), 1)
        let imageHeight = max(Double(image.height), 1)
        return SpriteCardAnchor(
            slot: slot,
            x: Double(rect.minX) / imageWidth,
            y: Double(rect.minY) / imageHeight,
            width: Double(rect.width) / imageWidth,
            height: Double(rect.height) / imageHeight,
            visualSignature: visualSignature(in: card)
        )
    }

    /// Tiny average-hash from the inner artwork. It ignores the selection border
    /// and level strip, so changing the Fortnite highlight does not make the
    /// overlay forget a card it already identified.
    private func visualSignature(in card: CGImage) -> UInt64 {
        guard let artwork = artworkCrop(from: card),
              let pixels = downsampleRGBA(artwork, width: 8, height: 8) else { return 0 }

        var luminance = [Int]()
        luminance.reserveCapacity(64)
        for index in 0..<64 {
            let offset = index * 4
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            luminance.append((r * 30 + g * 59 + b * 11) / 100)
        }
        let average = luminance.reduce(0, +) / max(luminance.count, 1)
        var hash: UInt64 = 0
        for (index, value) in luminance.enumerated() where value >= average {
            hash |= UInt64(1) << UInt64(index)
        }
        return hash
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

private struct GridLevelObservation {
    let level: Int
    let point: CGPoint
}

private struct GridLayout {
    let rects: [CGRect]
    let levelsBySlot: [Int: Int]
    let isCalibrated: Bool
}

private struct CardFeature {
    let slot: Int
    let level: Int?
    let mastered: Bool
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
