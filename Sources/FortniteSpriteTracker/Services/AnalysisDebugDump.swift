import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Stage 0 visibility. Collects everything one analysed frame saw — the frame,
/// each card crop, the raw OCR strings and the ranked match candidates — and
/// writes it to a timestamped folder so a wrong result can be inspected
/// instead of guessed at.
final class AnalysisDebugDump {
    struct Candidate {
        let name: String
        let distance: Float
    }

    private let root: URL
    private var notes: [String] = []
    private var cardCount = 0

    /// A live scan analyses many stable frames, and each dump is a full-size
    /// frame plus a crop per card. Cap it so leaving the flag on cannot quietly
    /// fill the disk; the early frames are the ones worth inspecting anyway.
    private static let maximumDumps = 40
    private static let lock = NSLock()
    private static var dumpsThisLaunch = 0

    static var reachedLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dumpsThisLaunch >= maximumDumps
    }

    static var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SpriteVault/Debug", isDirectory: true)
    }

    init?() {
        guard Fixes.debugDump else { return nil }

        Self.lock.lock()
        let allowed = Self.dumpsThisLaunch < Self.maximumDumps
        if allowed { Self.dumpsThisLaunch += 1 }
        Self.lock.unlock()
        guard allowed else { return nil }

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime]
        let name = stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        root = Self.baseDirectory.appendingPathComponent(name, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil else {
            return nil
        }
    }

    func note(_ line: String) {
        notes.append(line)
    }

    func writeFrame(_ image: CGImage, named name: String) {
        write(image, to: root.appendingPathComponent("\(name).png"))
    }

    func writeCard(_ image: CGImage, slot: Int, label: String) {
        cardCount += 1
        write(image, to: root.appendingPathComponent(String(format: "card-%02d-%@.png", slot, label)))
    }

    func recordCandidates(slot: Int, candidates: [Candidate]) {
        let listing = candidates.prefix(5)
            .map { String(format: "%@ (%.4f)", $0.name, $0.distance) }
            .joined(separator: ", ")
        notes.append("slot \(slot) top5: \(listing)")
    }

    func recordOCR(_ label: String, strings: [String]) {
        notes.append("OCR[\(label)]: \(strings.joined(separator: " | "))")
    }

    /// Writes the accumulated text log. Safe to call more than once.
    func finish() {
        let text = notes.joined(separator: "\n") + "\n"
        try? text.write(to: root.appendingPathComponent("analysis.txt"), atomically: true, encoding: .utf8)
    }

    private func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
