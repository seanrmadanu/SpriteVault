import SwiftUI
import CoreGraphics

struct LiveCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SpriteStore
    @EnvironmentObject private var liveCapture: LiveCaptureManager
    @EnvironmentObject private var activityStore: ActivityStore

    @State private var showPermissions = false
    @State private var showPreview = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                sourceCard
                scanCard
                if showPreview { previewCard }
                resultsCard
                permissionsDisclosure
            }
            .padding(20)
        }
        .frame(minWidth: 720, idealWidth: 800, minHeight: 620, idealHeight: 760)
        .background(AnimatedBackground())
        .task {
            liveCapture.installGlobalHotkey(store: store, activityStore: activityStore)
            liveCapture.setLivePreviewEnabled(showPreview)
            if liveCapture.targetProfileID == nil {
                liveCapture.targetProfileID = store.selectedProfileID
            }
            await liveCapture.refreshSources()
            if showPreview, liveCapture.sourceMode == .systemPicker, liveCapture.systemSelection != nil {
                await liveCapture.refreshPreview()
            }
        }
        .onDisappear {
            liveCapture.setLivePreviewEnabled(false)
        }
        .onChange(of: liveCapture.sourceMode) { _, mode in
            Task {
                await liveCapture.refreshSources()
                if showPreview, mode == .systemPicker, liveCapture.systemSelection != nil {
                    await liveCapture.refreshPreview()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Live Capture")
                    .font(.title2.weight(.black))
                Text("Select Fortnite, start the scan, then return to the game.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(showPreview ? "Hide Preview" : "Show Preview") {
                showPreview.toggle()
                liveCapture.setLivePreviewEnabled(showPreview)
                if showPreview, liveCapture.systemSelection != nil, !liveCapture.isStreaming {
                    Task { await liveCapture.refreshPreview() }
                }
            }
            .buttonStyle(.bordered)
            Button("Done") { dismiss() }
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Source")
                    .font(.headline)
                Spacer()
                Picker("Source", selection: $liveCapture.sourceMode) {
                    Text("Screen / Window").tag(CaptureSourceMode.systemPicker)
                    Text("Capture Device").tag(CaptureSourceMode.captureDevice)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 270)
                .disabled(liveCapture.isStreaming)
            }

            if liveCapture.sourceMode == .systemPicker {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            liveCapture.chooseSystemCaptureSource()
                        } label: {
                            Label(
                                liveCapture.systemSelection == nil ? "Select Window / Screen" : "Change Window / Screen",
                                systemImage: "rectangle.on.rectangle"
                            )
                            .fontWeight(.bold)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(liveCapture.isStreaming)

                        Button {
                            liveCapture.chooseRegionCaptureSource()
                        } label: {
                            Label("Custom Area", systemImage: "viewfinder.rectangular")
                        }
                        .buttonStyle(.bordered)
                        .disabled(liveCapture.isStreaming)
                    }

                    Text("Use Window / Screen for full-screen Fortnite or OBS Projector. Custom Area is best for windowed setups. For recognition, include the full Fortnite viewport rather than only the card grid.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let selection = liveCapture.systemSelection {
                        HStack(spacing: 9) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selection.displayName)
                                    .font(.subheadline.weight(.bold))
                                    .lineLimit(nil)
                                Text("\(selection.styleName) · \(selection.sizeText)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            } else {
                devicePicker
            }

            Divider()

            HStack(spacing: 10) {
                Label("Profile", systemImage: "person.crop.circle")
                    .font(.subheadline.weight(.semibold))
                Picker("Profile", selection: profileSelection) {
                    ForEach(store.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                .disabled(liveCapture.isStreaming)
                Spacer()
            }
        }
        .cardStyle()
    }

    private var devicePicker: some View {
        HStack(spacing: 10) {
            Picker("Capture Device", selection: captureDeviceSelection) {
                Text("Choose a device…").tag("")
                ForEach(liveCapture.captureDevices) { device in
                    Text(device.displayName).tag(device.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 420)
            .disabled(liveCapture.isStreaming)

            Button {
                Task { await liveCapture.refreshSources() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(liveCapture.isRefreshing || liveCapture.isStreaming)
            Spacer()
        }
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scanner")
                        .font(.headline)
                    Text("Heavy Vision work runs only after the collection stops moving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Picker("Speed", selection: $liveCapture.framesPerSecond) {
                    Text("Efficient · 2 FPS").tag(2)
                    Text("Responsive · 3 FPS").tag(3)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 255)
                .disabled(liveCapture.isStreaming)
            }

            HStack(spacing: 9) {
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
                        Label("Start Scan", systemImage: "play.fill")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    Task { await liveCapture.captureOnce() }
                } label: {
                    Label(liveCapture.isCapturingOnce ? "Scanning…" : "Scan Current View", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.bordered)
                .disabled(liveCapture.sourceMode == .captureDevice || liveCapture.isCapturingOnce || liveCapture.isStreaming)

                Spacer()

                Label(liveCapture.shortcutText, systemImage: "keyboard")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if liveCapture.isHotkeyScanning {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                    metric("Status", liveCapture.scanPhase.label, symbol: "dot.radiowaves.left.and.right")
                    metric("Time", liveCapture.elapsedText, symbol: "timer")
                    metric("Collection", liveCapture.collectionText, symbol: "checkmark.circle")
                    metric("Coverage", liveCapture.coverageText, symbol: "scope")
                    metric("Changes", "+\(liveCapture.changesSoFar)", symbol: "sparkles")
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: liveCapture.errorText == nil ? "waveform.path.ecg" : "exclamationmark.triangle.fill")
                    .foregroundStyle(liveCapture.errorText == nil ? Color.cyan : Color.red)
                Text(liveCapture.errorText ?? liveCapture.statusText)
                    .font(.caption)
                    .foregroundStyle(liveCapture.errorText == nil ? Color.secondary : Color.red)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .cardStyle()
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if liveCapture.systemSelection != nil && !liveCapture.isStreaming {
                    Button {
                        Task { await liveCapture.refreshPreview() }
                    } label: {
                        Label(liveCapture.isPreviewRefreshing ? "Loading…" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(liveCapture.isPreviewRefreshing)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.44))

                if let image = liveCapture.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(5)
                } else if liveCapture.isPreviewRefreshing {
                    ProgressView()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.dashed")
                            .font(.title2)
                        Text("Choose a source to verify what the scanner sees.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 165)

            Label(
                liveCapture.isCollectionScreenDetected ? "Sprite Collection detected" : "Waiting for Sprite Collection",
                systemImage: liveCapture.isCollectionScreenDetected ? "checkmark.seal.fill" : "scope"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(liveCapture.isCollectionScreenDetected ? .green : .secondary)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var resultsCard: some View {
        if !liveCapture.latestDetections.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Recognized in Latest View")
                        .font(.headline)
                    Spacer()
                    Text("\(liveCapture.latestDetections.count)")
                        .font(.caption.monospacedDigit().weight(.black))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 7)], spacing: 7) {
                    ForEach(liveCapture.latestDetections) { result in
                        HStack(spacing: 7) {
                            Image(systemName: result.status == .lost ? "clock.arrow.circlepath" : result.mastered ? "crown.fill" : "checkmark.circle.fill")
                                .foregroundStyle(result.status == .lost ? .orange : result.mastered ? .yellow : .green)
                            Text(result.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Text(result.level.map { "Lvl \($0)" } ?? "Owned")
                                .font(.caption2.monospacedDigit().weight(.black))
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .cardStyle()
        }
    }

    private var permissionsDisclosure: some View {
        DisclosureGroup(isExpanded: $showPermissions) {
            VStack(spacing: 0) {
                permissionRow(
                    title: "Screen Recording",
                    detail: "Required for screen/window capture.",
                    granted: liveCapture.screenRecordingGranted,
                    buttonTitle: "Enable"
                ) { liveCapture.requestScreenRecordingPermission() }

                Divider()

                permissionRow(
                    title: "Accessibility",
                    detail: "Required for the global \(liveCapture.shortcutText) shortcut.",
                    granted: liveCapture.accessibilityGranted,
                    buttonTitle: "Enable"
                ) { liveCapture.requestAccessibilityPermission() }

                Divider()

                permissionRow(
                    title: "Capture Device",
                    detail: "Only needed for USB video devices.",
                    granted: liveCapture.captureDeviceGranted,
                    buttonTitle: "Enable"
                ) { liveCapture.requestCaptureDevicePermission() }

                Divider()

                permissionRow(
                    title: "Notifications",
                    detail: "Optional scan completion alerts.",
                    granted: liveCapture.notificationsGranted,
                    buttonTitle: "Enable"
                ) { liveCapture.requestNotificationPermission() }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Text("Permissions")
                    .font(.headline)
                Spacer()
                Text(permissionSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var permissionSummary: String {
        var ready = 0
        if liveCapture.screenRecordingGranted { ready += 1 }
        if liveCapture.accessibilityGranted { ready += 1 }
        if liveCapture.captureDeviceGranted { ready += 1 }
        if liveCapture.notificationsGranted { ready += 1 }
        return "\(ready)/4 ready"
    }

    private func metric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.system(size: 8, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
            }
            Spacer()
            if granted {
                Text("Ready")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
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

private extension View {
    func cardStyle() -> some View {
        self
            .padding(14)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.07)))
    }
}
