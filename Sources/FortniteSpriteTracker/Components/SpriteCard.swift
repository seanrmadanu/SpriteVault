import SwiftUI

struct SpriteCard: View {
    let item: SpriteItem
    let onOwned: () -> Void
    let onMastered: () -> Void
    let onLevel: (Int?) -> Void

    @State private var hovered = false
    @State private var burst = false
    @State private var showHoverInfo = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            imagePanel

            HStack(spacing: 8) {
                rarityBadge
                Spacer()
                statusIcon
            }

            Text(item.name)
                .font(.headline.weight(.heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            HStack(spacing: 8) {
                Button(action: onOwned) {
                    Label(item.owned ? "Owned" : "Not owned", systemImage: item.owned ? "checkmark" : "plus")
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
                                Label(
                                    "Level \(level)",
                                    systemImage: item.level == level ? "checkmark.circle.fill" : "\(level).circle"
                                )
                            }
                        }
                    }

                    Divider()

                    Button {
                        onMastered()
                    } label: {
                        Label(
                            item.mastered ? "Clear Level 5" : "Set Level 5 (Mastered)",
                            systemImage: item.mastered ? "crown" : "crown.fill"
                        )
                    }

                    Button {
                        onLevel(nil)
                    } label: {
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
                .help("Set the exact level or Mastered crown")
            }
        }
        .padding(12)
        .frame(height: 286)
        .background(cardBackground)
        .overlay(alignment: .center) {
            if burst {
                Image(systemName: "sparkles")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.yellow)
                    .transition(.scale.combined(with: .opacity))
                    .symbolEffect(.variableColor.iterative, isActive: burst)
            }
        }
        .overlay(alignment: .top) {
            if showHoverInfo {
                FortniteSpriteHoverInfo(item: item)
                    .frame(width: 270)
                    .offset(y: 7)
                    .allowsHitTesting(false)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom)
                                .combined(with: .scale(scale: 0.88, anchor: .bottom))
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.94, anchor: .bottom)
                                .combined(with: .opacity)
                        )
                    )
            }
        }
        .zIndex(showHoverInfo ? 50 : 0)
        .scaleEffect(hovered ? 1.025 : 1)
        .rotation3DEffect(.degrees(hovered ? 1.8 : 0), axis: (x: -0.6, y: 1, z: 0))
        .shadow(color: .black.opacity(hovered ? 0.32 : 0.17), radius: hovered ? 16 : 6, y: hovered ? 9 : 4)
        .onHover { inside in
            hoverTask?.cancel()

            if inside {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                    hovered = true
                }

                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(160))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) {
                            showHoverInfo = true
                        }
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    hovered = false
                    showHoverInfo = false
                }
            }
        }
        .onDisappear {
            hoverTask?.cancel()
        }
    }

    private var imagePanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(spriteBackdrop)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(hovered ? 0.14 : 0.07), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 72
                    )
                )
                .frame(width: 144, height: 144)
                .scaleEffect(hovered ? 1.1 : 0.9)

            spriteImage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .scaleEffect(hovered ? 1.08 : 1)
                .rotationEffect(.degrees(hovered ? -1.5 : 0))
                .animation(.spring(response: 0.35, dampingFraction: 0.68), value: hovered)
        }
        .frame(height: 154)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(hovered ? 0.2 : 0.07), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if item.mastered {
                HStack(spacing: 4) {
                    Image(systemName: "crown.fill")
                    Text(item.level == 5 ? "LVL 5" : "MASTERED")
                }
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.yellow.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
            } else if let level = item.level {
                Text("LVL \(level)")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private var spriteImage: some View {
        CachedSpriteImage(
            assetName: item.imageAssetName,
            accessibilityLabel: item.name
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        if item.mastered {
            Image(systemName: "crown.fill")
                .symbolEffect(.bounce, value: item.mastered)
                .foregroundStyle(.yellow)
        } else if item.owned {
            Image(systemName: "checkmark.circle.fill")
                .symbolEffect(.bounce, value: item.owned)
                .foregroundStyle(.green)
        }
    }

    private var rarityBadge: some View {
        Text(item.rarity.rawValue)
            .font(.system(size: 9, weight: .black, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.12), in: Capsule())
    }

    private var levelControlSymbol: String {
        if item.mastered {
            return "crown.fill"
        }
        if let level = item.level {
            return "\(level).circle.fill"
        }
        return "slider.horizontal.3"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(red: 0.115, green: 0.115, blue: 0.125).opacity(0.96))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(item.mastered ? .yellow.opacity(0.08) : item.owned ? .green.opacity(0.05) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(hovered ? .white.opacity(0.24) : .white.opacity(0.08), lineWidth: hovered ? 1.5 : 1)
            }
    }

    private var spriteBackdrop: LinearGradient {
        let name = item.name.lowercased()
        let colors: [Color]

        if name.hasPrefix("gold ") {
            colors = [.yellow.opacity(0.58), .orange.opacity(0.24)]
        } else if name.hasPrefix("cube ") {
            colors = [.purple.opacity(0.64), .indigo.opacity(0.25)]
        } else if name.hasPrefix("gummy ") {
            colors = [.red.opacity(0.52), .pink.opacity(0.24)]
        } else if name.hasPrefix("galaxy ") {
            colors = [.indigo.opacity(0.65), .purple.opacity(0.28)]
        } else if name.hasPrefix("gem ") {
            colors = [.cyan.opacity(0.34), .white.opacity(0.13)]
        } else if name.hasPrefix("holofoil ") {
            colors = [.pink.opacity(0.52), .purple.opacity(0.24)]
        } else if name.hasPrefix("quack ") {
            colors = [.purple.opacity(0.48), .blue.opacity(0.2)]
        } else {
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


private struct FortniteSpriteHoverInfo: View {
    let item: SpriteItem
    @State private var sweep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("SPRITE INTEL", systemImage: "scope")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.yellow)

                Spacer()

                Text(item.rarity.rawValue)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.yellow.opacity(0.92), in: Capsule())
                    .foregroundStyle(.black)
            }

            Text(item.name.uppercased())
                .font(.system(size: 17, weight: .black, design: .rounded))
                .italic()
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(item.gameplayDescription)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            if let variantBonus = item.variantBonusDescription {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.yellow)
                    Text(variantBonus)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.yellow.opacity(0.92))
                }
            }

            HStack(spacing: 7) {
                hoverChip(
                    item.owned ? "OWNED" : "LOCKED",
                    symbol: item.owned ? "checkmark.circle.fill" : "lock.fill"
                )

                if let level = item.level {
                    hoverChip("LVL \(level)", symbol: "bolt.fill")
                }

                if item.mastered {
                    hoverChip("MASTERED", symbol: "crown.fill", highlighted: true)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background {
            FortniteInfoShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.045, green: 0.055, blue: 0.12),
                            Color(red: 0.11, green: 0.07, blue: 0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    FortniteInfoShape()
                        .stroke(.yellow.opacity(0.72), lineWidth: 1.2)
                }
        }
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(.yellow)
                .frame(width: 112, height: 4)
                .offset(x: 16, y: 1)
        }
        .overlay {
            GeometryReader { geometry in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.13), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 48, height: geometry.size.height * 1.6)
                    .rotationEffect(.degrees(16))
                    .offset(
                        x: sweep ? geometry.size.width + 40 : -80,
                        y: -geometry.size.height * 0.25
                    )
            }
            .clipShape(FortniteInfoShape())
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.58), radius: 22, y: 12)
        .shadow(color: .yellow.opacity(0.12), radius: 12)
        .onAppear {
            sweep = false
            withAnimation(.easeOut(duration: 0.62)) {
                sweep = true
            }
        }
    }

    private func hoverChip(
        _ title: String,
        symbol: String,
        highlighted: Bool = false
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 8, weight: .black, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                highlighted ? Color.yellow.opacity(0.9) : Color.white.opacity(0.10),
                in: Capsule()
            )
            .foregroundStyle(highlighted ? Color.black : Color.white.opacity(0.9))
    }
}

private struct FortniteInfoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cut: CGFloat = 13
        var path = Path()
        path.move(to: CGPoint(x: 0, y: cut))
        path.addLine(to: CGPoint(x: cut, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - cut * 1.5, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: cut * 1.5, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY - cut))
        path.closeSubpath()
        return path
    }
}
