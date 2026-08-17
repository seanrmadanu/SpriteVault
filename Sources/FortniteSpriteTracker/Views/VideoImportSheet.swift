import SwiftUI
import UniformTypeIdentifiers

struct VideoImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SpriteStore

    @State private var targetProfileID: UUID
    @State private var fileURL: URL?
    @State private var isImporterOpen = false
    @State private var analyzing = false
    @State private var progress = 0.0
    @State private var scanText = "Waiting for media…"
    @State private var results: [DetectedSprite] = []
    @State private var errorText: String?
    @State private var scanning = false
    @State private var replaceExisting = true
    @State private var resultsApplied = false
    @State private var showResetConfirmation = false
    @State private var hasAnalyzed = false

    init(initialProfileID: UUID) {
        _targetProfileID = State(initialValue: initialProfileID)
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Auto-check from recording or screenshot")
                        .font(.title2.weight(.black))
                    Text(importDescription)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Label("Target profile", systemImage: "person.crop.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.cyan)
                        Picker("Target profile", selection: $targetProfileID) {
                            ForEach(store.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 230)
                        .disabled(analyzing)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(
                                style: StrokeStyle(lineWidth: 1.5, dash: [8, 8])
                            )
                            .foregroundStyle(.white.opacity(0.18))
                    )

                VStack(spacing: 14) {
                    Image(systemName: importIcon)
                        .font(.system(size: 48, weight: .bold))
                        .symbolEffect(.pulse, isActive: analyzing)
                    Text(fileURL?.lastPathComponent ?? "Choose a Fortnite recording or screenshot")
                        .font(.headline)
                    Button(fileURL == nil ? "Choose Media" : "Choose Another") {
                        isImporterOpen = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                if analyzing {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.28), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 110)
                            .offset(x: scanning ? geo.size.width : -120)
                            .animation(
                                .linear(duration: 1.25).repeatForever(autoreverses: false),
                                value: scanning
                            )
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
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text(scanText.isEmpty ? "Scanning media…" : scanText)
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
                                Text(result.name)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(result.mastered ? "MASTERED · LVL 5" : "LVL \(result.level)")
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(.secondary)
                                Text(resultSourceText(result))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                if !isScreenshotImport {
                                    Text(timestamp(result.timestamp))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
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
                             ? "Clears \(targetProfileName), then marks only the Sprites detected in this \(mediaNoun)."
                             : "Updates detected Sprites in \(targetProfileName) but leaves every other saved entry unchanged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(resultsApplied ? "Applied" : "Apply Reviewed Results") {
                            store.applyDetections(
                                results,
                                to: targetProfileID,
                                replacingExisting: replaceExisting
                            )
                            store.selectProfile(targetProfileID)
                            resultsApplied = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(resultsApplied)
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Clear Target Profile", role: .destructive) {
                    showResetConfirmation = true
                }

                Text(importHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(analyzeButtonTitle) { analyze() }
                    .buttonStyle(.borderedProminent)
                    .disabled(fileURL == nil || analyzing)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 820, height: 760)
        .background(AnimatedBackground())
        .alert("Clear \(targetProfileName)?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                store.reset(profileID: targetProfileID)
                resultsApplied = false
                hasAnalyzed = false
            }
        } message: {
            Text("This removes owned, level, and mastery values only from this profile. Other profiles are not changed.")
        }
        .onChange(of: targetProfileID) { _, _ in
            resultsApplied = false
        }
        .fileImporter(
            isPresented: $isImporterOpen,
            allowedContentTypes: [.movie, .image]
        ) { result in
            switch result {
            case .success(let url):
                fileURL = url
                results = []
                progress = 0
                errorText = nil
                resultsApplied = false
                hasAnalyzed = false
                let kind = mediaKind(for: url)
                replaceExisting = kind == .video
                scanText = kind == .screenshot
                    ? "Ready to scan the visible Sprite cards. Merge mode is selected so later screenshots keep earlier matches."
                    : "Ready to scan the selected Sprite details."
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }

    private func analyze() {
        guard let fileURL else { return }
        let screenshotImport = mediaKind(for: fileURL) == .screenshot

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
                let progressHandler: @Sendable (Double, String) -> Void = { value, text in
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: 0.15)) {
                            progress = value
                        }
                        scanText = text
                    }
                }

                let found: [DetectedSprite]
                if screenshotImport {
                    found = try await ScreenshotSpriteAnalyzer.shared.analyze(
                        url: fileURL,
                        onProgress: progressHandler
                    )
                } else {
                    found = try await VideoSpriteAnalyzer().analyze(
                        url: fileURL,
                        onProgress: progressHandler
                    )
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
                        scanText = screenshotImport
                            ? "No owned cards were confirmed. Use a Collection screenshot with the 3-column grid and readable Lvl labels."
                            : "No readable name and level found. Make sure each card is actually selected for 1 second."
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

    private func mediaKind(for url: URL) -> ImportedMediaKind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return .video
        }
        return type.conforms(to: .image) ? .screenshot : .video
    }

    private var isScreenshotImport: Bool {
        guard let fileURL else { return false }
        return mediaKind(for: fileURL) == .screenshot
    }

    private var importIcon: String {
        guard fileURL != nil else { return "rectangle.stack.badge.play" }
        return isScreenshotImport ? "photo.fill" : "film.stack.fill"
    }

    private var importDescription: String {
        if isScreenshotImport {
            return "Reads each visible card's level, then matches the Sprite artwork against the built-in 117-Sprite catalog. Level 5 is treated as Mastered."
        }
        return "Recordings read the selected title, level, and Mastered banner from the high-resolution right-side details panel."
    }

    private var importHint: String {
        if isScreenshotImport {
            return "One screenshot scans the visible cards only. Keep the full grid visible and use Merge for additional screenshots; Level 5 becomes Mastered."
        }
        return "Select every card for about 1 second. Wrapped titles and the Mastered banner are supported."
    }

    private var analyzeButtonTitle: String {
        isScreenshotImport ? "Analyze Screenshot" : "Analyze Recording"
    }

    private var mediaNoun: String {
        isScreenshotImport ? "screenshot" : "recording"
    }

    private func resultSourceText(_ result: DetectedSprite) -> String {
        if isScreenshotImport {
            return "\(result.rarity.rawValue) · SCREENSHOT CARD"
        }
        return "\(result.rarity.rawValue) · RIGHT PANEL · \(result.observations)x"
    }

    private func timestamp(_ value: Double) -> String {
        let m = Int(value) / 60
        let s = Int(value) % 60
        return String(format: "%d:%02d", m, s)
    }

    private var targetProfileName: String {
        store.profile(withID: targetProfileID)?.name ?? "Selected Profile"
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

private enum ImportedMediaKind {
    case video
    case screenshot
}
