import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo

final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias DetectionHandler = @Sendable ([DetectedSprite]) -> Void
    typealias StatusHandler = @Sendable (String) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private let sampleQueue = DispatchQueue(label: "FortniteSpriteTracker.ScreenCapture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var stream: SCStream?
    private var isAnalyzingFrame = false
    private var lastAnalysisStarted = CFAbsoluteTime(0)
    private var analysisInterval: TimeInterval = 0.45

    private var onDetections: DetectionHandler?
    private var onStatus: StatusHandler?
    private var onError: ErrorHandler?

    func availableWindows() async throws -> [CaptureWindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let ownBundleID = Bundle.main.bundleIdentifier

        return content.windows
            .filter { window in
                guard window.frame.width >= 640,
                      window.frame.height >= 360,
                      let app = window.owningApplication else {
                    return false
                }
                if let ownBundleID, app.bundleIdentifier == ownBundleID {
                    return false
                }
                return true
            }
            .map { window in
                let appName = window.owningApplication?.applicationName ?? "Unknown App"
                let title = window.title ?? ""
                let haystack = "\(appName) \(title) \(window.owningApplication?.bundleIdentifier ?? "")".lowercased()
                let likelyTokens = [
                    "fortnite", "geforce now", "nvidia", "xbox", "cloud gaming",
                    "playstation", "remote play", "obs", "elgato", "capture"
                ]
                let likely = likelyTokens.contains { haystack.contains($0) }

                return CaptureWindowInfo(
                    id: window.windowID,
                    applicationName: appName,
                    title: title,
                    width: max(Int(window.frame.width.rounded()), 1),
                    height: max(Int(window.frame.height.rounded()), 1),
                    isLikelyGameWindow: likely
                )
            }
            .sorted { lhs, rhs in
                if lhs.isLikelyGameWindow != rhs.isLikelyGameWindow {
                    return lhs.isLikelyGameWindow && !rhs.isLikelyGameWindow
                }
                let lhsArea = lhs.width * lhs.height
                let rhsArea = rhs.width * rhs.height
                if lhsArea != rhsArea { return lhsArea > rhsArea }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
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
        onDetections: @escaping DetectionHandler,
        onStatus: @escaping StatusHandler,
        onError: @escaping ErrorHandler
    ) async throws {
        if stream != nil {
            await stop()
        }

        let window = try await shareableWindow(withID: windowID)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let clampedFPS = min(max(fps, 2), 5)
        let configuration = configuration(for: window, filter: filter, fps: clampedFPS)

        self.onDetections = onDetections
        self.onStatus = onStatus
        self.onError = onError
        self.analysisInterval = max(0.34, 1.0 / Double(clampedFPS))

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        stream = newStream
        try await newStream.startCapture()
        onStatus("Live capture started at \(clampedFPS) FPS. Frames are dropped while Vision is busy.")
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
            self?.isAnalyzingFrame = false
        }
        onStatus?("Live capture stopped.")
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
        guard !isAnalyzingFrame,
              now - lastAnalysisStarted >= analysisInterval else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        isAnalyzingFrame = true
        lastAnalysisStarted = now
        onStatus?("Vision is scanning the visible Sprite grid…")

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.sampleQueue.async { [weak self] in
                    self?.isAnalyzingFrame = false
                }
            }

            do {
                let detections = try await ScreenshotSpriteAnalyzer.shared.analyze(
                    image: cgImage,
                    onProgress: { _, _ in }
                )
                self.onDetections?(detections)
            } catch is CancellationError {
                return
            } catch {
                self.onError?(error)
            }
        }
    }

    private func shareableWindow(withID windowID: CGWindowID) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
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

        // 1440 px is plenty for the small Lvl labels while keeping Vision work cheap.
        let outputWidth = min(nativeWidth, 1440)
        let scale = outputWidth / nativeWidth
        configuration.width = max(Int(outputWidth.rounded()), 2)
        configuration.height = max(Int((nativeHeight * scale).rounded()), 2)
        configuration.scalesToFit = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }
}

private enum ScreenCaptureServiceError: LocalizedError {
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .windowUnavailable:
            return "The selected game window is no longer available. Refresh the window list and select it again."
        }
    }
}
