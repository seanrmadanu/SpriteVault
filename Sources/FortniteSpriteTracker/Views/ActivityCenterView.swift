import SwiftUI

struct ActivityCenterView: View {
    @EnvironmentObject private var activityStore: ActivityStore
    @EnvironmentObject private var store: SpriteStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVITY")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .tracking(1.2)
                    Text("Recent Sprite scans and collection changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !activityStore.events.isEmpty {
                    Button("Clear") { activityStore.clear() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()

            if activityStore.events.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "bell.slash",
                    description: Text("Scan results, new Sprites, level changes, mastery, and lost-Sprite updates will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(activityStore.recentEvents) { event in
                            activityCard(event)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 430, height: 540)
        .background(.ultraThinMaterial)
        .onAppear { activityStore.markAllRead() }
    }

    private func activityCard(_ event: ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: event.kind.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(kindColor(event.kind))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.subheadline.weight(.bold))
                    Text(event.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
                Text(event.date, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if let spriteName = event.spriteName {
                Button {
                    openSprite(spriteName)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                        Text("Show \(spriteName)")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.caption.weight(.bold))
                }
                .buttonStyle(.bordered)
            }

            if let summary = event.summary, summary.totalChanges > 0 {
                summarySection("NEW", names: summary.newSprites, symbol: "sparkles")
                summarySection("LEVELED UP", names: summary.levelUps, symbol: "arrow.up.circle.fill")
                summarySection("MASTERED", names: summary.mastered, symbol: "crown.fill")
                summarySection("LOST", names: summary.lost, symbol: "clock.arrow.circlepath")
            }
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08))
        }
    }

    @ViewBuilder
    private func summarySection(_ title: String, names: [String], symbol: String) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        Button(name) { openSprite(name) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func openSprite(_ name: String) {
        store.focusSprite(named: name)
        dismiss()
    }

    private func kindColor(_ kind: ActivityKind) -> Color {
        switch kind {
        case .newSprite: return .green
        case .mastered: return .yellow
        case .levelUp: return .cyan
        case .lost: return .orange
        case .error: return .red
        case .scanStarted: return .green
        case .scanCompleted: return .green
        case .scanStopped: return .secondary
        }
    }
}

/// Small wrapping layout so a scan summary can show clickable Sprite names
/// without becoming a single horizontally scrolling line.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + (x == 0 ? 0 : spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
