import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo

final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver, @unchecked Sendable {
    typealias AnalysisHandler = @Sendable (SpriteFrameAnalysis) -> Void
    typealias StatusHandler = @Sendable (String) -> Void
    typealias PreviewHandler = @Sendable (CGImage) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void
    typealias PickerSelectionHandler = @Sendable (SystemCaptureSelection?) -> Void

    private let sampleQueue = DispatchQueue(label: "FortniteSpriteTracker.ScreenCapture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var stream: SCStream?
    private var isAnalyzingFrame = false
    private var lastAnalysisStarted = CFAbsoluteTime(0)
    private var lastMotionAt = CFAbsoluteTime(0)
    private var lastPreviewAt = CFAbsoluteTime(0)
    private var previousFingerprint: [UInt8]?
    private var lastAnalyzedFingerprint: [UInt8]?
    private var minimumAnalysisInterval: TimeInterval = 0.65
    private let settleDelay: TimeInterval = 0.48
    private var motionStateActive = false
    private var previewEnabled = false
    private var lastFrameReceivedAt = CFAbsoluteTime(0)
    private var watchdogTimer: DispatchSourceTimer?
    private var watchdogReportedIdle = false

    private var onAnalysis: AnalysisHandler?
    private var onStatus: StatusHandler?
    private var onPreview: PreviewHandler?
    private var onError: ErrorHandler?

    private var selectedSystemFilter: SCContentFilter?
    private var selectedSystemSelection: SystemCaptureSelection?
    private var selectedOverlayRect: CGRect?
    private var latestStableFrame: CGImage?
    private let overlayController = SpriteScanOverlayController()
    private var pickerSelectionHandler: PickerSelectionHandler?
    private var pickerObserverInstalled = false

    var hasSystemSelection: Bool { selectedSystemFilter != nil }
    var systemSelection: SystemCaptureSelection? { selectedSystemSelection }

    func setPreviewEnabled(_ enabled: Bool) {
        sampleQueue.async { [weak self] in
            self?.previewEnabled = enabled
        }
    }

    /// Presents Apple's native ScreenCaptureKit window picker. The scan hotkey
    /// deliberately invokes this every time so the source is explicit and a
    /// stale source selection can never attach overlays to another app.
    func presentWindowPicker(onSelection: @escaping PickerSelectionHandler) {
        cancelWindowPicker(notify: false)
        pickerSelectionHandler = onSelection

        let picker = SCContentSharingPicker.shared
        if !pickerObserverInstalled {
            picker.add(self)
            pickerObserverInstalled = true
        }

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = .singleWindow
        configuration.allowsChangingSelectedContent = true
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present()
    }

    func cancelWindowPicker() {
        cancelWindowPicker(notify: true)
    }

    private func cancelWindowPicker(notify: Bool) {
        let handler = pickerSelectionHandler
        pickerSelectionHandler = nil
        SCContentSharingPicker.shared.isActive = false
        if notify { handler?(nil) }
    }

    func clearSystemSelection() {
        selectedSystemFilter = nil
        selectedSystemSelection = nil
        selectedOverlayRect = nil
        DispatchQueue.main.async { [overlayController] in overlayController.hide() }
    }

    func captureSystemSelectionOnce() async throws -> CGImage {
        guard let filter = selectedSystemFilter else {
            throw ScreenCaptureServiceError.noSystemSelection
        }
        let configuration = configuration(for: filter, fps: 20)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    func startSystemSelection(
        fps: Int,
        onAnalysis: @escaping AnalysisHandler,
        onStatus: @escaping StatusHandler,
        onPreview: @escaping PreviewHandler,
        onError: @escaping ErrorHandler
    ) async throws {
        guard let filter = selectedSystemFilter else {
            throw ScreenCaptureServiceError.noSystemSelection
        }
        try await start(
            filter: filter,
            fps: fps,
            onAnalysis: onAnalysis,
            onStatus: onStatus,
            onPreview: onPreview,
            onError: onError
        )
    }

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
        let configuration = configuration(for: filter, fps: 12)
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
        let window = try await shareableWindow(withID: windowID)
        selectedOverlayRect = Self.resolveOverlayRect(forWindowID: windowID, fallback: window.frame)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        try await start(
            filter: filter,
            fps: fps,
            onAnalysis: onAnalysis,
            onStatus: onStatus,
            onPreview: onPreview,
            onError: onError
        )
    }

    private func start(
        filter: SCContentFilter,
        fps: Int,
        onAnalysis: @escaping AnalysisHandler,
        onStatus: @escaping StatusHandler,
        onPreview: @escaping PreviewHandler,
        onError: @escaping ErrorHandler
    ) async throws {
        if stream != nil { await stop() }

        // Capture and recognition have separate clocks. The overlay gets a
        // responsive 12–30 FPS feed while Vision remains stability-gated below.
        let clampedFPS = min(max(fps, 12), 30)
        let configuration = configuration(for: filter, fps: clampedFPS)

        self.onAnalysis = onAnalysis
        self.onStatus = onStatus
        self.onPreview = onPreview
        self.onError = onError
        // Keep motion/overlay feedback smooth while limiting expensive Vision.
        // A stable view is analyzed at most about twice per second.
        self.minimumAnalysisInterval = 0.48
        resetAdaptiveState()
        latestStableFrame = nil
        overlayController.onDeepScan = { [weak self] slot in
            self?.requestDeepScan(slot: slot)
        }

        if selectedOverlayRect == nil {
            selectedOverlayRect = Self.resolveOverlayRect(for: filter)
        }
        if let overlayRect = selectedOverlayRect {
            DispatchQueue.main.async { [overlayController] in
                overlayController.show(over: overlayRect)
                overlayController.showWaiting(message: "Open Sprites → Collection · Stop ⌃⌥X")
            }
        }

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        stream = newStream
        try await newStream.startCapture()
        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.lastFrameReceivedAt = CFAbsoluteTimeGetCurrent()
            self.watchdogReportedIdle = false
            self.installWatchdog()
        }
        onStatus("Capture connected. Checking Sprites → Collection…")
    }

    func stop() async {
        DispatchQueue.main.async { [overlayController] in overlayController.hide() }
        latestStableFrame = nil
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            onError?(error)
        }
        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.watchdogTimer?.cancel()
            self.watchdogTimer = nil
            self.watchdogReportedIdle = false
            self.resetAdaptiveState()
        }
        onStatus?("Capture stopped.")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let handler = pickerSelectionHandler
        pickerSelectionHandler = nil
        picker.isActive = false

        guard filter.style == .window else {
            handler?(nil)
            return
        }
        selectedSystemFilter = filter
        selectedOverlayRect = Self.resolveOverlayRect(for: filter)
        let selection = Self.describeSystemSelection(filter)
        selectedSystemSelection = selection
        handler?(selection)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        let handler = pickerSelectionHandler
        pickerSelectionHandler = nil
        picker.isActive = false
        handler?(nil)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let handler = pickerSelectionHandler
        pickerSelectionHandler = nil
        SCContentSharingPicker.shared.isActive = false
        onError?(error)
        handler?(nil)
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
        lastFrameReceivedAt = now
        if watchdogReportedIdle {
            watchdogReportedIdle = false
            previousFingerprint = nil
            lastAnalyzedFingerprint = nil
            latestStableFrame = nil
            motionStateActive = false
            DispatchQueue.main.async { [overlayController] in
                overlayController.showWaiting(message: "Open Sprites → Collection · Stop ⌃⌥X")
            }
            onStatus?("Capture resumed — checking Sprites → Collection…")
        }
        guard let fingerprint = motionFingerprint(pixelBuffer) else { return }

        if let previousFingerprint {
            let motion = fingerprintDistance(previousFingerprint, fingerprint)
            if motion > 0.075 {
                lastMotionAt = now
                // A real scene change invalidates the previous stable-frame cache.
                // Without this reset, switching away from Fortnite and returning
                // to the same page can leave the scanner permanently "paused".
                lastAnalyzedFingerprint = nil
                latestStableFrame = nil
                if !motionStateActive {
                    motionStateActive = true
                    DispatchQueue.main.async { [overlayController] in
                        overlayController.showMoving()
                    }
                    onStatus?("Screen moving — waiting briefly for the collection to settle…")
                }
            }
        } else {
            lastMotionAt = now
        }
        previousFingerprint = fingerprint

        guard now - lastMotionAt >= settleDelay else { return }

        if motionStateActive {
            motionStateActive = false
            onStatus?("Screen stable — scanner active.")
        }

        guard !isAnalyzingFrame,
              now - lastAnalysisStarted >= minimumAnalysisInterval else { return }

        if let lastAnalyzedFingerprint,
           fingerprintDistance(lastAnalyzedFingerprint, fingerprint) < 0.018 {
            // Same stable view. Keep the scan alive, but avoid expensive OCR.
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        if previewEnabled, now - lastPreviewAt >= 2.0 {
            lastPreviewAt = now
            onPreview?(cgImage)
        }

        isAnalyzingFrame = true
        lastAnalysisStarted = now
        lastAnalyzedFingerprint = fingerprint
        latestStableFrame = cgImage
        onStatus?("Stable view found — validating the Sprites tab…")

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
                    onProgress: { _, _ in },
                    onCollectionValidated: { [weak self] in
                        guard let self else { return }
                        DispatchQueue.main.async { [overlayController = self.overlayController] in
                            // Processing boxes are shown only after the current
                            // frame has passed the strict tab-selection gate.
                            overlayController.beginProcessing()
                        }
                    },
                    onCardsAligned: { [weak self] anchors in
                        guard let self else { return }
                        DispatchQueue.main.async { [overlayController = self.overlayController] in
                            overlayController.showProcessing(anchors: anchors)
                        }
                    }
                )
                DispatchQueue.main.async { [overlayController] in
                    overlayController.update(with: analysis)
                }
                self.onAnalysis?(analysis)
            } catch is CancellationError {
                return
            } catch {
                self.onError?(error)
            }
        }
    }

    private func requestDeepScan(slot: Int) {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isAnalyzingFrame, let frame = self.latestStableFrame else {
                DispatchQueue.main.async { [overlayController = self.overlayController] in
                    overlayController.finishDeepScan(slot: slot, detection: nil)
                }
                return
            }

            self.isAnalyzingFrame = true
            Task { [weak self] in
                guard let self else { return }
                defer {
                    self.sampleQueue.async { [weak self] in self?.isAnalyzingFrame = false }
                }

                do {
                    let detection = try await ScreenshotSpriteAnalyzer.shared.deepAnalyzeCard(
                        image: frame,
                        slot: slot
                    )
                    DispatchQueue.main.async { [overlayController = self.overlayController] in
                        overlayController.finishDeepScan(slot: slot, detection: detection)
                    }

                    if let detection {
                        self.onAnalysis?(SpriteFrameAnalysis(
                            detections: [detection],
                            isCollectionScreen: true,
                            visibleSlots: 0,
                            inferredPageStart: nil,
                            coveredCatalogIndexes: [],
                            lockedSlots: [],
                            needsHelpSlots: [],
                            selectedSpriteName: detection.name,
                            cardAnchors: []
                        ))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    DispatchQueue.main.async { [overlayController = self.overlayController] in
                        overlayController.finishDeepScan(slot: slot, detection: nil)
                    }
                }
            }
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func installWatchdog() {
        watchdogTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let age = CFAbsoluteTimeGetCurrent() - self.lastFrameReceivedAt
            guard age > 4.0, !self.watchdogReportedIdle else { return }

            self.watchdogReportedIdle = true
            self.previousFingerprint = nil
            self.lastAnalyzedFingerprint = nil
            self.motionStateActive = false
            DispatchQueue.main.async { [overlayController = self.overlayController] in
                overlayController.showWaiting(message: "Capture idle · Stop ⌃⌥X")
            }
            self.onStatus?("Capture source is temporarily idle — scanning will resume automatically when frames return.")
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func resetAdaptiveState() {
        isAnalyzingFrame = false
        latestStableFrame = nil
        lastAnalysisStarted = 0
        lastMotionAt = CFAbsoluteTimeGetCurrent()
        lastPreviewAt = 0
        motionStateActive = false
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
        for filter: SCContentFilter,
        fps: Int
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        configuration.showsCursor = false
        configuration.queueDepth = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))

        let pixelScale = max(CGFloat(filter.pointPixelScale), 1)
        let sourceSize = filter.contentRect.size
        let nativeWidth = max(sourceSize.width * pixelScale, 1)
        let nativeHeight = max(sourceSize.height * pixelScale, 1)
        // 1280 px is enough for the Fortnite card grid/right-panel OCR while
        // substantially reducing Core Image + Vision work on Retina displays.
        let outputWidth = min(nativeWidth, 1280)
        let scale = outputWidth / nativeWidth
        configuration.width = max(Int(outputWidth.rounded()), 2)
        configuration.height = max(Int((nativeHeight * scale).rounded()), 2)
        configuration.scalesToFit = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    private static func resolveOverlayRect(for filter: SCContentFilter) -> CGRect? {
        if #available(macOS 15.2, *) {
            if filter.style == .window, let window = filter.includedWindows.first {
                return resolveOverlayRect(forWindowID: window.windowID, fallback: window.frame)
            }

            if filter.style == .display,
               filter.contentRect.width > 20,
               filter.contentRect.height > 20 {
                // contentRect is the exact selected display rectangle in
                // Quartz coordinates. Converting it directly avoids choosing
                // the wrong monitor when displays share the same resolution.
                return appKitRect(fromQuartzRect: filter.contentRect)
            }
        }

        // Fallback for older systems where the picker does not expose its
        // included window list. contentRect uses the Quartz top-left desktop
        // coordinate space, so convert it to AppKit's bottom-left coordinates.
        if filter.contentRect.width > 20, filter.contentRect.height > 20 {
            return appKitRect(fromQuartzRect: filter.contentRect)
        }
        return NSScreen.main?.frame
    }

    private static func resolveOverlayRect(forWindowID windowID: CGWindowID, fallback: CGRect) -> CGRect? {
        if let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
           let boundsValue = info.first?[kCGWindowBounds as String] {
            // CGWindowListCopyWindowInfo documents kCGWindowBounds as a
            // CGRect dictionary. Avoid `as? CFDictionary`: Swift 6 diagnoses
            // conditional casts to CoreFoundation collection types because
            // bridging makes that conditional cast meaningless.
            let boundsDictionary = boundsValue as! CFDictionary
            if let quartzRect = CGRect(dictionaryRepresentation: boundsDictionary) {
                return appKitRect(fromQuartzRect: quartzRect)
            }
        }
        return appKitRect(fromQuartzRect: fallback)
    }

    private static func appKitRect(fromQuartzRect rect: CGRect) -> CGRect {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            let quartzDisplay = CGDisplayBounds(displayID)
            guard quartzDisplay.contains(center) || quartzDisplay.intersects(rect) else { continue }

            let sx = screen.frame.width / max(quartzDisplay.width, 1)
            let sy = screen.frame.height / max(quartzDisplay.height, 1)
            let localX = (rect.minX - quartzDisplay.minX) * sx
            let localTop = (rect.minY - quartzDisplay.minY) * sy
            let width = rect.width * sx
            let height = rect.height * sy
            return CGRect(
                x: screen.frame.minX + localX,
                y: screen.frame.maxY - localTop - height,
                width: width,
                height: height
            )
        }

        let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? rect.maxY
        return CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func describeSystemSelection(_ filter: SCContentFilter) -> SystemCaptureSelection {
        let width = max(Int((filter.contentRect.width * CGFloat(max(filter.pointPixelScale, 1))).rounded()), 1)
        let height = max(Int((filter.contentRect.height * CGFloat(max(filter.pointPixelScale, 1))).rounded()), 1)

        switch filter.style {
        case .window:
            // `includedWindows` was added in macOS 15.2. The picker itself works
            // on our macOS 14 deployment target, so older systems simply use a
            // generic label while still capturing the exact filter the user chose.
            if #available(macOS 15.2, *), let window = filter.includedWindows.first {
                let appName = window.owningApplication?.applicationName ?? "Window"
                let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = title.isEmpty ? appName : "\(appName) — \(title)"
                return SystemCaptureSelection(
                    styleName: "Window",
                    displayName: name,
                    detail: "Selected with the macOS sharing picker",
                    width: width,
                    height: height
                )
            }
            return SystemCaptureSelection(
                styleName: "Window",
                displayName: "Selected Window",
                detail: "Selected with the macOS sharing picker",
                width: width,
                height: height
            )

        case .application:
            // `includedApplications` is also macOS 15.2+. Keep the app deployable
            // to macOS 14 by falling back to a generic description there.
            if #available(macOS 15.2, *), let app = filter.includedApplications.first {
                return SystemCaptureSelection(
                    styleName: "Application",
                    displayName: app.applicationName,
                    detail: "All selected \(app.applicationName) windows",
                    width: width,
                    height: height
                )
            }
            return SystemCaptureSelection(
                styleName: "Application",
                displayName: "Selected Application",
                detail: "Selected with the macOS sharing picker",
                width: width,
                height: height
            )

        case .display:
            return SystemCaptureSelection(
                styleName: "Screen",
                displayName: "Selected Screen",
                detail: "Full display capture",
                width: width,
                height: height
            )

        case .none:
            return SystemCaptureSelection(styleName: "Source", displayName: "Selected Source", detail: "macOS sharing picker", width: width, height: height)

        @unknown default:
            return SystemCaptureSelection(styleName: "Source", displayName: "Selected Source", detail: "macOS sharing picker", width: width, height: height)
        }
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

        @inline(__always) func luma(_ x: Int, _ y: Int) -> Int {
            let p = pointer + y * rowBytes + x * 4
            return (Int(p[2]) * 30 + Int(p[1]) * 59 + Int(p[0]) * 11) / 100
        }

        // 1.7 — sample the letterbox-trimmed picture, not the raw window.
        // These used to be fractions of whatever the capture happened to be, so
        // any framing other than a clean fullscreen game — a windowed feed, a
        // recording played back in a player — pointed them at the wrong pixels.
        var left = 0, right = width - 1, top = 0, bottom = height - 1
        func columnIsBar(_ x: Int) -> Bool {
            var bright = 0
            var samples = 0
            for y in stride(from: 0, to: height, by: max(1, height / 64)) {
                if luma(x, y) > 40 { bright += 1 }
                samples += 1
            }
            return samples > 0 && Double(bright) / Double(samples) < 0.02
        }
        func rowIsBar(_ y: Int) -> Bool {
            var bright = 0
            var samples = 0
            for x in stride(from: 0, to: width, by: max(1, width / 64)) {
                if luma(x, y) > 40 { bright += 1 }
                samples += 1
            }
            return samples > 0 && Double(bright) / Double(samples) < 0.02
        }
        while left < width / 3, columnIsBar(left) { left += 1 }
        while right > 2 * width / 3, columnIsBar(right) { right -= 1 }
        while top < height / 3, rowIsBar(top) { top += 1 }
        while bottom > 2 * height / 3, rowIsBar(bottom) { bottom -= 1 }

        let contentWidth = Double(right - left + 1)
        let contentHeight = Double(bottom - top + 1)
        guard contentWidth > 32, contentHeight > 32 else { return nil }

        // Watch only the card grid. The detail panel used to be sampled too, but
        // it renders a continuously animating 3D Sprite, so a frame containing it
        // never settles — the scan sat on "tracking scroll" forever and never
        // produced anchors. Scroll position is what we actually need to detect,
        // and the grid alone shows that.
        let region = (x: 0.045, y: 0.20, width: 0.32, height: 0.72)
        let samplesX = 16
        let samplesY = 14
        var output: [UInt8] = []
        output.reserveCapacity(samplesX * samplesY)

        for sy in 0..<samplesY {
            for sx in 0..<samplesX {
                let nx = region.x + region.width * (Double(sx) + 0.5) / Double(samplesX)
                let ny = region.y + region.height * (Double(sy) + 0.5) / Double(samplesY)
                let x = min(max(left + Int(nx * contentWidth), 0), width - 1)
                let y = min(max(top + Int(ny * contentHeight), 0), height - 1)
                output.append(UInt8(clamping: luma(x, y)))
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

private enum SpriteOverlayCardState: Equatable {
    case processing
    case recognized(name: String, level: Int?, mastered: Bool)
    case needsHelp(promptForSelection: Bool)
    case locked
    case lost(name: String, level: Int?, mastered: Bool)

    var isResolvedIdentity: Bool {
        switch self {
        case .recognized, .lost: return true
        default: return false
        }
    }
}

private struct RememberedOverlayState {
    let signature: UInt64
    let state: SpriteOverlayCardState
}

// AppKit overlay state is touched on the main thread. ScreenCaptureKit invokes
// its owner from a sample queue, so the controller is explicitly synchronized.
private final class SpriteScanOverlayController: @unchecked Sendable {
    var onDeepScan: ((Int) -> Void)?

    private var panel: NSPanel?
    private var overlayView: SpriteScanOverlayView?
    private var hoverTimer: Timer?
    private var animationTimer: Timer?
    private var hoveredSlot: Int?
    private var hoverStartedAt: TimeInterval = 0
    private var deepScannedSlots = Set<Int>()
    private var rememberedStates: [Int: RememberedOverlayState] = [:]
    private var requiresRealignment = false
    private var sessionIdentifiedNames = Set<String>()

    deinit {
        hoverTimer?.invalidate()
        animationTimer?.invalidate()
    }

    func show(over frame: CGRect) {
        precondition(Thread.isMainThread)
        let usableFrame = frame.standardized
        guard usableFrame.width >= 100, usableFrame.height >= 100 else { return }

        if let panel {
            panel.setFrame(usableFrame, display: true)
            panel.orderFrontRegardless()
            startHoverTracking()
            startAnimationTimer()
            return
        }

        let panel = NSPanel(
            contentRect: usableFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.isReleasedWhenClosed = false

        let view = SpriteScanOverlayView(frame: CGRect(origin: .zero, size: usableFrame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        self.panel = panel
        self.overlayView = view
        panel.orderFrontRegardless()
        startHoverTracking()
        startAnimationTimer()
    }

    func hide() {
        precondition(Thread.isMainThread)
        hoverTimer?.invalidate()
        hoverTimer = nil
        animationTimer?.invalidate()
        animationTimer = nil
        hoveredSlot = nil
        deepScannedSlots.removeAll()
        rememberedStates.removeAll()
        requiresRealignment = false
        panel?.orderOut(nil)
        panel = nil
        overlayView = nil
    }

    func showWaiting(message: String) {
        precondition(Thread.isMainThread)
        deepScannedSlots.removeAll()
        requiresRealignment = false
        hoveredSlot = nil
        overlayView?.hoveredSlot = nil
        overlayView?.mode = .waiting
        overlayView?.statusText = message
        overlayView?.cardAnchors = []
        overlayView?.cardStates = [:]
        overlayView?.needsDisplay = true
    }

    func showMoving() {
        precondition(Thread.isMainThread)
        // Do not leave a fixed stencil sitting over the game while Fortnite is
        // scrolling. Keep the last confirmed anchors internally, hide the card
        // boxes, then reuse them for animated processing dots only after the next
        // stable frame passes the strict Sprites/Collection gate.
        deepScannedSlots.removeAll()
        requiresRealignment = true
        hoveredSlot = nil
        overlayView?.hoveredSlot = nil
        overlayView?.mode = .moving
        overlayView?.statusText = "Tracking scroll · aligning cards…"
        overlayView?.cardStates = [:]
        overlayView?.needsDisplay = true
    }

    func beginProcessing() {
        precondition(Thread.isMainThread)
        guard let view = overlayView else { return }
        guard !view.cardAnchors.isEmpty else {
            view.mode = .waiting
            view.statusText = "Collection found · aligning visible cards…"
            view.needsDisplay = true
            return
        }

        var states = view.cardStates
        let forceProcessing = requiresRealignment
        requiresRealignment = false
        for anchor in view.cardAnchors {
            if !forceProcessing,
               let current = states[anchor.slot], current.isResolvedIdentity {
                continue
            }
            if !forceProcessing,
               let remembered = rememberedStates[anchor.slot],
               signaturesMatch(remembered.signature, anchor.visualSignature),
               remembered.state.isResolvedIdentity {
                states[anchor.slot] = remembered.state
            } else {
                states[anchor.slot] = .processing
            }
        }
        view.mode = .collection
        view.statusText = "Reading aligned Sprite cards…"
        view.cardStates = states
        view.needsDisplay = true
    }

    func showProcessing(anchors: [SpriteCardAnchor]) {
        precondition(Thread.isMainThread)
        guard let view = overlayView, !anchors.isEmpty else { return }
        let aligned = anchors.sorted { $0.slot < $1.slot }
        hoveredSlot = nil
        view.hoveredSlot = nil
        view.cardAnchors = aligned
        view.cardStates = Dictionary(uniqueKeysWithValues: aligned.map {
            ($0.slot, SpriteOverlayCardState.processing)
        })
        view.mode = .collection
        view.statusText = "Reading aligned Sprite cards…"
        requiresRealignment = false
        view.needsDisplay = true
    }

    func update(with analysis: SpriteFrameAnalysis) {
        precondition(Thread.isMainThread)
        guard analysis.isCollectionScreen else {
            showWaiting(message: "Please open Sprites → Collection · Stop ⌃⌥X")
            return
        }
        guard let view = overlayView else { return }

        let anchors = analysis.cardAnchors.sorted { $0.slot < $1.slot }
        view.cardAnchors = anchors

        guard !anchors.isEmpty else {
            view.mode = .waiting
            view.statusText = "Collection found · aligning visible cards…"
            view.cardStates = [:]
            view.needsDisplay = true
            return
        }

        let anchorBySlot = Dictionary(uniqueKeysWithValues: anchors.map { ($0.slot, $0) })

        // Drop memory when the pixels in a slot clearly changed. This is what
        // lets a deep-scan result survive repeated scans without attaching an
        // old name to a different Sprite after the user scrolls.
        let staleSlots = rememberedStates.compactMap { slot, remembered -> Int? in
            guard let anchor = anchorBySlot[slot],
                  signaturesMatch(remembered.signature, anchor.visualSignature) else {
                return slot
            }
            return nil
        }
        for slot in staleSlots {
            rememberedStates.removeValue(forKey: slot)
            deepScannedSlots.remove(slot)
        }

        var states: [Int: SpriteOverlayCardState] = [:]
        for anchor in anchors {
            if let remembered = rememberedStates[anchor.slot],
               signaturesMatch(remembered.signature, anchor.visualSignature),
               remembered.state.isResolvedIdentity {
                states[anchor.slot] = remembered.state
            } else {
                states[anchor.slot] = .needsHelp(promptForSelection: false)
            }
        }

        for slot in analysis.lockedSlots where anchorBySlot[slot] != nil {
            states[slot] = .locked
        }
        for slot in analysis.needsHelpSlots where anchorBySlot[slot] != nil {
            // Never downgrade a remembered successful deep scan of the same card.
            if states[slot]?.isResolvedIdentity != true {
                states[slot] = .needsHelp(promptForSelection: deepScannedSlots.contains(slot))
            }
        }

        for detection in analysis.detections {
            guard let slot = detection.gridSlot,
                  let anchor = anchorBySlot[slot] else { continue }
            let state: SpriteOverlayCardState = detection.status == .lost
                ? .lost(name: detection.name, level: detection.level, mastered: detection.mastered)
                : .recognized(name: detection.name, level: detection.level, mastered: detection.mastered)
            states[slot] = state
            rememberedStates[slot] = RememberedOverlayState(
                signature: anchor.visualSignature,
                state: state
            )
        }

        // The right-hand panel names exactly one card. Mark that slot so the
        // overlay can show which identification is independently confirmed.
        if let selectedName = analysis.selectedSpriteName {
            let key = selectedName.lowercased().filter { $0.isLetter || $0.isNumber }
            view.selectedSlot = analysis.detections.first {
                $0.name.lowercased().filter { $0.isLetter || $0.isNumber } == key
            }?.gridSlot
        } else {
            view.selectedSlot = nil
        }

        sessionIdentifiedNames.formUnion(analysis.detections.map(\.name))
        view.spritesRead = sessionIdentifiedNames.count
        if view.sessionStartedAt == nil { view.sessionStartedAt = Date() }

        view.mode = .collection
        view.statusText = analysis.detections.isEmpty
            ? "Cards aligned · hover 👎 to retry"
            : "Cards aligned · \(analysis.detections.count) recognized"
        view.cardStates = states
        view.needsDisplay = true
    }

    /// Distinct Sprites identified during this overlay session, for the readout.
    func resetSessionReadout(newThisSession: Int) {
        precondition(Thread.isMainThread)
        sessionIdentifiedNames.removeAll()
        overlayView?.spritesRead = 0
        overlayView?.newThisSession = newThisSession
        overlayView?.sessionStartedAt = Date()
    }

    func setNewThisSession(_ count: Int) {
        precondition(Thread.isMainThread)
        guard overlayView?.newThisSession != count else { return }
        overlayView?.newThisSession = count
        overlayView?.needsDisplay = true
    }

    func finishDeepScan(slot: Int, detection: DetectedSprite?) {
        precondition(Thread.isMainThread)
        deepScannedSlots.insert(slot)
        guard let view = overlayView else { return }
        var states = view.cardStates

        if let detection {
            let state: SpriteOverlayCardState = detection.status == .lost
                ? .lost(name: detection.name, level: detection.level, mastered: detection.mastered)
                : .recognized(name: detection.name, level: detection.level, mastered: detection.mastered)
            states[slot] = state
            if let anchor = view.cardAnchors.first(where: { $0.slot == slot }) {
                rememberedStates[slot] = RememberedOverlayState(
                    signature: anchor.visualSignature,
                    state: state
                )
            }
            view.statusText = "Recognized \(detection.name)"
        } else {
            states[slot] = .needsHelp(promptForSelection: true)
            view.statusText = "Needs help · select this Sprite in Fortnite"
        }
        view.cardStates = states
        view.needsDisplay = true
    }

    private func startHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.pollMouse()
        }
        if let hoverTimer { RunLoop.main.add(hoverTimer, forMode: .common) }
    }

    private func startAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.34, repeats: true) { [weak self] _ in
            guard let view = self?.overlayView else { return }
            view.processingPhase = (view.processingPhase + 1) % 3
            if view.cardStates.values.contains(.processing) {
                view.needsDisplay = true
            }
        }
        if let animationTimer { RunLoop.main.add(animationTimer, forMode: .common) }
    }

    private func pollMouse() {
        guard let panel, let view = overlayView, view.mode == .collection else { return }
        let globalPoint = NSEvent.mouseLocation
        guard panel.frame.contains(globalPoint) else {
            resetHover()
            return
        }

        let local = CGPoint(x: globalPoint.x - panel.frame.minX, y: globalPoint.y - panel.frame.minY)
        guard let slot = view.cardSlot(at: local),
              let state = view.cardStates[slot],
              case .needsHelp = state else {
            resetHover()
            return
        }

        if hoveredSlot != slot {
            hoveredSlot = slot
            hoverStartedAt = ProcessInfo.processInfo.systemUptime
            view.hoveredSlot = slot
            view.needsDisplay = true
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - hoverStartedAt
        guard elapsed >= 0.70, !deepScannedSlots.contains(slot) else { return }
        deepScannedSlots.insert(slot)
        view.cardStates[slot] = .processing
        view.hoveredSlot = slot
        view.statusText = "Deep scanning this Sprite…"
        view.needsDisplay = true
        onDeepScan?(slot)
    }

    private func resetHover() {
        guard hoveredSlot != nil else { return }
        hoveredSlot = nil
        overlayView?.hoveredSlot = nil
        overlayView?.needsDisplay = true
    }

    private func signaturesMatch(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
        guard lhs != 0, rhs != 0 else { return lhs == rhs }
        return (lhs ^ rhs).nonzeroBitCount <= 10
    }
}

private final class SpriteScanOverlayView: NSView {
    enum Mode { case waiting, moving, collection }

    var mode: Mode = .waiting
    var statusText = "Finding Sprite Collection…"
    var cardStates: [Int: SpriteOverlayCardState] = [:]
    var cardAnchors: [SpriteCardAnchor] = []
    var hoveredSlot: Int?
    var processingPhase = 0
    /// Slot the right-hand detail panel is currently describing, if known.
    var selectedSlot: Int?
    /// 5.2 — live session readout.
    var spritesRead = 0
    var newThisSession = 0
    var sessionStartedAt: Date?

    private let magenta = NSColor(calibratedRed: 1.0, green: 0.10, blue: 0.72, alpha: 1.0)

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !bounds.isEmpty else { return }

        // Moving mode intentionally shows no stale boxes. They reappear only
        // after the analyzer has actively re-aligned to the current card rows.
        if mode == .collection {
            drawAlignedCards()
        }
        drawStatusPill()
        drawSessionReadout()
    }

    func cardSlot(at point: CGPoint) -> Int? {
        for anchor in cardAnchors where cardRect(for: anchor).contains(point) {
            return anchor.slot
        }
        return nil
    }

    /// 5.1 — box colour carries the card's state at a glance.
    ///
    /// green   identified
    /// yellow  currently selected, name confirmed by the right-hand panel
    /// orange  still reading, or not confident enough to name
    /// grey    locked
    private func outlineColour(for state: SpriteOverlayCardState?, slot: Int) -> NSColor {
        if slot == selectedSlot, state?.isResolvedIdentity == true {
            return NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.10, alpha: 1)
        }
        switch state {
        case .recognized, .lost:
            return NSColor(calibratedRed: 0.16, green: 0.86, blue: 0.38, alpha: 1)
        case .processing, .needsHelp:
            return NSColor(calibratedRed: 1.00, green: 0.56, blue: 0.10, alpha: 1)
        case .locked:
            return NSColor(calibratedWhite: 0.62, alpha: 1)
        case nil:
            return magenta
        }
    }

    private func drawAlignedCards() {
        for anchor in cardAnchors {
            let slot = anchor.slot
            let rect = cardRect(for: anchor)
            guard rect.width >= 16, rect.height >= 16 else { continue }

            let state = cardStates[slot]
            let colour = outlineColour(for: state, slot: slot)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)

            // Darken the inside so a name printed over busy artwork stays
            // readable. Locked cards stay untinted; there is nothing to read.
            if state != .locked {
                NSColor.black.withAlphaComponent(hoveredSlot == slot ? 0.34 : 0.22).setFill()
                path.fill()
            }

            colour.withAlphaComponent(hoveredSlot == slot ? 1.0 : 0.92).setStroke()
            path.lineWidth = hoveredSlot == slot ? 3.0 : 2.0
            path.stroke()

            guard let state else { continue }
            drawState(state, in: rect, slot: slot)
        }
    }

    private func drawState(_ state: SpriteOverlayCardState, in card: CGRect, slot: Int) {
        let badgeText: String
        switch state {
        case .processing:
            badgeText = String(repeating: "•", count: processingPhase + 1)
        case let .recognized(_, level, mastered):
            badgeText = "👍\(level.map { " L\($0)" } ?? "")\(mastered ? " 👑" : "")"
        case let .needsHelp(prompt):
            badgeText = prompt ? "👎 SELECT" : "👎"
        case .locked:
            badgeText = "🔒"
        case let .lost(_, level, mastered):
            badgeText = "SUMMON\(level.map { " L\($0)" } ?? "")\(mastered ? " 👑" : "")"
        }
        drawBadge(text: badgeText, in: card)

        switch state {
        case let .recognized(name, _, _), let .lost(name, _, _):
            drawName(name, in: card)
        default:
            break
        }

        if case .needsHelp = state, hoveredSlot == slot {
            drawHelpText(for: state, card: card)
        }
    }

    private func drawBadge(text: String, in card: CGRect) {
        let font = NSFont.systemFont(ofSize: max(9, min(11.5, card.width * 0.075)), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let badgeWidth = min(card.width - 8, size.width + 10)
        let badge = CGRect(
            x: card.maxX - badgeWidth - 4,
            y: card.maxY - size.height - 10,
            width: badgeWidth,
            height: size.height + 6
        )
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        text.draw(at: CGPoint(x: badge.minX + 5, y: badge.minY + 3), withAttributes: attributes)
    }

    private func drawName(_ name: String, in card: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let font = NSFont.systemFont(ofSize: max(9, min(11.5, card.width * 0.073)), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]

        let textWidth = max(card.width - 12, 20)
        let measured = (name as NSString).boundingRect(
            with: CGSize(width: textWidth, height: 80),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let height = min(max(18, ceil(measured.height) + 8), min(card.height * 0.34, 42))
        let plate = CGRect(
            x: card.minX + 4,
            y: card.minY + 4,
            width: card.width - 8,
            height: height
        )
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5).fill()
        (name as NSString).draw(
            in: plate.insetBy(dx: 4, dy: 4),
            withAttributes: attributes
        )
    }

    private func drawHelpText(for state: SpriteOverlayCardState, card: CGRect) {
        guard case let .needsHelp(prompt) = state else { return }
        let message = prompt ? "Select this Sprite in Fortnite to verify" : "Hover to deep scan"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let width = min(max(card.width * 1.65, 150), 235)
        let textRect = CGRect(x: card.midX - width / 2, y: card.minY - 30, width: width, height: 25)
        NSColor.black.withAlphaComponent(0.84).setFill()
        NSBezierPath(roundedRect: textRect, xRadius: 7, yRadius: 7).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var attrs = attributes
        attrs[.paragraphStyle] = paragraph
        message.draw(in: textRect.insetBy(dx: 6, dy: 6), withAttributes: attrs)
    }

    private func drawStatusPill() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = statusText.size(withAttributes: attributes)
        let width = min(max(size.width + 24, 150), max(bounds.width - 24, 150))
        let rect = CGRect(
            x: max((bounds.width - width) / 2, 12),
            y: max(bounds.height - size.height - 38, 12),
            width: width,
            height: size.height + 16
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        magenta.withAlphaComponent(0.75).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        border.lineWidth = 1
        border.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var attrs = attributes
        attrs[.paragraphStyle] = paragraph
        statusText.draw(in: rect.insetBy(dx: 10, dy: 8), withAttributes: attrs)
    }

    /// 5.2 — small live readout in the corner. OBS runs fullscreen while the
    /// user plays, so the menu bar is hidden and this is the only place session
    /// progress can be seen mid-scan.
    private func drawSessionReadout() {
        guard mode == .collection else { return }

        var lines = ["Read \(spritesRead)/\(SpriteCatalog.all.count)"]
        if newThisSession > 0 {
            lines.append("New \(newThisSession)")
        }
        if let started = sessionStartedAt {
            let elapsed = Int(Date().timeIntervalSince(started))
            lines.append(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
        }
        let text = lines.joined(separator: "   ")

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.maxX - size.width - 34,
            y: bounds.maxY - size.height - 30,
            width: size.width + 20,
            height: size.height + 12
        )
        guard rect.minX > bounds.minX, rect.minY > bounds.minY else { return }

        NSColor.black.withAlphaComponent(0.70).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        text.draw(in: rect.insetBy(dx: 10, dy: 6), withAttributes: attributes)
    }

    private func cardRect(for anchor: SpriteCardAnchor) -> CGRect {
        let width = bounds.width * CGFloat(anchor.width)
        let height = bounds.height * CGFloat(anchor.height)
        return CGRect(
            x: bounds.minX + bounds.width * CGFloat(anchor.x),
            y: bounds.maxY - bounds.height * CGFloat(anchor.y) - height,
            width: width,
            height: height
        )
    }
}

private enum ScreenCaptureServiceError: LocalizedError {
    case windowUnavailable
    case noSystemSelection

    var errorDescription: String? {
        switch self {
        case .windowUnavailable:
            return "The selected capture window is no longer available. Choose it again and try once more."
        case .noSystemSelection:
            return "Select the Fortnite window first."
        }
    }
}
