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
- Recording/screenshot import includes a target-profile picker, so one import cannot overwrite another profile by accident
- Video analysis uses Vision OCR on only the selected Sprite's right-side name and level
- Screenshot analysis scans the 3-column Collection grid, reads each visible owned card's Lvl label, and uses Vision image feature prints to match the card artwork against all 117 built-in Sprite images
- Screenshot matching compensates for black letterboxing and uses the catalog's Type-order sequence only when it agrees with the artwork matches, reducing variant mix-ups
- Matches that name to the built-in catalog for its rarity/type
- Marks a detected Sprite as owned, saves its exact level, and marks it Mastered only when that same Sprite is Level 5
- Preserves the recording's full text resolution, then crops and enhances only the right-side details panel
- Supports wrapped/name-only titles, the game's Lootin' Llama naming, and the Sprite Mastered banner
- Accepts an exact right-panel catalog match immediately; fuzzy OCR still requires matching frames
- Samples a little over twice per second and lets you review results before applying them
- Heavy motion/UI polish: animated background, hover tilt, Fortnite-style animated Sprite info panels, spring transitions, progress-ring animation, numeric count transitions, scanline import animation, symbol effects, toast animations, mastered sparkles, animated filter panel, and more
- Honors macOS Reduce Motion for the animated background

## Open in Xcode
1. On a Mac with Xcode 16+, open `Package.swift`.
2. Select the `FortniteSpriteTracker` scheme.
3. Run on **My Mac**.

## Best recording workflow
In Fortnite, move the selection onto every Sprite card; merely scrolling past a row does not expose every card's name. Keep each selected Sprite's name and level visible in the right-side details panel for roughly one second. The detector ignores the left grid, so a Level 5 label on another card cannot affect the selected Sprite.

## Important limitations
Recording detection is intentionally based on the right-side selected-Sprite details. A Sprite is not imported unless both its name and level are readable there. Exact catalog matches may be accepted from one frame; typo-tolerant matches require repeated agreement.

Screenshot detection expects the normal Fortnite Collection view with the visible 3-column card grid. Only cards with a readable `Lvl 1` through `Lvl 5` label are treated as owned. Level 5 is Mastered. A screenshot only imports the cards currently visible, so screenshot files default to **Merge** mode; take additional screenshots after scrolling to cover the rest of a collection. The screenshot importer is designed around the current 16:9 Collection layout; heavily cropped screenshots or a future Fortnite UI redesign may need updated grid coordinates.

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

## Live ScreenCaptureKit scanning
Choose **Live Capture** in the main toolbar. The app asks ScreenCaptureKit for shareable on-screen windows, ranks Fortnite/cloud-gaming/capture windows first, and lets you choose exactly which window should be scanned. It does **not** capture the entire desktop.

Live mode uses `SCStream` with a desktop-independent window filter, no audio, no cursor, a two-frame queue, and a selectable **2 / 3 / 5 FPS** capture rate. Frames are downscaled to at most 1440 px wide before Vision work. The detector drops incoming frames while a previous Vision pass is still running, so capture cannot queue up an expensive backlog.

For safety, a live frame is ignored unless Vision can first confirm the **COLLECTION** heading. A changed page must also be detected in two consecutive live frames before it is merged into the target profile. This is intentionally stricter than a manually requested screenshot because a false positive in fully automatic mode would silently corrupt collection data.

The Collection grid does not display each Sprite's name, so OCR alone cannot identify every visible card. The app therefore uses Vision OCR for each `Lvl 1`–`Lvl 5` label and Vision image feature prints for the Sprite/variant artwork. Level 5 is still treated as Mastered.

## One-press hotkey collection scan
After choosing a target window, press **Control + Option + S** (`⌃⌥S`) from anywhere. The shortcut now starts a scan session rather than taking a single screenshot. Keep the Fortnite Collection sorted by **Type** and scroll through the list. Each changed page must still be confirmed twice before it is merged, duplicate pages are ignored, and the app tracks inferred catalog coverage from the visible 3x4 grid.

When the scanner reaches the final Type-sorted catalog region and has covered most of the collection, it stops ScreenCaptureKit automatically. The hotkey does not need to be pressed a second time. The Live Capture sheet shows scan state and exposes a button to start the same session for testing.

macOS notifications can be enabled in the Live Capture sheet. A hotkey session posts a start alert, a completion summary, and—after the profile already has an existing collection—alerts for newly added Sprites, level increases, and newly mastered Sprites. Empty profiles are treated as an initial sync, so they receive one completion summary instead of dozens of individual "new Sprite" notifications.

The shortcut uses `NSEvent` global/local monitors. macOS requires **Accessibility** permission for key events observed while another app is focused. Window capture requires **Screen Recording** permission. Both permissions can be requested from the Live Capture sheet. Depending on macOS/TCC state, Screen Recording changes can require relaunching the app.

## Hover Sprite intel
Hovering a Sprite card briefly opens an animated angular info panel inspired by Fortnite's UI. It shows the Sprite name, rarity, gameplay ability summary, known variant perk, ownership, level, and mastery state. Variant cards inherit the underlying base Sprite ability.

If you turn this Swift package into a signed/distributed `.app`, add an `NSScreenCaptureUsageDescription` string to the app target's Info settings explaining that Sprite Vault reads the selected Fortnite/streaming window to detect collection progress.
