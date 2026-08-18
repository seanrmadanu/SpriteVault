import SwiftUI
import CoreGraphics

struct LiveCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SpriteStore
    @EnvironmentObject private var liveCapture: LiveCaptureManager
    @EnvironmentObject private var activityStore: ActivityStore

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                permissionsCard
                sourceCard
                previewCard
                controlsCard
                resultsCard
            }
            .padding(24)
        }
        .frame(width: 860, height: 820)
        .background(AnimatedBackground())
        .task {
            liveCapture.installGlobalHotkey(store: store, activityStore: activityStore)
            if liveCapture.targetProfileID == nil {
                liveCapture.targetProfileID = store.selectedProfileID
            }
            await liveCapture.refreshSources()
            if liveCapture.sourceMode == .systemPicker, liveCapture.systemSelection != nil {
                await liveCapture.refreshPreview()
            }
        }
        .onChange(of: liveCapture.sourceMode) { _, mode in
            Task {
                await liveCapture.refreshSources()
                if mode == .systemPicker, liveCapture.systemSelection != nil {
                    await liveCapture.refreshPreview()
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Live Capture")
                    .font(.title2.weight(.black))
                Text("Choose any way Fortnite reaches your Mac. Sprite Vault verifies the Sprites Collection before saving data.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions").font(.headline)

            permissionRow(
                title: "Screen Recording",
                detail: "Required for Screen / Window capture.",
                granted: liveCapture.screenRecordingGranted,
                buttonTitle: "Request Access"
            ) { liveCapture.requestScreenRecordingPermission() }

            Divider()

            permissionRow(
                title: "Capture Device / Camera",
                detail: "Required only when reading a USB capture card directly with AVFoundation.",
                granted: liveCapture.captureDeviceGranted,
                buttonTitle: "Enable Device"
            ) { liveCapture.requestCaptureDevicePermission() }

            Divider()

            permissionRow(
                title: "Accessibility",
                detail: "Required for the global \(liveCapture.shortcutText) hotkey while another app is focused.",
                granted: liveCapture.accessibilityGranted,
                buttonTitle: "Enable Hotkey"
            ) { liveCapture.requestAccessibilityPermission() }

            Divider()

            permissionRow(
                title: "Notifications",
                detail: "Start/completion summaries and clickable new, level, mastery, and lost-Sprite alerts.",
                granted: liveCapture.notificationsGranted,
                buttonTitle: "Enable Alerts"
            ) { liveCapture.requestNotificationPermission() }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Capture Source").font(.headline)
                    Text("Pick the exact Fortnite screen/window visually, or read a USB capture device directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if liveCapture.sourceMode == .captureDevice {
                    Button {
                        Task { await liveCapture.refreshSources() }
                    } label: {
                        Label(liveCapture.isRefreshing ? "Refreshing…" : "Refresh Devices", systemImage: "arrow.clockwise")
                    }
                    .disabled(liveCapture.isRefreshing || liveCapture.isStreaming)
                }
            }

            Picker("Source", selection: $liveCapture.sourceMode) {
                Label("Screen / Window", systemImage: "rectangle.on.rectangle").tag(CaptureSourceMode.systemPicker)
                Label("Capture Device", systemImage: "video.fill").tag(CaptureSourceMode.captureDevice)
            }
            .pickerStyle(.segmented)
            .disabled(liveCapture.isStreaming)

            if liveCapture.sourceMode == .systemPicker {
                systemPickerSource
            } else {
                devicePicker
            }

            HStack(spacing: 12) {
                Text("Profile")
                    .frame(width: 105, alignment: .leading)
                Picker("Profile", selection: profileSelection) {
                    ForEach(store.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
                .disabled(liveCapture.isStreaming)
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
    }

    private var systemPickerSource: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                liveCapture.chooseSystemCaptureSource()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.title3.weight(.bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(liveCapture.systemSelection == nil ? "Choose Screen or Window…" : "Change Screen or Window…")
                            .font(.headline)
                        Text("macOS shows visual thumbnails for screens and windows — including full-screen Spaces.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(liveCapture.isStreaming)

            if let selection = liveCapture.systemSelection {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.green.opacity(0.14))
                            .frame(width: 42, height: 42)
                        Image(systemName: selection.styleName == "Screen" ? "display" : "macwindow")
                            .foregroundStyle(.green)
                            .font(.system(size: 18, weight: .bold))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(selection.displayName)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        Text("\(selection.styleName) · \(selection.sizeText) · \(selection.detail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                }
                .padding(12)
                .background(.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.green.opacity(0.22)))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("This replaces the old Application + Specific Window dropdowns. Pick the source by thumbnail, like a screen-sharing app.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var applicationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Application")
                    .frame(width: 105, alignment: .leading)
                Picker("Application", selection: applicationSelection) {
                    Text("Choose an app…").tag("")
                    ForEach(liveCapture.applications) { app in
                        Text("\(app.applicationName) · \(app.windowCount) window\(app.windowCount == 1 ? "" : "s")")
                            .tag(app.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 420, alignment: .leading)
                .disabled(liveCapture.isStreaming)
            }

            if let target = liveCapture.resolvedApplicationTarget {
                Label(
                    "Auto window: \(target.windowTitle.isEmpty ? target.applicationName : target.windowTitle) · \(target.width)×\(target.height)",
                    systemImage: "viewfinder.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            } else if liveCapture.selectedApplication != nil {
                Label("Application selected, but no shareable gameplay window is available yet.", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var windowPicker: some View {
        HStack(spacing: 12) {
            Text("Window")
                .frame(width: 105, alignment: .leading)
            Picker("Window", selection: windowSelection) {
                Text("Choose a window…").tag(CGWindowID(0))
                ForEach(liveCapture.windows) { window in
                    Text("\(window.displayName) · \(window.sizeText)").tag(window.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 520, alignment: .leading)
            .disabled(liveCapture.isStreaming)
        }
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Video Device")
                    .frame(width: 105, alignment: .leading)
                Picker("Capture Device", selection: captureDeviceSelection) {
                    Text("Choose a device…").tag("")
                    ForEach(liveCapture.captureDevices) { device in
                        Text(device.displayName).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 480, alignment: .leading)
                .disabled(liveCapture.isStreaming)
            }
            Text("Use this for USB capture cards/VCC/UVC devices. It bypasses OBS and ScreenCaptureKit and reads the video feed directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What Sprite Vault Sees").font(.headline)
                Spacer()
                if liveCapture.sourceMode == .systemPicker && liveCapture.systemSelection != nil && !liveCapture.isStreaming {
                    Button {
                        Task { await liveCapture.refreshPreview() }
                    } label: {
                        Label(liveCapture.isPreviewRefreshing ? "Loading…" : "Refresh Preview", systemImage: "eye")
                    }
                    .disabled(liveCapture.isPreviewRefreshing)
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black.opacity(0.48))

                if let image = liveCapture.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(6)

                    if let source = liveCapture.previewSourceLabel {
                        Label(source, systemImage: "viewfinder")
                            .font(.caption2.weight(.bold))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.72), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.16)))
                            .padding(12)
                    }
                } else if liveCapture.isPreviewRefreshing {
                    VStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Locking preview to the selected source…")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.dashed.and.paperclip")
                            .font(.system(size: 28, weight: .bold))
                        Text(liveCapture.sourceMode == .captureDevice
                             ? "Start a scan to see the live capture-device preview."
                             : "Choose a screen/window above, then Sprite Vault shows exactly what it will read.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 210)

            HStack(spacing: 8) {
                Image(systemName: liveCapture.isCollectionScreenDetected ? "checkmark.seal.fill" : "scope")
                    .foregroundStyle(liveCapture.isCollectionScreenDetected ? .green : .secondary)
                Text(liveCapture.isCollectionScreenDetected
                     ? "Fortnite Sprites → Collection confirmed"
                     : "Sprite data is never saved until Sprites → Collection is visually confirmed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Adaptive Hotkey Scan").font(.headline)
                    Text("Press \(liveCapture.shortcutText) once. Fast scrolling pauses heavy OCR; each stable view is read once. The session auto-finishes only after all 117 catalog positions have actually been covered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("FPS", selection: $liveCapture.framesPerSecond) {
                    Text("2 FPS").tag(2)
                    Text("3 FPS").tag(3)
                    Text("5 FPS").tag(5)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(liveCapture.isStreaming)
            }

            if liveCapture.isHotkeyScanning {
                HStack(spacing: 10) {
                    metric("STATUS", liveCapture.scanPhase.label, symbol: "dot.radiowaves.left.and.right")
                    metric("TIME", liveCapture.elapsedText, symbol: "timer")
                    metric("COLLECTION", liveCapture.collectionText, symbol: "checkmark.circle")
                    metric("SCAN", liveCapture.coverageText, symbol: "scope")
                    metric("CHANGES", "+\(liveCapture.changesSoFar)", symbol: "sparkles")
                }
            }

            HStack(spacing: 10) {
                if liveCapture.isHotkeyScanning {
                    Button(role: .destructive) {
                        Task { await liveCapture.stopStreaming() }
                    } label: {
                        Label("Stop Scan", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task { await liveCapture.startHotkeyScanSession() }
                    } label: {
                        Label("Start \(liveCapture.shortcutText) Scan", systemImage: "keyboard.badge.ellipsis")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    Task { await liveCapture.captureOnce() }
                } label: {
                    Label(liveCapture.isCapturingOnce ? "Scanning…" : "Capture Once", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.bordered)
                .disabled(liveCapture.sourceMode == .captureDevice || liveCapture.isCapturingOnce || liveCapture.isStreaming)
            }

            HStack(spacing: 8) {
                Image(systemName: liveCapture.errorText == nil ? "waveform.path.ecg" : "exclamationmark.triangle.fill")
                    .foregroundStyle(liveCapture.errorText == nil ? Color.cyan : Color.red)
                Text(liveCapture.errorText ?? liveCapture.statusText)
                    .font(.caption.monospaced())
                    .foregroundStyle(liveCapture.errorText == nil ? Color.secondary : Color.red)
                    .lineLimit(3)
                Spacer()
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
    }

    @ViewBuilder
    private var resultsCard: some View {
        if !liveCapture.latestDetections.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Latest Stable View").font(.headline)
                    Spacer()
                    Text("\(liveCapture.latestDetections.count) unlocked")
                        .font(.caption.monospacedDigit().weight(.black))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(liveCapture.latestDetections) { result in
                        HStack(spacing: 8) {
                            Image(systemName: result.status == .lost ? "clock.arrow.circlepath" : result.mastered ? "crown.fill" : "checkmark.circle.fill")
                                .foregroundStyle(result.status == .lost ? .orange : result.mastered ? .yellow : .green)
                            Text(result.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(result.mastered ? "Lvl 5" : result.level.map { "Lvl \($0)" } ?? "Unlocked")
                                .font(.caption2.monospacedDigit().weight(.black))
                                .foregroundStyle(.secondary)
                        }
                        .padding(9)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(16)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
        }
    }

    private func metric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.system(size: 8, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Ready").font(.caption.weight(.bold)).foregroundStyle(.green)
            } else {
                Button(buttonTitle, action: action).buttonStyle(.bordered)
            }
        }
    }

    private var applicationSelection: Binding<String> {
        Binding(
            get: { liveCapture.selectedApplicationID ?? "" },
            set: { liveCapture.selectedApplicationID = $0.isEmpty ? nil : $0 }
        )
    }

    private var windowSelection: Binding<CGWindowID> {
        Binding(
            get: { liveCapture.selectedWindowID ?? 0 },
            set: { liveCapture.selectedWindowID = $0 == 0 ? nil : $0 }
        )
    }

    private var captureDeviceSelection: Binding<String> {
        Binding(
            get: { liveCapture.selectedCaptureDeviceID ?? "" },
            set: { liveCapture.selectedCaptureDeviceID = $0.isEmpty ? nil : $0 }
        )
    }

    private var profileSelection: Binding<UUID> {
        Binding(
            get: { liveCapture.targetProfileID ?? store.selectedProfileID },
            set: { liveCapture.targetProfileID = $0 }
        )
    }
}
