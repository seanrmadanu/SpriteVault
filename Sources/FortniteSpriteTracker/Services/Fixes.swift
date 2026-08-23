import Foundation

/// Feature flags for the recognition rework.
///
/// Each flag guards one behaviour change so a regression can be bisected by
/// flipping flags instead of re-reading the analyzer. The pre-fix code path
/// stays compiled and reachable whenever a flag is off.
enum Fixes {
    // Stage 0
    /// Writes full frames, card crops, OCR strings and candidate rankings to
    /// ~/Library/Application Support/SpriteVault/Debug on every analysed frame.
    static let debugDump = false

    // Stage 1 — geometry
    static let newCardGeometry = true
    static let hardEdgeLetterbox = true
    /// Find the game view from the COLLECTION tab underline rather than by
    /// trimming black bars. Black-bar trimming only works when the game is
    /// surrounded by black; a recording played back in a window is not.
    static let anchorViewportOnUnderline = true
    static let detectRowPhase = true
    /// Measure the card grid from the picture instead of assuming the
    /// letterbox-trimmed frame is the 16:9 game view. Lets a screen recording,
    /// a windowed feed, or a bordered source align correctly.
    static let detectGridFromContent = true
    static let absoluteSlotNumbering = true
    static let nativeResolutionAnalysis = true
    /// Warn when the capture buffer and the overlay panel disagree in aspect,
    /// which offsets every drawn box even though the geometry is correct.
    static let logCaptureAlignment = true

    // Stage 2 — identification
    static let colourMatching = true
    static let cardLikeReferences = true
    static let noPositionalNaming = true
    static let keyResultsBySlot = true

    // Stage 3 — level and mastery
    static let topCentreCrown = true
    static let strictLevelParsing = true
    static let containedLevelBinding = true
    static let colouredPixelOwnership = true

    // Stage 4 — safe writes
    static let requireAgreement = true
    static let reversibleMastery = true
    static let guardedStatusWrites = true
    static let confirmedCoverageOnly = true
    /// Reports what would change without writing to the profile.
    static let dryRun = false
}

/// Grid geometry, as fractions of the letterbox-trimmed 16:9 game picture.
///
/// Measured from the ground-truth captures in `TestScreenshots/` (game area
/// x=43 y=192 2474x1392 within a 2560x1664 window). Column positions are
/// stable; the row *phase* moves with scroll and is detected per frame.
enum GridMetrics {
    static let cardWidth: CGFloat = 0.0703
    static let cardHeight: CGFloat = 0.1386
    static let columnStep: CGFloat = 0.0806
    static let rowStep: CGFloat = 0.1610
    static let firstColumnCentre: CGFloat = 0.1182
    static let columnCount = 3

    /// Mastery crown, as fractions of one card. Artwork gold starts around
    /// y 0.30, so this window separates a crown from a gold-coloured Sprite.
    static let crownRegion = CGRect(x: 0.38, y: 0.08, width: 0.44, height: 0.16)
    static let crownGoldThreshold: Double = 0.04

    /// A locked card contains essentially no coloured pixels, whether it is
    /// dark (luma ~29) or selected and near-white (luma ~188).
    ///
    /// Measured across the ground-truth captures: locked cards run 0.000–0.059
    /// (the high end being a locked card sitting over bright background art),
    /// while the least colourful *owned* card — a desaturated needs-summon tile
    /// — is 0.358. The plan's 0.05 sat inside the locked range and let one leak
    /// through as owned; 0.15 keeps a wide margin on both sides.
    static let lockedColourRatio: Double = 0.15

    static func columnCentre(_ column: Int) -> CGFloat {
        firstColumnCentre + CGFloat(column) * columnStep
    }
}
