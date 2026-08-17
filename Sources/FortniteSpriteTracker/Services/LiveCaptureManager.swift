import Foundation
import SwiftUI
import CoreGraphics

@MainActor
final class LiveCaptureManager: ObservableObject {
    @Published private(set) var windows: [CaptureWindowInfo] = []
    @Published var selectedWindowID: CGWindowID?
    @Published var targetProfileID: UUID? {
        didSet {
            guard oldValue != targetProfileID else { return }
            lastDetectionSignature = ""
            pendingLiveSignature = ""
            pendingLiveConfirmations = 0
        }
    }
    @Published var framesPerSecond = 3

    @Published private(set) var isRefreshing = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isHotkeyScanning = false
    @Published private(set) var isCapturingOnce = false
    @Published private(set) var statusText = "Choose the Fortnite, cloud-gaming, or capture window to scan."
    @Published private(set) var errorText: String?
    @Published private(set) var latestDetections: [DetectedSprite] = []
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var resultRevision = UUID()
    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibilityGranted = GlobalCaptureHotkey.shared.hasAccessibilityPermission
    @Published private(set) var notificationsGranted = false
    @Published private(set) var hotkeyPagesScanned = 0

    private let captureService = ScreenCaptureService()
    private let notificationService = AppNotificationService.shared
    private weak var store: SpriteStore?

    private var lastDetectionSignature = ""
    private var pendingLiveSignature = ""
    private var pendingLiveConfirmations = 0
    private var hotkeyInstalled = false

    private var hotkeyInitialOwnedCount = 0
    private var hotkeyProfileName = "My Collection"
    private var hotkeySeenNames = Set<String>()
    private var hotkeyPageStarts = Set<Int>()
    private var hotkeyCoveredCatalogIndexes = Set<Int>()
    private var hotkeyReachedCatalogEnd = false
    private var hotkeyShouldFinishAfterApply = false
    private var hotkeyNewCount = 0
    private var hotkeyUpdatedCount = 0
    private var hotkeyMasteredCount = 0

    func installGlobalHotkey(store: SpriteStore) {
        self.store = store
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
            ? "Screen Recording access granted. Refresh the window list."
            : "Allow Screen Recording for Sprite Vault in System Settings. macOS may require the app to relaunch."
    }

    func requestNotificationPermission() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.notificationService.requestAuthorization()
            await MainActor.run {
                self.notificationsGranted = granted
                self.statusText = granted
                    ? "Notifications are ready for scan progress, new Sprites, level-ups, and mastery."
                    : "Notifications are disabled. You can enable them for Sprite Vault in System Settings."
            }
        }
    }

    func refreshWindows() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorText = nil
        defer { isRefreshing = false }

        screenRecordingGranted = CGPreflightScreenCaptureAccess()

        do {
            let available = try await captureService.availableWindows()
            windows = available

            if let selectedWindowID,
               !available.contains(where: { $0.id == selectedWindowID }) {
                self.selectedWindowID = nil
            }

            if selectedWindowID == nil {
                self.selectedWindowID = available.first(where: \.isLikelyGameWindow)?.id
                    ?? available.first?.id
            }

            if available.isEmpty {
                statusText = "No large shareable windows were found. Open Fortnite/cloud gaming first, then refresh."
            } else if let selected = selectedWindow {
                statusText = "Ready to scan \(selected.displayName)."
            } else {
                statusText = "Choose the window that contains Fortnite."
            }
        } catch {
            errorText = error.localizedDescription
            statusText = "Could not read shareable windows."
        }
    }

    func captureOnce() async {
        guard !isCapturingOnce, !isStreaming else { return }

        if selectedWindowID == nil {
            await refreshWindows()
        }
        guard let windowID = selectedWindowID else {
            errorText = "No capture window is selected. Open Live Capture and choose the Fortnite window first."
            return
        }

        isCapturingOnce = true
        errorText = nil
        statusText = "Capturing only the selected window…"
        defer { isCapturingOnce = false }

        do {
            let image = try await captureService.captureOnce(windowID: windowID)
            statusText = "Vision is scanning the captured Sprite grid…"
            let detections = try await ScreenshotSpriteAnalyzer.shared.analyze(
                image: image,
                onProgress: { [weak self] _, text in
                    Task { @MainActor in
                        self?.statusText = text
                    }
                }
            )
            receive(detections, requiresLiveConfirmation: false)
        } catch {
            errorText = error.localizedDescription
            statusText = "Capture failed."
        }
    }

    /// Starts the one-press collection scan used by Control + Option + S.
    /// The stream keeps running while the player moves through the Collection
    /// and stops itself after the final catalog region has been covered.
    func startHotkeyScanSession() async {
        guard !isHotkeyScanning else {
            notificationService.send(
                title: "Sprite Scan Already Active",
                body: "Keep scrolling through the Collection. The scan will stop automatically when it reaches the end.",
                identifier: "sprite-scan-already-active"
            )
            return
        }

        guard !isStreaming, !isCapturingOnce else {
            notificationService.send(
                title: "Sprite Scan Busy",
                body: "Another capture is already running. Stop it before starting the hotkey scan.",
                identifier: "sprite-scan-busy"
            )
            return
        }

        if selectedWindowID == nil {
            await refreshWindows()
        }
        guard selectedWindowID != nil else {
            errorText = "No capture window is selected. Open Live Capture once and choose the Fortnite window."
            notificationService.send(
                title: "Sprite Scan Couldn't Start",
                body: "Open Sprite Vault and choose the Fortnite or streaming window first.",
                identifier: "sprite-scan-no-window"
            )
            return
        }

        if targetProfileID == nil {
            targetProfileID = store?.selectedProfileID
        }

        if !notificationsGranted {
            notificationsGranted = await notificationService.requestAuthorization()
        }

        resetHotkeySessionState()
        hotkeyInitialOwnedCount = targetProfile?.ownedCount ?? 0
        hotkeyProfileName = targetProfile?.name ?? "My Collection"
        isHotkeyScanning = true
        errorText = nil
        lastDetectionSignature = ""
        pendingLiveSignature = ""
        pendingLiveConfirmations = 0

        notificationService.send(
            title: "Sprite Scan Started",
            body: "Hotkey activated. Reading \(hotkeyProfileName). Scroll through Sprites using Sort By: Type; the scan will stop automatically when complete.",
            identifier: "sprite-scan-started"
        )

        await startStreaming()

        if !isStreaming {
            isHotkeyScanning = false
            notificationService.send(
                title: "Sprite Scan Couldn't Start",
                body: errorText ?? "Screen capture could not be started.",
                identifier: "sprite-scan-start-failed"
            )
        }
    }

    func startStreaming() async {
        if selectedWindowID == nil {
            await refreshWindows()
        }
        guard let windowID = selectedWindowID else {
            errorText = "Choose a capture window first."
            return
        }

        errorText = nil
        do {
            try await captureService.start(
                windowID: windowID,
                fps: framesPerSecond,
                onDetections: { [weak self] detections in
                    Task { @MainActor in
                        self?.receive(detections, requiresLiveConfirmation: true)
                    }
                },
                onStatus: { [weak self] status in
                    Task { @MainActor in
                        self?.statusText = status
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.handleStreamError(error)
                    }
                }
            )
            isStreaming = true
            statusText = isHotkeyScanning
                ? "Hotkey scan active. Scroll through the Sprite Collection; confirmed pages are merged once."
                : "Live capture active at \(framesPerSecond) FPS. Only changed, confirmed detections are applied."
        } catch {
            isStreaming = false
            errorText = error.localizedDescription
            statusText = "Could not start live capture."
        }
    }

    func stopStreaming() async {
        await captureService.stop()
        isStreaming = false

        if isHotkeyScanning {
            isHotkeyScanning = false
            hotkeyShouldFinishAfterApply = false
            statusText = "Hotkey scan stopped before automatic completion."
            notificationService.send(
                title: "Sprite Scan Stopped",
                body: "The collection scan was stopped before it reached automatic completion.",
                identifier: "sprite-scan-stopped"
            )
        }
    }

    func toggleStreaming() async {
        if isStreaming {
            await stopStreaming()
        } else {
            await startStreaming()
        }
    }

    /// Called after ContentView merges the latest confirmed detections into the
    /// selected profile. This is where notification-worthy collection changes
    /// are derived, so duplicate frames never generate duplicate alerts.
    func reportAppliedChanges(_ summary: DetectionApplySummary, profileName: String) {
        guard isHotkeyScanning else { return }

        hotkeySeenNames.formUnion(summary.scannedNames)
        hotkeyNewCount += summary.newSprites.count
        hotkeyUpdatedCount += summary.updatedExistingCount
        hotkeyMasteredCount += summary.changes.filter(\.becameMastered).count

        // A brand-new/empty profile is an initial sync, not a sequence of
        // dozens of "new Sprite" events. It gets one completion summary instead.
        if hotkeyInitialOwnedCount > 0 {
            for change in summary.newSprites {
                let levelText = change.newLevel.map { "Lvl \($0)" } ?? "Owned"
                let masteryText = change.newLevel == 5 ? " · Mastered 👑" : ""
                notificationService.send(
                    title: "New Sprite Added",
                    body: "\(change.name) · \(change.rarity.rawValue) · \(levelText)\(masteryText) · Added to \(profileName)",
                    identifier: "sprite-new-\(notificationKey(change.name))"
                )
            }

            for change in summary.masteredSprites {
                notificationService.send(
                    title: "Sprite Mastered 👑",
                    body: "\(change.name) reached Level 5 in \(profileName).",
                    identifier: "sprite-mastered-\(notificationKey(change.name))"
                )
            }

            for change in summary.levelUps {
                let oldLevel = change.previousLevel ?? 0
                let newLevel = change.newLevel ?? oldLevel
                notificationService.send(
                    title: "Sprite Level Updated",
                    body: "\(change.name) · Lvl \(oldLevel) → Lvl \(newLevel)",
                    identifier: "sprite-level-\(notificationKey(change.name))-\(newLevel)"
                )
            }
        }

        if hotkeyShouldFinishAfterApply {
            hotkeyShouldFinishAfterApply = false
            Task { [weak self] in
                await self?.finishHotkeyScanSession()
            }
        }
    }

    var selectedWindow: CaptureWindowInfo? {
        guard let selectedWindowID else { return nil }
        return windows.first(where: { $0.id == selectedWindowID })
    }

    var shortcutText: String {
        "⌃⌥S"
    }

    private var targetProfile: CollectionProfile? {
        guard let targetProfileID else { return store?.selectedProfile }
        return store?.profile(withID: targetProfileID)
    }

    private func receive(
        _ detections: [DetectedSprite],
        requiresLiveConfirmation: Bool
    ) {
        lastScanDate = .now
        guard !detections.isEmpty else {
            pendingLiveSignature = ""
            pendingLiveConfirmations = 0
            statusText = isStreaming
                ? "No readable owned Sprite cards in this frame; continuing to watch…"
                : "No readable owned Sprite cards were found."
            return
        }

        let signature = detections
            .sorted { $0.name < $1.name }
            .map { "\($0.name.lowercased())=\($0.level)" }
            .joined(separator: "|")

        guard signature != lastDetectionSignature else {
            statusText = isStreaming
                ? "Same \(detections.count) visible Sprite cards; waiting for the collection grid to change…"
                : "Captured \(detections.count) Sprite cards; no tracking changes were needed."
            return
        }

        if requiresLiveConfirmation {
            if pendingLiveSignature == signature {
                pendingLiveConfirmations += 1
            } else {
                pendingLiveSignature = signature
                pendingLiveConfirmations = 1
            }

            guard pendingLiveConfirmations >= 2 else {
                statusText = "Potential \(detections.count)-card page found; confirming it on the next frame…"
                return
            }
        }

        pendingLiveSignature = ""
        pendingLiveConfirmations = 0
        lastDetectionSignature = signature
        latestDetections = detections

        if isHotkeyScanning {
            hotkeySeenNames.formUnion(detections.map(\.name))
            updateHotkeyCoverage(from: detections)
        }

        resultRevision = UUID()

        if isHotkeyScanning {
            let coverage = Int(hotkeyCoverageRatio * 100)
            statusText = "Hotkey scan · \(hotkeySeenNames.count) owned Sprites read · \(hotkeyPagesScanned) grid positions · ~\(coverage)% catalog coverage."
        } else {
            statusText = "Confirmed \(detections.count) visible Sprite card\(detections.count == 1 ? "" : "s") and merged the result."
        }
    }

    private func updateHotkeyCoverage(from detections: [DetectedSprite]) {
        guard let pageStart = inferredPageStart(from: detections) else { return }

        hotkeyPageStarts.insert(pageStart)
        hotkeyPagesScanned = hotkeyPageStarts.count

        let lastIndex = SpriteCatalog.all.count - 1
        guard lastIndex >= 0 else { return }
        let pageEnd = min(pageStart + 11, lastIndex)
        if pageStart <= pageEnd {
            for index in pageStart...pageEnd {
                hotkeyCoveredCatalogIndexes.insert(index)
            }
        }

        let lastPossibleStart = max(SpriteCatalog.all.count - 12, 0)
        if pageStart >= lastPossibleStart {
            hotkeyReachedCatalogEnd = true
        }

        // Reaching the last page alone is not enough: a player can jump straight
        // to the bottom and skip most of the list. Require broad coverage before
        // auto-stopping, while allowing several well-spaced pages as a fallback
        // when a sparse collection leaves some pages with no readable owned card.
        if hotkeyReachedCatalogEnd,
           hotkeyCoverageRatio >= 0.72 || hotkeyPageStarts.count >= 7 {
            hotkeyShouldFinishAfterApply = true
        }
    }

    private var hotkeyCoverageRatio: Double {
        guard !SpriteCatalog.all.isEmpty else { return 0 }
        return Double(hotkeyCoveredCatalogIndexes.count) / Double(SpriteCatalog.all.count)
    }

    private func inferredPageStart(from detections: [DetectedSprite]) -> Int? {
        let starts = detections.compactMap { detection -> Int? in
            guard let catalogIndex = detection.catalogIndex,
                  let gridSlot = detection.gridSlot else { return nil }
            return catalogIndex - gridSlot
        }

        guard starts.count >= 2,
              let first = starts.first,
              first >= 0,
              starts.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }

    private func finishHotkeyScanSession() async {
        guard isHotkeyScanning else { return }

        await captureService.stop()
        isStreaming = false
        isHotkeyScanning = false

        let coverage = Int(hotkeyCoverageRatio * 100)
        let summary = "\(hotkeySeenNames.count) Sprites checked · \(hotkeyNewCount) new · \(hotkeyUpdatedCount) updated · \(hotkeyMasteredCount) mastered"
        statusText = "Hotkey scan complete. \(summary) · ~\(coverage)% catalog coverage."

        notificationService.send(
            title: "Sprite Scan Complete ✓",
            body: "\(summary) · Saved to \(hotkeyProfileName).",
            identifier: "sprite-scan-complete"
        )
    }

    private func resetHotkeySessionState() {
        hotkeySeenNames.removeAll(keepingCapacity: true)
        hotkeyPageStarts.removeAll(keepingCapacity: true)
        hotkeyCoveredCatalogIndexes.removeAll(keepingCapacity: true)
        hotkeyReachedCatalogEnd = false
        hotkeyShouldFinishAfterApply = false
        hotkeyPagesScanned = 0
        hotkeyNewCount = 0
        hotkeyUpdatedCount = 0
        hotkeyMasteredCount = 0
    }

    private func handleStreamError(_ error: Error) {
        errorText = error.localizedDescription
        statusText = "Live capture stopped because of an error."
        isStreaming = false

        if isHotkeyScanning {
            isHotkeyScanning = false
            notificationService.send(
                title: "Sprite Scan Stopped",
                body: "The live read stopped because of an error: \(error.localizedDescription)",
                identifier: "sprite-scan-error"
            )
        }
    }

    private func notificationKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
