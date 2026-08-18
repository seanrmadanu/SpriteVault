import SwiftUI

struct SpriteCard: View {
    let item: SpriteItem
    var highlighted: Bool = false
    let onOwned: () -> Void
    let onMastered: () -> Void
    let onLevel: (Int?) -> Void

    @State private var hovered = false
    @State private var burst = false

    private let cardHeight: CGFloat = 268

    var body: some View {
        card
            .frame(height: cardHeight)
            .zIndex(highlighted ? 100 : 0)
            .shadow(
                color: .black.opacity(0.16),
                radius: 6,
                x: 0,
                y: 4
            )
            .overlay {
                if burst {
                    Image(systemName: "sparkles")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.yellow)
                        .symbolEffect(.variableColor.iterative, isActive: burst)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovered = inside
            }
            .help(item.gameplayDescription)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 9) {
            imagePanel

            HStack(spacing: 7) {
                rarityBadge
                if item.isLost { lostBadge }
                Spacer(minLength: 4)
                statusIcon
            }

            Text(item.name)
                .font(.headline.weight(.heavy))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)

            controls
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    private var imagePanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(spriteBackdrop)

            CachedSpriteImage(assetName: item.imageAssetName, accessibilityLabel: item.name)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .saturation(item.isLost ? 0.05 : item.isLocked ? 0.25 : 1)
                .opacity(item.isLost ? 0.58 : item.isLocked ? 0.42 : 1)

            if item.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(.white.opacity(0.74))
            }
        }
        .frame(height: 146)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(hovered ? 0.18 : 0.07), lineWidth: 1)
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
                Text(item.level.map { "LVL \($0)" } ?? "MASTERED")
            }
            .font(.system(size: 10, weight: .black, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.yellow.opacity(0.94), in: Capsule())
            .foregroundStyle(.black)
        } else if let level = item.level {
            Text("LVL \(level)")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.9), in: Capsule())
                .foregroundStyle(.black)
        }
    }

    private var controls: some View {
        HStack(spacing: 7) {
            Button(action: onOwned) {
                Label(ownedButtonTitle, systemImage: item.owned ? "checkmark" : "plus")
                    .frame(maxWidth: .infinity)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.borderedProminent)
            .tint(item.owned ? .green.opacity(0.82) : .white.opacity(0.12))

            Menu {
                Section("Level") {
                    ForEach(1...5, id: \.self) { level in
                        Button {
                            onLevel(level)
                            if level == 5, !item.mastered {
                                burst = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { burst = false }
                            }
                        } label: {
                            Label("Level \(level)", systemImage: item.level == level ? "checkmark.circle.fill" : "\(level).circle")
                        }
                    }
                }
                Divider()
                Button(action: onMastered) {
                    Label(item.mastered ? "Clear Mastered" : "Mark Mastered", systemImage: item.mastered ? "crown" : "crown.fill")
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
            .frame(width: 44, height: 30)
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
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.white.opacity(0.10), in: Capsule())
    }

    private var lostBadge: some View {
        Text("LOST")
            .font(.system(size: 8, weight: .black, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }

    private var ownedButtonTitle: String {
        switch item.status {
        case .locked: return "Not owned"
        case .collected: return "Owned"
        case .lost: return "Lost"
        }
    }

    private var levelControlSymbol: String {
        if item.mastered { return "crown.fill" }
        if let level = item.level { return "\(level).circle.fill" }
        return "slider.horizontal.3"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(red: 0.105, green: 0.105, blue: 0.115).opacity(0.995))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        item.mastered ? Color.yellow.opacity(0.06) :
                        item.isLost ? Color.orange.opacity(0.04) :
                        item.owned ? Color.green.opacity(0.035) : Color.clear
                    )
            }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(
                highlighted ? Color.yellow.opacity(0.95) : Color.white.opacity(hovered ? 0.20 : 0.075),
                lineWidth: highlighted ? 2.2 : hovered ? 1.4 : 1
            )
    }

    private var spriteBackdrop: LinearGradient {
        let name = item.name.lowercased()
        let colors: [Color]
        if name.hasPrefix("gold ") { colors = [.yellow.opacity(0.52), .orange.opacity(0.20)] }
        else if name.hasPrefix("cube ") { colors = [.purple.opacity(0.56), .indigo.opacity(0.22)] }
        else if name.hasPrefix("gummy ") { colors = [.red.opacity(0.46), .pink.opacity(0.20)] }
        else if name.hasPrefix("galaxy ") { colors = [.indigo.opacity(0.57), .purple.opacity(0.24)] }
        else if name.hasPrefix("gem ") { colors = [.cyan.opacity(0.30), .white.opacity(0.11)] }
        else if name.hasPrefix("holofoil ") { colors = [.pink.opacity(0.46), .purple.opacity(0.21)] }
        else if name.hasPrefix("quack ") { colors = [.purple.opacity(0.42), .blue.opacity(0.18)] }
        else {
            switch item.rarity {
            case .rare: colors = [.blue.opacity(0.50), .cyan.opacity(0.15)]
            case .epic: colors = [.purple.opacity(0.52), .pink.opacity(0.17)]
            case .legendary: colors = [.orange.opacity(0.52), .yellow.opacity(0.15)]
            case .mythic: colors = [.yellow.opacity(0.48), .orange.opacity(0.15)]
            case .special: colors = [.purple.opacity(0.42), .blue.opacity(0.15)]
            }
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
