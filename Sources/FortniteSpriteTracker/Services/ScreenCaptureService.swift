import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo

final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias AnalysisHandler = @Sendable (SpriteFrameAnalysis) -> Void
    typealias StatusHandler = @Sendable (String) -> Void
    typealias PreviewHandler = @Sendable (CGImage) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private let sampleQueue = DispatchQueue(label: "FortniteSpriteTracker.ScreenCapture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var stream: SCStream?
    private var isAnalyzingFrame = false
    private var lastAnalysisStarted = CFAbsoluteTime(0)
    private var lastMotionAt = CFAbsoluteTime(0)
    private var lastPreviewAt = CFAbsoluteTime(0)
    private var previousFingerprint: [UInt8]?
    private var lastAnalyzedFingerprint: [UInt8]?
    private var minimumAnalysisInterval: TimeInterval = 0.55
    private let settleDelay: TimeInterval = 0.55

    private var onAnalysis: AnalysisHandler?
    private var onStatus: StatusHandler?
    private var onPreview: PreviewHandler?
    private var onError: ErrorHandler?

    func availableContent() async throws -> (applications: [CaptureApplicationInfo], windows: [CaptureWindowInfo]) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        let eligibleWindows = content.windows.filter { window in
            guard window.frame.width >= 320,
                  window.frame.height >= 180,
                  let app = window.owningApplication,
                  app.processID != ownPID else {
                return false
            }
            return true
        }

        let windows = eligibleWindows.map { window in
            let appName = window.owningApplication?.applicationName ?? "Unknown App"
            let title = window.title ?? ""
            let haystack = "\(appName) \(title) \(window.owningApplication?.bundleIdentifier ?? "")".lowercased()
            let likely = Self.gameTokens.contains { haystack.contains($0) }

            return CaptureWindowInfo(
                id: window.windowID,
                applicationName: appName,
                title: title,
                width: max(Int(window.frame.width.rounded()), 1),
                height: max(Int(window.frame.height.rounded()), 1),
                isLikelyGameWindow: likely
            )
        }
        .sorted(by: Self.windowSort)

        let windowsByPID = Dictionary(grouping: eligibleWindows) { $0.owningApplication?.processID ?? 0 }
        let applications = content.applications
            .filter { $0.processID != ownPID && !(windowsByPID[$0.processID] ?? []).isEmpty }
            .map { app in
                let appWindows = windowsByPID[app.processID] ?? []
                let bundleID = app.bundleIdentifier
                let identifier = bundleID.isEmpty ? "pid:\(app.processID)" : bundleID
                let haystack = "\(app.applicationName) \(bundleID)".lowercased()
                return CaptureApplicationInfo(
                    id: identifier,
                    applicationName: app.applicationName,
                    bundleIdentifier: bundleID,
                    processID: app.processID,
                    windowCount: appWindows.count,
                    isLikelyGameApplication: Self.gameTokens.contains { haystack.contains($0) }
                )
            }
            .sorted { lhs, rhs in
                if lhs.isLikelyGameApplication != rhs.isLikelyGameApplication {
                    return lhs.isLikelyGameApplication && !rhs.isLikelyGameApplication
                }
                return lhs.applicationName.localizedCaseInsensitiveCompare(rhs.applicationName) == .orderedAscending
            }

        return (applications, windows)
    }

    func availableWindows() async throws -> [CaptureWindowInfo] {
        try await availableContent().windows
    }

    func resolvedWindow(for applicationID: String) async throws -> ResolvedCaptureTarget? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication,
                  app.processID != ownPID,
                  window.frame.width >= 320,
                  window.frame.height >= 180 else { return false }
            let bundleID = app.bundleIdentifier
            let id = bundleID.isEmpty ? "pid:\(app.processID)" : bundleID
            return id == applicationID
        }

        guard let best = candidates.sorted(by: Self.scWindowSort).first,
              let app = best.owningApplication else { return nil }
        return ResolvedCaptureTarget(
            windowID: best.windowID,
            applicationName: app.applicationName,
            windowTitle: best.title ?? "",
            width: max(Int(best.frame.width.rounded()), 1),
            height: max(Int(best.frame.height.rounded()), 1)
        )
    }

    func captureOnce(windowID: CGWindowID) async throws -> CGImage {
        let window = try await shareableWindow(withID: windowID)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = configuration(for: window, filter: filter, fps: 3)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    func start(
        windowID: CGWindowID,
        fps: Int,
        onAnalysis: @escaping AnalysisHandler,
        onStatus: @escaping StatusHandler,
        onPreview: @escaping PreviewHandler,
        onError: @escaping ErrorHandler
    ) async throws {
        if stream != nil { await stop() }

        let window = try await shareableWindow(withID: windowID)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let clampedFPS = min(max(fps, 2), 5)
        let configuration = configuration(for: window, filter: filter, fps: clampedFPS)

        self.onAnalysis = onAnalysis
        self.onStatus = onStatus
        self.onPreview = onPreview
        self.onError = onError
        self.minimumAnalysisInterval = max(0.50, 1.0 / Double(clampedFPS))
        resetAdaptiveState()

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        stream = newStream
        try await newStream.startCapture()
        onStatus("Capture connected. Waiting for the Sprite Collection to settle…")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            onError?(error)
        }
        sampleQueue.async { [weak self] in
            self?.resetAdaptiveState()
        }
        onStatus?("Capture stopped.")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard let fingerprint = motionFingerprint(pixelBuffer) else { return }

        if let previousFingerprint {
            let motion = fingerprintDistance(previousFingerprint, fingerprint)
            if motion > 0.075 {
                lastMotionAt = now
                onStatus?("Fast scrolling detected — pausing Vision until the grid settles…")
            }
        } else {
            lastMotionAt = now
        }
        previousFingerprint = fingerprint

        guard now - lastMotionAt >= settleDelay else { return }
        guard !isAnalyzingFrame,
              now - lastAnalysisStarted >= minimumAnalysisInterval else { return }

        if let lastAnalyzedFingerprint,
           fingerprintDistance(lastAnalyzedFingerprint, fingerprint) < 0.018 {
            // Same stable view. Do not keep re-running Vision/OCR on it.
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        if now - lastPreviewAt >= 1.0 {
            lastPreviewAt = now
            onPreview?(cgImage)
        }

        isAnalyzingFrame = true
        lastAnalysisStarted = now
        lastAnalyzedFingerprint = fingerprint
        onStatus?("Stable view found — reading left grid and right Sprite details…")

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.sampleQueue.async { [weak self] in
                    self?.isAnalyzingFrame = false
                }
            }

            do {
                let analysis = try await ScreenshotSpriteAnalyzer.shared.analyzeFrame(
                    image: cgImage,
                    onProgress: { _, _ in }
                )
                self.onAnalysis?(analysis)
            } catch is CancellationError {
                return
            } catch {
                self.onError?(error)
            }
        }
    }

    private func resetAdaptiveState() {
        isAnalyzingFrame = false
        lastAnalysisStarted = 0
        lastMotionAt = CFAbsoluteTimeGetCurrent()
        lastPreviewAt = 0
        previousFingerprint = nil
        lastAnalyzedFingerprint = nil
    }

    private func shareableWindow(withID windowID: CGWindowID) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCaptureServiceError.windowUnavailable
        }
        return window
    }

    private func configuration(
        for window: SCWindow,
        filter: SCContentFilter,
        fps: Int
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        configuration.showsCursor = false
        configuration.queueDepth = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))

        let pixelScale = max(CGFloat(filter.pointPixelScale), 1)
        let nativeWidth = max(window.frame.width * pixelScale, 1)
        let nativeHeight = max(window.frame.height * pixelScale, 1)
        let outputWidth = min(nativeWidth, 1440)
        let scale = outputWidth / nativeWidth
        configuration.width = max(Int(outputWidth.rounded()), 2)
        configuration.height = max(Int((nativeHeight * scale).rounded()), 2)
        configuration.scalesToFit = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    /// Samples only the collection grid and right detail panel. The animated 3D
    /// Sprite in the center of Fortnite is intentionally ignored so its idle
    /// animation doesn't make a stationary collection look like fast scrolling.
    private func motionFingerprint(_ pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let regions: [(Double, Double, Double, Double)] = [
            (0.055, 0.205, 0.285, 0.690), // left 3-column collection grid
            (0.655, 0.455, 0.285, 0.270)  // selected Sprite details
        ]
        let samplesX = 12
        let samplesY = 10
        var output: [UInt8] = []
        output.reserveCapacity(regions.count * samplesX * samplesY)

        for region in regions {
            for sy in 0..<samplesY {
                for sx in 0..<samplesX {
                    let nx = region.0 + region.2 * (Double(sx) + 0.5) / Double(samplesX)
                    let ny = region.1 + region.3 * (Double(sy) + 0.5) / Double(samplesY)
                    let x = min(max(Int(nx * Double(width)), 0), width - 1)
                    let y = min(max(Int(ny * Double(height)), 0), height - 1)
                    let p = pointer + y * rowBytes + x * 4
                    let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                    output.append(UInt8(clamping: (r * 30 + g * 59 + b * 11) / 100))
                }
            }
        }
        return output
    }

    private func fingerprintDistance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1 }
        let total = zip(lhs, rhs).reduce(0) { partial, pair in
            partial + abs(Int(pair.0) - Int(pair.1))
        }
        return Double(total) / (Double(lhs.count) * 255.0)
    }

    private static let gameTokens = [
        "fortnite", "geforce now", "nvidia", "xbox", "cloud gaming",
        "playstation", "remote play", "chiaki", "obs", "elgato", "capture"
    ]

    private static func windowSort(_ lhs: CaptureWindowInfo, _ rhs: CaptureWindowInfo) -> Bool {
        if lhs.isLikelyGameWindow != rhs.isLikelyGameWindow {
            return lhs.isLikelyGameWindow && !rhs.isLikelyGameWindow
        }
        let lhsArea = lhs.width * lhs.height
        let rhsArea = rhs.width * rhs.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func scWindowSort(_ lhs: SCWindow, _ rhs: SCWindow) -> Bool {
        let lhsScore = automaticWindowScore(lhs)
        let rhsScore = automaticWindowScore(rhs)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
    }

    /// OBS and similar capture apps often expose several windows. Prefer a
    /// projector/program/preview surface over the large control window, then
    /// fall back to a likely game title and finally the largest video surface.
    private static func automaticWindowScore(_ window: SCWindow) -> Int {
        let app = (window.owningApplication?.applicationName ?? "").lowercased()
        let title = (window.title ?? "").lowercased()
        let combined = "\(app) \(title)"

        var score = 0
        if title.contains("projector") { score += 100 }
        if title.contains("program") { score += 80 }
        if title.contains("preview") { score += 70 }
        if title.contains("fullscreen") || title.contains("full screen") { score += 45 }
        if gameTokens.contains(where: { title.contains($0) }) { score += 50 }
        if gameTokens.contains(where: { combined.contains($0) }) { score += 15 }

        // Penalize obvious utility/dialog windows that are poor video sources.
        if title.contains("settings") || title.contains("preferences") || title.contains("properties") {
            score -= 80
        }
        return score
    }
}

private enum ScreenCaptureServiceError: LocalizedError {
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .windowUnavailable:
            return "The selected capture window is no longer available. Refresh the capture source and try again."
        }
    }
}
