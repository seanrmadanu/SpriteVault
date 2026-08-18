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
    private var selectedSourceRect: CGRect?
    private var selectedOverlayRect: CGRect?
    private var latestStableFrame: CGImage?
    private let overlayController = SpriteScanOverlayController()
    private var regionSelector: ScreenRegionSelector?
    private var pickerSelectionHandler: PickerSelectionHandler?
    private var pickerObserverInstalled = false

    var hasSystemSelection: Bool { selectedSystemFilter != nil }
    var systemSelection: SystemCaptureSelection? { selectedSystemSelection }

    func setPreviewEnabled(_ enabled: Bool) {
        sampleQueue.async { [weak self] in
            self?.previewEnabled = enabled
        }
    }

    /// Screenshot-style region selection. The user can drag around the exact
    /// Fortnite pixels regardless of whether they come from OBS, Remote Play,
    /// GeForce NOW, a browser, or a full-screen projector.
    @MainActor
    func presentRegionSelector(onSelection: @escaping PickerSelectionHandler) {
        regionSelector?.cancel()
        let selector = ScreenRegionSelector { [weak self] screen, localRect in
            guard let self else { return }
            self.regionSelector = nil
            guard let screen, let localRect else {
                onSelection(nil)
                return
            }

            Task {
                do {
                    let selection = try await self.configureRegion(screen: screen, localRect: localRect)
                    onSelection(selection)
                } catch {
                    self.onError?(error)
                    onSelection(nil)
                }
            }
        }
        regionSelector = selector
        selector.begin()
    }

    func restoreSavedRegionSelection() async -> SystemCaptureSelection? {
        guard selectedSystemFilter == nil,
              let saved = SavedCaptureRegion.load() else {
            return selectedSystemSelection
        }

        let screen = await MainActor.run {
            NSScreen.screens.first(where: { Self.displayID(for: $0) == saved.displayID })
        }
        guard let screen else { return nil }

        let localRect = CGRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
        do {
            return try await configureRegion(screen: screen, localRect: localRect, persist: false)
        } catch {
            return nil
        }
    }

    /// The older native sharing picker remains available internally as a
    /// fallback, but Live Capture now uses the region selector above.
    /// Presents Apple's native ScreenCaptureKit sharing picker. This is the
    /// same system-level content picker ScreenCaptureKit recommends instead of
    /// maintaining our own fragile list of windows. It can see displays and
    /// windows across Spaces, including full-screen OBS projector surfaces.
    func presentSystemPicker(onSelection: @escaping PickerSelectionHandler) {
        pickerSelectionHandler = onSelection

        let picker = SCContentSharingPicker.shared
        if !pickerObserverInstalled {
            picker.add(self)
            pickerObserverInstalled = true
        }

        var configuration = SCContentSharingPickerConfiguration()
        let modesRawValue = SCContentSharingPickerMode.singleWindow.rawValue
            | SCContentSharingPickerMode.singleDisplay.rawValue
        configuration.allowedPickerModes = SCContentSharingPickerMode(rawValue: modesRawValue)
        configuration.allowsChangingSelectedContent = true
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present()
    }

    func clearSystemSelection() {
        selectedSystemFilter = nil
        selectedSystemSelection = nil
        selectedSourceRect = nil
        selectedOverlayRect = nil
        DispatchQueue.main.async { [overlayController] in overlayController.hide() }
        SavedCaptureRegion.clear()
    }

    func captureSystemSelectionOnce() async throws -> CGImage {
        guard let filter = selectedSystemFilter else {
            throw ScreenCaptureServiceError.noSystemSelection
        }
        let configuration = configuration(for: filter, fps: 12, sourceRect: selectedSourceRect)
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
            sourceRect: selectedSourceRect,
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
        let configuration = configuration(for: filter, fps: 12, sourceRect: nil)
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
            sourceRect: nil,
            fps: fps,
            onAnalysis: onAnalysis,
            onStatus: onStatus,
            onPreview: onPreview,
            onError: onError
        )
    }

    private func start(
        filter: SCContentFilter,
        sourceRect: CGRect?,
        fps: Int,
        onAnalysis: @escaping AnalysisHandler,
        onStatus: @escaping StatusHandler,
        onPreview: @escaping PreviewHandler,
        onError: @escaping ErrorHandler
    ) async throws {
        if stream != nil { await stop() }

        // Capture at a genuinely responsive rate. Vision is throttled separately
        // below, so 12–15 capture FPS does not mean 12–15 OCR passes per second.
        let clampedFPS = min(max(fps, 8), 15)
        let configuration = configuration(for: filter, fps: clampedFPS, sourceRect: sourceRect)

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
                overlayController.showWaiting(message: "Finding Sprite Collection…")
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
        onStatus("Capture connected. Waiting for the Sprite Collection to settle…")
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

        Task { [weak self] in
            guard let self else { return }
            let cleanFilter = await self.filterExcludingSpriteVaultIfNeeded(filter)
            self.selectedSystemFilter = cleanFilter
            self.selectedSourceRect = nil
            self.selectedOverlayRect = Self.resolveOverlayRect(for: cleanFilter)
            let selection = Self.describeSystemSelection(cleanFilter)
            self.selectedSystemSelection = selection
            handler?(selection)
        }
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
                overlayController.showWaiting(message: "Capture resumed · finding collection…")
            }
            onStatus?("Capture resumed — waiting briefly for the Sprite Collection to settle…")
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
            DispatchQueue.main.async { [overlayController] in
                overlayController.beginProcessing()
            }
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
        DispatchQueue.main.async { [overlayController] in
            overlayController.beginProcessing()
        }
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
                            lockedSlots: [],
                            needsHelpSlots: [],
                            selectedSpriteName: detection.name
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

    /// A desktop-independent window filter only contains the selected app
    /// window, so our overlay cannot appear in it. A whole-display picker filter
    /// does include other app windows, however. Rebuild that case with Sprite
    /// Vault excluded so the user sees magenta feedback while Vision sees clean
    /// Fortnite pixels.
    private func filterExcludingSpriteVaultIfNeeded(_ filter: SCContentFilter) async -> SCContentFilter {
        guard #available(macOS 15.2, *),
              filter.style == .display,
              let display = filter.includedDisplays.first,
              let ownBundleID = Bundle.main.bundleIdentifier else {
            return filter
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
            guard !ownApps.isEmpty else { return filter }
            return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        } catch {
            // The original system picker filter is still usable. Falling back is
            // better than canceling a capture simply because exclusion refresh
            // failed transiently.
            return filter
        }
    }

    @MainActor
    private func configureRegion(
        screen: NSScreen,
        localRect: CGRect,
        persist: Bool = true
    ) async throws -> SystemCaptureSelection {
        guard let displayID = Self.displayID(for: screen) else {
            throw ScreenCaptureServiceError.displayUnavailable
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureServiceError.displayUnavailable
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let excludedApps = content.applications.filter { app in
            guard let ownBundleID else { return false }
            return app.bundleIdentifier == ownBundleID
        }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let clamped = CGRect(
            x: max(0, min(localRect.minX, screen.frame.width - 1)),
            y: max(0, min(localRect.minY, screen.frame.height - 1)),
            width: max(1, min(localRect.width, screen.frame.width - max(localRect.minX, 0))),
            height: max(1, min(localRect.height, screen.frame.height - max(localRect.minY, 0)))
        )

        // AppKit view coordinates start at the bottom-left. ScreenCaptureKit's
        // display source rectangle uses the display's logical coordinate system
        // with the top edge as y=0, so flip the local y coordinate.
        let sourceRect = CGRect(
            x: clamped.minX,
            y: screen.frame.height - clamped.maxY,
            width: clamped.width,
            height: clamped.height
        )

        selectedSystemFilter = filter
        selectedSourceRect = sourceRect
        selectedOverlayRect = CGRect(
            x: screen.frame.minX + clamped.minX,
            y: screen.frame.minY + clamped.minY,
            width: clamped.width,
            height: clamped.height
        )

        let scale = max(screen.backingScaleFactor, 1)
        let selection = SystemCaptureSelection(
            styleName: "Area",
            displayName: "Selected Fortnite Area",
            detail: "\(screen.localizedName) · drag-selected region",
            width: max(Int((clamped.width * scale).rounded()), 1),
            height: max(Int((clamped.height * scale).rounded()), 1)
        )
        selectedSystemSelection = selection

        if persist {
            SavedCaptureRegion(
                displayID: displayID,
                x: clamped.minX,
                y: clamped.minY,
                width: clamped.width,
                height: clamped.height
            ).save()
        }
        return selection
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
                overlayController.showWaiting(message: "Capture idle · waiting for frames")
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
        fps: Int,
        sourceRect: CGRect?
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        configuration.showsCursor = false
        configuration.queueDepth = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))

        // sourceRect is expressed in the display's logical point coordinate
        // system. Capturing only that region keeps Vision away from unrelated
        // desktop pixels and avoids an extra crop on every frame.
        if let sourceRect {
            configuration.sourceRect = sourceRect
        }

        let pixelScale = max(CGFloat(filter.pointPixelScale), 1)
        let sourceSize = sourceRect?.size ?? filter.contentRect.size
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
           let dictionary = info.first?[kCGWindowBounds as String] as? CFDictionary,
           let quartzRect = CGRect(dictionaryRepresentation: dictionary) {
            return appKitRect(fromQuartzRect: quartzRect)
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

private enum SpriteOverlayCardState: Equatable {
    case processing
    case recognized(name: String, level: Int?, mastered: Bool)
    case needsHelp(promptForSelection: Bool)
    case locked
    case lost(name: String, level: Int?, mastered: Bool)
}

private final class SpriteScanOverlayController {
    var onDeepScan: ((Int) -> Void)?

    private var panel: NSPanel?
    private var overlayView: SpriteScanOverlayView?
    private var hoverTimer: Timer?
    private var hoveredSlot: Int?
    private var hoverStartedAt: TimeInterval = 0
    private var deepScannedSlots = Set<Int>()

    deinit { hoverTimer?.invalidate() }

    func show(over frame: CGRect) {
        precondition(Thread.isMainThread)
        let usableFrame = frame.standardized
        guard usableFrame.width >= 100, usableFrame.height >= 100 else { return }

        if let panel {
            panel.setFrame(usableFrame, display: true)
            panel.orderFrontRegardless()
            startHoverTracking()
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
    }

    func hide() {
        precondition(Thread.isMainThread)
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoveredSlot = nil
        deepScannedSlots.removeAll()
        panel?.orderOut(nil)
        panel = nil
        overlayView = nil
    }

    func showWaiting(message: String) {
        precondition(Thread.isMainThread)
        deepScannedSlots.removeAll()
        overlayView?.mode = .waiting
        overlayView?.statusText = message
        overlayView?.cardStates = [:]
        overlayView?.needsDisplay = true
    }

    func showMoving() {
        precondition(Thread.isMainThread)
        // Slot numbers are positional. Once the collection scrolls, slot 4 can
        // contain a completely different Sprite, so retry history must reset.
        deepScannedSlots.removeAll()
        hoveredSlot = nil
        overlayView?.hoveredSlot = nil
        overlayView?.mode = .moving
        overlayView?.statusText = "Scrolling…"
        overlayView?.needsDisplay = true
    }

    func beginProcessing() {
        precondition(Thread.isMainThread)
        var states: [Int: SpriteOverlayCardState] = [:]
        for slot in 0..<12 { states[slot] = .processing }
        overlayView?.mode = .collection
        overlayView?.statusText = "Reading visible Sprites…"
        overlayView?.cardStates = states
        overlayView?.needsDisplay = true
    }

    func update(with analysis: SpriteFrameAnalysis) {
        precondition(Thread.isMainThread)
        guard analysis.isCollectionScreen else {
            showWaiting(message: "Finding Sprite Collection…")
            return
        }

        let visibleCount = max(0, min(analysis.visibleSlots, 12))
        var states: [Int: SpriteOverlayCardState] = [:]
        for slot in 0..<visibleCount { states[slot] = .needsHelp(promptForSelection: false) }

        for slot in analysis.lockedSlots where slot < visibleCount {
            states[slot] = .locked
        }
        for slot in analysis.needsHelpSlots where slot < visibleCount {
            states[slot] = .needsHelp(promptForSelection: deepScannedSlots.contains(slot))
        }
        for detection in analysis.detections {
            guard let slot = detection.gridSlot, slot < 12 else { continue }
            if detection.status == .lost {
                states[slot] = .lost(
                    name: detection.name,
                    level: detection.level,
                    mastered: detection.mastered
                )
            } else {
                states[slot] = .recognized(
                    name: detection.name,
                    level: detection.level,
                    mastered: detection.mastered
                )
            }
        }

        overlayView?.mode = .collection
        overlayView?.statusText = analysis.detections.isEmpty
            ? "Collection found · waiting for readable cards"
            : "Collection found · \(analysis.detections.count) recognized"
        overlayView?.cardStates = states
        overlayView?.needsDisplay = true
    }

    func finishDeepScan(slot: Int, detection: DetectedSprite?) {
        precondition(Thread.isMainThread)
        deepScannedSlots.insert(slot)
        guard var states = overlayView?.cardStates else { return }
        if let detection {
            states[slot] = detection.status == .lost
                ? .lost(name: detection.name, level: detection.level, mastered: detection.mastered)
                : .recognized(name: detection.name, level: detection.level, mastered: detection.mastered)
        } else {
            states[slot] = .needsHelp(promptForSelection: true)
        }
        overlayView?.cardStates = states
        if let detection {
            overlayView?.statusText = "Deep scan recognized \(detection.name)"
        } else {
            overlayView?.statusText = "Needs help · select this Sprite in Fortnite"
        }
        overlayView?.needsDisplay = true
    }

    private func startHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.pollMouse()
        }
        if let hoverTimer { RunLoop.main.add(hoverTimer, forMode: .common) }
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
        view.statusText = "Deep scanning card \(slot + 1)…"
        view.needsDisplay = true
        onDeepScan?(slot)
    }

    private func resetHover() {
        guard hoveredSlot != nil else { return }
        hoveredSlot = nil
        overlayView?.hoveredSlot = nil
        overlayView?.needsDisplay = true
    }
}

private final class SpriteScanOverlayView: NSView {
    enum Mode { case waiting, moving, collection }

    var mode: Mode = .waiting
    var statusText = "Finding Sprite Collection…"
    var cardStates: [Int: SpriteOverlayCardState] = [:]
    var hoveredSlot: Int?

    private let magenta = NSColor(calibratedRed: 1.0, green: 0.10, blue: 0.72, alpha: 1.0)

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !bounds.isEmpty else { return }

        if mode == .collection || mode == .moving {
            drawCardGrid()
            drawRightPanelGuide()
        }
        drawStatusPill()
    }

    func cardSlot(at point: CGPoint) -> Int? {
        for slot in 0..<12 where cardRect(slot: slot).contains(point) {
            return slot
        }
        return nil
    }

    private func drawCardGrid() {
        let alpha: CGFloat = mode == .moving ? 0.34 : 0.96
        for slot in 0..<12 {
            let rect = cardRect(slot: slot)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            magenta.withAlphaComponent(alpha).setStroke()
            path.lineWidth = hoveredSlot == slot ? 3.0 : 2.0
            path.stroke()

            guard mode == .collection, let state = cardStates[slot] else { continue }
            drawBadge(state: state, in: rect, slot: slot)
        }
    }

    private func drawBadge(state: SpriteOverlayCardState, in card: CGRect, slot: Int) {
        let text: String
        let fill: NSColor
        switch state {
        case .processing:
            text = "•••"
            fill = NSColor.black.withAlphaComponent(0.78)
        case let .recognized(_, level, mastered):
            let levelText = level.map { " L\($0)" } ?? ""
            text = "👍\(levelText)\(mastered ? " 👑" : "")"
            fill = NSColor.black.withAlphaComponent(0.80)
        case let .needsHelp(prompt):
            text = prompt ? "👎 SELECT" : "👎"
            fill = NSColor.black.withAlphaComponent(0.82)
        case .locked:
            text = "🔒"
            fill = NSColor.black.withAlphaComponent(0.76)
        case let .lost(_, level, mastered):
            let levelText = level.map { " L\($0)" } ?? ""
            text = "LOST\(levelText)\(mastered ? " 👑" : "")"
            fill = NSColor.black.withAlphaComponent(0.82)
        }

        let font = NSFont.systemFont(ofSize: max(10, min(13, card.width * 0.10)), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let badgeWidth = min(card.width - 8, size.width + 12)
        let badge = CGRect(
            x: card.maxX - badgeWidth - 4,
            y: card.maxY - size.height - 12,
            width: badgeWidth,
            height: size.height + 8
        )
        fill.setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        text.draw(
            at: CGPoint(x: badge.minX + 6, y: badge.minY + 4),
            withAttributes: attributes
        )

        if case .needsHelp = state, hoveredSlot == slot {
            drawHelpText(for: state, card: card)
        }
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

    private func drawRightPanelGuide() {
        let viewport = viewportRect
        let topLeft = CGRect(
            x: viewport.minX + viewport.width * 0.655,
            y: viewport.minY + viewport.height * 0.455,
            width: viewport.width * 0.285,
            height: viewport.height * 0.270
        )
        let rect = CGRect(
            x: topLeft.minX,
            y: viewport.maxY - (topLeft.minY - viewport.minY) - topLeft.height,
            width: topLeft.width,
            height: topLeft.height
        )
        magenta.withAlphaComponent(mode == .moving ? 0.18 : 0.38).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.lineWidth = 1.2
        path.stroke()
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

    private var viewportRect: CGRect {
        let targetAspect: CGFloat = 16.0 / 9.0
        let currentAspect = bounds.width / max(bounds.height, 1)
        if currentAspect > targetAspect {
            let width = bounds.height * targetAspect
            return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        }
        let height = bounds.width / targetAspect
        return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    private func cardRect(slot: Int) -> CGRect {
        let viewport = viewportRect
        let column = slot % 3
        let row = slot / 3
        let firstColumnCenter: CGFloat = 0.118
        let columnStep: CGFloat = 0.080
        let firstRowTop: CGFloat = 0.232
        let rowStep: CGFloat = 0.180
        let cardWidth: CGFloat = 0.079
        let cardHeight: CGFloat = 0.166

        let normalizedX = firstColumnCenter + CGFloat(column) * columnStep - cardWidth / 2
        let normalizedTop = firstRowTop + CGFloat(row) * rowStep
        let width = viewport.width * cardWidth
        let height = viewport.height * cardHeight
        return CGRect(
            x: viewport.minX + viewport.width * normalizedX,
            y: viewport.maxY - viewport.height * normalizedTop - height,
            width: width,
            height: height
        )
    }
}

private struct SavedCaptureRegion: Codable {
    let displayID: CGDirectDisplayID
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    private static let key = "capture.region.selection.v1"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    static func load() -> SavedCaptureRegion? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedCaptureRegion.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

@MainActor
private final class ScreenRegionSelector {
    typealias Completion = (NSScreen?, CGRect?) -> Void

    private let completion: Completion
    private var windows: [RegionSelectionWindow] = []
    private var hiddenAppWindows: [NSWindow] = []
    private var eventMonitor: Any?
    private var finished = false

    init(completion: @escaping Completion) {
        self.completion = completion
    }

    func begin() {
        // Get Sprite Vault itself out of the way before the screenshot-style
        // drag starts. The overlay windows stay visible while the normal app
        // windows are temporarily ordered out.
        hiddenAppWindows = NSApp.windows.filter { $0.isVisible }
        hiddenAppWindows.forEach { $0.orderOut(nil) }

        for screen in NSScreen.screens {
            let window = RegionSelectionWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.acceptsMouseMovedEvents = true

            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onSelection = { [weak self] rect in
                self?.finish(screen: screen, rect: rect)
            }
            window.contentView = view
            windows.append(window)
            window.orderFrontRegardless()
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }
    }

    func cancel() {
        finish(screen: nil, rect: nil)
    }

    private func finish(screen: NSScreen?, rect: CGRect?) {
        guard !finished else { return }
        finished = true
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        hiddenAppWindows.forEach { $0.orderFront(nil) }
        hiddenAppWindows.last?.makeKey()
        hiddenAppWindows.removeAll()
        NSApp.activate(ignoringOtherApps: true)
        completion(screen, rect)
    }
}

private final class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        let rect = selectionRect
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
        guard rect.width >= 40, rect.height >= 40 else { return }
        onSelection?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let selected = selectionRect
        NSColor.black.withAlphaComponent(0.44).setFill()
        if selected.isEmpty {
            NSBezierPath(rect: bounds).fill()
            drawInstruction()
            return
        }

        let outsideRects = [
            CGRect(x: bounds.minX, y: selected.maxY, width: bounds.width, height: max(bounds.maxY - selected.maxY, 0)),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(selected.minY - bounds.minY, 0)),
            CGRect(x: bounds.minX, y: selected.minY, width: max(selected.minX - bounds.minX, 0), height: selected.height),
            CGRect(x: selected.maxX, y: selected.minY, width: max(bounds.maxX - selected.maxX, 0), height: selected.height)
        ]
        for rect in outsideRects where rect.width > 0 && rect.height > 0 {
            NSBezierPath(rect: rect).fill()
        }

        NSColor.systemPink.setStroke()
        let border = NSBezierPath(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
        border.lineWidth = 3
        border.stroke()

        drawInstruction()
    }

    private var selectionRect: CGRect {
        guard let dragStart, let dragCurrent else { return .zero }
        return CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        ).intersection(bounds)
    }

    private func drawInstruction() {
        let message = dragStart == nil
            ? "Drag around the Fortnite area · Esc to cancel"
            : "Release to scan only this area"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = message.size(withAttributes: attributes)
        let rect = CGRect(
            x: max((bounds.width - size.width) / 2 - 14, 12),
            y: max(bounds.height - size.height - 54, 12),
            width: size.width + 28,
            height: size.height + 18
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        message.draw(at: CGPoint(x: rect.minX + 14, y: rect.minY + 9), withAttributes: attributes)
    }
}

private enum ScreenCaptureServiceError: LocalizedError {
    case windowUnavailable
    case noSystemSelection
    case displayUnavailable

    var errorDescription: String? {
        switch self {
        case .windowUnavailable:
            return "The selected capture window is no longer available. Choose it again and try once more."
        case .noSystemSelection:
            return "Select a Fortnite screen area first."
        case .displayUnavailable:
            return "The display used by the saved capture area is no longer available. Select the Fortnite area again."
        }
    }
}
