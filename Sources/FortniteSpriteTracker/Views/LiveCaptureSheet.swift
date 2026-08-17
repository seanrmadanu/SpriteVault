import SwiftUI
import CoreGraphics

struct LiveCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SpriteStore
    @EnvironmentObject private var liveCapture: LiveCaptureManager

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Live Window Capture")
                        .font(.title2.weight(.black))
                    Text("Capture only the game/streaming window, then run the same Vision artwork + level detector used by screenshot imports.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            permissionsCard
            targetCard
            controlsCard
            resultsCard

            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(width: 860, height: 800)
        .background(AnimatedBackground())
        .task {
            liveCapture.installGlobalHotkey(store: store)
            if liveCapture.targetProfileID == nil {
                liveCapture.targetProfileID = store.selectedProfileID
            }
            if liveCapture.windows.isEmpty {
                await liveCapture.refreshWindows()
            }
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)

            permissionRow(
                title: "Screen Recording",
                detail: "Required by ScreenCaptureKit to read another app window.",
                granted: liveCapture.screenRecordingGranted,
                buttonTitle: "Request Access"
            ) {
                liveCapture.requestScreenRecordingPermission()
            }

            Divider()

            permissionRow(
                title: "Accessibility",
                detail: "Required for the global \(liveCapture.shortcutText) hotkey while Fortnite is focused.",
                granted: liveCapture.accessibilityGranted,
                buttonTitle: "Enable Hotkey"
            ) {
                liveCapture.requestAccessibilityPermission()
            }

            Divider()

            permissionRow(
                title: "Notifications",
                detail: "Shows scan start/completion, new Sprite, level-up, and mastery alerts while you stay in Fortnite.",
                granted: liveCapture.notificationsGranted,
                buttonTitle: "Enable Alerts"
            ) {
                liveCapture.requestNotificationPermission()
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Capture Target")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await liveCapture.refreshWindows() }
                } label: {
                    Label(liveCapture.isRefreshing ? "Refreshing…" : "Refresh Windows", systemImage: "arrow.clockwise")
                }
                .disabled(liveCapture.isRefreshing || liveCapture.isStreaming)
            }

            HStack(spacing: 12) {
                Text("Window")
                    .frame(width: 95, alignment: .leading)
                Picker("Window", selection: windowSelection) {
                    Text("Choose a window…").tag(CGWindowID(0))
                    ForEach(liveCapture.windows) { window in
                        HStack {
                            Text(window.displayName)
                            Text(window.sizeText)
                        }
                        .tag(window.id)
                    }
                }
                .labelsHidden()
                .disabled(liveCapture.isStreaming)
            }

            if let selected = liveCapture.selectedWindow {
                HStack(spacing: 8) {
                    Image(systemName: selected.isLikelyGameWindow ? "gamecontroller.fill" : "macwindow")
                        .foregroundStyle(selected.isLikelyGameWindow ? .green : .secondary)
                    Text("\(selected.applicationName) · \(selected.sizeText)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Text("Profile")
                    .frame(width: 95, alignment: .leading)
                Picker("Profile", selection: profileSelection) {
                    ForEach(store.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .disabled(liveCapture.isStreaming)
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automated Vision Scan")
                        .font(.headline)
                    Text("Press \(liveCapture.shortcutText) in Fortnite to start a one-press collection scan. Confirmed pages merge into the chosen profile and the scan stops itself near the end of the Type-sorted catalog.")
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

            HStack(spacing: 10) {
                Button {
                    Task { await liveCapture.captureOnce() }
                } label: {
                    Label(
                        liveCapture.isCapturingOnce ? "Scanning…" : "Capture Once",
                        systemImage: "camera.viewfinder"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(liveCapture.selectedWindowID == nil || liveCapture.isCapturingOnce || liveCapture.isStreaming)

                Button {
                    Task { await liveCapture.startHotkeyScanSession() }
                } label: {
                    Label(
                        liveCapture.isHotkeyScanning ? "Hotkey Scan Active" : "Start \(liveCapture.shortcutText) Scan",
                        systemImage: liveCapture.isHotkeyScanning ? "waveform.badge.magnifyingglass" : "keyboard.badge.ellipsis"
                    )
                    .fontWeight(.bold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(liveCapture.selectedWindowID == nil || liveCapture.isCapturingOnce || liveCapture.isStreaming)

                Button {
                    Task { await liveCapture.toggleStreaming() }
                } label: {
                    Label(
                        liveCapture.isStreaming ? "Stop Live Scan" : "Start Live Scan",
                        systemImage: liveCapture.isStreaming ? "stop.fill" : "dot.radiowaves.left.and.right"
                    )
                    .fontWeight(.bold)
                }
                .buttonStyle(.borderedProminent)
                .tint(liveCapture.isStreaming ? .red : .accentColor)
                .disabled(liveCapture.selectedWindowID == nil || liveCapture.isCapturingOnce)

                if liveCapture.isStreaming {
                    Label(liveCapture.isHotkeyScanning ? "HOTKEY" : "LIVE", systemImage: "circle.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.green)
                        .symbolEffect(.pulse)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: liveCapture.errorText == nil ? "waveform.path.ecg" : "exclamationmark.triangle.fill")
                    .foregroundStyle(liveCapture.errorText == nil ? Color.cyan : Color.red)
                Text(liveCapture.errorText ?? liveCapture.statusText)
                    .font(.caption.monospaced())
                    .foregroundStyle(liveCapture.errorText == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
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
                    Text("Latest Confirmed Cards")
                        .font(.headline)
                    Spacer()
                    Text("\(liveCapture.latestDetections.count)")
                        .font(.caption.monospacedDigit().weight(.black))
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(liveCapture.latestDetections) { result in
                            HStack(spacing: 8) {
                                Image(systemName: result.mastered ? "crown.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(result.mastered ? .yellow : .green)
                                Text(result.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text("Lvl \(result.level)")
                                    .font(.caption2.monospacedDigit().weight(.black))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(9)
                            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
            .padding(16)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
        }
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
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }

    private var windowSelection: Binding<CGWindowID> {
        Binding(
            get: { liveCapture.selectedWindowID ?? 0 },
            set: { liveCapture.selectedWindowID = $0 == 0 ? nil : $0 }
        )
    }

    private var profileSelection: Binding<UUID> {
        Binding(
            get: { liveCapture.targetProfileID ?? store.selectedProfileID },
            set: { liveCapture.targetProfileID = $0 }
        )
    }
}
