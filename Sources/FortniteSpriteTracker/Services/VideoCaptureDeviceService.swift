import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

final class VideoCaptureDeviceService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias AnalysisHandler = @Sendable (SpriteFrameAnalysis) -> Void
    typealias StatusHandler = @Sendable (String) -> Void
    typealias PreviewHandler = @Sendable (CGImage) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "FortniteSpriteTracker.CaptureDevice.Session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "FortniteSpriteTracker.CaptureDevice.Samples", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let output = AVCaptureVideoDataOutput()

    private var currentInput: AVCaptureDeviceInput?
    private var isAnalyzing = false
    private var previousFingerprint: [UInt8]?
    private var lastAnalyzedFingerprint: [UInt8]?
    private var lastMotionAt = CFAbsoluteTimeGetCurrent()
    private var lastPreviewAt = CFAbsoluteTime(0)
    private var lastAnalysisAt = CFAbsoluteTime(0)
    private var minimumAnalysisInterval: TimeInterval = 0.55
    private let settleDelay: TimeInterval = 0.55

    private var onAnalysis: AnalysisHandler?
    private var onStatus: StatusHandler?
    private var onPreview: PreviewHandler?
    private var onError: ErrorHandler?

    var authorizationGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func requestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    func availableDevices() -> [CaptureDeviceInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map {
            CaptureDeviceInfo(
                id: $0.uniqueID,
                name: $0.localizedName,
                manufacturer: $0.manufacturer
            )
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func start(
        deviceID: String,
        fps: Int,
        onAnalysis: @escaping AnalysisHandler,
        onStatus: @escaping StatusHandler,
        onPreview: @escaping PreviewHandler,
        onError: @escaping ErrorHandler
    ) async throws {
        guard authorizationGranted else {
            throw CaptureDeviceError.permissionRequired
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first(where: { $0.uniqueID == deviceID }) else {
            throw CaptureDeviceError.deviceUnavailable
        }

        self.onAnalysis = onAnalysis
        self.onStatus = onStatus
        self.onPreview = onPreview
        self.onError = onError
        self.minimumAnalysisInterval = max(0.50, 1.0 / Double(min(max(fps, 2), 5)))

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CaptureDeviceError.deviceUnavailable)
                    return
                }
                do {
                    if self.session.isRunning { self.session.stopRunning() }
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .high

                    if let currentInput = self.currentInput {
                        self.session.removeInput(currentInput)
                        self.currentInput = nil
                    }
                    for existingOutput in self.session.outputs {
                        self.session.removeOutput(existingOutput)
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else {
                        self.session.commitConfiguration()
                        throw CaptureDeviceError.cannotConfigure
                    }
                    self.session.addInput(input)
                    self.currentInput = input

                    self.output.alwaysDiscardsLateVideoFrames = true
                    self.output.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    self.output.setSampleBufferDelegate(self, queue: self.sampleQueue)
                    guard self.session.canAddOutput(self.output) else {
                        self.session.commitConfiguration()
                        throw CaptureDeviceError.cannotConfigure
                    }
                    self.session.addOutput(self.output)
                    self.session.commitConfiguration()
                    self.resetAdaptiveState()
                    self.session.startRunning()
                    continuation.resume()
                    self.onStatus?("Capture device connected. Waiting for the Sprite Collection to settle…")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if self.session.isRunning { self.session.stopRunning() }
                self.resetAdaptiveState()
                continuation.resume()
            }
        }
        onStatus?("Capture device stopped.")
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let fingerprint = motionFingerprint(pixelBuffer) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if let previousFingerprint {
            if fingerprintDistance(previousFingerprint, fingerprint) > 0.075 {
                lastMotionAt = now
                onStatus?("Fast scrolling detected — pausing Vision until the grid settles…")
            }
        } else {
            lastMotionAt = now
        }
        previousFingerprint = fingerprint

        guard now - lastMotionAt >= settleDelay,
              !isAnalyzing,
              now - lastAnalysisAt >= minimumAnalysisInterval else { return }
        if let lastAnalyzedFingerprint,
           fingerprintDistance(lastAnalyzedFingerprint, fingerprint) < 0.018 {
            return
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        if now - lastPreviewAt >= 1.0 {
            lastPreviewAt = now
            onPreview?(cgImage)
        }

        isAnalyzing = true
        lastAnalysisAt = now
        lastAnalyzedFingerprint = fingerprint
        onStatus?("Stable view found — reading left grid and right Sprite details…")

        Task { [weak self] in
            guard let self else { return }
            defer { self.sampleQueue.async { [weak self] in self?.isAnalyzing = false } }
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
        isAnalyzing = false
        previousFingerprint = nil
        lastAnalyzedFingerprint = nil
        lastMotionAt = CFAbsoluteTimeGetCurrent()
        lastPreviewAt = 0
        lastAnalysisAt = 0
    }

    private func motionFingerprint(_ pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let regions: [(Double, Double, Double, Double)] = [
            (0.055, 0.205, 0.285, 0.690),
            (0.655, 0.455, 0.285, 0.270)
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
        let total = zip(lhs, rhs).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / (Double(lhs.count) * 255.0)
    }
}

private enum CaptureDeviceError: LocalizedError {
    case permissionRequired
    case deviceUnavailable
    case cannotConfigure

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Camera access is required to read a USB capture device. Enable it in System Settings → Privacy & Security → Camera."
        case .deviceUnavailable:
            return "The selected capture device is no longer available."
        case .cannotConfigure:
            return "Sprite Vault could not configure that video capture device."
        }
    }
}
