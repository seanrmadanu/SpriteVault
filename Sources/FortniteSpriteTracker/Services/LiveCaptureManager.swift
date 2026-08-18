import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import AVFoundation

enum LiveScanPhase: String, Sendable {
    case idle
    case waitingForSource
    case waitingForCollection
    case waitingForStability
    case scanning
    case complete
    case error

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .waitingForSource: return "Waiting for source"
        case .waitingForCollection: return "Waiting for Sprites"
        case .waitingForStability: return "Waiting for screen to settle"
        case .scanning: return "Scanning"
        case .complete: return "Scan complete"
        case .error: return "Needs attention"
        }
    }
}

@MainActor
final class LiveCaptureManager: ObservableObject {
    @Published private(set) var applications: [CaptureApplicationInfo] = []
    @Published private(set) var windows: [CaptureWindowInfo] = []
    @Published private(set) var captureDevices: [CaptureDeviceInfo] = []

    @Published var sourceMode: CaptureSourceMode {
        didSet {
            persistSourceSelection()
            invalidatePreview()
        }
    }
    @Published var selectedApplicationID: String? {
        didSet {
            persistSourceSelection()
            resolvedApplicationTarget = nil
            invalidatePreview()
        }
    }
    @Published var selectedWindowID: CGWindowID? {
        didSet {
            persistSourceSelection()
            invalidatePreview()
        }
    }
    @Published var selectedCaptureDeviceID: String? {
        didSet {
            persistSourceSelection()
            invalidatePreview()
        }
    }
    @Published var targetProfileID: UUID? {
        didSet { lastDetectionSignature = "" }
    }
    @Published var framesPerSecond = 2

    @Published private(set) var systemSelection: SystemCaptureSelection?
    @Published private(set) var resolvedApplicationTarget: ResolvedCaptureTarget?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewSourceLabel: String?
    @Published private(set) var isPreviewRefreshing = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isHotkeyScanning = false
    @Published private(set) var isCapturingOnce = false
    @Published private(set) var statusText = "Choose how Sprite Vault should read Fortnite."
    @Published private(set) var errorText: String?
    @Published private(set) var latestDetections: [DetectedSprite] = []
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var resultRevision = UUID()
    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var captureDeviceGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @Published private(set) var accessibilityGranted = GlobalCaptureHotkey.shared.hasAccessibilityPermission
    @Published private(set) var notificationsGranted = false
    @Published private(set) var scanPhase: LiveScanPhase = .idle
    @Published private(set) var sessionElapsedSeconds = 0
    @Published private(set) var scanCoverageCount = 0
    @Published private(set) var sessionObservedSpriteCount = 0
    @Published private(set) var sessionNewCount = 0
    @Published private(set) var sessionLevelUpCount = 0
    @Published private(set) var sessionMasteredCount = 0
    @Published private(set) var sessionLostCount = 0
    @Published private(set) var isCollectionScreenDetected = false
    @Published private(set) var lastCompletedSummary: ScanChangeSummary?

    private let captureService = ScreenCaptureService()
    private let captureDeviceService = VideoCaptureDeviceService()
    private let notificationService = AppNotificationService.shared
    private weak var store: SpriteStore?
    private weak var activityStore: ActivityStore?

    private var hotkeyInstalled = false
    private var lastDetectionSignature = ""
    private var sessionTimerTask: Task<Void, Never>?
    private var currentSessionID: UUID?
    private var sessionInitialOwnedCount = 0
    private var sessionProfileName = "My Collection"
    private var sessionSeenNames = Set<String>()
    private var coveredCatalogIndexes = Set<Int>()
    private var shouldFinishAfterApply = false
    private var newNames = Set<String>()
    private var levelUpNames = Set<String>()
    private var masteredNames = Set<String>()
    private var lostNames = Set<String>()
    private var previewRequestID = UUID()

    private enum DefaultsKey {
        static let mode = "capture.source.mode"
        static let application = "capture.source.application"
        static let window = "capture.source.window"
        static let device = "capture.source.device"
    }

    init() {
        let defaults = UserDefaults.standard
        let restoredMode = CaptureSourceMode(rawValue: defaults.string(forKey: DefaultsKey.mode) ?? "")
        sourceMode = restoredMode == .captureDevice ? .captureDevice : .systemPicker
        selectedApplicationID = defaults.string(forKey: DefaultsKey.application)
        let savedWindow = defaults.object(forKey: DefaultsKey.window) as? NSNumber
        selectedWindowID = savedWindow.map { CGWindowID($0.uint32Value) }
        selectedCaptureDeviceID = defaults.string(forKey: DefaultsKey.device)
    }

    func installGlobalHotkey(store: SpriteStore, activityStore: ActivityStore) {
        self.store = store
        self.activityStore = activityStore
        guard !hotkeyInstalled else { return }
        hotkeyInstalled = true

        GlobalCaptureHotkey.shared.install { [weak self] in
            Task { @MainActor in
                await self?.startHotkeyScanSession()
            }
        }
        accessibilityGranted = GlobalCaptureHotkey.shared.hasAccessibilityPermission

        Task { [weak self] in
            guard let self else { return }
            self.notificationsGranted = await self.notificationService.authorizationGranted()
        }
    }

    func requestAccessibilityPermission() {
        _ = GlobalCaptureHotkey.shared.requestAccessibilityPermission()
        accessibilityGranted = GlobalCaptureHotkey.shared.hasAccessibilityPermission
        statusText = accessibilityGranted
            ? "Global hotkey ready: Control + Option + S."
            : "Allow Accessibility for Sprite Vault in System Settings, then return here."
    }

    func requestScreenRecordingPermission() {
        screenRecordingGranted = CGRequestScreenCaptureAccess()
        statusText = screenRecordingGranted
            ? "Screen Recording access granted. You can select the Fortnite area now."
            : "Allow Screen Recording for Sprite Vault in System Settings. macOS may require a relaunch."
    }

    func requestCaptureDevicePermission() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.captureDeviceService.requestAuthorization()
            self.captureDeviceGranted = granted
            self.statusText = granted
                ? "Capture-device access granted."
                : "Camera access is required for USB capture devices."
        }
    }

    func requestNotificationPermission() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.notificationService.requestAuthorization()
            self.notificationsGranted = granted
            self.statusText = granted
                ? "Notifications are ready."
                : "Notifications are disabled. Enable them in System Settings if you want scan alerts."
        }
    }

    /// Recommended source picker. Apple's ScreenCaptureKit picker can select a
    /// full-screen Fortnite/OBS window or an entire display even when that content
    /// lives in another macOS Space. This is more reliable than trying to draw an
    /// AppKit drag overlay over another app's exclusive full-screen Space.
    func chooseSystemCaptureSource() {
        guard !isStreaming else { return }
        sourceMode = .systemPicker
        errorText = nil
        statusText = "Choose the Fortnite window or display in the macOS capture picker…"

        captureService.presentSystemPicker { [weak self] selection in
            Task { @MainActor in
                guard let self else { return }
                guard let selection else {
                    if self.systemSelection == nil {
                        self.statusText = "No Fortnite source selected yet."
                    }
                    return
                }

                self.systemSelection = selection
                self.statusText = "Selected \(selection.displayName) · \(selection.sizeText). Ready to scan."
            }
        }
    }

    /// Optional screenshot-style crop for windowed setups. Full-screen users
    /// should use chooseSystemCaptureSource(), which works across Spaces.
    func chooseRegionCaptureSource() {
        guard !isStreaming else { return }
        sourceMode = .systemPicker
        errorText = nil
        statusText = "Drag around the full Fortnite viewport…"

        captureService.presentRegionSelector { [weak self] selection in
            Task { @MainActor in
                guard let self else { return }
                guard let selection else {
                    if self.systemSelection == nil {
                        self.statusText = "No custom area selected."
                    }
                    return
                }

                self.systemSelection = selection
                self.statusText = "Selected custom area · \(selection.sizeText). Ready to scan."
            }
        }
    }

    func setLivePreviewEnabled(_ enabled: Bool) {
        captureService.setPreviewEnabled(enabled)
        if !enabled, isStreaming {
            previewImage = nil
        }
    }

    func refreshSources() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorText = nil
        defer { isRefreshing = false }

        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        captureDeviceGranted = captureDeviceService.authorizationGranted
        captureDevices = captureDeviceService.availableDevices()
        if selectedCaptureDeviceID == nil || !captureDevices.contains(where: { $0.id == selectedCaptureDeviceID }) {
            selectedCaptureDeviceID = captureDevices.first?.id
        }

        if sourceMode == .systemPicker {
            if let existingSelection = captureService.systemSelection {
                systemSelection = existingSelection
            } else {
                systemSelection = await captureService.restoreSavedRegionSelection()
            }
            statusText = sourceReadyDescription
            return
        }

        if sourceMode == .captureDevice {
            statusText = sourceReadyDescription
            return
        }

        do {
            let content = try await captureService.availableContent()
            applications = content.applications
            windows = content.windows

            if let selectedApplicationID,
               !applications.contains(where: { $0.id == selectedApplicationID }) {
                self.selectedApplicationID = nil
            }
            if selectedApplicationID == nil {
                selectedApplicationID = applications.first(where: \.isLikelyGameApplication)?.id
                    ?? applications.first?.id
            }

            if let selectedWindowID,
               !windows.contains(where: { $0.id == selectedWindowID }) {
                self.selectedWindowID = nil
            }
            if selectedWindowID == nil {
                selectedWindowID = windows.first(where: \.isLikelyGameWindow)?.id
                    ?? windows.first?.id
            }

            await resolveApplicationTarget()
            statusText = sourceReadyDescription
        } catch {
            // Direct capture-device mode can still work without Screen Recording.
            applications = []
            windows = []
            resolvedApplicationTarget = nil
            if sourceMode == .captureDevice, !captureDevices.isEmpty {
                statusText = sourceReadyDescription
            } else {
                errorText = error.localizedDescription
                statusText = "Could not enumerate shareable applications/windows."
            }
        }
    }

    func resolveApplicationTarget() async {
        guard sourceMode == .application, let selectedApplicationID else {
            resolvedApplicationTarget = nil
            return
        }

        let requestedApplicationID = selectedApplicationID
        do {
            let target = try await captureService.resolvedWindow(for: requestedApplicationID)
            guard sourceMode == .application,
                  self.selectedApplicationID == requestedApplicationID else { return }
            resolvedApplicationTarget = target
        } catch {
            guard sourceMode == .application,
                  self.selectedApplicationID == requestedApplicationID else { return }
            resolvedApplicationTarget = nil
        }
    }

    func refreshPreview() async {
        guard !isStreaming else { return }

        let requestID = UUID()
        previewRequestID = requestID
        isPreviewRefreshing = true
        errorText = nil
        previewImage = nil
        previewSourceLabel = nil
        defer {
            if previewRequestID == requestID {
                isPreviewRefreshing = false
            }
        }

        do {
            let image: CGImage
            let sourceKey: String
            let sourceLabel: String

            switch sourceMode {
            case .systemPicker:
                guard let selection = systemSelection, captureService.hasSystemSelection else {
                    throw LiveCaptureError.sourceUnavailable
                }
                sourceKey = "system:\(selection.styleName):\(selection.displayName):\(selection.width)x\(selection.height)"
                sourceLabel = "\(selection.styleName): \(selection.displayName)"
                image = try await captureService.captureSystemSelectionOnce()

                guard previewRequestID == requestID,
                      sourceMode == .systemPicker,
                      systemSelection == selection else { return }

            case .application:
                guard let applicationID = selectedApplicationID else {
                    throw LiveCaptureError.sourceUnavailable
                }
                guard let target = try await captureService.resolvedWindow(for: applicationID) else {
                    throw LiveCaptureError.sourceUnavailable
                }
                sourceKey = "application:\(applicationID):\(target.windowID)"
                sourceLabel = target.windowTitle.isEmpty
                    ? target.applicationName
                    : "\(target.applicationName) — \(target.windowTitle)"
                image = try await captureService.captureOnce(windowID: target.windowID)

                guard previewRequestID == requestID,
                      sourceMode == .application,
                      selectedApplicationID == applicationID else { return }
                resolvedApplicationTarget = target

            case .window:
                guard let windowID = selectedWindowID,
                      let selected = windows.first(where: { $0.id == windowID }) else {
                    throw LiveCaptureError.sourceUnavailable
                }
                sourceKey = "window:\(windowID)"
                sourceLabel = selected.displayName
                image = try await captureService.captureOnce(windowID: windowID)

                guard previewRequestID == requestID,
                      sourceMode == .window,
                      selectedWindowID == windowID else { return }

            case .captureDevice:
                statusText = "Start a scan to preview the live capture device."
                return
            }

            // A source picker can generate several async preview requests in a
            // fraction of a second. Only the newest request is allowed to paint
            // the preview. This prevents an older Weather/OBS/etc. capture from
            // appearing under the newly selected window name.
            guard previewRequestID == requestID,
                  currentPreviewSourceKey == sourceKey else { return }

            previewImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            previewSourceLabel = sourceLabel
            statusText = "Preview locked to \(sourceLabel). Sprite Vault will still verify Sprites → Collection before saving anything."
        } catch {
            guard previewRequestID == requestID else { return }
            errorText = error.localizedDescription
            previewImage = nil
            previewSourceLabel = nil
        }
    }

    func captureOnce() async {
        guard !isCapturingOnce, !isStreaming else { return }
        guard sourceMode != .captureDevice else {
            errorText = "Capture Once is available for screen-area capture. Use Start Scan for a capture device."
            return
        }

        isCapturingOnce = true
        errorText = nil
        statusText = "Capturing the selected source…"
        defer { isCapturingOnce = false }

        do {
            let image: CGImage
            switch sourceMode {
            case .systemPicker:
                image = try await captureService.captureSystemSelectionOnce()
            case .application:
                guard let target = try await resolveWindowForCurrentSource() else { throw LiveCaptureError.sourceUnavailable }
                image = try await captureService.captureOnce(windowID: target.windowID)
            case .window:
                guard let selectedWindowID else { throw LiveCaptureError.sourceUnavailable }
                image = try await captureService.captureOnce(windowID: selectedWindowID)
            case .captureDevice:
                throw LiveCaptureError.sourceUnavailable
            }
            previewImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            let analysis = try await ScreenshotSpriteAnalyzer.shared.analyzeFrame(
                image: image,
                onProgress: { [weak self] _, text in
                    Task { @MainActor in self?.statusText = text }
                }
            )
            receive(analysis)
        } catch {
            errorText = error.localizedDescription
            statusText = "Capture failed."
        }
    }

    /// Control + Option + S starts one collection session. A second hotkey press
    /// does not stop it; the scan ends automatically only after all 117 catalog
    /// positions have actually been covered, or by the explicit Stop control.
    func startHotkeyScanSession() async {
        guard !isHotkeyScanning else {
            notificationService.send(
                title: "Sprite Scan Already Active",
                body: "The current scan is still running. Fast scrolling is ignored until the grid becomes stable.",
                identifier: "sprite-scan-already-active",
                openActivityCenter: true
            )
            return
        }
        guard !isStreaming, !isCapturingOnce else { return }

        if sourceMode == .captureDevice && captureDevices.isEmpty {
            await refreshSources()
        }
        guard await ensureSourceReady() else { return }

        if targetProfileID == nil { targetProfileID = store?.selectedProfileID }
        if !notificationsGranted {
            notificationsGranted = await notificationService.requestAuthorization()
        }

        resetSessionState()
        currentSessionID = UUID()
        sessionInitialOwnedCount = targetProfile?.ownedCount ?? 0
        sessionProfileName = targetProfile?.name ?? "My Collection"
        isHotkeyScanning = true
        errorText = nil
        scanPhase = .waitingForSource
        startSessionTimer()

        let startEvent = ActivityEvent(
            kind: .scanStarted,
            title: "Sprite scan started",
            message: "Reading \(sessionProfileName) from \(selectedSourceDisplayName).",
            profileID: targetProfileID,
            profileName: sessionProfileName,
            sessionID: currentSessionID
        )
        activityStore?.add(startEvent)
        notificationService.send(
            title: "Sprite Scan Started",
            body: "Reading \(sessionProfileName). Fast scrolling will pause Vision until the collection is stable.",
            identifier: "sprite-scan-started",
            openActivityCenter: true
        )

        await startStreaming()
        if !isStreaming {
            isHotkeyScanning = false
            stopSessionTimer()
            scanPhase = .error
            notificationService.send(
                title: "Sprite Scan Couldn't Start",
                body: errorText ?? "The selected capture source could not be started.",
                identifier: "sprite-scan-start-failed",
                openActivityCenter: true
            )
        }
    }

    func startStreaming() async {
        errorText = nil
        do {
            switch sourceMode {
            case .systemPicker:
                try await captureService.startSystemSelection(
                    fps: framesPerSecond,
                    onAnalysis: { [weak self] analysis in
                        Task { @MainActor in self?.receive(analysis) }
                    },
                    onStatus: { [weak self] status in
                        Task { @MainActor in self?.receiveCaptureStatus(status) }
                    },
                    onPreview: { [weak self] image in
                        Task { @MainActor in
                            guard let self else { return }
                            self.previewImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                            self.previewSourceLabel = self.selectedSourceDisplayName
                        }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor in self?.handleStreamError(error) }
                    }
                )

            case .application, .window:
                let windowID: CGWindowID
                if sourceMode == .application {
                    guard let target = try await resolveWindowForCurrentSource() else {
                        throw LiveCaptureError.sourceUnavailable
                    }
                    windowID = target.windowID
                } else {
                    guard let selectedWindowID else { throw LiveCaptureError.sourceUnavailable }
                    windowID = selectedWindowID
                }

                try await captureService.start(
                    windowID: windowID,
                    fps: framesPerSecond,
                    onAnalysis: { [weak self] analysis in
                        Task { @MainActor in self?.receive(analysis) }
                    },
                    onStatus: { [weak self] status in
                        Task { @MainActor in self?.receiveCaptureStatus(status) }
                    },
                    onPreview: { [weak self] image in
                        Task { @MainActor in
                            guard let self else { return }
                            self.previewImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                            self.previewSourceLabel = self.selectedSourceDisplayName
                        }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor in self?.handleStreamError(error) }
                    }
                )

            case .captureDevice:
                guard let selectedCaptureDeviceID else { throw LiveCaptureError.sourceUnavailable }
                try await captureDeviceService.start(
                    deviceID: selectedCaptureDeviceID,
                    fps: framesPerSecond,
                    onAnalysis: { [weak self] analysis in
                        Task { @MainActor in self?.receive(analysis) }
                    },
                    onStatus: { [weak self] status in
                        Task { @MainActor in self?.receiveCaptureStatus(status) }
                    },
                    onPreview: { [weak self] image in
                        Task { @MainActor in
                            guard let self else { return }
                            self.previewImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                            self.previewSourceLabel = self.selectedSourceDisplayName
                        }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor in self?.handleStreamError(error) }
                    }
                )
            }

            isStreaming = true
            scanPhase = .waitingForCollection
            statusText = "Capture active. Waiting for Fortnite Sprites → Collection…"
        } catch {
            isStreaming = false
            errorText = error.localizedDescription
            statusText = "Could not start capture."
            scanPhase = .error
        }
    }

    func stopStreaming() async {
        if isHotkeyScanning {
            await finishHotkeyScanSession(completed: false)
            return
        }
        await stopCaptureEngine()
        isStreaming = false
        scanPhase = .idle
        statusText = "Capture stopped."
    }

    func toggleStreaming() async {
        if isStreaming { await stopStreaming() }
        else { await startHotkeyScanSession() }
    }

    func reportAppliedChanges(_ summary: DetectionApplySummary, profileName: String) {
        guard isHotkeyScanning else { return }
        sessionSeenNames.formUnion(summary.scannedNames)
        sessionObservedSpriteCount = sessionSeenNames.count

        for change in summary.newSprites { newNames.insert(change.name) }
        for change in summary.levelUps { levelUpNames.insert(change.name) }
        for change in summary.changes where change.becameMastered { masteredNames.insert(change.name) }
        for change in summary.lostSprites { lostNames.insert(change.name) }
        refreshChangeCounters()

        // Initial profile syncs get one detailed completion entry instead of a
        // wall of system banners. Subsequent scans produce clickable alerts.
        if sessionInitialOwnedCount > 0 {
            for change in summary.newSprites {
                let levelText = change.newLevel.map { "Lvl \($0)" } ?? "Unlocked"
                let body = "\(change.name) · \(levelText)\(change.becameMastered ? " · Mastered 👑" : "")"
                addSpriteActivity(kind: .newSprite, title: "New Sprite added", message: body, change: change)
                notificationService.send(
                    title: "New Sprite Added",
                    body: body,
                    identifier: "sprite-new-\(notificationKey(change.name))",
                    spriteName: change.name
                )
            }

            for change in summary.masteredSprites {
                addSpriteActivity(kind: .mastered, title: "Sprite mastered 👑", message: "\(change.name) reached Level 5.", change: change)
                notificationService.send(
                    title: "Sprite Mastered 👑",
                    body: "\(change.name) reached Level 5 in \(profileName).",
                    identifier: "sprite-mastered-\(notificationKey(change.name))",
                    spriteName: change.name
                )
            }

            for change in summary.levelUps {
                let oldLevel = change.previousLevel ?? 0
                let newLevel = change.newLevel ?? oldLevel
                addSpriteActivity(kind: .levelUp, title: "Sprite leveled up", message: "\(change.name) · Lvl \(oldLevel) → Lvl \(newLevel)", change: change)
                notificationService.send(
                    title: "Sprite Level Updated",
                    body: "\(change.name) · Lvl \(oldLevel) → Lvl \(newLevel)",
                    identifier: "sprite-level-\(notificationKey(change.name))-\(newLevel)",
                    spriteName: change.name
                )
            }

            for change in summary.lostSprites {
                addSpriteActivity(kind: .lost, title: "Sprite lost in past match", message: "\(change.name) is greyed out in Fortnite but remains in your unlocked collection.", change: change)
                notificationService.send(
                    title: "Sprite Lost",
                    body: "\(change.name) was lost in a past match. It still counts as unlocked.",
                    identifier: "sprite-lost-\(notificationKey(change.name))",
                    spriteName: change.name
                )
            }
        }

        if shouldFinishAfterApply {
            shouldFinishAfterApply = false
            Task { [weak self] in await self?.finishHotkeyScanSession(completed: true) }
        }
    }

    var shortcutText: String { "⌃⌥S" }

    var selectedWindow: CaptureWindowInfo? {
        guard let selectedWindowID else { return nil }
        return windows.first(where: { $0.id == selectedWindowID })
    }

    var selectedApplication: CaptureApplicationInfo? {
        guard let selectedApplicationID else { return nil }
        return applications.first(where: { $0.id == selectedApplicationID })
    }

    var selectedCaptureDevice: CaptureDeviceInfo? {
        guard let selectedCaptureDeviceID else { return nil }
        return captureDevices.first(where: { $0.id == selectedCaptureDeviceID })
    }

    var selectedSourceDisplayName: String {
        switch sourceMode {
        case .systemPicker:
            return systemSelection?.displayName ?? "No capture source selected"
        case .application:
            return selectedApplication?.displayName ?? "No application selected"
        case .window:
            return selectedWindow?.displayName ?? "No window selected"
        case .captureDevice:
            return selectedCaptureDevice?.name ?? "No capture device selected"
        }
    }

    var targetCollectionCount: Int { targetProfile?.ownedCount ?? 0 }
    var totalSpriteCount: Int { SpriteCatalog.all.count }
    var changesSoFar: Int { sessionNewCount + sessionLevelUpCount + sessionMasteredCount + sessionLostCount }

    var elapsedText: String {
        let minutes = sessionElapsedSeconds / 60
        let seconds = sessionElapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var menuBarSymbol: String {
        switch scanPhase {
        case .idle: return "sparkles"
        case .waitingForSource, .waitingForCollection: return "scope"
        case .waitingForStability: return "pause.circle.fill"
        case .scanning: return "dot.radiowaves.left.and.right"
        case .complete: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var liveButtonSummary: String {
        guard isHotkeyScanning else { return "Live Capture" }
        return "\(scanPhase.label.uppercased()) · \(elapsedText) · \(targetCollectionCount)/\(totalSpriteCount) · +\(changesSoFar)"
    }

    var coverageText: String { "\(scanCoverageCount)/\(totalSpriteCount)" }
    var collectionText: String { "\(targetCollectionCount)/\(totalSpriteCount)" }

    private var targetProfile: CollectionProfile? {
        guard let targetProfileID else { return store?.selectedProfile }
        return store?.profile(withID: targetProfileID)
    }

    private var sourceReadyDescription: String {
        switch sourceMode {
        case .systemPicker:
            if let selection = systemSelection {
                return "Ready: \(selection.styleName) — \(selection.displayName) · \(selection.sizeText)."
            }
            return "Select the Fortnite window/display. Use Custom Area only for windowed setups."
        case .application:
            if let app = selectedApplication {
                if let target = resolvedApplicationTarget {
                    return "Ready: \(app.applicationName) → \(target.windowTitle.isEmpty ? "largest gameplay window" : target.windowTitle)."
                }
                return "\(app.applicationName) is selected. Waiting for a shareable window."
            }
            return "Choose the app that contains Fortnite."
        case .window:
            return selectedWindow.map { "Ready to read \($0.displayName)." } ?? "Choose a specific window."
        case .captureDevice:
            return selectedCaptureDevice.map { "Ready to read \($0.name) directly." } ?? "Choose a USB/video capture device."
        }
    }

    private func ensureSourceReady() async -> Bool {
        switch sourceMode {
        case .systemPicker:
            guard systemSelection != nil, captureService.hasSystemSelection else {
                await failToStart("Select the Fortnite window/display or a custom area in Live Capture first.")
                return false
            }
            guard screenRecordingGranted || CGPreflightScreenCaptureAccess() else {
                await failToStart("Screen Recording permission is required for live capture.")
                return false
            }
        case .application:
            guard selectedApplicationID != nil else {
                await failToStart("Choose an application in Live Capture first.")
                return false
            }
            guard screenRecordingGranted || CGPreflightScreenCaptureAccess() else {
                await failToStart("Screen Recording permission is required for application capture.")
                return false
            }
            guard (try? await resolveWindowForCurrentSource()) != nil else {
                await failToStart("The selected application has no shareable window right now.")
                return false
            }
        case .window:
            guard selectedWindowID != nil else {
                await failToStart("Choose a specific window in Live Capture first.")
                return false
            }
            guard screenRecordingGranted || CGPreflightScreenCaptureAccess() else {
                await failToStart("Screen Recording permission is required for window capture.")
                return false
            }
        case .captureDevice:
            guard selectedCaptureDeviceID != nil else {
                await failToStart("Choose a capture device in Live Capture first.")
                return false
            }
            if !captureDeviceService.authorizationGranted {
                captureDeviceGranted = await captureDeviceService.requestAuthorization()
            }
            guard captureDeviceGranted else {
                await failToStart("Camera access is required to read the selected capture device.")
                return false
            }
        }
        return true
    }

    private func resolveWindowForCurrentSource() async throws -> ResolvedCaptureTarget? {
        guard sourceMode == .application, let selectedApplicationID else { return nil }
        let requestedApplicationID = selectedApplicationID
        let target = try await captureService.resolvedWindow(for: requestedApplicationID)
        guard sourceMode == .application,
              self.selectedApplicationID == requestedApplicationID else { return nil }
        resolvedApplicationTarget = target
        return target
    }

    private var currentPreviewSourceKey: String? {
        switch sourceMode {
        case .systemPicker:
            guard let selection = systemSelection else { return nil }
            return "system:\(selection.styleName):\(selection.displayName):\(selection.width)x\(selection.height)"
        case .application:
            guard let applicationID = selectedApplicationID,
                  let target = resolvedApplicationTarget else { return nil }
            return "application:\(applicationID):\(target.windowID)"
        case .window:
            guard let windowID = selectedWindowID else { return nil }
            return "window:\(windowID)"
        case .captureDevice:
            guard let deviceID = selectedCaptureDeviceID else { return nil }
            return "device:\(deviceID)"
        }
    }

    private func invalidatePreview() {
        previewRequestID = UUID()
        isPreviewRefreshing = false
        previewImage = nil
        previewSourceLabel = nil
        if !isStreaming {
            isCollectionScreenDetected = false
        }
    }

    private func receive(_ analysis: SpriteFrameAnalysis) {
        lastScanDate = .now
        isCollectionScreenDetected = analysis.isCollectionScreen

        guard analysis.isCollectionScreen else {
            scanPhase = .waitingForCollection
            statusText = "Capture is active — waiting for Fortnite Sprites → Collection."
            return
        }

        if let pageStart = analysis.inferredPageStart {
            let end = min(pageStart + max(analysis.visibleSlots, 1) - 1, totalSpriteCount - 1)
            if pageStart <= end {
                for index in pageStart...end { coveredCatalogIndexes.insert(index) }
            }
            scanCoverageCount = coveredCatalogIndexes.count
        }

        sessionSeenNames.formUnion(analysis.detections.map(\.name))
        sessionObservedSpriteCount = sessionSeenNames.count

        if analysis.detections.isEmpty {
            scanPhase = .scanning
            statusText = "Collection detected. This view has no readable unlocked cards yet; waiting for the next stable view…"
            checkForAutomaticCompletion(afterApplying: false)
            return
        }

        let signature = analysis.detections
            .sorted { $0.name < $1.name }
            .map { "\($0.name.lowercased())=\($0.status.rawValue)=\($0.level.map(String.init) ?? "?")" }
            .joined(separator: "|") + "@\(analysis.inferredPageStart ?? -1)"

        let isNewDetectionPage = signature != lastDetectionSignature
        if isNewDetectionPage {
            lastDetectionSignature = signature
            latestDetections = analysis.detections
            resultRevision = UUID()
        }

        scanPhase = .scanning
        statusText = "Scanning · collection \(targetCollectionCount)/\(totalSpriteCount) · coverage \(scanCoverageCount)/\(totalSpriteCount) · \(changesSoFar) changes."
        checkForAutomaticCompletion(afterApplying: isNewDetectionPage)
    }

    private func checkForAutomaticCompletion(afterApplying: Bool) {
        guard isHotkeyScanning, scanCoverageCount >= totalSpriteCount else { return }
        if afterApplying {
            shouldFinishAfterApply = true
        } else {
            Task { [weak self] in await self?.finishHotkeyScanSession(completed: true) }
        }
    }

    private func receiveCaptureStatus(_ status: String) {
        statusText = status
        let lower = status.lowercased()
        if lower.contains("screen moving") || lower.contains("settle") || lower.contains("temporarily idle") {
            scanPhase = .waitingForStability
        } else if lower.contains("screen stable") || lower.contains("stable view") || lower.contains("reading") {
            scanPhase = .scanning
        } else if lower.contains("connected") || lower.contains("capture active") {
            scanPhase = .waitingForCollection
        }
    }

    private func finishHotkeyScanSession(completed: Bool) async {
        guard isHotkeyScanning else { return }
        await stopCaptureEngine()
        isStreaming = false
        isHotkeyScanning = false
        stopSessionTimer()

        let summary = ScanChangeSummary(
            newSprites: newNames.sorted(),
            levelUps: levelUpNames.sorted(),
            mastered: masteredNames.sorted(),
            lost: lostNames.sorted()
        )
        lastCompletedSummary = summary

        let core = "\(targetCollectionCount)/\(totalSpriteCount) unlocked · \(sessionNewCount) new · \(sessionLevelUpCount) leveled · \(sessionMasteredCount) mastered"
        if completed {
            scanPhase = .complete
            statusText = "Scan complete · \(core)."
            activityStore?.add(ActivityEvent(
                kind: .scanCompleted,
                title: "Scan complete",
                message: "\(core) · coverage \(scanCoverageCount)/\(totalSpriteCount)",
                profileID: targetProfileID,
                profileName: sessionProfileName,
                sessionID: currentSessionID,
                summary: summary
            ))
            notificationService.send(
                title: "Sprite Scan Complete ✓",
                body: core,
                identifier: "sprite-scan-complete",
                openActivityCenter: true
            )
        } else {
            scanPhase = .idle
            statusText = "Scan stopped · \(core) · coverage \(scanCoverageCount)/\(totalSpriteCount)."
            activityStore?.add(ActivityEvent(
                kind: .scanStopped,
                title: "Scan stopped",
                message: "\(core) · coverage \(scanCoverageCount)/\(totalSpriteCount)",
                profileID: targetProfileID,
                profileName: sessionProfileName,
                sessionID: currentSessionID,
                summary: summary
            ))
            notificationService.send(
                title: "Sprite Scan Stopped",
                body: "Saved what was confirmed so far. \(core)",
                identifier: "sprite-scan-stopped",
                openActivityCenter: true
            )
        }
        currentSessionID = nil
    }

    private func stopCaptureEngine() async {
        switch sourceMode {
        case .systemPicker, .application, .window:
            await captureService.stop()
        case .captureDevice:
            await captureDeviceService.stop()
        }
    }

    private func handleStreamError(_ error: Error) {
        errorText = error.localizedDescription
        statusText = "Capture stopped because of an error."
        isStreaming = false
        scanPhase = .error
        stopSessionTimer()

        if isHotkeyScanning {
            isHotkeyScanning = false
            activityStore?.add(ActivityEvent(
                kind: .error,
                title: "Sprite scan error",
                message: error.localizedDescription,
                profileID: targetProfileID,
                profileName: sessionProfileName,
                sessionID: currentSessionID
            ))
            notificationService.send(
                title: "Sprite Scan Stopped",
                body: error.localizedDescription,
                identifier: "sprite-scan-error",
                openActivityCenter: true
            )
        }
    }

    private func addSpriteActivity(
        kind: ActivityKind,
        title: String,
        message: String,
        change: DetectionCollectionChange
    ) {
        activityStore?.add(ActivityEvent(
            kind: kind,
            title: title,
            message: message,
            profileID: targetProfileID,
            profileName: sessionProfileName,
            spriteName: change.name,
            sessionID: currentSessionID
        ))
    }

    private func refreshChangeCounters() {
        sessionNewCount = newNames.count
        sessionLevelUpCount = levelUpNames.count
        sessionMasteredCount = masteredNames.count
        sessionLostCount = lostNames.count
    }

    private func resetSessionState() {
        lastDetectionSignature = ""
        sessionElapsedSeconds = 0
        scanCoverageCount = 0
        sessionObservedSpriteCount = 0
        sessionNewCount = 0
        sessionLevelUpCount = 0
        sessionMasteredCount = 0
        sessionLostCount = 0
        isCollectionScreenDetected = false
        sessionSeenNames.removeAll(keepingCapacity: true)
        coveredCatalogIndexes.removeAll(keepingCapacity: true)
        newNames.removeAll(keepingCapacity: true)
        levelUpNames.removeAll(keepingCapacity: true)
        masteredNames.removeAll(keepingCapacity: true)
        lostNames.removeAll(keepingCapacity: true)
        shouldFinishAfterApply = false
    }

    private func startSessionTimer() {
        sessionTimerTask?.cancel()
        let start = Date()
        sessionTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.sessionElapsedSeconds = max(Int(Date().timeIntervalSince(start)), 0)
                }
            }
        }
    }

    private func stopSessionTimer() {
        sessionTimerTask?.cancel()
        sessionTimerTask = nil
    }

    private func failToStart(_ message: String) async {
        errorText = message
        statusText = message
        scanPhase = .error
        notificationService.send(
            title: "Sprite Scan Couldn't Start",
            body: message,
            identifier: "sprite-scan-source-error",
            openActivityCenter: true
        )
    }

    private func persistSourceSelection() {
        let defaults = UserDefaults.standard
        defaults.set(sourceMode.rawValue, forKey: DefaultsKey.mode)
        defaults.set(selectedApplicationID, forKey: DefaultsKey.application)
        if let selectedWindowID {
            defaults.set(NSNumber(value: selectedWindowID), forKey: DefaultsKey.window)
        } else {
            defaults.removeObject(forKey: DefaultsKey.window)
        }
        defaults.set(selectedCaptureDeviceID, forKey: DefaultsKey.device)
    }

    private func notificationKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private enum LiveCaptureError: LocalizedError {
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "The selected capture source is not currently available."
        }
    }
}
