import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: SpriteStore
    @EnvironmentObject private var liveCapture: LiveCaptureManager
    @EnvironmentObject private var activityStore: ActivityStore

    @State private var activeSheet: ContentSheet?
    @State private var showFilters = false
    @State private var toastVisible = false
    @State private var sparkle = false
    @State private var showResetConfirmation = false
    @State private var showDeleteProfileConfirmation = false
    @State private var isExportingPDF = false
    @State private var statusMessage: AppStatusMessage?
    @State private var showActivityCenter = false
    @State private var highlightedSpriteName: String?

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    var body: some View {
        let filteredSprites = store.filteredSprites

        ZStack {
            AnimatedBackground()

            VStack(spacing: 0) {
                header
                filters

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filteredSprites) { item in
                                SpriteCard(
                                    item: item,
                                    highlighted: highlightedSpriteName == item.name,
                                    onOwned: {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                                            store.toggleOwned(item)
                                        }
                                    },
                                    onMastered: {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                                            store.toggleMastered(item)
                                        }
                                    },
                                    onLevel: { level in
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                                            store.setLevel(level, for: item)
                                        }
                                    }
                                )
                                .id(item.name)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 34)
                        .padding(.bottom, 100)
                        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: filteredSprites.count)
                    }
                    .scrollClipDisabled()
                    .onChange(of: store.focusRequest) { _, request in
                        guard let request else { return }
                        highlightedSpriteName = request.name
                        withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) {
                            proxy.scrollTo(request.name, anchor: .center)
                        }
                        Task {
                            try? await Task.sleep(for: .seconds(2.5))
                            await MainActor.run {
                                guard highlightedSpriteName == request.name else { return }
                                withAnimation(.easeOut(duration: 0.3)) {
                                    highlightedSpriteName = nil
                                }
                            }
                        }
                    }
                }
            }

            if let statusMessage {
                appStatusToast(statusMessage)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92)))
                    .zIndex(300)
            } else if toastVisible, let event = store.recentEvent {
                spriteToast(event)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    .zIndex(300)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .importer:
                VideoImportSheet(initialProfileID: store.selectedProfileID)
                    .environmentObject(store)
            case .liveCapture:
                LiveCaptureSheet()
                    .environmentObject(store)
                    .environmentObject(liveCapture)
                    .environmentObject(activityStore)
            case .profileEditor(let mode):
                ProfileEditorSheet(mode: mode)
                    .environmentObject(store)
            case .comparison(let primaryID, let comparisonID):
                ProfileComparisonSheet(
                    primaryProfileID: primaryID,
                    initialComparisonProfileID: comparisonID
                )
                .environmentObject(store)
            }
        }
        .alert("Clear \(store.selectedProfileName)?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Profile", role: .destructive) { store.reset() }
        } message: {
            Text("This removes unlocked, lost, level, and mastery values only from this profile. Other profiles are not changed.")
        }
        .confirmationDialog(
            "Delete \(store.selectedProfileName)?",
            isPresented: $showDeleteProfileConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                store.deleteProfile(store.selectedProfileID)
                showStatus("Profile deleted", symbol: "trash.fill", isError: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes this profile and its collection data. The last remaining profile cannot be deleted.")
        }
        .onAppear {
            liveCapture.installGlobalHotkey(store: store, activityStore: activityStore)
            if liveCapture.targetProfileID == nil {
                liveCapture.targetProfileID = store.selectedProfileID
            }
            routePendingNotificationIfNeeded()
            Task { await liveCapture.refreshSources() }
        }
        .onChange(of: store.selectedProfileID) { _, id in
            if !liveCapture.isHotkeyScanning {
                liveCapture.targetProfileID = id
            }
        }
        .onChange(of: liveCapture.resultRevision) { _, _ in
            guard !liveCapture.latestDetections.isEmpty else { return }
            let targetID = liveCapture.targetProfileID ?? store.selectedProfileID
            guard let profile = store.profile(withID: targetID) else { return }

            let summary = store.applyDetections(
                liveCapture.latestDetections,
                to: targetID,
                replacingExisting: false
            )
            liveCapture.reportAppliedChanges(summary, profileName: profile.name)

            if !liveCapture.isStreaming {
                showStatus(
                    "Captured \(liveCapture.latestDetections.count) Sprite card\(liveCapture.latestDetections.count == 1 ? "" : "s") into \(profile.name)",
                    symbol: "camera.viewfinder",
                    isError: false
                )
            }
        }
        .onChange(of: store.recentEvent) { _, event in
            guard event != nil else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) { toastVisible = true }
            if event?.kind == .mastered { sparkle.toggle() }
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.25)) { toastVisible = false }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spriteNotificationSelected)) { note in
            guard let name = note.userInfo?["spriteName"] as? String else { return }
            _ = AppNotificationService.shared.consumePendingDestination()
            showActivityCenter = false
            store.focusSprite(named: name)
        }
        .onReceive(NotificationCenter.default.publisher(for: .activityNotificationSelected)) { _ in
            _ = AppNotificationService.shared.consumePendingDestination()
            showActivityCenter = true
        }
    }

    private func routePendingNotificationIfNeeded() {
        guard let destination = AppNotificationService.shared.consumePendingDestination() else { return }
        switch destination {
        case .sprite(let name):
            showActivityCenter = false
            store.focusSprite(named: name)
        case .activity:
            showActivityCenter = true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("SPRITE VAULT")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .tracking(1.8)
                Text("Fortnite collection checklist")
                    .foregroundStyle(.secondary)
                profileMenu
            }

            Spacer(minLength: 18)

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressPill(title: "Owned", value: store.ownedCount, total: store.sprites.count, symbol: "checkmark")
                    ProgressPill(title: "Mastered", value: store.masteredCount, total: store.sprites.count, symbol: "crown.fill")
                        .symbolEffect(.pulse, value: sparkle)
                    if store.lostCount > 0 {
                        ProgressPill(title: "Lost", value: store.lostCount, total: store.sprites.count, symbol: "clock.arrow.circlepath")
                    }
                }

                HStack(spacing: 9) {
                    Button {
                        presentComparison()
                    } label: {
                        Label("Compare", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.profiles.count < 2)

                    Button(action: exportPDF) {
                        Label(isExportingPDF ? "Exporting..." : "Export PDF", systemImage: isExportingPDF ? "hourglass" : "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExportingPDF || store.selectedProfile == nil)

                    Button {
                        showActivityCenter.toggle()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Label("Activity", systemImage: "bell")
                            if activityStore.unreadCount > 0 {
                                Text("\(min(activityStore.unreadCount, 99))")
                                    .font(.system(size: 8, weight: .black, design: .rounded))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.red, in: Capsule())
                                    .foregroundStyle(.white)
                                    .offset(x: 9, y: -7)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showActivityCenter, arrowEdge: .top) {
                        ActivityCenterView()
                            .environmentObject(activityStore)
                            .environmentObject(store)
                    }

                    LiveCaptureHeaderButton(liveCapture: liveCapture) {
                        activeSheet = .liveCapture
                    }

                    Button {
                        activeSheet = .importer
                    } label: {
                        Label("Import Media", systemImage: "wand.and.stars.inverse")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var profileMenu: some View {
        Menu {
            Section("Switch Profile") {
                ForEach(store.profiles) { profile in
                    Button {
                        store.selectProfile(profile.id)
                    } label: {
                        Label(
                            profile.name,
                            systemImage: profile.id == store.selectedProfileID
                                ? "checkmark.circle.fill"
                                : "person.crop.circle"
                        )
                    }
                }
            }

            Divider()

            Button {
                activeSheet = .profileEditor(.create)
            } label: {
                Label("New Profile", systemImage: "person.crop.circle.badge.plus")
            }

            Button {
                activeSheet = .profileEditor(
                    .rename(profileID: store.selectedProfileID, currentName: store.selectedProfileName)
                )
            } label: {
                Label("Rename Current Profile", systemImage: "pencil")
            }

            Button(role: .destructive) {
                showDeleteProfileConfirmation = true
            } label: {
                Label("Delete Current Profile", systemImage: "trash")
            }
            .disabled(!store.canDeleteProfile)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.cyan)
                Text(store.selectedProfileName)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text("\(store.profiles.count)")
                    .font(.caption2.monospacedDigit().weight(.black))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.10), in: Capsule())
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var filters: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    NativeSearchField(text: $store.searchText, placeholder: "Search all 117 Sprites")
                        .frame(minWidth: 260, minHeight: 30)

                    if !store.searchText.isEmpty {
                        Text("\(store.filteredSprites.count) found")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { showFilters.toggle() }
                } label: {
                    Label("Filters", systemImage: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.bordered)

                Button("Clear Profile") { showResetConfirmation = true }
                    .buttonStyle(.bordered)
            }

            if showFilters {
                HStack(spacing: 8) {
                    filterChip("All", selected: store.selectedRarity == nil) { store.selectedRarity = nil }
                    ForEach(SpriteRarity.allCases, id: \.self) { rarity in
                        filterChip(rarity.rawValue.capitalized, selected: store.selectedRarity == rarity) { store.selectedRarity = rarity }
                    }
                    Divider().frame(height: 22)
                    Toggle("Owned", isOn: Binding(
                        get: { store.showOnlyOwned },
                        set: { store.setOwnedFilter($0) }
                    ))
                    .toggleStyle(.button)

                    Toggle("Not Owned", isOn: Binding(
                        get: { store.showOnlyNotOwned },
                        set: { store.setNotOwnedFilter($0) }
                    ))
                    .toggleStyle(.button)

                    Toggle("Mastered", isOn: Binding(
                        get: { store.showOnlyMastered },
                        set: { store.setMasteredFilter($0) }
                    ))
                    .toggleStyle(.button)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.caption.weight(.bold)) }
            .buttonStyle(.borderedProminent)
            .tint(selected ? .white.opacity(0.22) : .white.opacity(0.07))
            .scaleEffect(selected ? 1.03 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
    }

    private func spriteToast(_ event: SpriteEvent) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: event.kind == .mastered ? "crown.fill" : event.kind == .owned ? "checkmark.circle.fill" : "minus.circle.fill")
                    .foregroundStyle(event.kind == .mastered ? .yellow : event.kind == .owned ? .green : .secondary)
                    .symbolEffect(.bounce, value: toastVisible)
                Text(event.kind == .mastered ? "\(event.name) mastered - Level 5" : event.kind == .owned ? "\(event.name) added" : "\(event.name) removed")
                    .fontWeight(.bold)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14)))
            .shadow(radius: 18, y: 8)
            Spacer()
        }
        .padding(.top, 14)
    }

    private func appStatusToast(_ message: AppStatusMessage) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: message.symbol)
                    .foregroundStyle(message.isError ? .red : .green)
                Text(message.text)
                    .fontWeight(.bold)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke((message.isError ? Color.red : Color.white).opacity(0.18)))
            .shadow(radius: 18, y: 8)
            Spacer()
        }
        .padding(.top, 14)
    }

    private func presentComparison() {
        guard let comparisonProfile = store.profiles.first(where: { $0.id != store.selectedProfileID }) else {
            showStatus("Create a second profile before comparing.", symbol: "person.crop.circle.badge.plus", isError: true)
            return
        }
        activeSheet = .comparison(primaryID: store.selectedProfileID, comparisonID: comparisonProfile.id)
    }

    private func exportPDF() {
        guard !isExportingPDF, let profile = store.selectedProfile else { return }
        isExportingPDF = true

        Task { @MainActor in
            await Task.yield()
            defer { isExportingPDF = false }

            do {
                if let url = try CollectionPDFExporter.export(profile: profile) {
                    showStatus("Exported \(url.lastPathComponent)", symbol: "doc.fill", isError: false)
                }
            } catch {
                showStatus(error.localizedDescription, symbol: "exclamationmark.triangle.fill", isError: true)
            }
        }
    }

    private func showStatus(_ text: String, symbol: String, isError: Bool) {
        let message = AppStatusMessage(text: text, symbol: symbol, isError: isError)
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            statusMessage = message
        }

        Task {
            try? await Task.sleep(for: .seconds(isError ? 3.5 : 2.3))
            await MainActor.run {
                guard statusMessage?.id == message.id else { return }
                withAnimation(.easeOut(duration: 0.25)) { statusMessage = nil }
            }
        }
    }
}

private enum ContentSheet: Identifiable {
    case importer
    case liveCapture
    case profileEditor(ProfileEditorMode)
    case comparison(primaryID: UUID, comparisonID: UUID)

    var id: String {
        switch self {
        case .importer: return "importer"
        case .liveCapture: return "live-capture"
        case .profileEditor(let mode):
            switch mode {
            case .create: return "profile-create"
            case .rename(let profileID, _): return "profile-rename-\(profileID.uuidString)"
            }
        case .comparison(let primaryID, let comparisonID):
            return "comparison-\(primaryID.uuidString)-\(comparisonID.uuidString)"
        }
    }
}

private struct AppStatusMessage: Identifiable {
    let id = UUID()
    let text: String
    let symbol: String
    let isError: Bool
}
