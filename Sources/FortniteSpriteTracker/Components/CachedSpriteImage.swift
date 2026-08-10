import SwiftUI
import AppKit
import ImageIO

/// Loads only the images needed by visible cards, decodes them away from the
/// main thread, and reuses recently displayed thumbnails while scrolling.
struct CachedSpriteImage: View {
    let assetName: String
    let accessibilityLabel: String

    @StateObject private var loader: SpriteImageLoader

    init(assetName: String, accessibilityLabel: String) {
        self.assetName = assetName
        self.accessibilityLabel = accessibilityLabel
        _loader = StateObject(wrappedValue: SpriteImageLoader(assetName: assetName))
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(accessibilityLabel)
            } else if loader.isFinished {
                VStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                    Text("Missing image")
                        .font(.caption.bold())
                    Text(assetName + ".png")
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.22))
                    .accessibilityLabel("Loading \(accessibilityLabel)")
            }
        }
        .onAppear(perform: loader.load)
    }
}

private final class SpriteImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isFinished = false

    private let assetName: String
    private var hasRequestedImage = false

    init(assetName: String) {
        self.assetName = assetName
    }

    func load() {
        guard !hasRequestedImage else { return }
        hasRequestedImage = true

        SpriteImageCache.shared.load(named: assetName) { [weak self] image in
            self?.image = image
            self?.isFinished = true
        }
    }
}

private final class SpriteImageCache {
    static let shared = SpriteImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let loadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Sprite image decoding"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    private init() {
        // Enough for several screens without retaining all 117 decoded images.
        cache.countLimit = 48
    }

    func load(named assetName: String, completion: @escaping (NSImage?) -> Void) {
        let key = assetName as NSString

        if let cachedImage = cache.object(forKey: key) {
            DispatchQueue.main.async {
                completion(cachedImage)
            }
            return
        }

        loadQueue.addOperation { [weak self] in
            guard let self else { return }
            let thumbnail = self.decodeThumbnail(named: assetName)

            OperationQueue.main.addOperation { [weak self] in
                guard let self else { return }

                let image = thumbnail.map {
                    NSImage(
                        cgImage: $0,
                        size: NSSize(width: CGFloat($0.width), height: CGFloat($0.height))
                    )
                }

                if let image {
                    self.cache.setObject(image, forKey: key)
                }
                completion(image)
            }
        }
    }

    private func decodeThumbnail(named assetName: String) -> CGImage? {
        guard let url = resourceURL(named: assetName),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        // Cards display artwork at roughly 280 physical pixels on a Retina Mac.
        // A 320 px thumbnail avoids decoding every 512 px source at full size.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceShouldCacheImmediately: true
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func resourceURL(named assetName: String) -> URL? {
        Bundle.module.url(forResource: assetName, withExtension: "png")
            ?? Bundle.module.url(
                forResource: assetName,
                withExtension: "png",
                subdirectory: "SpriteImages"
            )
            ?? Bundle.module.url(
                forResource: assetName,
                withExtension: "png",
                subdirectory: "Resources/SpriteImages"
            )
    }
}
