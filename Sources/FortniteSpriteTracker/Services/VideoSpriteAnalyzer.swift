import Foundation
import AVFoundation
import Vision
import CoreImage

struct DetectedSprite: Identifiable, Hashable, Sendable {
    var id: String { name }

    let name: String
    let rarity: SpriteRarity
    let status: SpriteCollectionStatus
    let level: Int?
    let mastered: Bool
    let timestamp: Double
    let observations: Int
    var catalogIndex: Int? = nil
    var gridSlot: Int? = nil

    var owned: Bool { status.isUnlocked }
}

struct SpriteCardAnchor: Hashable, Sendable {
    let slot: Int
    /// Rectangle normalized to the captured frame using top-left coordinates.
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    /// Small perceptual hash of the card artwork. Used only to keep overlay
    /// labels attached to the same visible card across repeated scans.
    let visualSignature: UInt64
}

struct SpriteFrameAnalysis: Sendable {
    let detections: [DetectedSprite]
    let isCollectionScreen: Bool
    let visibleSlots: Int
    let inferredPageStart: Int?
    /// Exact catalog positions confirmed visible in this stable frame. This
    /// avoids treating ignored partial rows as scan coverage.
    let coveredCatalogIndexes: Set<Int>
    let lockedSlots: Set<Int>
    let needsHelpSlots: Set<Int>
    let selectedSpriteName: String?
    let cardAnchors: [SpriteCardAnchor]
    /// The grid's outer frame, normalized to the captured frame with top-left
    /// origin. Anchored to static chrome — the rule under the filter row and the
    /// Sprite Dust bar — so it holds still while the cards scroll behind it.
    var gridFrame: CGRect? = nil
}

actor VideoSpriteAnalyzer {
    private let catalog = SpriteCatalog.all
    private let catalogByLongestName = SpriteCatalog.all.sorted {
        $0.name.count > $1.name.count
    }
    private let ciContext = CIContext()
    private let detailsRegion = CGRect(x: 0.52, y: 0.23, width: 0.46, height: 0.39)

    func analyze(
        url: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [DetectedSprite] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = max(CMTimeGetSeconds(duration), 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1250)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let textRequest = makeTextRequest()

        // A little over two precise samples per second catches the recording's
        // one-second selections. Vision receives only the cropped details panel.
        let interval = max(0.45, seconds / 300.0)
        var times: [CMTime] = []
        var sampleTime = 0.0
        while sampleTime < seconds {
            times.append(CMTime(seconds: sampleTime, preferredTimescale: 600))
            sampleTime += interval
        }
        if times.isEmpty {
            times = [.zero]
        }

        var tallies: [String: DetectionTally] = [:]
        onProgress(0.01, "Reading the selected Sprite details…")

        for (frameIndex, time) in times.enumerated() {
            try Task.checkCancellation()
            let frame = try await generator.image(at: time).image
            let lines: [OCRLine] = try autoreleasepool {
                guard let panel = preparedDetailsPanel(from: frame) else { return [] }
                return try recognizeRightPanelText(in: panel, request: textRequest)
            }
            let timestamp = CMTimeGetSeconds(time)
            var progressDescription = "Reading the right-side name and level…"
            var foundSelection = false

            if let selected = selectedSprite(in: lines) {
                record(
                    item: selected.item,
                    level: selected.level,
                    mastered: selected.mastered,
                    isExactMatch: selected.isExactMatch,
                    frameIndex: frameIndex,
                    timestamp: timestamp,
                    tallies: &tallies
                )
                let levelText = selected.level.map { "Lvl \($0)" } ?? "level unreadable"
                progressDescription = "\(selected.item.name) · \(levelText)\(selected.mastered ? " · Mastered" : "")"
                foundSelection = true
            }

            let progress = Double(frameIndex + 1) / Double(max(times.count, 1))
            if foundSelection || frameIndex.isMultiple(of: 4) || frameIndex == times.count - 1 {
                onProgress(progress, progressDescription)
            }
        }

        return tallies.values.compactMap { tally in
            let level = tally.confirmedLevel
            let mastered = tally.confirmedMastered || level == 5
            guard level != nil || mastered else { return nil }

            return DetectedSprite(
                name: tally.item.name,
                rarity: tally.item.rarity,
                status: .collected,
                level: level,
                mastered: mastered,
                timestamp: tally.firstTimestamp,
                observations: tally.frameIndices.count
            )
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    private func makeTextRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.032

        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        request.customWords = recognitionWords
        return request
    }

    private var recognitionWords: [String] {
        var words = catalog.flatMap { item in
            [item.name, "\(item.name) Sprite"]
        }
        for item in catalog where item.name.contains("Llama") {
            let gameName = item.name.replacingOccurrences(
                of: "Llama",
                with: "Lootin' Llama"
            )
            words.append(gameName)
            words.append("\(gameName) Sprite")
        }
        words.append("Sprite Mastered")
        words += SpriteRarity.allCases.map(\.rawValue)
        words += (1...5).flatMap { ["Lvl \($0)", "Level \($0)"] }
        return words
    }

    private func preparedDetailsPanel(from image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let extent = source.extent
        let cropRect = CGRect(
            x: extent.minX + extent.width * detailsRegion.minX,
            y: extent.minY + extent.height * detailsRegion.minY,
            width: extent.width * detailsRegion.width,
            height: extent.height * detailsRegion.height
        ).intersection(extent)
        guard !cropRect.isNull, cropRect.width > 1, cropRect.height > 1 else { return nil }

        let prepared = source
            .cropped(to: cropRect)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.30,
                kCIInputBrightnessKey: 0.025
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.45
            ])
        return ciContext.createCGImage(prepared, from: cropRect)
    }

    private func recognizeRightPanelText(
        in image: CGImage,
        request: VNRecognizeTextRequest
    ) throws -> [OCRLine] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? []).flatMap { observation in
            observation.topCandidates(3).enumerated().map { rank, candidate in
                OCRLine(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    box: observation.boundingBox,
                    candidateRank: rank
                )
            }
        }
    }

    private func selectedSprite(
        in lines: [OCRLine]
    ) -> (item: SpriteItem, level: Int?, mastered: Bool, isExactMatch: Bool)? {
        let expandedLines = linesIncludingJoinedFragments(lines)
        let largestTextHeight = expandedLines.map(\.box.height).max() ?? 0
        let panelShowsMastered = expandedLines.contains { line in
            canonicalOCRText(line.text).contains("mastered")
        }
        let observedRarity = detectedRarity(in: expandedLines)
        let nameMatches = expandedLines.compactMap { line -> (match: CatalogMatch, line: OCRLine)? in
            let isLikelyTitle = largestTextHeight > 0
                && line.box.height >= largestTextHeight * 0.52
            guard let match = catalogMatch(
                from: line.text,
                allowNameWithoutSprite: isLikelyTitle
            ) else { return nil }
            guard observedRarity == nil || match.item.rarity == observedRarity else {
                return nil
            }
            let minimumConfidence: Float = match.isExact ? 0.20 : 0.35
            guard line.confidence >= minimumConfidence else { return nil }
            return (match, line)
        }

        for match in nameMatches.sorted(by: { $0.line.confidence > $1.line.confidence }) {
            let nearbyLevels = expandedLines.compactMap { line -> (level: Int, distance: CGFloat)? in
                guard line.confidence >= 0.20,
                      let level = parseLevel(from: line.text) else { return nil }
                let horizontal = abs(line.box.midX - match.line.box.midX)
                let vertical = abs(line.box.midY - match.line.box.midY)
                return (level, horizontal * 0.25 + vertical)
            }

            let nearest = nearbyLevels.min(by: { $0.distance < $1.distance })
            if nearest != nil || panelShowsMastered {
                return (
                    match.match.item,
                    nearest?.level,
                    panelShowsMastered,
                    match.match.isExact && match.line.candidateRank == 0
                )
            }
        }

        return nil
    }

    private func linesIncludingJoinedFragments(_ lines: [OCRLine]) -> [OCRLine] {
        var expanded = lines
        var joinedTexts = Set(lines.map { normalize($0.text) })
        let primaryLines = lines.filter { $0.candidateRank == 0 }

        for anchor in primaryLines {
            let row = primaryLines
                .filter { candidate in
                    abs(candidate.box.midY - anchor.box.midY) < 0.025
                }
                .sorted { $0.box.minX < $1.box.minX }

            guard row.count > 1 else { continue }
            let joinedText = row.map(\.text).joined(separator: " ")
            guard joinedTexts.insert(normalize(joinedText)).inserted else { continue }
            let joinedBox = row.dropFirst().reduce(row[0].box) {
                $0.union($1.box)
            }
            expanded.append(OCRLine(
                text: joinedText,
                confidence: row.map(\.confidence).min() ?? 0,
                box: joinedBox,
                candidateRank: 0
            ))
        }

        // Fortnite wraps long titles onto two rows. Pair large neighboring rows
        // so "GUMMY LOOTIN'" + "LLAMA SPRITE" maps to Gummy Llama rather than
        // incorrectly collapsing to the base Llama entry.
        let rowCandidates = expanded.filter { $0.candidateRank == 0 }
        let largestHeight = rowCandidates.map(\.box.height).max() ?? 0
        for firstIndex in rowCandidates.indices {
            for secondIndex in rowCandidates.indices where secondIndex > firstIndex {
                let first = rowCandidates[firstIndex]
                let second = rowCandidates[secondIndex]
                let verticalDistance = abs(first.box.midY - second.box.midY)
                guard largestHeight > 0,
                      first.box.height >= largestHeight * 0.48,
                      second.box.height >= largestHeight * 0.48,
                      verticalDistance >= 0.025,
                      verticalDistance <= 0.24 else { continue }

                let ordered = [first, second].sorted { $0.box.midY > $1.box.midY }
                let joinedText = ordered.map(\.text).joined(separator: " ")
                guard joinedTexts.insert(normalize(joinedText)).inserted else { continue }
                expanded.append(OCRLine(
                    text: joinedText,
                    confidence: min(first.confidence, second.confidence),
                    box: first.box.union(second.box),
                    candidateRank: 0
                ))
            }
        }

        return expanded
    }

    private func catalogMatch(
        from recognizedText: String,
        allowNameWithoutSprite: Bool
    ) -> CatalogMatch? {
        let normalizedLine = canonicalOCRText(recognizedText)
        let containsSprite = normalizedLine.contains("sprite")
        guard containsSprite || allowNameWithoutSprite else { return nil }

        // Check longer names first so variants never collapse into their base.
        if let exact = catalogByLongestName
            .first(where: { item in
                let name = normalize(item.name)
                return normalizedLine.contains(name + "sprite")
                    || (allowNameWithoutSprite && normalizedLine.contains(name))
            }) {
            return CatalogMatch(item: exact, isExact: true)
        }

        let target = normalizedLine
            .replacingOccurrences(of: "mastered", with: "")
            .replacingOccurrences(of: "sprite", with: "")
        let ranked = catalog.map { item in
            (item: item, distance: editDistance(target, normalize(item.name)))
        }.sorted { $0.distance < $1.distance }

        guard let best = ranked.first else { return nil }
        let allowance = target.count >= 10 ? 2 : 1
        let secondDistance = ranked.dropFirst().first?.distance ?? Int.max
        guard best.distance <= allowance, secondDistance > best.distance else { return nil }
        return CatalogMatch(item: best.item, isExact: false)
    }

    private func parseLevel(from text: String) -> Int? {
        let compact = text.uppercased()
            .filter { $0.isLetter || $0.isNumber }
            .replacingOccurrences(of: "LVI", with: "LVL")
        for level in 1...5 {
            if compact.contains("LVL\(level)")
                || compact.contains("LEVEL\(level)")
                || compact.contains("LV\(level)") {
                return level
            }
        }
        return nil
    }

    private func detectedRarity(in lines: [OCRLine]) -> SpriteRarity? {
        for line in lines where line.candidateRank == 0 {
            let text = normalize(line.text)
            for rarity in SpriteRarity.allCases {
                let token = normalize(rarity.rawValue)
                if text == token
                    || text.hasPrefix(token + "lvl")
                    || (text.count <= token.count + 4 && text.contains(token)) {
                    return rarity
                }
            }
        }
        return nil
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
        if text.hasPrefix("ofoil") {
            text = "hol" + text
        }
        if !text.contains("holofoil"), let foilRange = text.range(of: "foil") {
            text.replaceSubrange(foilRange, with: "holofoil")
        }
        if !text.contains("galaxy"), let laxyRange = text.range(of: "laxy") {
            text.replaceSubrange(laxyRange, with: "galaxy")
        }
        return text
    }

    private func record(
        item: SpriteItem,
        level: Int?,
        mastered: Bool,
        isExactMatch: Bool,
        frameIndex: Int,
        timestamp: Double,
        tallies: inout [String: DetectionTally]
    ) {
        let key = normalize(item.name)
        var tally = tallies[key] ?? DetectionTally(item: item, firstTimestamp: timestamp)
        tally.add(level: level, mastered: mastered, isExactMatch: isExactMatch, frameIndex: frameIndex)
        tallies[key] = tally
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

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
}

private struct OCRLine {
    let text: String
    let confidence: Float
    let box: CGRect
    let candidateRank: Int
}

private struct CatalogMatch {
    let item: SpriteItem
    let isExact: Bool
}

private struct DetectionTally {
    let item: SpriteItem
    let firstTimestamp: Double
    var levelVotes: [Int: Int] = [:]
    var exactLevelVotes: [Int: Int] = [:]
    var masteredVotes = 0
    var exactMasteredVotes = 0
    var frameIndices = Set<Int>()

    var confirmedLevel: Int? {
        let ranked = levelVotes.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
        let runnerUpVotes = ranked.dropFirst().first?.value ?? 0
        guard let best = ranked.first,
              (best.value >= 2 || exactLevelVotes[best.key, default: 0] >= 1),
              best.value > runnerUpVotes else { return nil }
        return best.key
    }

    var confirmedMastered: Bool {
        masteredVotes >= 2 || exactMasteredVotes >= 1
    }

    mutating func add(level: Int?, mastered: Bool, isExactMatch: Bool, frameIndex: Int) {
        guard frameIndices.insert(frameIndex).inserted else { return }
        if let level {
            levelVotes[level, default: 0] += 1
            if isExactMatch {
                exactLevelVotes[level, default: 0] += 1
            }
        }
        if mastered {
            masteredVotes += 1
            if isExactMatch {
                exactMasteredVotes += 1
            }
        }
    }
}
