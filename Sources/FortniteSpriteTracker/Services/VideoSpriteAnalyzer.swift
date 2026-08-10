import Foundation
import AVFoundation
import Vision

struct DetectedSprite: Identifiable, Hashable, Sendable {
    var id: String { name }

    let name: String
    let rarity: SpriteRarity
    let owned: Bool
    let level: Int
    let mastered: Bool
    let timestamp: Double
    let observations: Int
}

actor VideoSpriteAnalyzer {
    private let catalog = SpriteCatalog.all
    private let catalogByLongestName = SpriteCatalog.all.sorted {
        $0.name.count > $1.name.count
    }

    func analyze(
        url: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [DetectedSprite] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = max(CMTimeGetSeconds(duration), 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let textRequest = makeTextRequest()

        // Roughly three samples per second catches a one-second selection even
        // when its start falls between sample boundaries. The cap keeps long
        // recordings from taking unbounded time.
        let interval = max(0.33, seconds / 360.0)
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
            let lines = try autoreleasepool {
                try recognizeRightPanelText(in: frame, request: textRequest)
            }
            let timestamp = CMTimeGetSeconds(time)
            var progressDescription = "Reading the right-side name and level…"
            var foundSelection = false

            if let selected = selectedSprite(in: lines) {
                record(
                    item: selected.item,
                    level: selected.level,
                    isExactMatch: selected.isExactMatch,
                    frameIndex: frameIndex,
                    timestamp: timestamp,
                    tallies: &tallies
                )
                progressDescription = "\(selected.item.name) · Lvl \(selected.level)"
                foundSelection = true
            }

            let progress = Double(frameIndex + 1) / Double(max(times.count, 1))
            if foundSelection || frameIndex.isMultiple(of: 4) || frameIndex == times.count - 1 {
                onProgress(progress, progressDescription)
            }
        }

        return tallies.values.compactMap { tally in
            guard let level = tally.confirmedLevel else { return nil }

            return DetectedSprite(
                name: tally.item.name,
                rarity: tally.item.rarity,
                owned: true,
                level: level,
                mastered: level == 5,
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
        request.minimumTextHeight = 0.016

        // The selected rarity, level, and name occupy this band. Excluding most
        // description text and all grid cards cuts Vision's per-frame workload.
        request.regionOfInterest = CGRect(x: 0.57, y: 0.27, width: 0.40, height: 0.31)
        request.customWords = catalog.flatMap { item in
            [item.name, "\(item.name) Sprite"]
        } + (1...5).flatMap { ["Lvl \($0)", "Level \($0)"] }
        return request
    }

    private func recognizeRightPanelText(
        in image: CGImage,
        request: VNRecognizeTextRequest
    ) throws -> [OCRLine] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(
                text: candidate.string,
                confidence: candidate.confidence,
                box: observation.boundingBox
            )
        }
    }

    private func selectedSprite(
        in lines: [OCRLine]
    ) -> (item: SpriteItem, level: Int, isExactMatch: Bool)? {
        let expandedLines = linesIncludingJoinedFragments(lines)
        let nameMatches = expandedLines.compactMap { line -> (match: CatalogMatch, line: OCRLine)? in
            guard let match = catalogMatch(from: line.text) else { return nil }
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

            if let nearest = nearbyLevels.min(by: { $0.distance < $1.distance }) {
                return (match.match.item, nearest.level, match.match.isExact)
            }
        }

        return nil
    }

    private func linesIncludingJoinedFragments(_ lines: [OCRLine]) -> [OCRLine] {
        var expanded = lines
        var joinedTexts = Set(lines.map { normalize($0.text) })

        for anchor in lines {
            let row = lines
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
                box: joinedBox
            ))
        }

        return expanded
    }

    private func catalogMatch(from recognizedText: String) -> CatalogMatch? {
        let normalizedLine = normalize(recognizedText)
            .replacingOccurrences(of: "spr1te", with: "sprite")
            .replacingOccurrences(of: "sprlte", with: "sprite")
            .replacingOccurrences(of: "sprtte", with: "sprite")
        guard normalizedLine.contains("sprite") else { return nil }

        // Check longer names first so "Gold Water Sprite" never becomes Water.
        if let exact = catalogByLongestName
            .first(where: { item in
                normalizedLine.contains(normalize(item.name) + "sprite")
            }) {
            return CatalogMatch(item: exact, isExact: true)
        }

        let target = normalizedLine.replacingOccurrences(of: "sprite", with: "")
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

    private func record(
        item: SpriteItem,
        level: Int,
        isExactMatch: Bool,
        frameIndex: Int,
        timestamp: Double,
        tallies: inout [String: DetectionTally]
    ) {
        let key = normalize(item.name)
        var tally = tallies[key] ?? DetectionTally(item: item, firstTimestamp: timestamp)
        tally.add(level: level, isExactMatch: isExactMatch, frameIndex: frameIndex)
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

    mutating func add(level: Int, isExactMatch: Bool, frameIndex: Int) {
        guard frameIndices.insert(frameIndex).inserted else { return }
        levelVotes[level, default: 0] += 1
        if isExactMatch {
            exactLevelVotes[level, default: 0] += 1
        }
    }
}
