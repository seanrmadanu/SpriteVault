import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
enum CollectionPDFExporter {
    static func export(profile: CollectionProfile) throws -> URL? {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Sprite Collection"
        savePanel.prompt = "Export PDF"
        savePanel.allowedContentTypes = [.pdf]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "\(safeFilename(profile.name))-sprite-collection.pdf"

        guard savePanel.runModal() == .OK, let destination = savePanel.url else {
            return nil
        }

        try render(profile: profile, to: destination)
        return destination
    }

    static func render(profile: CollectionProfile, to destination: URL) throws {
        let families = PDFSpriteFamily.make(from: profile.sprites)
        let artwork = loadArtwork(for: profile.sprites)
        let size = CollectionPDFDocumentView.documentSize(rowCount: families.count)
        let document = CollectionPDFDocumentView(
            profile: profile,
            families: families,
            artwork: artwork,
            documentSize: size
        )

        let renderer = ImageRenderer(content: document)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = 1
        renderer.isOpaque = true

        var renderingError: CollectionPDFExportError?
        renderer.render { renderedSize, renderInContext in
            var mediaBox = CGRect(origin: .zero, size: renderedSize)
            guard let consumer = CGDataConsumer(url: destination as CFURL),
                  let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                renderingError = .couldNotCreateContext
                return
            }

            pdfContext.beginPDFPage(nil)
            renderInContext(pdfContext)
            pdfContext.endPDFPage()
            pdfContext.closePDF()
        }

        if let renderingError {
            throw renderingError
        }

        guard FileManager.default.fileExists(atPath: destination.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue > 0 else {
            throw CollectionPDFExportError.emptyOutput
        }
    }

    private static func loadArtwork(for sprites: [SpriteItem]) -> [String: NSImage] {
        var images: [String: NSImage] = [:]
        for item in sprites {
            guard let url = resourceURL(named: item.imageAssetName),
                  let image = NSImage(contentsOf: url) else { continue }
            images[item.imageAssetName] = image
        }
        return images
    }

    private static func resourceURL(named assetName: String) -> URL? {
        ResourceLocator.spriteImageURL(named: assetName)
    }

    private static func safeFilename(_ value: String) -> String {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "profile" : cleaned
    }
}

private enum CollectionPDFExportError: LocalizedError {
    case couldNotCreateContext
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .couldNotCreateContext:
            return "The PDF drawing context could not be created."
        case .emptyOutput:
            return "The PDF was created without any data."
        }
    }
}

private enum PDFSpriteVariant: String, CaseIterable, Identifiable {
    case normal = "NORMAL"
    case cube = "CUBE"
    case gold = "GOLD"
    case quack = "QUACK"
    case gummy = "GUMMY"
    case galaxy = "GALAXY"
    case gem = "GEM"
    case holofoil = "HOLOFOIL"

    var id: String { rawValue }

    var prefix: String? {
        switch self {
        case .normal: nil
        case .cube: "Cube "
        case .gold: "Gold "
        case .quack: "Quack "
        case .gummy: "Gummy "
        case .galaxy: "Galaxy "
        case .gem: "Gem "
        case .holofoil: "Holofoil "
        }
    }

    var gradient: LinearGradient {
        let colors: [Color]
        switch self {
        case .normal:
            colors = [Color(red: 0.65, green: 0.73, blue: 0.86), Color(red: 0.29, green: 0.42, blue: 0.65)]
        case .cube:
            colors = [Color(red: 0.40, green: 0.25, blue: 0.80), Color(red: 0.18, green: 0.09, blue: 0.43)]
        case .gold:
            colors = [Color(red: 1.00, green: 0.79, blue: 0.20), Color(red: 0.93, green: 0.46, blue: 0.04)]
        case .quack:
            colors = [Color(red: 1.00, green: 0.60, blue: 0.16), Color(red: 0.82, green: 0.27, blue: 0.07)]
        case .gummy:
            colors = [Color(red: 1.00, green: 0.31, blue: 0.64), Color(red: 0.73, green: 0.08, blue: 0.42)]
        case .galaxy:
            colors = [Color(red: 0.59, green: 0.31, blue: 0.96), Color(red: 0.20, green: 0.11, blue: 0.60)]
        case .gem:
            colors = [Color(red: 0.22, green: 0.87, blue: 0.95), Color(red: 0.06, green: 0.44, blue: 0.77)]
        case .holofoil:
            colors = [Color(red: 0.31, green: 0.96, blue: 0.76), Color(red: 0.06, green: 0.57, blue: 0.57)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func split(_ name: String) -> (variant: PDFSpriteVariant, baseName: String) {
        for variant in allCases where variant != .normal {
            guard let prefix = variant.prefix, name.hasPrefix(prefix) else { continue }
            return (variant, String(name.dropFirst(prefix.count)))
        }
        return (.normal, name)
    }
}

private struct PDFSpriteFamily: Identifiable {
    let name: String
    let rarity: SpriteRarity
    let variants: [PDFSpriteVariant: SpriteItem]

    var id: String { name }

    static func make(from sprites: [SpriteItem]) -> [PDFSpriteFamily] {
        var orderedNames: [String] = []
        var itemGroups: [String: [PDFSpriteVariant: SpriteItem]] = [:]
        var rarityByName: [String: SpriteRarity] = [:]

        for item in sprites {
            let split = PDFSpriteVariant.split(item.name)
            if itemGroups[split.baseName] == nil {
                orderedNames.append(split.baseName)
                itemGroups[split.baseName] = [:]
            }
            var group = itemGroups[split.baseName] ?? [:]
            group[split.variant] = item
            itemGroups[split.baseName] = group
            if split.variant == .normal || rarityByName[split.baseName] == nil {
                rarityByName[split.baseName] = item.rarity
            }
        }

        return orderedNames.map { name in
            PDFSpriteFamily(
                name: name,
                rarity: rarityByName[name] ?? .special,
                variants: itemGroups[name] ?? [:]
            )
        }
    }
}

private struct CollectionPDFDocumentView: View {
    static let width: CGFloat = 1080
    static let horizontalPadding: CGFloat = 34
    static let topPadding: CGFloat = 28
    static let bottomPadding: CGFloat = 24
    static let headerHeight: CGFloat = 174
    static let columnHeaderHeight: CGFloat = 48
    static let rowHeight: CGFloat = 108
    static let footerHeight: CGFloat = 42
    static let nameColumnWidth: CGFloat = 188
    static let cellSize: CGFloat = 94
    static let columnSpacing: CGFloat = 8

    let profile: CollectionProfile
    let families: [PDFSpriteFamily]
    let artwork: [String: NSImage]
    let documentSize: CGSize

    static func documentSize(rowCount: Int) -> CGSize {
        let height = topPadding
            + headerHeight
            + columnHeaderHeight
            + CGFloat(rowCount) * rowHeight
            + footerHeight
            + bottomPadding
        return CGSize(width: width, height: height)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: Self.headerHeight)

            variantHeaders
                .frame(height: Self.columnHeaderHeight)

            ForEach(families) { family in
                familyRow(family)
                    .frame(height: Self.rowHeight)
            }

            footer
                .frame(height: Self.footerHeight)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, Self.topPadding)
        .padding(.bottom, Self.bottomPadding)
        .frame(width: documentSize.width, height: documentSize.height, alignment: .top)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.48, blue: 0.91),
                    Color(red: 0.08, green: 0.27, blue: 0.70),
                    Color(red: 0.10, green: 0.06, blue: 0.34)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("FORTNITE COLLECTION TRACKER")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .italic()
                        .foregroundStyle(.white.opacity(0.72))

                    Text("SPRITE VAULT")
                        .font(.system(size: 47, weight: .black, design: .rounded))
                        .italic()
                        .tracking(-1.2)
                        .foregroundStyle(.white)

                    Text("\(profile.name) - every Sprite and variant")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .italic()
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 7) {
                    Text("\(profile.ownedCount) / \(profile.sprites.count) - \(completionPercent)%")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .monospacedDigit()
                    HStack(spacing: 7) {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(.yellow)
                        Text("\(profile.masteredCount) MASTERED")
                    }
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                }
                .padding(.top, 20)
            }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.36))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan, Color(red: 0.57, green: 0.95, blue: 0.71)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: progressWidth)
            }
            .frame(height: 13)
        }
    }

    private var variantHeaders: some View {
        HStack(spacing: Self.columnSpacing) {
            Color.clear
                .frame(width: Self.nameColumnWidth, height: 30)

            ForEach(PDFSpriteVariant.allCases) { variant in
                Text(variant.rawValue)
                    .font(.system(size: variant == .holofoil ? 9.5 : 10.5, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(variant == .gold ? Color.black.opacity(0.82) : .white)
                    .frame(width: Self.cellSize, height: 30)
                    .background(variant.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.22), lineWidth: 1)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func familyRow(_ family: PDFSpriteFamily) -> some View {
        HStack(spacing: Self.columnSpacing) {
            HStack(spacing: 11) {
                Circle()
                    .fill(rarityColor(family.rarity))
                    .frame(width: 9, height: 9)
                    .shadow(color: rarityColor(family.rarity).opacity(0.75), radius: 4)

                Text(family.name.uppercased())
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 0)
            }
            .frame(width: Self.nameColumnWidth, alignment: .leading)

            ForEach(PDFSpriteVariant.allCases) { variant in
                PDFSpriteCell(
                    item: family.variants[variant],
                    variant: variant,
                    image: family.variants[variant].flatMap { artwork[$0.imageAssetName] }
                )
                .frame(width: Self.cellSize, height: Self.cellSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.045))
                .frame(height: 1)
        }
    }

    private var footer: some View {
        HStack {
            Text("SPRITE VAULT")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .tracking(1.1)
            Spacer()
            Text("Generated \(Self.dateFormatter.string(from: Date()))")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
        }
        .foregroundStyle(.white.opacity(0.72))
        .padding(.top, 12)
    }

    private var completionPercent: Int {
        guard !profile.sprites.isEmpty else { return 0 }
        return Int((Double(profile.ownedCount) / Double(profile.sprites.count) * 100).rounded())
    }

    private var progressWidth: CGFloat {
        let totalWidth = Self.width - (Self.horizontalPadding * 2)
        guard !profile.sprites.isEmpty else { return 0 }
        return totalWidth * CGFloat(profile.ownedCount) / CGFloat(profile.sprites.count)
    }

    private func rarityColor(_ rarity: SpriteRarity) -> Color {
        switch rarity {
        case .rare: Color.cyan
        case .epic: Color(red: 0.93, green: 0.24, blue: 0.95)
        case .legendary: Color.orange
        case .mythic: Color(red: 1.00, green: 0.31, blue: 0.28)
        case .special: Color(red: 0.40, green: 0.95, blue: 0.71)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct PDFSpriteCell: View {
    let item: SpriteItem?
    let variant: PDFSpriteVariant
    let image: NSImage?

    var body: some View {
        Group {
            if let item {
                if item.owned {
                    ownedCell(item)
                } else {
                    lockedCell(item)
                }
            } else {
                unavailableCell
            }
        }
    }

    private func ownedCell(_ item: SpriteItem) -> some View {
        ZStack {
            variant.gradient

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .shadow(color: .black.opacity(0.28), radius: 4, y: 3)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }

            LevelCornerShape()
                .fill(Color(red: 0.02, green: 0.12, blue: 0.29).opacity(0.96))
                .frame(width: 35, height: 35)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Text(item.level.map { String($0) } ?? "?")
                .font(.system(size: 14, weight: .black, design: .rounded))
                .italic()
                .foregroundStyle(.white)
                .padding(.leading, 7)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if item.mastered {
                Image(systemName: "crown.fill")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color.black.opacity(0.84))
                    .frame(width: 22, height: 22)
                    .background(Color.yellow, in: Circle())
                    .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 1))
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(item.mastered ? Color.yellow : Color.white.opacity(0.46), lineWidth: item.mastered ? 2.5 : 1.2)
        )
    }

    private func lockedCell(_ item: SpriteItem) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.34, blue: 0.67),
                    Color(red: 0.04, green: 0.17, blue: 0.42)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .grayscale(1)
                    .opacity(0.17)
                    .padding(9)
            }

            Circle()
                .fill(.white.opacity(0.14))
                .frame(width: 39, height: 39)

            Image(systemName: "lock.fill")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(.white.opacity(0.90))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.17), lineWidth: 1.2)
        )
        .accessibilityLabel("\(item.name) not owned")
    }

    private var unavailableCell: some View {
        ZStack {
            Color.black.opacity(0.22)
            Text("-")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.26))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    .white.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
    }
}

private struct LevelCornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
