import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct VideoImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SpriteStore

    @State private var targetProfileID: UUID
    @State private var fileURLs: [URL] = []
    @State private var isImporterOpen = false
    @State private var analyzing = false
    @State private var progress = 0.0
    @State private var scanText = "Waiting for media…"
    @State private var results: [DetectedSprite] = []
    @State private var errorText: String?
    @State private var replaceExisting = true
    @State private var resultsApplied = false
    @State private var showResetConfirmation = false
    @State private var hasAnalyzed = false
    @State private var failedScreenshotNames: [String] = []

    init(initialProfileID: UUID) {
        _targetProfileID = State(initialValue: initialProfileID)
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Auto-check from recording or screenshots")
                        .font(.title2.weight(.black))
                    Text(importDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

                    Text(selectionTitle)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if isScreenshotImport, !fileURLs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(fileURLs, id: \.self) { url in
                                    screenshotThumbnail(for: url)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .frame(maxWidth: 620)
                    }

                    HStack(spacing: 10) {
                        Button(selectionButtonTitle) {
                            isImporterOpen = true
                        }
                        .buttonStyle(.borderedProminent)

                        if !fileURLs.isEmpty {
                            Button("Clear Selection") {
                                clearMediaSelection()
                            }
                            .buttonStyle(.bordered)
                            .disabled(analyzing)
                        }
                    }
                }
            }
            .frame(height: isScreenshotImport && fileURLs.count > 1 ? 250 : 220)

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
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results, id: \.self) { result in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: result.mastered ? "crown.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(result.mastered ? .yellow : .green)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.name)
                                        .fontWeight(.semibold)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(result.mastered ? "MASTERED · LVL 5" : result.level.map { "LVL \($0)" } ?? (result.status == .lost ? "LOST" : "UNLOCKED"))
                                        .font(.caption2.weight(.black))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 12)

                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(resultSourceText(result))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .multilineTextAlignment(.trailing)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if !isScreenshotImport {
                                        Text(timestamp(result.timestamp))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .padding(10)
                            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .frame(maxHeight: 210)
            }

            if !failedScreenshotNames.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        "\(failedScreenshotNames.count) screenshot\(failedScreenshotNames.count == 1 ? "" : "s") could not be read; the rest of the batch was kept.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)

                    Text(failedScreenshotNames.joined(separator: " · "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Picker("Apply mode", selection: $replaceExisting) {
                        Text("Replace incorrect tracking").tag(true)
                        Text("Merge with current tracking").tag(false)
                    }
                    .pickerStyle(.segmented)

                    HStack(alignment: .top) {
                        Text(replaceExisting
                             ? "Clears \(targetProfileName), then marks only the Sprites detected in this \(mediaNoun)."
                             : "Updates detected Sprites in \(targetProfileName) but leaves every other saved entry unchanged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top) {
                Button("Clear Target Profile", role: .destructive) {
                    showResetConfirmation = true
                }

                Text(importHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(analyzeButtonTitle) { analyze() }
                    .buttonStyle(.borderedProminent)
                    .disabled(fileURLs.isEmpty || analyzing)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 820, height: 790)
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
            allowedContentTypes: [.movie, .image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                prepareMediaSelection(urls)
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }


    @ViewBuilder
    private func screenshotThumbnail(for url: URL) -> some View {
        let image = previewImage(for: url)

        VStack(spacing: 5) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.05)
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 112, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.white.opacity(0.11))
            }

            Text(url.lastPathComponent)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 112)
        }
        .padding(6)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func previewImage(for url: URL) -> NSImage? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return NSImage(contentsOf: url)
    }

    private func prepareMediaSelection(_ urls: [URL]) {
        let selected = urls.filter { !$0.path.isEmpty }
        guard !selected.isEmpty else { return }

        let images = selected.filter { mediaKind(for: $0) == .screenshot }
        let videos = selected.filter { mediaKind(for: $0) == .video }

        guard videos.isEmpty || (videos.count == 1 && images.isEmpty) else {
            errorText = "Choose either one recording or one/more screenshots. A mixed batch cannot be analyzed reliably."
            return
        }

        if !images.isEmpty {
            let existingImages = fileURLs.filter { mediaKind(for: $0) == .screenshot }
            let combined = existingImages + images
            var seen = Set<String>()
            fileURLs = combined.filter { seen.insert($0.standardizedFileURL.path).inserted }
            replaceExisting = false
            scanText = "Ready to scan \(fileURLs.count) screenshot\(fileURLs.count == 1 ? "" : "s"). Results will be merged and duplicate Sprites reconciled automatically."
        } else if let video = videos.first {
            fileURLs = [video]
            replaceExisting = true
            scanText = "Ready to scan the selected Sprite details."
        }

        results = []
        progress = 0
        errorText = nil
        failedScreenshotNames = []
        resultsApplied = false
        hasAnalyzed = false
    }

    private func clearMediaSelection() {
        fileURLs = []
        results = []
        failedScreenshotNames = []
        progress = 0
        errorText = nil
        resultsApplied = false
        hasAnalyzed = false
        scanText = "Waiting for media…"
        replaceExisting = true
    }

    private func analyze() {
        guard !fileURLs.isEmpty else { return }
        let screenshotImport = isScreenshotImport

        analyzing = true
        results = []
        failedScreenshotNames = []
        errorText = nil
        progress = 0
        resultsApplied = false
        hasAnalyzed = false

        Task {
            if screenshotImport {
                await analyzeScreenshotBatch(fileURLs)
            } else if let fileURL = fileURLs.first {
                await analyzeVideo(fileURL)
            }
        }
    }

    private func analyzeScreenshotBatch(_ urls: [URL]) async {
        var combined: [DetectedSprite] = []
        var failures: [String] = []
        let total = max(urls.count, 1)

        for (index, url) in urls.enumerated() {
            if Task.isCancelled { break }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            do {
                let found = try await ScreenshotSpriteAnalyzer.shared.analyze(
                    url: url,
                    onProgress: { value, text in
                        Task { @MainActor in
                            let overall = (Double(index) + value) / Double(total)
                            withAnimation(.easeOut(duration: 0.15)) {
                                progress = min(max(overall, 0), 1)
                            }
                            scanText = "Screenshot \(index + 1)/\(total) · \(text)"
                        }
                    }
                )
                combined = mergeScreenshotDetections(combined, with: found)
            } catch is CancellationError {
                break
            } catch {
                failures.append(url.lastPathComponent)
                await MainActor.run {
                    scanText = "Screenshot \(index + 1)/\(total) could not be read. Continuing with the rest…"
                    progress = Double(index + 1) / Double(total)
                }
            }
        }

        await MainActor.run {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                results = combined.sorted { lhs, rhs in
                    let li = lhs.catalogIndex ?? Int.max
                    let ri = rhs.catalogIndex ?? Int.max
                    return li == ri ? lhs.name < rhs.name : li < ri
                }
                failedScreenshotNames = failures
                progress = 1
                analyzing = false
                hasAnalyzed = true
            }

            if combined.isEmpty {
                scanText = failures.count == urls.count
                    ? "None of the selected screenshots could be analyzed."
                    : "No owned cards were confirmed. Use Collection screenshots with the 3-column grid and readable Lvl labels."
            } else {
                let failureSuffix = failures.isEmpty ? "" : " · \(failures.count) screenshot\(failures.count == 1 ? "" : "s") need review"
                scanText = "Batch complete · \(combined.count) unique Sprite\(combined.count == 1 ? "" : "s") confirmed\(failureSuffix). Review before applying."
            }
        }
    }

    private func analyzeVideo(_ fileURL: URL) async {
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            let found = try await VideoSpriteAnalyzer().analyze(
                url: fileURL,
                onProgress: { value, text in
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: 0.15)) {
                            progress = value
                        }
                        scanText = text
                    }
                }
            )

            await MainActor.run {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                    results = found
                    progress = 1
                    analyzing = false
                        hasAnalyzed = true
                }
                scanText = found.isEmpty
                    ? "No readable name and level found. Make sure each card is actually selected for about 1 second."
                    : "Review the detections before applying them."
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
                analyzing = false
                hasAnalyzed = true
            }
        }
    }

    private func mergeScreenshotDetections(
        _ existing: [DetectedSprite],
        with incoming: [DetectedSprite]
    ) -> [DetectedSprite] {
        var byName: [String: DetectedSprite] = [:]
        for detection in existing + incoming {
            let key = detection.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            guard let previous = byName[key] else {
                byName[key] = detection
                continue
            }

            let previousLevel = previous.level ?? 0
            let detectedLevel = detection.level ?? 0
            let mergedLevelValue = max(previousLevel, detectedLevel)
            let mergedLevel: Int? = mergedLevelValue == 0 ? nil : mergedLevelValue
            let mergedMastered = previous.mastered || detection.mastered || mergedLevel == 5
            let mergedStatus: SpriteCollectionStatus = (previous.status == .lost || detection.status == .lost) ? .lost : .collected

            byName[key] = DetectedSprite(
                name: detection.name,
                rarity: detection.rarity,
                status: mergedStatus,
                level: mergedLevel,
                mastered: mergedMastered,
                timestamp: max(previous.timestamp, detection.timestamp),
                observations: previous.observations + detection.observations,
                catalogIndex: detection.catalogIndex ?? previous.catalogIndex,
                gridSlot: detection.gridSlot ?? previous.gridSlot
            )
        }
        return Array(byName.values)
    }

    private func mediaKind(for url: URL) -> ImportedMediaKind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return .video
        }
        return type.conforms(to: .image) ? .screenshot : .video
    }

    private var isScreenshotImport: Bool {
        guard !fileURLs.isEmpty else { return false }
        return fileURLs.allSatisfy { mediaKind(for: $0) == .screenshot }
    }

    private var importIcon: String {
        guard !fileURLs.isEmpty else { return "rectangle.stack.badge.play" }
        return isScreenshotImport ? "photo.stack.fill" : "film.stack.fill"
    }

    private var selectionTitle: String {
        guard !fileURLs.isEmpty else { return "Choose a Fortnite recording or one/more screenshots" }
        if isScreenshotImport {
            return "\(fileURLs.count) screenshot\(fileURLs.count == 1 ? "" : "s") selected"
        }
        return fileURLs[0].lastPathComponent
    }

    private var selectionButtonTitle: String {
        if fileURLs.isEmpty { return "Choose Media" }
        return isScreenshotImport ? "Add More Screenshots" : "Choose Another"
    }

    private var importDescription: String {
        if isScreenshotImport {
            return "Batch screenshots are scanned one by one, then merged into one profile session. Duplicate Sprite matches are reconciled automatically and one unreadable image does not cancel the rest."
        }
        return "Recordings read the selected title, level, and Mastered banner from the high-resolution right-side details panel."
    }

    private var importHint: String {
        if isScreenshotImport {
            return "Select as many Collection screenshots as needed. Overlap is fine: duplicates are merged, higher confirmed levels win, and Level 5 becomes Mastered."
        }
        return "Select every card for about 1 second. Wrapped titles and the Mastered banner are supported."
    }

    private var analyzeButtonTitle: String {
        if isScreenshotImport {
            return fileURLs.count == 1 ? "Analyze Screenshot" : "Analyze \(fileURLs.count) Screenshots"
        }
        return "Analyze Recording"
    }

    private var mediaNoun: String {
        isScreenshotImport ? (fileURLs.count == 1 ? "screenshot" : "screenshot batch") : "recording"
    }

    private func resultSourceText(_ result: DetectedSprite) -> String {
        if isScreenshotImport {
            let evidence = result.observations > 1 ? " · \(result.observations)x evidence" : ""
            return "\(result.rarity.rawValue) · SCREENSHOT CARD\(evidence)"
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
            return isScreenshotImport ? "Analyzing screenshot batch…" : "Analyzing…"
        }
        if results.isEmpty {
            return "No confirmed Sprites"
        }
        return "Detected \(results.count) unique Sprite\(results.count == 1 ? "" : "s")"
    }
}

private enum ImportedMediaKind {
    case video
    case screenshot
}
