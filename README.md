# Sprite Vault — Fortnite Sprite Tracker for macOS

Sprite Vault is a native SwiftUI macOS app for tracking all 117 Fortnite Sprites. It stores ownership, summon-needed state, level, mastery, profiles, comparisons, activity, imported-media results, and live window scans.

## Open and run

Open `FortniteSpriteTracker.xcodeproj` in Xcode. Use **My Mac** as the run destination.

Requirements:

- macOS 14 or later
- Xcode 16 or later
- Screen Recording permission
- Accessibility permission for global hotkeys
- Notifications permission only if scan alerts are wanted

`Package.swift` is retained for source-layout convenience; the `.xcodeproj` builds the real `Sprite Vault.app` bundle needed by macOS privacy services.

## Window-only scan flow

Sprite Vault no longer asks the user to draw or save a capture area.

1. Press **Control + Option + S** (`⌃⌥S`).
2. Apple's native window picker opens in single-window mode.
3. Select the window that contains Fortnite, Remote Play, or an OBS projector showing Fortnite.
4. Sprite Vault checks the top navigation and requires both selected treatments:
   - the highlighted **SPRITES** tab;
   - the yellow underline under **COLLECTION**.
5. If either check fails, the overlay says **Please open Sprites → Collection** and does not save scan data.
6. Open the correct page and leave each view still briefly while Sprite Vault identifies the visible cards.
7. Press **Control + Option + X** (`⌃⌥X`) to cancel the picker or stop the current scan. Confirmed results are saved before a stopped scan is summarized.

The start hotkey always opens a fresh window picker. A previous selection is never silently reused for a new hotkey scan.

## Live card overlay

The magenta overlay is aligned from level-label OCR in the current stable frame instead of using a permanent stencil.

- At the catalog's top: up to **4 rows × 3 columns**.
- Through the middle: the **3 centered rows × 3 columns**; clipped edge rows are ignored.
- At the catalog's end: up to **4 rows × 3 columns**.
- Boxes are hidden while the collection is moving and re-aligned after it settles.
- Animated dots show cards being processed after the page-selection check passes.
- A recognized card shows a thumbs-up, its Sprite name, level, and mastery crown when present.
- Locked cards show a lock.
- Gray previously owned cards show **SUMMON**, not Locked.
- An uncertain card can be hovered to run a deeper artwork match.

The large right-detail-panel rectangle is not drawn. The detail panel is still read internally and is used as stronger evidence for the selected Sprite's exact name, rarity, level, mastery, and lost state.

## Saved Sprite state

Each profile persists three independent collection states:

- **Locked** — missing/not unlocked; Fortnite shows a dark silhouette.
- **Collected** — unlocked and currently available.
- **Needs summon** — previously unlocked but gray after being lost/equipped in a past match. It still counts as owned.

Level and mastery are saved separately. A previously mastered Sprite can be Level 1 and keep its mastery crown. A confirmed Level 5 also establishes mastery. Scan results are written by the capture manager itself, so they remain durable even when the main window is hidden and only the menu-bar companion is open.

## Performance behavior

- ScreenCaptureKit supplies a responsive 12, 20, or 30 FPS window feed.
- Frames are downscaled to at most 1280 pixels wide for analysis.
- Motion is sampled with a small fingerprint instead of running Vision on every frame.
- OCR and artwork matching pause while the collection scrolls.
- A stable view is analyzed once; duplicate stable frames are skipped.
- Catalog reference feature prints are cached.
- The overlay and live preview use separate update rates.
- Main-grid cards are lazy, equatable, and use cached images while retaining hover, sparkle, spring, and status animations.

## Main-window interface

The collection grid is clipped below the controls and no longer draws over the header or search field. Scrolling down collapses the complete header/search/settings area; scrolling upward or returning to the top restores it. Search, rarity filters, owned/locked/mastered filters, profiles, comparison, Activity, import, PDF export, and live-capture controls remain available.

## Scan progress

Two values remain separate:

- **Collection x/117** — unlocked Sprites in the selected profile, including summon-needed Sprites.
- **Coverage x/117** — catalog positions confidently visited during this scan, including visually locked positions when their page alignment is known.

The session can finish automatically after all catalog positions are covered, or it can be stopped safely with `⌃⌥X` at any time.

## Notifications and Activity

Optional native alerts cover scan start, completion/stop, new Sprites, level changes, mastery, summon-needed Sprites, and capture errors. Sprite alerts can navigate to the matching card. Activity is grouped by scan session, and an initial profile sync uses a summary instead of producing a wall of individual alerts.

## Menu-bar companion

The menu-bar view remains usable if the main window is hidden. It shows scan phase, elapsed time, selected window, Collection confirmation, collection total, coverage, changes, start/stop controls, Activity, and a shortcut back to Sprite Vault.

## Imported media and profiles

- Batch screenshot import with independent error handling and merged duplicate detections
- One video import at a time
- Multiple local profiles
- Profile comparison
- Poster-style PDF export
- Migration from the older single-profile save format

Profile data is stored locally under Application Support in the `FortniteSpriteTracker` folder.

## Stable signing for macOS permissions

To keep Screen Recording approval stable across source builds:

1. Select the **SpriteVault** target in Xcode.
2. Open **Signing & Capabilities**.
3. Keep **Automatically manage signing** enabled.
4. Select the same Personal Team or Developer Team for each build.
5. Keep the bundle identifier `com.spritevault.FortniteSpriteTracker`.

Do not add an automatic `tccutil reset` on quit; that would erase approval and force the user through permission setup again.

## Verification note

The project should be built and exercised on macOS because ScreenCaptureKit, Vision, SwiftUI/AppKit overlays, and privacy prompts are macOS-only. Source-level consistency checks can be run elsewhere, but they do not replace an Xcode build and a live Fortnite-window test.
