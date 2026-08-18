import SwiftUI
import AppKit

struct SpriteCard: View {
    let item: SpriteItem
    var highlighted: Bool = false
    let onOwned: () -> Void
    let onMastered: () -> Void
    let onLevel: (Int?) -> Void

    @State private var hovered = false
    @State private var burst = false
    @State private var sweep = false
    @State private var collapseTask: Task<Void, Never>?

    private let normalHeight: CGFloat = 286
    private let expandedWidth: CGFloat = 330
    private let expandedHeight: CGFloat = 500

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                compactCard
                    .opacity(hovered ? 0.18 : 1)

                if hovered {
                    expandedCard
                        .frame(width: expandedWidth, height: expandedHeight, alignment: .top)
                        .offset(x: horizontalCorrection(for: geometry), y: -18)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.88, anchor: .top)
                                    .combined(with: .opacity),
                                removal: .scale(scale: 0.96, anchor: .top)
                                    .combined(with: .opacity)
                            )
                        )
                        .onHover { inside in
                            if inside {
                                keepExpanded()
                            } else {
                                scheduleCollapse()
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: normalHeight)
        .zIndex(hovered ? 500 : highlighted ? 80 : 0)
        .shadow(color: .black.opacity(hovered ? 0.62 : 0.18), radius: hovered ? 34 : 7, y: hovered ? 18 : 5)
        .overlay {
            if burst {
                Image(systemName: "sparkles")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.yellow)
                    .symbolEffect(.variableColor.iterative, isActive: burst)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                keepExpanded()
            } else {
                scheduleCollapse()
            }
        }
        .onDisappear {
            collapseTask?.cancel()
        }
    }

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            imagePanel(height: 154, imageScale: 1)

            HStack(spacing: 8) {
                rarityBadge
                if item.isLost { lostBadge }
                Spacer()
                statusIcon
            }

            Text(item.name)
                .font(.headline.weight(.heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            controls
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: normalHeight, alignment: .top)
        .background(cardBackground)
        .overlay(cardBorder(expanded: false))
    }

    /// The hover state is intentionally a complete, larger version of the card
    /// rather than a detached tooltip. It floats above the grid without changing
    /// neighboring card positions, matching the Fortnite "selected item" feel.
    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            imagePanel(height: 230, imageScale: 1.08)

            HStack(spacing: 8) {
                rarityBadge
                if item.isLost { lostBadge }
                Spacer()
                statusIcon
            }

            Text(item.name)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Text(item.gameplayDescription)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if let variantBonus = item.variantBonusDescription {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.yellow)
                    Text(variantBonus)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.yellow.opacity(0.95))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 7) {
                infoChip(statusLabel, symbol: statusSymbol, highlighted: item.mastered)
                if let level = item.level {
                    infoChip("LVL \(level)", symbol: "bolt.fill")
                }
                if item.mastered {
                    infoChip("MASTERED", symbol: "crown.fill", highlighted: true)
                }
            }

            Spacer(minLength: 0)
            controls
        }
        .padding(14)
        .frame(width: expandedWidth, height: expandedHeight, alignment: .topLeading)
        .background(cardBackground)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(.yellow)
                .frame(width: 130, height: 4)
                .padding(.leading, 20)
                .overlay {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.26), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 58, height: geometry.size.height * 2)
                            .rotationEffect(.degrees(14))
                            .offset(x: sweep ? geometry.size.width + 35 : -80, y: -20)
                            .animation(.easeOut(duration: 0.7), value: sweep)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .allowsHitTesting(false)
                }
        }
        .overlay(cardBorder(expanded: true))
        .shadow(color: .yellow.opacity(0.08), radius: 26)
    }

    private func imagePanel(height: CGFloat, imageScale: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(spriteBackdrop)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.14), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: height * 0.55
                    )
                )
                .frame(width: height * 0.95, height: height * 0.95)

            CachedSpriteImage(assetName: item.imageAssetName, accessibilityLabel: item.name)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(height > 200 ? 14 : 8)
                .scaleEffect(imageScale)
                .rotationEffect(.degrees(hovered ? -1.2 : 0))
                .saturation(item.isLost ? 0.05 : item.isLocked ? 0.25 : 1)
                .opacity(item.isLost ? 0.58 : item.isLocked ? 0.42 : 1)
                .animation(.spring(response: 0.36, dampingFraction: 0.72), value: hovered)

            if item.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: height > 200 ? 42 : 30, weight: .black))
                    .foregroundStyle(.white.opacity(0.74))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(hovered ? 0.19 : 0.07), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            levelBadge.padding(10)
        }
    }

    @ViewBuilder
    private var levelBadge: some View {
        if item.mastered {
            HStack(spacing: 4) {
                Image(systemName: "crown.fill")
                Text("LVL 5")
            }
            .font(.system(size: 10, weight: .black, design: .rounded))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.yellow.opacity(0.94), in: Capsule())
            .foregroundStyle(.black)
        } else if let level = item.level {
            Text("LVL \(level)")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.white.opacity(0.9), in: Capsule())
                .foregroundStyle(.black)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: onOwned) {
                Label(ownedButtonTitle, systemImage: item.owned ? "checkmark" : "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(item.owned ? .green.opacity(0.85) : .white.opacity(0.12))

            Menu {
                Section("Current level") {
                    ForEach(1...5, id: \.self) { level in
                        Button {
                            onLevel(level)
                            if level == 5, !item.mastered {
                                burst = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { burst = false }
                            }
                        } label: {
                            Label("Level \(level)", systemImage: item.level == level ? "checkmark.circle.fill" : "\(level).circle")
                        }
                    }
                }
                Divider()
                Button(action: onMastered) {
                    Label(item.mastered ? "Clear Level 5" : "Set Level 5 (Mastered)", systemImage: item.mastered ? "crown" : "crown.fill")
                }
                Button { onLevel(nil) } label: {
                    Label("Clear Level", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: levelControlSymbol)
                    .foregroundStyle(item.mastered ? Color.yellow : Color.primary)
                    .frame(width: 26, height: 22)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 50, height: 30)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var statusIcon: some View {
        Group {
            if item.mastered {
                Image(systemName: "crown.fill").foregroundStyle(.yellow)
            } else if item.isLost {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
            } else if item.owned {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
        }
    }

    private var rarityBadge: some View {
        Text(item.rarity.rawValue)
            .font(.system(size: 9, weight: .black, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.12), in: Capsule())
    }

    private var lostBadge: some View {
        Text("LOST")
            .font(.system(size: 8, weight: .black, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }

    private func infoChip(_ title: String, symbol: String, highlighted: Bool = false) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 8.5, weight: .black, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(highlighted ? Color.yellow.opacity(0.9) : Color.white.opacity(0.10), in: Capsule())
            .foregroundStyle(highlighted ? Color.black : Color.white.opacity(0.92))
    }

    private var ownedButtonTitle: String {
        switch item.status {
        case .locked: return "Not owned"
        case .collected: return "Owned"
        case .lost: return "Collected · Lost"
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .locked: return "LOCKED"
        case .collected: return "OWNED"
        case .lost: return "LOST"
        }
    }

    private var statusSymbol: String {
        switch item.status {
        case .locked: return "lock.fill"
        case .collected: return "checkmark.circle.fill"
        case .lost: return "clock.arrow.circlepath"
        }
    }

    private var levelControlSymbol: String {
        if item.mastered { return "crown.fill" }
        if let level = item.level { return "\(level).circle.fill" }
        return "slider.horizontal.3"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: hovered ? 24 : 20, style: .continuous)
            .fill(Color(red: 0.115, green: 0.115, blue: 0.125).opacity(0.992))
            .overlay {
                RoundedRectangle(cornerRadius: hovered ? 24 : 20, style: .continuous)
                    .fill(
                        item.mastered ? Color.yellow.opacity(0.075) :
                        item.isLost ? Color.orange.opacity(0.05) :
                        item.owned ? Color.green.opacity(0.04) : Color.clear
                    )
            }
    }

    private func cardBorder(expanded: Bool) -> some View {
        RoundedRectangle(cornerRadius: expanded ? 24 : 20, style: .continuous)
            .stroke(
                highlighted ? Color.yellow.opacity(0.95) : Color.white.opacity(expanded ? 0.26 : 0.08),
                lineWidth: highlighted ? 2.4 : expanded ? 1.6 : 1
            )
            .shadow(color: highlighted ? .yellow.opacity(0.35) : .clear, radius: 12)
    }

    private func keepExpanded() {
        collapseTask?.cancel()
        collapseTask = nil
        guard !hovered else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.74, blendDuration: 0.08)) {
            hovered = true
            sweep.toggle()
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    hovered = false
                }
            }
        }
    }

    /// Keep the expanded card inside the main window at the left/right edges.
    private func horizontalCorrection(for geometry: GeometryProxy) -> CGFloat {
        let cardFrame = geometry.frame(in: .global)
        let windowWidth = NSApp.keyWindow?.contentView?.bounds.width ?? 1200
        let margin: CGFloat = 16
        let desiredLeft = cardFrame.midX - expandedWidth / 2
        let desiredRight = cardFrame.midX + expandedWidth / 2

        if desiredLeft < margin {
            return margin - desiredLeft
        }
        if desiredRight > windowWidth - margin {
            return (windowWidth - margin) - desiredRight
        }
        return 0
    }

    private var spriteBackdrop: LinearGradient {
        let name = item.name.lowercased()
        let colors: [Color]
        if name.hasPrefix("gold ") { colors = [.yellow.opacity(0.58), .orange.opacity(0.24)] }
        else if name.hasPrefix("cube ") { colors = [.purple.opacity(0.64), .indigo.opacity(0.25)] }
        else if name.hasPrefix("gummy ") { colors = [.red.opacity(0.52), .pink.opacity(0.24)] }
        else if name.hasPrefix("galaxy ") { colors = [.indigo.opacity(0.65), .purple.opacity(0.28)] }
        else if name.hasPrefix("gem ") { colors = [.cyan.opacity(0.34), .white.opacity(0.13)] }
        else if name.hasPrefix("holofoil ") { colors = [.pink.opacity(0.52), .purple.opacity(0.24)] }
        else if name.hasPrefix("quack ") { colors = [.purple.opacity(0.48), .blue.opacity(0.2)] }
        else {
            switch item.rarity {
            case .rare: colors = [.blue.opacity(0.56), .cyan.opacity(0.18)]
            case .epic: colors = [.purple.opacity(0.58), .pink.opacity(0.2)]
            case .legendary: colors = [.orange.opacity(0.58), .yellow.opacity(0.17)]
            case .mythic: colors = [.yellow.opacity(0.54), .orange.opacity(0.17)]
            case .special: colors = [.purple.opacity(0.48), .blue.opacity(0.17)]
            }
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
