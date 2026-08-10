import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: SpriteStore
    @State private var showImporter = false
    @State private var showFilters = false
    @State private var toastVisible = false
    @State private var sparkle = false
    @State private var showResetConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    var body: some View {
        let filteredSprites = store.filteredSprites

        ZStack {
            AnimatedBackground()

            VStack(spacing: 0) {
                header
                filters

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filteredSprites) { item in
                            SpriteCard(
                                item: item,
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
                        }
                    }
                    .padding(22)
                    .animation(.spring(response: 0.42, dampingFraction: 0.85), value: filteredSprites.count)
                }
            }

            if toastVisible, let event = store.recentEvent {
                toast(event)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    .zIndex(20)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showImporter) { VideoImportSheet().environmentObject(store) }
        .alert("Clear all tracking data?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { store.reset() }
        } message: {
            Text("This removes all owned, level, and mastery values.")
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
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SPRITE VAULT")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .tracking(1.8)
                Text("Fortnite collection checklist")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ProgressPill(title: "Owned", value: store.ownedCount, total: store.sprites.count, symbol: "checkmark")
            ProgressPill(title: "Mastered", value: store.masteredCount, total: store.sprites.count, symbol: "crown.fill")
                .symbolEffect(.pulse, value: sparkle)

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { showImporter = true }
            } label: {
                Label("Import Recording", systemImage: "wand.and.stars.inverse")
                    .fontWeight(.bold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
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

                Button("Clear All") {
                    showResetConfirmation = true
                }
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

    private func toast(_ event: SpriteEvent) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: event.kind == .mastered ? "crown.fill" : event.kind == .owned ? "checkmark.circle.fill" : "minus.circle.fill")
                    .foregroundStyle(event.kind == .mastered ? .yellow : event.kind == .owned ? .green : .secondary)
                    .symbolEffect(.bounce, value: toastVisible)
                Text(event.kind == .mastered ? "\(event.name) mastered — Level 5" : event.kind == .owned ? "\(event.name) added" : "\(event.name) removed")
                    .fontWeight(.bold)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14)))
            .shadow(radius: 18, y: 8)
            Spacer()
        }
        .padding(.top, 14)
    }
}
