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
    /// Vertical grid scale measured from the last analysed frame. Written by
    /// `detectedRowTops` so the card rectangles use the pitch that was actually
    /// found rather than one derived from an assumed aspect ratio.
    private var measuredRowStep: CGFloat?
    private var measuredCardHeight: CGFloat?

    // Normalized to the visible 16:9 Fortnite viewport. Letterboxing is removed
    // first by contentViewport(in:), so capture-card and Remote Play windows can
    // have arbitrary outer sizes without changing these values.
    //
    // Fixes.newCardGeometry switches these to the values measured from the
    // ground-truth captures; the pre-fix constants stay for bisecting.
    private var firstColumnCenter: CGFloat {
        Fixes.newCardGeometry ? GridMetrics.firstColumnCentre : 0.118
    }
    private var columnStep: CGFloat {
        Fixes.newCardGeometry ? GridMetrics.columnStep : 0.080
    }
    private let firstRowTop: CGFloat = 0.232
    private var rowStep: CGFloat {
        Fixes.newCardGeometry ? GridMetrics.rowStep : 0.180
    }
    private var cardWidth: CGFloat {
        Fixes.newCardGeometry ? GridMetrics.cardWidth : 0.079
    }
    private var cardHeight: CGFloat {
        Fixes.newCardGeometry ? GridMetrics.cardHeight : 0.166
    }

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
        onProgress: @escaping @Sendable (Double, String) -> Void,
        onCollectionValidated: (@Sendable () -> Void)? = nil,
        onCardsAligned: (@Sendable ([SpriteCardAnchor]) -> Void)? = nil
    ) async throws -> SpriteFrameAnalysis {
        try Task.checkCancellation()
        let viewport = contentViewport(in: screenshot)

        // Nothing is allowed to mutate collection data until both selected-tab
        // treatments are visible: the highlighted SPRITES top-navigation tab
        // and the yellow COLLECTION underline. Card text alone is not proof.
        onProgress(0.03, "Checking the Fortnite Sprites tab…")
        guard try isSpritesCollectionSelected(screenshot, viewport: viewport) else {
            onProgress(1.0, "Please open Sprites → Collection…")
            return SpriteFrameAnalysis(
                detections: [],
                isCollectionScreen: false,
                visibleSlots: 0,
                inferredPageStart: nil,
                coveredCatalogIndexes: [],
                lockedSlots: [],
                needsHelpSlots: [],
                selectedSpriteName: nil,
                cardAnchors: []
            )
        }
        onCollectionValidated?()

        // Calibrate only after the cheap page gate succeeds. This prevents
        // expensive right-panel/grid OCR from running on unrelated windows.
        onProgress(0.10, "Calibrating the visible Sprite cards…")
        let grid = try recognizedGridLayout(in: screenshot, viewport: viewport)
        let detail = try recognizedRightPanel(in: screenshot, viewport: viewport)

        let cardRects = grid.rects
        var cardImages: [Int: CGImage] = [:]
        var selectionCandidates: [(slot: Int, score: Double)] = []
        for (slot, rect) in cardRects.enumerated() {
            guard let card = cropTopLeft(screenshot, to: rect) else { continue }
            cardImages[slot] = card
            selectionCandidates.append((slot, selectionScore(in: card)))
        }

        // Publish grounded geometry before artwork feature matching begins. The
        // live overlay can animate processing dots on the current cards instead
        // of showing no feedback until the expensive matching pass is finished.
        let provisionalPageStart: Int? = {
            guard let detail,
                  let selectedSlot = bestSelectedSlot(selectionCandidates),
                  let catalogIndex = catalog.firstIndex(where: {
                      normalize($0.name) == normalize(detail.item.name)
                  }) else { return nil }
            let candidate = catalogIndex - selectedSlot
            return candidate >= 0 ? candidate : nil
        }()
        let provisionalVisibleSlots = selectedVisibleSlots(
            from: cardRects,
            viewport: viewport,
            pageStart: provisionalPageStart
        )
        if grid.isCalibrated {
            let provisionalAnchors: [SpriteCardAnchor] = cardRects.enumerated().compactMap { slot, rect -> SpriteCardAnchor? in
                guard provisionalVisibleSlots.contains(slot),
                      let card = cardImages[slot] else {
                    return nil
                }

                return makeCardAnchor(
                    slot: slot,
                    rect: rect,
                    card: card,
                    image: screenshot
                )
            }

            if !provisionalAnchors.isEmpty {
                onCardsAligned?(provisionalAnchors)
            }
        }

        let dump = AnalysisDebugDump()
        dump?.writeFrame(screenshot, named: "frame")
        dump?.note("viewport \(viewport)")
        dump?.note("rows \(cardRects.count / GridMetrics.columnCount) calibrated=\(grid.isCalibrated)")
        dump?.note("levelsBySlot \(grid.levelsBySlot.sorted { $0.key < $1.key })")
        dump?.note("rightPanel \(detail?.item.name ?? "nil") level=\(detail.flatMap(\.level).map(String.init) ?? "-")")

        var cards: [CardFeature] = []
        var confidentLockedSlots = Set<Int>()
        var needsHelpSlots = Set<Int>()
        onProgress(0.16, grid.isCalibrated ? "Aligned to the visible Sprite rows…" : "Matching the visible Sprite cards…")

        for slot in cardRects.indices {
            try Task.checkCancellation()
            guard let card = cardImages[slot] else { continue }

            var level = grid.levelsBySlot[slot]
            let mastered = hasMasteryCrown(in: card)
            let status: SpriteCollectionStatus
            let visualScore = unlockedVisualScore(in: card)

            if let dump {
                let ratio = colouredPixelRatio(in: card)
                let pill = pillKind(in: card)
                dump.note(String(
                    format: "slot %2d colour=%.3f pill=%@ crown=%@ level=%@",
                    slot, ratio, String(describing: pill), mastered ? "Y" : "n",
                    level.map(String.init) ?? "-"
                ))
                dump.writeCard(card, slot: slot, label: String(describing: pill))
            }

            if Fixes.colouredPixelOwnership {
                // 3.4 — colour, not brightness, decides ownership, and the pill
                // decides which owned state this is.
                if isLockedCard(card) {
                    confidentLockedSlots.insert(slot)
                    continue
                }
                switch pillKind(in: card) {
                case .white:
                    status = .collected
                case .black:
                    // Needs summon. Still owned, but there is no level to read.
                    status = .lost
                    level = nil
                case .none:
                    // Coloured, so not locked, but no readable pill — usually a
                    // row clipped by the grid edge. Report it as unresolved
                    // rather than inventing a state for it.
                    needsHelpSlots.insert(slot)
                    continue
                }
            } else {
                status = isVisuallyLost(in: card) ? .lost : .collected
                guard level != nil || mastered || visualScore >= 0.28 else {
                    if visualScore <= 0.10 {
                        confidentLockedSlots.insert(slot)
                    } else {
                        needsHelpSlots.insert(slot)
                    }
                    continue
                }
            }

            guard let artwork = artworkCrop(from: card),
                  let feature = try featurePrint(for: artwork) else {
                needsHelpSlots.insert(slot)
                continue
            }

            cards.append(CardFeature(
                slot: slot,
                status: status,
                level: level,
                mastered: mastered,
                feature: feature,
                colours: colourHistogram(for: artwork)
            ))
        }

        var detections: [DetectedSprite] = []

        if !cards.isEmpty {
            onProgress(0.48, "Matching card artwork to the Sprite catalog…")
            let references = try referenceFeatures(onProgress: onProgress)
            guard !references.isEmpty else {
                throw ScreenshotAnalysisError.missingReferenceArtwork
            }

            // 2.1 — shape selects the family (King), colour selects the
            // treatment (Gold / Gummy / Galaxy). Feature prints alone cannot
            // separate the ~90 recolours that share a silhouette.
            let scoreMatrix = try cards.map { card in
                try references.map { reference -> Float in
                    let shape = try featureDistance(card.feature, reference.feature)
                    guard Fixes.colourMatching else { return shape }
                    let colour = colourDistance(card.colours, reference.colours)
                    return shape + colour * colourWeight
                }
            }

            let assignments = chooseAssignments(
                cards: cards,
                references: references,
                scores: scoreMatrix
            )

            if let dump {
                for (cardIndex, card) in cards.enumerated() {
                    let ranked = scoreMatrix[cardIndex].enumerated()
                        .sorted { $0.element < $1.element }
                        .prefix(5)
                        .map { AnalysisDebugDump.Candidate(
                            name: references[$0.offset].item.name,
                            distance: $0.element
                        ) }
                    dump.recordCandidates(slot: card.slot, candidates: Array(ranked))
                }
            }

            detections = cards.enumerated().compactMap { cardIndex, card -> DetectedSprite? in
                guard let referenceIndex = assignments[cardIndex],
                      references.indices.contains(referenceIndex) else { return nil }

                let reference = references[referenceIndex]
                return DetectedSprite(
                    name: reference.item.name,
                    rarity: reference.item.rarity,
                    status: card.status,
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

        // 2.4 — keying by name silently dropped a card whenever two slots matched
        // the same catalog entry. One grid slot is one result.
        let unique: [DetectedSprite]
        if Fixes.keyResultsBySlot {
            var bySlot: [Int: DetectedSprite] = [:]
            var slotless: [DetectedSprite] = []
            for detection in detections {
                if let slot = detection.gridSlot {
                    bySlot[slot] = detection
                } else {
                    slotless.append(detection)
                }
            }
            unique = (bySlot.values.sorted { $0.gridSlot! < $1.gridSlot! }) + slotless
        } else {
            var byName: [String: DetectedSprite] = [:]
            for detection in detections {
                byName[normalize(detection.name)] = detection
            }
            unique = Array(byName.values).sorted {
                ($0.gridSlot ?? Int.max) < ($1.gridSlot ?? Int.max)
            }
        }

        let pageStart = inferredPageStart(from: unique)
        let visibleSlotSet = selectedVisibleSlots(
            from: cardRects,
            viewport: viewport,
            pageStart: pageStart
        )
        let displayedDetections = unique.filter { detection in
            guard let slot = detection.gridSlot else { return true }
            return visibleSlotSet.contains(slot)
        }
        let visibleSlots = visibleSlotSet.count
        let identifiedSlots = Set(displayedDetections.compactMap(\.gridSlot))
        let unresolvedSlots = visibleSlotSet.subtracting(identifiedSlots)
        let lockedSlots = confidentLockedSlots.intersection(unresolvedSlots)
        needsHelpSlots.formUnion(unresolvedSlots.subtracting(lockedSlots))
        needsHelpSlots.formIntersection(visibleSlotSet)

        let coveredCatalogIndexes: Set<Int>
        if let pageStart {
            coveredCatalogIndexes = Set(visibleSlotSet.compactMap { slot in
                let index = pageStart + slot
                return catalog.indices.contains(index) ? index : nil
            })
        } else {
            coveredCatalogIndexes = []
        }

        let anchors: [SpriteCardAnchor]
        if grid.isCalibrated {
            anchors = cardRects.enumerated().compactMap { slot, rect in
                guard visibleSlotSet.contains(slot) else { return nil }
                guard let card = cardImages[slot] else { return nil }
                return makeCardAnchor(slot: slot, rect: rect, card: card, image: screenshot)
            }
        } else {
            // Do not draw a guessed stencil. Recognition may still use the old
            // fallback crops, but the overlay waits until geometry is grounded.
            anchors = []
        }

        if displayedDetections.isEmpty {
            onProgress(1.0, grid.isCalibrated
                ? "Cards aligned, but no unlocked Sprite details were readable yet."
                : "Collection visible; waiting for enough card anchors to align the overlay.")
        } else {
            onProgress(1.0, "Matched \(displayedDetections.count) unlocked Sprite\(displayedDetections.count == 1 ? "" : "s") in this stable view.")
        }

        dump?.note("detections \(displayedDetections.map { "\($0.gridSlot ?? -1):\($0.name)" })")
        dump?.note("locked \(lockedSlots.sorted()) needsHelp \(needsHelpSlots.sorted())")
        dump?.finish()

        return SpriteFrameAnalysis(
            detections: displayedDetections,
            isCollectionScreen: true,
            visibleSlots: visibleSlots,
            inferredPageStart: pageStart,
            coveredCatalogIndexes: coveredCatalogIndexes,
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
        let status: SpriteCollectionStatus = isVisuallyLost(in: card) ? .lost : .collected

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
            status: status,
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

    private func isSpritesCollectionSelected(_ screenshot: CGImage, viewport: CGRect) throws -> Bool {
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

        let observations = request.results ?? []
        let recognized = observations.compactMap { observation -> (String, VNRecognizedTextObservation)? in
            guard let candidate = observation.topCandidates(2).first else { return nil }
            let text = candidate.string.uppercased().replacingOccurrences(of: "0", with: "O")
            return (text, observation)
        }
        // A capture-card feed of a console is soft, so the tab words rarely OCR
        // cleanly — "COLLECTION" comes back as "COLLEERWM", or not at all. Match
        // SPRITES tolerantly; prove COLLECTION from its underline instead.
        guard let spritesObservation = recognized.first(where: { headerWordMatches($0.0, "SPRITES") })?.1 else {
            return false
        }
        guard hasCollectionUnderline(screenshot, viewport: viewport) else { return false }

        // OCR proves the word exists, not that the tab is selected. Derive the
        // visual test rectangle from OCR coordinates so OBS title bars,
        // letterboxing, and different window sizes cannot shift calibration.
        let spritesText = topLeftRect(spritesObservation.boundingBox, in: header)
        let spritesTab = spritesText
            .insetBy(dx: -spritesText.width * 0.42, dy: -spritesText.height * 0.62)
            .intersection(CGRect(x: 0, y: 0, width: header.width, height: header.height))

        // Intentionally conservative: the SPRITES tab must actually be wearing
        // its pale selected pill before overlays or collection writes happen.
        return paleSelectionRatio(in: header, rect: spritesTab) >= 0.20
    }

    /// The COLLECTION sub-tab underline: a solid yellow bar roughly 0.11 of the
    /// picture wide, sitting just under the sub-navigation row.
    ///
    /// Read geometrically rather than from OCR. On a soft console capture the
    /// word itself frequently fails to recognise, but the bar is unmistakable
    /// and lands at the same place in every frame.
    private func hasCollectionUnderline(_ screenshot: CGImage, viewport: CGRect) -> Bool {
        let band = CGRect(
            x: viewport.minX + viewport.width * 0.25,
            y: viewport.minY + viewport.height * 0.19,
            width: viewport.width * 0.55,
            height: viewport.height * 0.07
        )
        guard let crop = cropTopLeft(screenshot, to: band) else { return false }

        let sampleWidth = 240
        let sampleHeight = 40
        guard let pixels = downsampleRGBA(crop, width: sampleWidth, height: sampleHeight) else {
            return false
        }

        // Require a contiguous yellow run. Scattered yellow UI never forms one.
        let required = Int(Double(sampleWidth) * (0.06 / 0.55))
        for y in 0..<sampleHeight {
            var run = 0
            for x in 0..<sampleWidth {
                let offset = (y * sampleWidth + x) * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                if r >= 175, g >= 145, b <= 125, r > b + 45, g > b + 25 {
                    run += 1
                    if run >= required { return true }
                } else {
                    run = 0
                }
            }
        }
        return false
    }

    /// Tolerant match for a header tab word against noisy OCR.
    ///
    /// Accepts an exact hit, a shared leading stem, or any token close enough
    /// in edit distance. This only decides *where* to run the pale/yellow
    /// selection probes, so being generous here costs nothing.
    private func headerWordMatches(_ text: String, _ target: String) -> Bool {
        let haystack = text.uppercased().filter { $0.isLetter }
        guard !haystack.isEmpty else { return false }
        if haystack.contains(target) { return true }

        let stem = String(target.prefix(5))
        if haystack.contains(stem) { return true }

        let allowance = max(2, target.count / 3)
        for token in text.uppercased().split(whereSeparator: { !$0.isLetter }) {
            let candidate = String(token)
            guard abs(candidate.count - target.count) <= allowance else { continue }
            if editDistance(candidate, target) <= allowance { return true }
        }
        return false
    }

    private func topLeftRect(_ visionRect: CGRect, in image: CGImage) -> CGRect {
        CGRect(
            x: visionRect.minX * CGFloat(image.width),
            y: (1 - visionRect.maxY) * CGFloat(image.height),
            width: visionRect.width * CGFloat(image.width),
            height: visionRect.height * CGFloat(image.height)
        )
    }

    private func paleSelectionRatio(in image: CGImage, rect: CGRect) -> Double {
        guard let crop = cropTopLeft(image, to: rect),
              let pixels = downsampleRGBA(crop, width: 40, height: 20) else { return 0 }
        var matches = 0
        let count = 40 * 20
        for index in 0..<count {
            let offset = index * 4
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            let maximum = max(r, max(g, b))
            let minimum = min(r, min(g, b))
            if maximum >= 145, minimum >= 105, maximum - minimum <= 95 {
                matches += 1
            }
        }
        return Double(matches) / Double(count)
    }

    private func yellowSelectionRatio(in image: CGImage, rect: CGRect) -> Double {
        guard let crop = cropTopLeft(image, to: rect),
              let pixels = downsampleRGBA(crop, width: 48, height: 12) else { return 0 }
        var matches = 0
        let count = 48 * 12
        for index in 0..<count {
            let offset = index * 4
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            if r >= 175, g >= 145, b <= 125, r > b + 45, g > b + 25 {
                matches += 1
            }
        }
        return Double(matches) / Double(count)
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

        // 1.6 — one source of truth for card size. These used to be independent
        // pixel constants (0.076 / 0.145) that disagreed with the type's
        // fractions, so calibrated and fallback paths cropped differently.
        let cardWidth = viewport.width * self.cardWidth
        let cardHeight = viewport.height * self.cardHeight
        let defaultRowStep = viewport.height * rowStep
        let rowThreshold = viewport.height * 0.045

        // 1.3/1.4 — rows come from card edges, so a fully locked row keeps its
        // place and slots stay at absolute grid positions. Columns come from the
        // picture too, so the grid does not depend on the outer framing being a
        // clean 16:9 capture.
        if Fixes.detectRowPhase {
            let columns = Fixes.detectGridFromContent
                ? detectedColumns(in: screenshot, viewport: viewport)
                : nil
            measuredCardHeight = nil
            measuredRowStep = nil
            let tops = detectedRowTops(in: screenshot, viewport: viewport, columns: columns)
            if !tops.isEmpty {
                let cardWidth = columns?.cardWidth ?? viewport.width * self.cardWidth
                // Height comes from the measured row pitch, not from the card
                // width via an assumed 16:9 source.
                let cardHeight = measuredCardHeight
                    ?? columns?.cardHeight
                    ?? viewport.height * self.cardHeight
                let centres = (0..<GridMetrics.columnCount).map { column -> CGFloat in
                    if let columns {
                        return columns.firstCentre + CGFloat(column) * columns.step
                    }
                    return viewport.minX + viewport.width * columnCentre(column)
                }
                var rects: [CGRect] = []
                rects.reserveCapacity(tops.count * GridMetrics.columnCount)
                for top in tops {
                    for centre in centres {
                        rects.append(CGRect(
                            x: centre - cardWidth / 2,
                            y: top,
                            width: cardWidth,
                            height: cardHeight
                        ))
                    }
                }
                var levels: [Int: Int] = [:]
                for observation in observations {
                    guard let slot = nearestSlot(to: observation.point, in: rects) else { continue }
                    // 3.3 — the label must fall inside the card it is bound to,
                    // and one card takes one reading rather than a running max.
                    guard rects[slot].contains(observation.point) else { continue }
                    if levels[slot] == nil { levels[slot] = observation.level }
                }
                return GridLayout(rects: rects, levelsBySlot: levels, isCalibrated: true)
            }
        }

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

    /// The three card columns, found from the picture itself.
    ///
    /// Everything else used to hang off the assumption that the letterbox-
    /// trimmed frame *is* the 16:9 game picture. That holds for a clean capture
    /// of the game, but not for a screen recording, a window with chrome, or a
    /// feed with a border — and when it breaks, every card rectangle is wrong.
    ///
    /// The grid is strongly periodic, so find it directly: score candidate
    /// (firstCentre, step) pairs by the vertical edge energy landing on the six
    /// card borders, and take the best. Card width follows from the step, and
    /// card height from the card's known aspect ratio, so the whole geometry is
    /// derived from content with no dependence on the outer framing.
    private func detectedColumns(in image: CGImage, viewport: CGRect) -> DetectedColumns? {
        // Resolution here sets the precision of every card rectangle: at 480
        // samples across a 2560-wide frame one sample is 5px, which is enough
        // drift to slide the crown probe off the crown. Sample finely and search
        // sub-sample.
        let sampleWidth = 960
        let bandTop = viewport.minY + viewport.height * 0.30
        let bandHeight = viewport.height * 0.55
        let band = CGRect(x: viewport.minX, y: bandTop, width: viewport.width, height: bandHeight)
        guard let crop = cropTopLeft(image, to: band),
              let pixels = downsampleRGBA(crop, width: sampleWidth, height: 64) else { return nil }

        // Vertical edge energy per sampled column.
        var energy = [Double](repeating: 0, count: sampleWidth)
        for x in 2..<(sampleWidth - 2) {
            var total = 0.0
            for y in 0..<64 {
                let a = (y * sampleWidth + x - 2) * 4
                let b = (y * sampleWidth + x + 2) * 4
                let lumA = Double(pixels[a]) * 0.30 + Double(pixels[a + 1]) * 0.59 + Double(pixels[a + 2]) * 0.11
                let lumB = Double(pixels[b]) * 0.30 + Double(pixels[b + 1]) * 0.59 + Double(pixels[b + 2]) * 0.11
                total += abs(lumB - lumA)
            }
            energy[x] = total / 64
        }

        let scale = viewport.width / CGFloat(sampleWidth)
        // Card-width-to-step ratio is fixed by the game's layout.
        let widthOverStep = GridMetrics.cardWidth / GridMetrics.columnStep

        // Linear interpolation so the search is not quantised to whole samples.
        func energyAt(_ position: Double) -> Double {
            guard position >= 0, position < Double(sampleWidth - 1) else { return 0 }
            let index = Int(position)
            let fraction = position - Double(index)
            return energy[index] * (1 - fraction) + energy[index + 1] * fraction
        }

        func score(centre: Double, step: Double) -> Double? {
            let half = step * Double(widthOverStep) / 2
            var total = 0.0
            for column in 0..<GridMetrics.columnCount {
                let c = centre + Double(column) * step
                let left = c - half
                let right = c + half
                guard left >= 0, right < Double(sampleWidth - 1) else { return nil }
                total += energyAt(left) + energyAt(right)
            }
            return total
        }

        var best: (centre: Double, step: Double, score: Double)?
        let minimumStep = Double(sampleWidth) * 0.030
        let maximumStep = Double(sampleWidth) * 0.180
        let maximumCentre = Double(sampleWidth) * 0.55

        // Coarse pass on whole samples, then refine around the winner.
        var step = minimumStep
        while step <= maximumStep {
            var centre = step * Double(widthOverStep) / 2 + 1
            while centre <= maximumCentre {
                if let value = score(centre: centre, step: step), value > (best?.score ?? -1) {
                    best = (centre, step, value)
                }
                centre += 1
            }
            step += 1
        }
        guard var refined = best else { return nil }

        for granularity in [0.25, 0.05] {
            var localBest = refined
            var deltaStep = -1.5
            while deltaStep <= 1.5 {
                var deltaCentre = -1.5
                while deltaCentre <= 1.5 {
                    let candidateStep = refined.step + deltaStep
                    let candidateCentre = refined.centre + deltaCentre
                    if candidateStep > 0,
                       let value = score(centre: candidateCentre, step: candidateStep),
                       value > localBest.score {
                        localBest = (candidateCentre, candidateStep, value)
                    }
                    deltaCentre += granularity
                }
                deltaStep += granularity
            }
            refined = localBest
        }

        guard refined.score > 0 else { return nil }

        let stepPixels = refined.step * Double(scale)
        let centrePixels = viewport.minX + CGFloat(refined.centre) * scale
        let cardWidthPixels = stepPixels * Double(widthOverStep)
        // Card aspect is fixed, so height comes from the measured width rather
        // than from any assumption about the height of the picture.
        let cardAspect = (GridMetrics.cardWidth * 16) / (GridMetrics.cardHeight * 9)
        let cardHeightPixels = cardWidthPixels / Double(cardAspect)
        let rowStepPixels = cardHeightPixels * Double(GridMetrics.rowStep / GridMetrics.cardHeight)

        return DetectedColumns(
            firstCentre: centrePixels,
            step: CGFloat(stepPixels),
            cardWidth: CGFloat(cardWidthPixels),
            cardHeight: CGFloat(cardHeightPixels),
            rowStep: CGFloat(rowStepPixels)
        )
    }

    /// Row phase from card edges instead of level text.
    ///
    /// Row spacing is a known constant; only the phase moves with scroll. Card
    /// tiles have a bright top and bottom border — locked cards included — so
    /// correlating a comb of that period against per-scanline edge energy finds
    /// the phase without needing any card to be readable. A row of entirely
    /// locked cards no longer drops out and shifts every slot below it.
    private func detectedRowTops(
        in image: CGImage,
        viewport: CGRect,
        columns: DetectedColumns?
    ) -> [CGFloat] {
        let fallbackStep = viewport.height * rowStep
        let fallbackCard = viewport.height * cardHeight
        guard fallbackStep > 4 || (columns?.rowStep ?? 0) > 4 else { return [] }

        let bandTop = viewport.minY + viewport.height * 0.20
        let bandBottom = viewport.minY + viewport.height * 0.97
        let bandHeight = Int(bandBottom - bandTop)
        guard bandHeight > 8 else { return [] }

        // Sample the three card columns at reduced width; only vertical
        // structure matters, so a narrow strip per column is enough. Use the
        // measured column positions when we have them — sampling the wrong
        // strips would measure the background instead of the cards.
        let stripWidth = 48
        var energy = [Double](repeating: 0, count: bandHeight)
        var sampled = false
        for column in 0..<GridMetrics.columnCount {
            let centre: CGFloat
            let width: CGFloat
            if let columns {
                centre = columns.firstCentre + CGFloat(column) * columns.step
                width = columns.cardWidth
            } else {
                centre = viewport.minX + viewport.width * columnCentre(column)
                width = viewport.width * cardWidth
            }
            let rect = CGRect(
                x: centre - width / 2,
                y: bandTop,
                width: width,
                height: CGFloat(bandHeight)
            )
            guard let strip = cropTopLeft(image, to: rect),
                  let pixels = downsampleRGBA(strip, width: stripWidth, height: bandHeight) else {
                continue
            }
            sampled = true
            var rowMean = [Double](repeating: 0, count: bandHeight)
            for y in 0..<bandHeight {
                var total = 0.0
                for x in 0..<stripWidth {
                    let offset = (y * stripWidth + x) * 4
                    total += Double(pixels[offset]) * 0.30
                        + Double(pixels[offset + 1]) * 0.59
                        + Double(pixels[offset + 2]) * 0.11
                }
                rowMean[y] = total / Double(stripWidth)
            }
            for y in 4..<bandHeight {
                energy[y] += abs(rowMean[y] - rowMean[y - 4])
            }
        }
        guard sampled else { return [] }

        // Search the row period around its expected value as well as the phase.
        //
        // Pixels are square in every source that matters here — a recording or a
        // resized window scales both axes together — so the measured column
        // pitch predicts the row pitch. The search only has to absorb small
        // error, and the range is kept tight on purpose: shot3-style pages are
        // mostly locked cards with weak edges, and given a wide range a sparse
        // long period can score better than the true one.
        let cardOverStep = Double(GridMetrics.cardHeight / GridMetrics.rowStep)
        let stepOverCardWidth = Double((GridMetrics.rowStep * 9) / (GridMetrics.cardWidth * 16))
        let estimate = columns.map { Double($0.cardWidth) * stepOverCardWidth }
            ?? Double(fallbackStep)
        let minimumStep = max(8.0, estimate * 0.88)
        let maximumStep = min(Double(bandHeight) / 2, estimate * 1.14)
        guard maximumStep > minimumStep else { return [] }

        func score(step: Double, phase: Double) -> Double {
            let card = step * cardOverStep
            var total = 0.0
            var rows = 0
            var y = phase
            while y + card < Double(bandHeight) {
                total += energy[Int(y)] + energy[Int(y + card)]
                rows += 1
                y += step
            }
            // Normalise by row count so a short period is not favoured purely
            // for fitting more rows into the band.
            return rows > 0 ? total / Double(rows) : 0
        }

        var best = (step: estimate, phase: 0.0, score: -1.0)
        var step = minimumStep
        while step <= maximumStep {
            var phase = 0.0
            while phase < step {
                let value = score(step: step, phase: phase)
                if value > best.score { best = (step, phase, value) }
                phase += 1
            }
            step += 1
        }
        guard best.score > 0 else { return [] }

        // Refine both together at sub-pixel resolution.
        for granularity in [0.25, 0.05] {
            var localBest = best
            var deltaStep = -1.5
            while deltaStep <= 1.5 {
                var deltaPhase = -1.5
                while deltaPhase <= 1.5 {
                    let candidateStep = best.step + deltaStep
                    let candidatePhase = best.phase + deltaPhase
                    if candidateStep > 8, candidatePhase >= 0 {
                        let value = score(step: candidateStep, phase: candidatePhase)
                        if value > localBest.score {
                            localBest = (candidateStep, candidatePhase, value)
                        }
                    }
                    deltaPhase += granularity
                }
                deltaStep += granularity
            }
            best = localBest
        }

        let card = best.step * cardOverStep
        measuredRowStep = CGFloat(best.step)
        measuredCardHeight = CGFloat(card)

        var tops: [CGFloat] = []
        var y = best.phase
        while y + card <= Double(bandHeight) {
            tops.append(bandTop + CGFloat(y))
            y += best.step
        }
        return tops
    }

    private func columnCentre(_ column: Int) -> CGFloat {
        firstColumnCenter + CGFloat(column) * columnStep
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

    /// Which slots the overlay should cover.
    ///
    /// Once the grid is measured from the picture, every row that is *fully*
    /// on screen is fair game — the lattice simply grows and shrinks with the
    /// number of complete rows visible. Only rows clipped by the top divider or
    /// the Sprite Dust bar are dropped, because a half-height card yields a
    /// half-height crop and a meaningless match.
    private func selectedVisibleSlots(
        from rects: [CGRect],
        viewport: CGRect,
        pageStart: Int?
    ) -> Set<Int> {
        guard !rects.isEmpty else { return [] }
        let rowCount = Int(ceil(Double(rects.count) / 3.0))
        let rows = Array(0..<rowCount)

        if Fixes.detectGridFromContent {
            // The grid sits between the tab divider and the Sprite Dust bar.
            let gridTop = viewport.minY + viewport.height * 0.225
            let gridBottom = viewport.minY + viewport.height * 0.885
            let fullyVisible = rows.filter { row in
                let index = min(row * 3, rects.count - 1)
                let rect = rects[index]
                return rect.minY >= gridTop && rect.maxY <= gridBottom
            }
            if !fullyVisible.isEmpty {
                let allowed = Set(fullyVisible)
                return Set(rects.indices.filter { allowed.contains($0 / 3) })
            }
        }

        guard rowCount > 3 else { return Set(rects.indices) }

        let isAtTop = pageStart == 0
        let highestSlot = rects.indices.last ?? 0
        let isAtBottom = pageStart.map { $0 + highestSlot >= catalog.count - 1 } ?? false

        let selectedRows: [Int]
        if isAtTop {
            selectedRows = Array(rows.prefix(4))
        } else if isAtBottom {
            selectedRows = Array(rows.suffix(4))
        } else {
            selectedRows = Array(rows
                .sorted { lhs, rhs in
                    let leftRect = rects[min(lhs * 3, rects.count - 1)]
                    let rightRect = rects[min(rhs * 3, rects.count - 1)]
                    return abs(leftRect.midY - viewport.midY) < abs(rightRect.midY - viewport.midY)
                }
                .prefix(3))
                .sorted()
        }

        let allowedRows = Set(selectedRows)
        return Set(rects.indices.filter { allowedRows.contains($0 / 3) })
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

        // 3.2 — "LEVELS"/"LVLS" used to be rewritten to level 5. Any plural on
        // screen then read as Level 5, which permanently set mastered.
        if !Fixes.strictLevelParsing {
            text = text
                .replacingOccurrences(of: "LVLS", with: "LVL5")
                .replacingOccurrences(of: "LEVELS", with: "LEVEL5")
        }

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

    /// Fraction of the card holding a genuinely coloured pixel.
    ///
    /// This is the one measurement that separates owned from locked. Brightness
    /// does not: a locked card averages ~29, but a *selected* locked card is
    /// near-white at ~188. Both contain no colour at all, while owned cards
    /// measure 0.25 upwards.
    private func colouredPixelRatio(in image: CGImage) -> Double {
        guard let pixels = downsampleRGBA(image, width: 28, height: 28) else { return 0 }
        var coloured = 0
        let count = 28 * 28
        for index in 0..<count {
            let offset = index * 4
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            let maximum = max(r, max(g, b))
            let minimum = min(r, min(g, b))
            if maximum - minimum >= 30, maximum >= 70 { coloured += 1 }
        }
        return Double(coloured) / Double(count)
    }

    private func isLockedCard(_ image: CGImage) -> Bool {
        colouredPixelRatio(in: image) < GridMetrics.lockedColourRatio
    }

    /// Which status pill an *owned* card is showing, read from the bottom-left
    /// corner where Fortnite draws it.
    ///
    /// White pill with dark text -> collected, and the level is readable.
    /// Black pill with a dust icon -> needs summon; there is no level to read.
    ///
    /// Only meaningful once `isLockedCard` has ruled the card out: a locked card
    /// has no pill, yet its tile reads as uniformly dark (or uniformly white
    /// when selected), which would otherwise imitate either pill.
    private func pillKind(in image: CGImage) -> PillKind {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(
            x: width * 0.02,
            y: height * 0.80,
            width: width * 0.48,
            height: height * 0.15
        )
        guard let crop = cropTopLeft(image, to: rect),
              let pixels = downsampleRGBA(crop, width: 24, height: 10) else { return .none }

        var bright = 0
        var dark = 0
        let count = 24 * 10
        for index in 0..<count {
            let offset = index * 4
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            let maximum = max(r, max(g, b))
            let minimum = min(r, min(g, b))
            if maximum > 195, maximum - minimum < 55 { bright += 1 }
            if maximum < 85 { dark += 1 }
        }
        let brightRatio = Double(bright) / Double(count)
        let darkRatio = Double(dark) / Double(count)

        // Measured: white pill 0.59-0.63 bright; dust pill 0.12 bright / 0.44 dark.
        if brightRatio >= 0.35 { return .white }
        if darkRatio >= 0.30 { return .black }
        return .none
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

    /// Lost/equipped Sprites keep recognizable artwork but Fortnite removes
    /// most of its color. Locked cards are darker silhouettes; the brightness
    /// and contrast gates prevent those from being reported as summon-needed.
    private func isVisuallyLost(in card: CGImage) -> Bool {
        guard let artwork = artworkCrop(from: card),
              let pixels = downsampleRGBA(artwork, width: 24, height: 24) else { return false }

        var colored = 0
        var luminanceTotal = 0.0
        var luminances: [Double] = []
        luminances.reserveCapacity(24 * 24)

        for index in 0..<(24 * 24) {
            let offset = index * 4
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            let maximum = max(r, max(g, b))
            let minimum = min(r, min(g, b))
            if maximum - minimum >= 30, maximum >= 70 { colored += 1 }
            let luminance = Double(r * 30 + g * 59 + b * 11) / 100.0
            luminanceTotal += luminance
            luminances.append(luminance)
        }

        let count = Double(luminances.count)
        guard count > 0 else { return false }
        let mean = luminanceTotal / count
        let variance = luminances.reduce(0.0) { $0 + pow($1 - mean, 2) } / count
        let colorRatio = Double(colored) / count
        return mean >= 52 && variance >= 420 && colorRatio <= 0.16
    }

    /// Fortnite keeps the mastery crown even when a previously mastered Sprite
    /// returns to Level 1 after being lost. Detect the bright gold crown in the
    /// lower-right status area independently from the OCR'd level.
    private func hasMasteryCrown(in image: CGImage) -> Bool {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        // 3.1 — the crown sits top-centre. The old bottom-right region overlaps
        // the artwork, so every "Gold X" Sprite scored as mastered while real
        // crowns barely registered.
        if Fixes.topCentreCrown {
            let region = GridMetrics.crownRegion
            let rect = CGRect(
                x: width * region.minX,
                y: height * region.minY,
                width: width * region.width,
                height: height * region.height
            )
            guard let crop = cropTopLeft(image, to: rect),
                  let pixels = downsampleRGBA(crop, width: 40, height: 24) else { return false }
            var gold = 0
            let count = 40 * 24
            for index in 0..<count {
                let offset = index * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                if r >= 170, g >= 115, b <= 125, r > b + 55, g > b + 25 { gold += 1 }
            }
            return Double(gold) / Double(count) > GridMetrics.crownGoldThreshold
        }

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

        var missing: [String] = []
        for (index, item) in catalog.enumerated() {
            try Task.checkCancellation()
            guard let url = ResourceLocator.spriteImageURL(named: item.imageAssetName),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCache: true
                  ] as CFDictionary),
                  let preparedImage = referenceArtworkImage(from: image),
                  let feature = try featurePrint(for: preparedImage) else {
                // 2.5 — a silently skipped PNG degrades matching for every card
                // and also disables the sequence path via a count == catalog
                // guard. Collect the failures and surface them.
                missing.append(item.name)
                continue
            }

            references.append(ReferenceFeature(
                item: item,
                catalogIndex: index,
                feature: feature,
                colours: colourHistogram(for: preparedImage)
            ))

            if index.isMultiple(of: 12) || index == catalog.count - 1 {
                let fraction = Double(index + 1) / Double(max(catalog.count, 1))
                onProgress(0.50 + fraction * 0.34, "Comparing against \(index + 1)/\(catalog.count) Sprite artworks…")
            }
        }

        if !missing.isEmpty {
            throw ScreenshotAnalysisError.incompleteReferenceArtwork(missing)
        }

        cachedReferences = references
        return references
    }

    private func referenceArtworkImage(from image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)

        guard Fixes.cardLikeReferences else {
            let background = CIImage(color: CIColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1))
                .cropped(to: source.extent)
            return ciContext.createCGImage(source.composited(over: background), from: source.extent)
        }

        // 2.2 — real cards sit on a pale lilac-tinted tile rather than the
        // near-white this used to composite onto, which matters now that colour
        // is part of the score.
        //
        // Re-framing the reference to match `artworkCrop`'s aspect ratio and
        // padding was tried as well and measurably hurt: distances rose across
        // the board and margins narrowed enough to lose two correct matches. The
        // source PNGs are already framed close to how the game draws them, so
        // they are composited at their own extent.
        let background = CIImage(color: CIColor(red: 0.84, green: 0.85, blue: 0.90, alpha: 1))
            .cropped(to: source.extent)
        return ciContext.createCGImage(source.composited(over: background), from: source.extent)
    }

    /// Coarse hue/saturation histogram over the artwork.
    ///
    /// Feature prints are shape-driven and nearly colour-blind, so the ~90
    /// recolours in the catalog (Batman / Gold Batman / Gummy Batman / Galaxy
    /// Batman …) are indistinguishable by shape alone. Colour is the signal that
    /// separates them.
    private func colourHistogram(for image: CGImage) -> [Double] {
        let hueBins = 12
        let extra = 3   // dark, grey, bright — for pixels with no useful hue
        var histogram = [Double](repeating: 0, count: hueBins + extra)
        guard let pixels = downsampleRGBA(image, width: 24, height: 24) else { return histogram }

        var total = 0.0
        for index in 0..<(24 * 24) {
            let offset = index * 4
            let r = Double(pixels[offset]) / 255
            let g = Double(pixels[offset + 1]) / 255
            let b = Double(pixels[offset + 2]) / 255
            let maximum = max(r, max(g, b))
            let minimum = min(r, min(g, b))
            let delta = maximum - minimum

            if delta < 0.12 {
                // Achromatic: record lightness so white/grey/black treatments
                // (Gold vs Holofoil vs base) still differ.
                let bin = maximum < 0.30 ? 0 : (maximum < 0.70 ? 1 : 2)
                histogram[hueBins + bin] += 1
            } else {
                var hue: Double
                if maximum == r {
                    hue = (g - b) / delta
                } else if maximum == g {
                    hue = 2 + (b - r) / delta
                } else {
                    hue = 4 + (r - g) / delta
                }
                hue = (hue * 60).truncatingRemainder(dividingBy: 360)
                if hue < 0 { hue += 360 }
                let bin = min(hueBins - 1, Int(hue / (360 / Double(hueBins))))
                // Weight by saturation so washed-out pixels count for less.
                histogram[bin] += delta
            }
            total += 1
        }
        guard total > 0 else { return histogram }
        let sum = histogram.reduce(0, +)
        guard sum > 0 else { return histogram }
        return histogram.map { $0 / sum }
    }

    /// How much the colour histogram counts relative to the shape distance.
    ///
    /// Swept against the ground-truth captures. At this weight colour resolves
    /// same-silhouette recolours that shape alone misses (Holofoil Batman,
    /// Water) with no wrong answers. Higher weights start letting colour
    /// override the family — Gold Batman is read as Gold Llama at 6.
    private var colourWeight: Float { 4 }

    /// Chi-squared style distance between two colour histograms, scaled into
    /// roughly the same range as a Vision feature-print distance.
    private func colourDistance(_ lhs: [Double], _ rhs: [Double]) -> Float {
        guard lhs.count == rhs.count else { return 0 }
        var total = 0.0
        for index in lhs.indices {
            let a = lhs[index]
            let b = rhs[index]
            let denominator = a + b
            if denominator > 0 {
                total += ((a - b) * (a - b)) / denominator
            }
        }
        return Float(total)
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

        // 2.3 — the sequence fallback below names cards by grid position against
        // the catalog order. The in-game list has a Sort By control and its
        // observed order does not match the catalog, so position proves nothing.
        // A card that cannot be identified on its own evidence stays unknown.
        if Fixes.noPositionalNaming {
            return confidentIndependent
        }

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

    /// Letterbox removal by bar detection rather than "first not-black row".
    ///
    /// The top of the Fortnite screen is dark navy, so a brightness threshold
    /// walks into the picture. Instead, peel off the contiguous run of lines
    /// from each edge that are *uniformly* near-black; the first line holding
    /// any real content stops the scan even when that content is very dark.
    private func hardEdgeViewport(in image: CGImage) -> CGRect {
        let sampleWidth = 320
        let sampleHeight = max(120, Int(
            (CGFloat(image.height) / CGFloat(max(image.width, 1))) * CGFloat(sampleWidth)
        ))
        guard let pixels = downsampleRGBA(image, width: sampleWidth, height: sampleHeight) else {
            return CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }

        // A bar line has essentially no bright pixels anywhere along it.
        func rowIsBar(_ y: Int) -> Bool {
            var bright = 0
            for x in 0..<sampleWidth {
                let offset = (y * sampleWidth + x) * 4
                let maximum = max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2]))
                if maximum > 40 { bright += 1 }
            }
            return Double(bright) / Double(sampleWidth) < 0.02
        }
        func columnIsBar(_ x: Int) -> Bool {
            var bright = 0
            for y in 0..<sampleHeight {
                let offset = (y * sampleWidth + x) * 4
                let maximum = max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2]))
                if maximum > 40 { bright += 1 }
            }
            return Double(bright) / Double(sampleHeight) < 0.02
        }

        var top = 0
        while top < sampleHeight / 2, rowIsBar(top) { top += 1 }
        var bottom = sampleHeight - 1
        while bottom > sampleHeight / 2, rowIsBar(bottom) { bottom -= 1 }
        var left = 0
        while left < sampleWidth / 2, columnIsBar(left) { left += 1 }
        var right = sampleWidth - 1
        while right > sampleWidth / 2, columnIsBar(right) { right -= 1 }

        let normalized = CGRect(
            x: CGFloat(left) / CGFloat(sampleWidth),
            y: CGFloat(top) / CGFloat(sampleHeight),
            width: CGFloat(right - left + 1) / CGFloat(sampleWidth),
            height: CGFloat(bottom - top + 1) / CGFloat(sampleHeight)
        )
        guard normalized.width > 0.50, normalized.height > 0.50 else {
            return CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }

        return CGRect(
            x: normalized.minX * CGFloat(image.width),
            y: normalized.minY * CGFloat(image.height),
            width: normalized.width * CGFloat(image.width),
            height: normalized.height * CGFloat(image.height)
        )
    }

    private func contentViewport(in image: CGImage) -> CGRect {
        if Fixes.hardEdgeLetterbox {
            return hardEdgeViewport(in: image)
        }
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

enum PillKind {
    case white
    case black
    case none
}

/// Grid geometry measured from the picture, in pixels of the source frame.
struct DetectedColumns {
    let firstCentre: CGFloat
    let step: CGFloat
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let rowStep: CGFloat
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
    let status: SpriteCollectionStatus
    let level: Int?
    let mastered: Bool
    let feature: VNFeaturePrintObservation
    let colours: [Double]
}

private struct ReferenceFeature {
    let item: SpriteItem
    let catalogIndex: Int
    let feature: VNFeaturePrintObservation
    let colours: [Double]
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
    case incompleteReferenceArtwork([String])

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "That screenshot could not be opened as an image."
        case .missingReferenceArtwork:
            return "The built-in Sprite artwork could not be loaded for screenshot matching."
        case .incompleteReferenceArtwork(let names):
            let shown = names.prefix(5).joined(separator: ", ")
            let more = names.count > 5 ? " and \(names.count - 5) more" : ""
            return "Sprite artwork is missing for \(names.count) entries (\(shown)\(more)). "
                + "Matching would be unreliable, so this scan was stopped."
        }
    }
}
