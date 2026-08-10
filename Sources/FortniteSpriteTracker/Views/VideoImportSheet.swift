import SwiftUI
import UniformTypeIdentifiers

struct VideoImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SpriteStore

    @State private var fileURL: URL?
    @State private var isImporterOpen = false
    @State private var analyzing = false
    @State private var progress = 0.0
    @State private var scanText = "Waiting for a recording…"
    @State private var results: [DetectedSprite] = []
    @State private var errorText: String?
    @State private var scanning = false
    @State private var replaceExisting = true
    @State private var resultsApplied = false
    @State private var showResetConfirmation = false
    @State private var hasAnalyzed = false

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Auto-check from recording").font(.title2.weight(.black))
                    Text("Reads only the selected Sprite's right-side name and level, then matches it to the catalog.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(style: StrokeStyle(lineWidth: 1.5, dash: [8, 8])).foregroundStyle(.white.opacity(0.18)))

                VStack(spacing: 14) {
                    Image(systemName: fileURL == nil ? "movieclapper" : "film.stack.fill")
                        .font(.system(size: 48, weight: .bold))
                        .symbolEffect(.pulse, isActive: analyzing)
                    Text(fileURL?.lastPathComponent ?? "Choose a Fortnite screen recording")
                        .font(.headline)
                    Button(fileURL == nil ? "Choose Video" : "Choose Another") { isImporterOpen = true }
                        .buttonStyle(.borderedProminent)
                }

                if analyzing {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 110)
                            .offset(x: scanning ? geo.size.width : -120)
                            .animation(.linear(duration: 1.25).repeatForever(autoreverses: false), value: scanning)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 220)

            if analyzing || hasAnalyzed {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(analysisHeading)
                            .font(.headline)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text(scanText.isEmpty ? "Scanning frame text…" : scanText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results, id: \.self) { result in
                            HStack {
                                Image(systemName: result.mastered ? "crown.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(result.mastered ? .yellow : .green)
                                Text(result.name).fontWeight(.semibold)
                                Spacer()
                                Text(result.mastered ? "MASTERED · LVL 5" : "LVL \(result.level)")
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(.secondary)
                                Text("\(result.rarity.rawValue) · RIGHT PANEL · \(result.observations)x")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                Text(timestamp(result.timestamp))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .frame(maxHeight: 190)
            }

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Picker("Apply mode", selection: $replaceExisting) {
                        Text("Replace incorrect tracking").tag(true)
                        Text("Merge with current tracking").tag(false)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text(replaceExisting
                             ? "Clears the old result, then marks only the selected Sprites detected in this recording."
                             : "Updates detected Sprites but leaves every other saved entry unchanged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(resultsApplied ? "Applied" : "Apply Reviewed Results") {
                            store.applyDetections(results, replacingExisting: replaceExisting)
                            resultsApplied = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(resultsApplied)
                    }
                }
            }

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button("Clear Incorrect Tracking", role: .destructive) {
                    showResetConfirmation = true
                }

                Text("Tip: keep each selected Sprite's right-side name and level visible for 2 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Analyze Recording") { analyze() }
                    .buttonStyle(.borderedProminent)
                    .disabled(fileURL == nil || analyzing)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 820, height: 760)
        .background(AnimatedBackground())
        .alert("Clear all tracking data?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                store.reset()
                resultsApplied = false
                hasAnalyzed = false
            }
        } message: {
            Text("This removes the incorrect owned, level, and mastery values. It cannot be undone inside the app.")
        }
        .fileImporter(isPresented: $isImporterOpen, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            switch result {
            case .success(let url):
                fileURL = url
                results = []
                progress = 0
                errorText = nil
                resultsApplied = false
                hasAnalyzed = false
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }

    private func analyze() {
        guard let fileURL else { return }
        analyzing = true
        scanning = true
        results = []
        errorText = nil
        progress = 0
        resultsApplied = false
        hasAnalyzed = false

        Task {
            let didAccess = fileURL.startAccessingSecurityScopedResource()
            defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }
            do {
                let found = try await VideoSpriteAnalyzer().analyze(url: fileURL) { value, text in
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: 0.15)) { progress = value }
                        scanText = text
                    }
                }
                await MainActor.run {
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                        results = found
                        progress = 1
                        analyzing = false
                        scanning = false
                        hasAnalyzed = true
                    }
                    if found.isEmpty {
                        scanText = "No name and level were confirmed twice. Hold each selection still for 2 seconds."
                    } else {
                        scanText = "Review the detections before applying them."
                    }
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    analyzing = false
                    scanning = false
                    hasAnalyzed = true
                }
            }
        }
    }

    private func timestamp(_ value: Double) -> String {
        let m = Int(value) / 60
        let s = Int(value) % 60
        return String(format: "%d:%02d", m, s)
    }

    private var analysisHeading: String {
        if analyzing {
            return "Analyzing…"
        }
        if results.isEmpty {
            return "No confirmed Sprites"
        }
        return "Detected \(results.count) Sprite\(results.count == 1 ? "" : "s")"
    }
}
