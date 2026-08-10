# Fortnite Sprite Tracker (macOS)

A native SwiftUI macOS checklist for all 117 Fortnite Sprites in the supplied Fortnite.GG PDF.

## Features
- 117 Sprite checklist with the actual Sprite artwork extracted from the supplied PDF
- Separate **Owned** and **Mastered** states (Mastered = Level 5)
- Persistent local progress in Application Support
- Screen-recording import
- Vision OCR frame analysis to auto-detect Sprite names
- Auto-marks a detected Sprite as Mastered when the same frame contains `LEVEL 5`, `LVL 5`, `LEVEL: 5`, or `MASTERED`
- Heavy motion/UI polish: animated background, staggered card entrances, hover tilt, floating Sprite artwork, spring transitions, progress-ring animation, numeric count transitions, scanline import animation, symbol effects, toast animations, mastered sparkles, animated filter panel, and more
- Honors macOS Reduce Motion for the animated background

## Open in Xcode
1. On a Mac with Xcode 16+, open `Package.swift`.
2. Select the `FortniteSpriteTracker` scheme.
3. Run on **My Mac**.

## Best recording workflow
In Fortnite, slowly scroll through the Sprite inventory. Keep each Sprite name and its level/status visible for roughly one second. The current auto-detector is text-driven; it is much more reliable when the UI text is clear and not motion-blurred.

## Important limitation
The checklist now has visual reference art for every Sprite, but recording auto-detection is still text-driven. If Fortnite does **not** show the Sprite name/level on screen, OCR cannot identify it yet. The next upgrade should add visual-reference matching (Vision feature prints or a small Core ML classifier) using these bundled Sprite images as references.

## Image loading fix
Sprite PNGs are SwiftPM processed resources. SwiftPM can flatten nested resource directories, so the app now checks the resource bundle root first and then the original SpriteImages paths. If an asset cannot be found, the card displays the exact missing filename instead of a generic placeholder.

## Window + search fix
- Explicitly activates the Swift Package executable as a regular macOS app when Xcode launches it.
- Configures the SwiftUI window as resizable and full-screen-primary, so the green traffic-light button enters native full screen.
- Removed the in-app full-screen button.
- Search uses a native NSSearchField, preserves its live field editor while typing, and explicitly makes the tracker window key when clicked.

## Startup performance
- Visible Sprite artwork is decoded into 320 px thumbnails on a four-operation background queue instead of blocking SwiftUI's main thread.
- Recently viewed images are cached, so view updates and scrolling do not reopen the same PNG repeatedly.
- Removed the permanent floating animation from every card and the staggered launch animation.
- Replaced per-card material/blur effects and nine blurred background circles with cheaper gradients.
- Progress is no longer rewritten to disk during the initial load; later saves run on a utility queue.
