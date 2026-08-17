import SwiftUI
import AppKit

struct SpriteMenuBarView: View {
    @EnvironmentObject private var liveCapture: LiveCaptureManager
    @EnvironmentObject private var store: SpriteStore
    @EnvironmentObject private var activityStore: ActivityStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SPRITE VAULT")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .tracking(1.1)
                    Label(liveCapture.scanPhase.label, systemImage: liveCapture.menuBarSymbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if liveCapture.isHotkeyScanning {
                    Text(liveCapture.elapsedText)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            if let preview = liveCapture.previewImage {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.10)))
            }

            VStack(alignment: .leading, spacing: 7) {
                statusRow("Source", liveCapture.selectedSourceDisplayName, symbol: liveCapture.sourceMode.symbol)
                statusRow(
                    "Fortnite",
                    liveCapture.isCollectionScreenDetected ? "Sprites → Collection detected" : "Waiting for Collection",
                    symbol: liveCapture.isCollectionScreenDetected ? "checkmark.seal.fill" : "scope"
                )
            }

            if liveCapture.isHotkeyScanning || liveCapture.scanPhase == .complete {
                HStack(spacing: 8) {
                    compactMetric("COLLECTION", liveCapture.collectionText)
                    compactMetric("SCAN", liveCapture.coverageText)
                    compactMetric("CHANGES", "+\(liveCapture.changesSoFar)")
                }
            }

            Divider()

            HStack(spacing: 8) {
                if liveCapture.isHotkeyScanning {
                    Button("Stop Scan", role: .destructive) {
                        Task { await liveCapture.stopStreaming() }
                    }
                } else {
                    Button("Start Scan \(liveCapture.shortcutText)") {
                        Task { await liveCapture.startHotkeyScanSession() }
                    }
                }

                Button("Open Sprite Vault") {
                    showMainWindow()
                }
            }

            Button {
                showMainWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    NotificationCenter.default.post(name: .activityNotificationSelected, object: nil)
                }
            } label: {
                HStack {
                    Label("Activity", systemImage: "bell.fill")
                    Spacer()
                    if activityStore.unreadCount > 0 {
                        Text("\(activityStore.unreadCount)")
                            .font(.caption2.monospacedDigit().weight(.black))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 360)
        .onReceive(NotificationCenter.default.publisher(for: .spriteVaultOpenMainWindow)) { _ in
            showMainWindow()
        }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        Task { @MainActor in
            // Give SwiftUI one run-loop turn to materialize the window before
            // bringing it to the front.
            await Task.yield()
            MainWindowActivator.show()
        }
    }

    private func statusRow(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.caption.weight(.bold))
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func compactMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.black))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private var statusColor: Color {
        switch liveCapture.scanPhase {
        case .scanning: return .green
        case .waitingForCollection, .waitingForSource, .waitingForStability: return .orange
        case .complete: return .green
        case .error: return .red
        case .idle: return .secondary
        }
    }
}

enum MainWindowActivator {
    @MainActor
    static func show() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        if let window = app.windows.first(where: { $0.canBecomeKey && $0.title != "" })
            ?? app.windows.first(where: \.canBecomeKey) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
