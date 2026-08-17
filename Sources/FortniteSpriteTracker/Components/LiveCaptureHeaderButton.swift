import SwiftUI

struct LiveCaptureHeaderButton: View {
    @ObservedObject var liveCapture: LiveCaptureManager
    let action: () -> Void

    @State private var metricIndex = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(liveCapture.isHotkeyScanning ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                    if liveCapture.isHotkeyScanning {
                        Circle()
                            .stroke(Color.green.opacity(0.45), lineWidth: 2)
                            .frame(width: 14, height: 14)
                            .symbolEffect(.pulse)
                    }
                }

                Image(systemName: liveCapture.isHotkeyScanning ? "dot.radiowaves.left.and.right" : "camera.viewfinder")

                Text(displayText)
                    .fontWeight(liveCapture.isHotkeyScanning ? .bold : .regular)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .frame(minWidth: liveCapture.isHotkeyScanning ? 128 : nil, alignment: .leading)
            }
        }
        .buttonStyle(.bordered)
        .task(id: liveCapture.isHotkeyScanning) {
            metricIndex = 0
            guard liveCapture.isHotkeyScanning else { return }
            while !Task.isCancelled && liveCapture.isHotkeyScanning {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    metricIndex = (metricIndex + 1) % 5
                }
            }
        }
    }

    private var displayText: String {
        guard liveCapture.isHotkeyScanning else { return "Live Capture" }
        switch metricIndex {
        case 0: return liveCapture.scanPhase.label
        case 1: return "Running · \(liveCapture.elapsedText)"
        case 2: return "Collection · \(liveCapture.collectionText)"
        case 3: return "Scan · \(liveCapture.coverageText)"
        default: return "Changes · +\(liveCapture.changesSoFar)"
        }
    }
}
