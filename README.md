# Fortnite Sprite Tracker (macOS)

A native SwiftUI macOS checklist for all 117 Fortnite Sprites in the supplied Fortnite.GG PDF.

## Features
- 117 Sprite checklist with the actual Sprite artwork extracted from the supplied PDF
- Separate **Owned** and **Mastered** states (Mastered = Level 5)
- Multiple named profiles with completely separate local collection progress
- Automatic migration of the previous single `sprites.json` collection into **My Collection**
- Profile-to-profile comparison for shared ownership, unique Sprites, and level differences
- One-page poster PDF export with family names on the left and Normal/Cube/Gold/Quack/Gummy/Galaxy/Gem/Holofoil columns on the right
- PDF cells show artwork and level when owned, a crown at Level 5, a lock when unowned, and a dark dashed cell when that variant does not exist
- Screen-recording import includes a target-profile picker, so one recording cannot overwrite another profile by accident
- Vision OCR reads only the selected Sprite's right-side name and level
- Matches that name to the built-in catalog for its rarity/type
- Marks a detected Sprite as owned, saves its exact level, and marks it Mastered only when that same Sprite is Level 5
- Preserves the recording's full text resolution, then crops and enhances only the right-side details panel
- Supports wrapped/name-only titles, the game's Lootin' Llama naming, and the Sprite Mastered banner
- Accepts an exact right-panel catalog match immediately; fuzzy OCR still requires matching frames
- Samples a little over twice per second and lets you review results before applying them
- Heavy motion/UI polish: animated background, staggered card entrances, hover tilt, floating Sprite artwork, spring transitions, progress-ring animation, numeric count transitions, scanline import animation, symbol effects, toast animations, mastered sparkles, animated filter panel, and more
- Honors macOS Reduce Motion for the animated background

## Open in Xcode
1. On a Mac with Xcode 16+, open `Package.swift`.
2. Select the `FortniteSpriteTracker` scheme.
3. Run on **My Mac**.

## Best recording workflow
In Fortnite, move the selection onto every Sprite card; merely scrolling past a row does not expose every card's name. Keep each selected Sprite's name and level visible in the right-side details panel for roughly one second. The detector ignores the left grid, so a Level 5 label on another card cannot affect the selected Sprite.

## Important limitation
Recording detection is intentionally based on the right-side selected-Sprite details. A Sprite is not imported unless both its name and level are readable there. Exact catalog matches may be accepted from one frame; typo-tolerant matches require repeated agreement.

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


## Profiles
Use the profile menu below the **SPRITE VAULT** title to create, rename, delete, or switch profiles. To scan a friend's collection, create their profile, open the recording importer, and select that profile as the target before applying the reviewed detections. Each profile is stored independently in `profiles.json`. The app preserves an existing pre-profile collection by migrating `sprites.json` into **My Collection** on first launch.

## PDF export
Select a profile and choose **Export PDF**. The app creates a single tall poster-style PDF based on the checklist layout: one row per Sprite family and columns for every variant type in the built-in catalog. Owned cells include the Sprite artwork and exact level; Level 5 receives a crown. Unowned existing variants receive a lock, while impossible variants use a dark dashed placeholder.

## Compare profiles
Create at least two profiles, select the first one, and choose **Compare**. The comparison sheet reports both totals, shared ownership, Sprites owned by only one profile, and level or mastery differences.
