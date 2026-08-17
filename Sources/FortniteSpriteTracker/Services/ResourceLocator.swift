import Foundation

enum ResourceLocator {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }

    static func spriteImageURL(named assetName: String) -> URL? {
        bundle.url(forResource: assetName, withExtension: "png")
            ?? bundle.url(forResource: assetName, withExtension: "png", subdirectory: "SpriteImages")
            ?? bundle.url(forResource: assetName, withExtension: "png", subdirectory: "Resources/SpriteImages")
    }
}
