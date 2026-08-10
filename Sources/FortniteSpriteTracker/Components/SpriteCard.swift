import SwiftUI

struct SpriteCard: View {
    let item: SpriteItem
    let index: Int
    let onOwned: () -> Void
    let onMastered: () -> Void

    @State private var hovered = false
    @State private var appeared = false
    @State private var burst = false
    @State private var imageFloating = false

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

                Button(action: {
                    onMastered()
                    if !item.mastered {
                        burst = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { burst = false }
                    }
                }) {
                    Image(systemName: item.mastered ? "star.fill" : "star")
                        .frame(width: 20)
                }
                .buttonStyle(.bordered)
                .help("Mastered = Level 5")
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
        .scaleEffect(hovered ? 1.035 : (appeared ? 1 : 0.88))
        .rotation3DEffect(.degrees(hovered ? 1.8 : 0), axis: (x: -0.6, y: 1, z: 0))
        .shadow(color: .black.opacity(hovered ? 0.38 : 0.2), radius: hovered ? 22 : 9, y: hovered ? 12 : 5)
        .opacity(appeared ? 1 : 0)
        .onHover { inside in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { hovered = inside }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(Double(index % 18) * 0.018)) {
                appeared = true
            }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(Double(index % 7) * 0.08)) {
                imageFloating = true
            }
        }
    }

    private var imagePanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(spriteBackdrop)

            Circle()
                .fill(.white.opacity(hovered ? 0.13 : 0.06))
                .frame(width: 128, height: 128)
                .blur(radius: hovered ? 3 : 8)
                .scaleEffect(hovered ? 1.1 : 0.9)

            spriteImage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .offset(y: imageFloating ? -3 : 3)
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
                Text("LVL 5")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.yellow.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var spriteImage: some View {
        if let nsImage = loadSpriteImage() {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(item.name)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                Text("Missing image")
                    .font(.caption.bold())
                Text(item.imageAssetName + ".png")
                    .font(.caption2.monospaced())
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func loadSpriteImage() -> NSImage? {
        // SwiftPM's `.process("Resources")` may flatten nested resource folders
        // inside Bundle.module. Try the flattened location first, then the
        // original subdirectory so this also works if Xcode preserves it.
        let candidates: [URL?] = [
            Bundle.module.url(forResource: item.imageAssetName, withExtension: "png"),
            Bundle.module.url(forResource: item.imageAssetName, withExtension: "png", subdirectory: "SpriteImages"),
            Bundle.module.url(forResource: item.imageAssetName, withExtension: "png", subdirectory: "Resources/SpriteImages")
        ]

        for candidate in candidates {
            if let url = candidate, let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }

    @ViewBuilder
    private var statusIcon: some View {
        if item.mastered {
            Image(systemName: "star.circle.fill")
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
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
