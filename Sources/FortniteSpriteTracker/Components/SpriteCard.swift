import SwiftUI

struct SpriteCard: View {
    let item: SpriteItem
    var highlighted: Bool = false
    let onOwned: () -> Void
    let onMastered: () -> Void
    let onLevel: (Int?) -> Void

    @State private var hovered = false
    @State private var burst = false
    @State private var sweep = false

    var body: some View {
        ZStack(alignment: .top) {
            cardContent(expanded: false)
                .opacity(hovered ? 0 : 1)

            if hovered {
                cardContent(expanded: true)
                    .frame(height: 365, alignment: .top)
                    .scaleEffect(1.065, anchor: .top)
                    .offset(y: -12)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.92, anchor: .top)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.97, anchor: .top)
                                .combined(with: .opacity)
                        )
                    )
            }
        }
        .frame(height: 286, alignment: .top)
        .zIndex(hovered ? 100 : highlighted ? 80 : 0)
        .shadow(color: .black.opacity(hovered ? 0.48 : 0.18), radius: hovered ? 26 : 7, y: hovered ? 15 : 5)
        .overlay {
            if burst {
                Image(systemName: "sparkles")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.yellow)
                    .symbolEffect(.variableColor.iterative, isActive: burst)
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72, blendDuration: 0.08)) {
                hovered = inside
                if inside { sweep.toggle() }
            }
        }
    }

    @ViewBuilder
    private func cardContent(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: expanded ? 8 : 10) {
            imagePanel(expanded: expanded)

            HStack(spacing: 8) {
                rarityBadge
                if item.isLost {
                    Text("LOST")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                statusIcon
            }

            Text(item.name)
                .font(.headline.weight(.heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            if expanded {
                Text(item.gameplayDescription)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.move(edge: .top).combined(with: .opacity))

                if let variantBonus = item.variantBonusDescription {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.yellow)
                        Text(variantBonus)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.yellow.opacity(0.92))
                            .lineLimit(2)
                    }
                }

                HStack(spacing: 6) {
                    infoChip(statusLabel, symbol: statusSymbol, highlighted: item.mastered)
                    if let level = item.level {
                        infoChip("LVL \(level)", symbol: "bolt.fill")
                    }
                    if item.mastered {
                        infoChip("MASTERED", symbol: "crown.fill", highlighted: true)
                    }
                }
            }

            controls
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: expanded ? 365 : 286, alignment: .top)
        .background(cardBackground(expanded: expanded))
        .overlay(alignment: .topLeading) {
            if expanded {
                Rectangle()
                    .fill(.yellow)
                    .frame(width: 92, height: 3)
                    .padding(.leading, 16)
                    .overlay {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, .white.opacity(0.18), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: 42, height: geometry.size.height * 2)
                                .rotationEffect(.degrees(14))
                                .offset(x: sweep ? geometry.size.width + 30 : -70, y: -20)
                                .animation(.easeOut(duration: 0.62), value: sweep)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .allowsHitTesting(false)
                    }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    highlighted ? Color.yellow.opacity(0.95) : Color.white.opacity(expanded ? 0.24 : 0.08),
                    lineWidth: highlighted ? 2.4 : expanded ? 1.5 : 1
                )
                .shadow(color: highlighted ? .yellow.opacity(0.35) : .clear, radius: 12)
        }
    }

    private func imagePanel(expanded: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(spriteBackdrop)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(expanded ? 0.15 : 0.07), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 74
                    )
                )
                .frame(width: 148, height: 148)

            CachedSpriteImage(assetName: item.imageAssetName, accessibilityLabel: item.name)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .scaleEffect(expanded ? 1.10 : 1)
                .rotationEffect(.degrees(expanded ? -1.5 : 0))
                .saturation(item.isLost ? 0.05 : item.isLocked ? 0.25 : 1)
                .opacity(item.isLost ? 0.58 : item.isLocked ? 0.42 : 1)
                .animation(.spring(response: 0.34, dampingFraction: 0.68), value: expanded)

            if item.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(height: expanded ? 147 : 154)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(expanded ? 0.20 : 0.07), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            levelBadge.padding(8)
        }
    }

    @ViewBuilder
    private var levelBadge: some View {
        if item.mastered {
            HStack(spacing: 4) {
                Image(systemName: "crown.fill")
                Text("LVL 5")
            }
            .font(.system(size: 9, weight: .black, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.yellow.opacity(0.92), in: Capsule())
            .foregroundStyle(.black)
        } else if let level = item.level {
            Text("LVL \(level)")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.88), in: Capsule())
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
                    .frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 48, height: 28)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
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

    private func infoChip(_ title: String, symbol: String, highlighted: Bool = false) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 8, weight: .black, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(highlighted ? Color.yellow.opacity(0.9) : Color.white.opacity(0.10), in: Capsule())
            .foregroundStyle(highlighted ? Color.black : Color.white.opacity(0.9))
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

    private func cardBackground(expanded: Bool) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(red: 0.115, green: 0.115, blue: 0.125).opacity(0.985))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        item.mastered ? Color.yellow.opacity(0.075) :
                        item.isLost ? Color.orange.opacity(0.05) :
                        item.owned ? Color.green.opacity(0.04) : Color.clear
                    )
            }
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
