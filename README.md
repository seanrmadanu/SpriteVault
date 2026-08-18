# Sprite Vault — Fortnite Sprite Tracker for macOS

Native SwiftUI macOS app for tracking all 117 Fortnite Sprites, including level, mastery, profiles, comparison, PDF export, imported media analysis, and live capture.

## Open the correct project

**Open `FortniteSpriteTracker.xcodeproj` in Xcode. Do not open `Package.swift` for normal app testing.**

The Xcode project builds a real **Sprite Vault.app** bundle so Screen Recording, capture-device permission, Accessibility, native notifications, notification clicks, and the menu-bar companion have a proper application identity.

Requirements:
- macOS 14+
- Xcode 16+
- Run destination: **My Mac**

On first use, open **Live Capture** and grant the permissions needed by the capture source you choose.

## Capture sources

Live Capture now has two user-facing source modes:

1. **Screen / Window** — recommended. Press **Select Window / Screen** and use Apple's ScreenCaptureKit picker to choose the full-screen Fortnite window, OBS Projector, or an entire display. This works across macOS Spaces and avoids trying to draw Sprite Vault's own selection overlay on top of another app's full-screen Space. A secondary **Custom Area** button remains for windowed setups and stores the selected `sourceRect` for reuse.
2. **Capture Device** — reads a USB/UVC video capture device directly through AVFoundation, bypassing OBS entirely.

Recognition is calibrated against the full Fortnite viewport. If you use Custom Area, select the complete 16:9 Fortnite image rather than only the Sprite cards.

## Hotkey scan

Press **Control + Option + S** (`⌃⌥S`) to start a collection scan.

- One press starts the session. A second hotkey press does not stop it.
- The scanner waits until it visually confirms **SPRITES → COLLECTION**.
- While you scroll quickly, heavy Vision/OCR work pauses instead of repeatedly reading blurry frames.
- When the grid has been stable for roughly half a second, the current view is analyzed once.
- Duplicate stable views are ignored.
- The session auto-finishes only when all 117 catalog positions have been covered. A manual **Stop Scan** control remains available in Live Capture and the menu-bar companion.

Two progress values are kept separate:
- **Collection x/117** — how many Sprites the selected profile has unlocked.
- **Scan x/117** — how many catalog positions the current session has confidently covered.

## Left-grid + right-panel recognition

A stable Collection frame is analyzed from both sides:

- **Left grid:** artwork feature matching, `Lvl 1–5`, mastery from Level 5, and visible catalog slots.
- **Right detail panel:** exact selected Sprite name, rarity, level/mastery text, and `LOST IN PAST MATCH`.

The right panel is treated as stronger evidence for the selected card and can correct an uncertain visual artwork match.

## Locked, collected, and lost Sprites

Sprite Vault stores three states:

- **Locked** — never unlocked; Fortnite shows only the silhouette/no useful details.
- **Collected** — unlocked and currently available.
- **Lost** — greyed out / `LOST IN PAST MATCH`; it still counts toward the player's unlocked collection.

A lost Sprite is never automatically changed back to Locked just because it is greyed out in Fortnite.

## Notifications and Activity

Native macOS alerts are available for:
- scan started
- scan completed / stopped
- new Sprite
- level increase
- mastery
- lost Sprite
- capture errors

Clicking a recent Sprite notification opens Sprite Vault and navigates to that Sprite card. Completion alerts open the in-app **Activity Center**.

Activity is stored locally by scan session and includes clickable lists of new, leveled, mastered, and lost Sprites. Initial syncs use one summary instead of sending dozens of individual alerts.

## Menu-bar companion

Sprite Vault stays available from the macOS menu bar even if the main window is closed. The menu-bar panel shows:

- scan state and elapsed time
- selected source
- live preview
- whether the Fortnite Collection was confirmed
- Collection x/117
- Scan x/117
- change count
- Start/Stop Scan
- Open Sprite Vault
- Activity unread count

While scanning, the menu-bar label also displays scan coverage.

## Main-window scan status

The **Live Capture** toolbar button becomes a live status capsule while a hotkey scan is active. It cycles through:

- current state
- elapsed time
- Collection x/117
- Scan x/117
- changes so far

## Sprite card hover

Hovering keeps the Sprite card centered on its original grid position and expands it in every direction. The hover card uses a high stacking order so neighboring cards do not cover it. Expensive perpetual light-sweep/card-float effects were removed to keep scrolling smooth. Sprite names, gameplay descriptions, variant perks, and scan result text wrap to full lines instead of being shortened with ellipses.

## Batch screenshot import

Screenshot import accepts multiple images in one Finder selection. Additional screenshots can be appended to the same batch, each image is analyzed independently, unreadable screenshots do not abort the rest of the batch, and duplicate Sprite detections are merged before review. Repeated detections increase the evidence count; higher confirmed levels and Mastered status are preserved. Video import remains one recording at a time.

## Profiles, search, filters, compare, and PDF

- Multiple independent collection profiles
- Native search
- Owned / not-owned / mastered / rarity filters
- Profile comparison
- Poster-style PDF export
- Automatic migration of older single-profile save data

Profile data is stored locally under Application Support in the `FortniteSpriteTracker` folder.

## Permissions

Depending on the selected source, Sprite Vault may request:

- **Screen Recording** — Application / Specific Window modes
- **Camera** — direct USB capture-device mode
- **Accessibility** — global `⌃⌥S` shortcut while another app is focused
- **Notifications** — scan and collection-change alerts

The Xcode app target includes the required usage strings and camera entitlement.

## Development note

`Package.swift` remains in the repository as a fallback/source-layout convenience, but normal testing should use the included `.xcodeproj` app target. The source has been syntax-parsed in the provided build environment; ScreenCaptureKit, AVFoundation device capture, UserNotifications, and SwiftUI/AppKit runtime behavior still need to be exercised on macOS in Xcode.
## Development signing and macOS privacy permissions

Sprite Vault now fully quits when its last main window closes, so active screen/camera capture ends with the app process. macOS intentionally keeps the user's Privacy & Security approval after an app quits.

To make Screen Recording/Camera approval survive source-code updates, run the app with a stable Apple-issued signing identity rather than **Sign to Run Locally** / ad-hoc signing:

1. Open `FortniteSpriteTracker.xcodeproj`.
2. Select the **SpriteVault** target → **Signing & Capabilities**.
3. Leave **Automatically manage signing** enabled.
4. Choose your Apple ID's **Personal Team** (or your paid Developer Team) under **Team**.
5. Keep the bundle identifier as `com.spritevault.FortniteSpriteTracker`.
6. Build and approve Screen Recording once. Subsequent builds signed by the same team + bundle identifier should be recognized as the same app identity by macOS.

Do not add an automatic `tccutil reset` on app quit. That is a development shell utility, not an app permission-revocation API, and it would force a fresh approval every launch instead of solving the update problem.

