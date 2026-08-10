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

    func analyze(
        url: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [DetectedSprite] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = max(CMTimeGetSeconds(duration), 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)

        // The selected card must remain visible for about two sampled frames.
        // Limiting the sample count keeps long recordings reasonably quick.
        let interval = max(0.7, seconds / 180.0)
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
            let lines = try recognizeRightPanelText(in: frame)
            let timestamp = CMTimeGetSeconds(time)
            var progressDescription = "Reading the right-side name and level…"

            if let selected = selectedSprite(in: lines) {
                record(
                    item: selected.item,
                    level: selected.level,
                    frameIndex: frameIndex,
                    timestamp: timestamp,
                    tallies: &tallies
                )
                progressDescription = "\(selected.item.name) · Lvl \(selected.level)"
            }

            let progress = Double(frameIndex + 1) / Double(max(times.count, 1))
            onProgress(progress, progressDescription)
        }

        return tallies.values.compactMap { tally in
            guard tally.frameIndices.count >= 2,
                  let level = tally.confirmedLevel else { return nil }

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

    private func recognizeRightPanelText(in image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.01

        // Fortnite displays the selected Sprite's rarity, level, and name here.
        // OCRing only this region avoids grid labels and description text elsewhere.
        request.regionOfInterest = CGRect(x: 0.57, y: 0.22, width: 0.40, height: 0.36)
        request.customWords = catalog.flatMap { item in
            [item.name, "\(item.name) Sprite"]
        } + (1...5).flatMap { ["Lvl \($0)", "Level \($0)"] }

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

    private func selectedSprite(in lines: [OCRLine]) -> (item: SpriteItem, level: Int)? {
        let nameMatches = lines.compactMap { line -> (item: SpriteItem, line: OCRLine)? in
            guard line.confidence >= 0.35,
                  let item = catalogItem(from: line.text) else { return nil }
            return (item, line)
        }

        for match in nameMatches.sorted(by: { $0.line.confidence > $1.line.confidence }) {
            let nearbyLevels = lines.compactMap { line -> (level: Int, distance: CGFloat)? in
                guard line.confidence >= 0.25,
                      let level = parseLevel(from: line.text) else { return nil }
                let horizontal = abs(line.box.midX - match.line.box.midX)
                let vertical = abs(line.box.midY - match.line.box.midY)
                return (level, horizontal * 0.25 + vertical)
            }

            if let nearest = nearbyLevels.min(by: { $0.distance < $1.distance }) {
                return (match.item, nearest.level)
            }
        }

        return nil
    }

    private func catalogItem(from recognizedText: String) -> SpriteItem? {
        let normalizedLine = normalize(recognizedText)
        guard normalizedLine.contains("sprite") else { return nil }

        // Check longer names first so "Gold Water Sprite" never becomes Water.
        if let exact = catalog
            .sorted(by: { normalize($0.name).count > normalize($1.name).count })
            .first(where: { item in
                normalizedLine.contains(normalize(item.name) + "sprite")
            }) {
            return exact
        }

        let target = normalizedLine.replacingOccurrences(of: "sprite", with: "")
        let ranked = catalog.map { item in
            (item: item, distance: editDistance(target, normalize(item.name)))
        }.sorted { $0.distance < $1.distance }

        guard let best = ranked.first else { return nil }
        let allowance = target.count >= 10 ? 2 : 1
        let secondDistance = ranked.dropFirst().first?.distance ?? Int.max
        guard best.distance <= allowance, secondDistance > best.distance else { return nil }
        return best.item
    }

    private func parseLevel(from text: String) -> Int? {
        let compact = text.uppercased().filter { $0.isLetter || $0.isNumber }
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
        frameIndex: Int,
        timestamp: Double,
        tallies: inout [String: DetectionTally]
    ) {
        let key = normalize(item.name)
        var tally = tallies[key] ?? DetectionTally(item: item, firstTimestamp: timestamp)
        tally.add(level: level, frameIndex: frameIndex)
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

private struct DetectionTally {
    let item: SpriteItem
    let firstTimestamp: Double
    var levelVotes: [Int: Int] = [:]
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
              best.value >= 2,
              best.value > runnerUpVotes else { return nil }
        return best.key
    }

    mutating func add(level: Int, frameIndex: Int) {
        guard frameIndices.insert(frameIndex).inserted else { return }
        levelVotes[level, default: 0] += 1
    }
}
