# SpriteVault — Recognition Fix Plan

Working brief. Everything needed to do this work is in this file; no external
conversation is required.

---

## 1. What the app is

Native SwiftUI macOS app that tracks a Fortnite Sprite collection (117 items).

The user plays Fortnite on a **PS4 Pro**. There is no monitor — the console goes
through a **video capture card into OBS on a 13" MacBook Air**, and OBS acts as
the display. SpriteVault uses ScreenCaptureKit to read the OBS window, finds the
Sprites → Collection screen, and identifies which Sprites are owned, their level,
and whether they are mastered.

Flow: `⌃⌥S` opens the macOS window picker → user selects the OBS window → the app
watches for stable frames → each stable frame is analysed → results are written
into the selected profile. `⌃⌥X` stops.

**Reported symptom:** counts are wrong. Sprite totals, mastered totals, and
coverage do not match reality, and the numbers only ever drift upward.

---

## 2. Root cause summary

Investigated against four real screenshots. Five independent problems:

1. **Card boxes are in the wrong place.** Hardcoded geometry is measurably wrong,
   so crops straddle two cards. The app asks "which sprite is this?" about an
   image containing the bottom half of one sprite and the top half of another.
2. **Variants cannot be told apart.** Roughly 90 of the 117 Sprites are recolours
   of ~20 shapes (Batman / Cube Batman / Gold Batman / Gummy Batman / Galaxy
   Batman / Holofoil Batman are one silhouette). Matching uses
   `VNGenerateImageFeaturePrintRequest`, which is shape-driven and largely colour
   insensitive, so these are indistinguishable. Colour is the discriminating
   signal and is currently unused.
3. **Names are guessed by position.** When artwork matching fails to separate a
   winner, the code assigns names by grid position against a hardcoded catalog
   order. The in-game screen has a **Sort By** control and the observed order does
   not match the catalog, so this is systematically wrong.
4. **Mastery and level detection have outright bugs** — wrong search region,
   a string-replacement false positive, and level values leaking between cards.
5. **Every frame writes straight to the profile.** No agreement across frames, and
   mastery can never be cleared, so one bad frame is permanent. This is why counts
   only climb.

---

## 3. Measured ground truth

All values normalised to the **game picture area** (letterbox-trimmed 16:9
region), not the raw window.

### Grid geometry

| Value | Measured | Code currently uses |
|---|---|---|
| `cardWidth` | **0.0703** | 0.079 |
| `cardHeight` | **0.1386** | 0.166 |
| `columnStep` | **0.0809** | 0.080 ✓ |
| `rowStep` | **0.1610** | 0.180 ✗ |
| `firstColumnCentre` | **0.1185** | 0.118 ✓ |
| level-pill centre, down the card | **0.829** | 0.86 |

Row *phase* (where rows start) changes with scroll and **must be detected per
frame** — it is not a constant. Column positions are stable.

Derivation: `cardTop = pillCentreY - 0.829 * cardHeight`.

### The window is not a fixed size

Two capture sessions produced different geometry:

| Session | game area | offset |
|---|---|---|
| A | 2560 × 1440 | x=0, y=112 |
| B | 2474 × 1392 | x=43, y=192 |

Both 16:9. The letterbox must be measured every frame.

The existing letterbox detector was **28 px off at the top**, because it looks for
"not black" pixels and the top of the Fortnite screen is very dark navy. Replace
with hard-edge detection (find the sharp transition from bar to picture), which
survives dark content.

### Card states — measured

| State | avg brightness | coloured-pixel ratio |
|---|---|---|
| Owned | 85 – 177 | 0.28 – 0.65 |
| Locked | ~29 | **0.000** |
| Locked **and selected** | 188 | **0.000** |

Brightness does not separate these — a selected locked card is nearly white.
**Coloured-pixel ratio does, cleanly.**

Rule: `locked  ⟺  colouredPixelRatio < 0.05`

where a pixel counts as coloured when `max-min >= 30 && max >= 70`.

### Mastery crown — measured

Crown sits at **top-centre** of the card, roughly `x 0.42–0.80, y 0.04–0.26`.

Gold-pixel ratio in that region, over verified cards:

- crowned: **0.1255, 0.1237, 0.1237**
- not crowned: **0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000**

Threshold `> 0.04` is safe. Gold test:
`r>=170 && g>=115 && b<=125 && r>b+55 && g>b+25`

The current code searches `x 0.48–0.98, y 0.69–0.98` (bottom-right), which returns
0.008–0.022 for crowned cards and 0 for uncrowned — almost no signal, and it
overlaps the artwork so gold-coloured Sprites (there are ~17 named "Gold X") score
as mastered purely for being gold.

### Third card state, currently unhandled

Some cards show a **black pill with a dust icon and a number** at bottom-left,
instead of the usual white "Lvl N" pill. Artwork is present but desaturated. This
is the **needs-summon / lost** state — still owned.

Detect by which pill is present:

- white pill, dark text → **collected**, read the level
- black pill, light text → **needs summon**, do not read a level
- no pill at all → **locked**

This is far more reliable than the current saturation/variance heuristic.

### Free signal from the right-hand panel

The detail panel prints the exact selected Sprite name (e.g. `CUBE GRIM SPRITE`)
and shows `UNDISCOVERED SPRITE` when the selection is locked. OCR on this panel is
reliable. Use it as the page anchor — one guaranteed-correct identification per
frame.

### Catalog order does not match the screen

Top of the in-game list, observed: **Cube Batman, John Wick, Batman**.
`SpriteCatalog.all` order: **John Wick, Batman, Cube Batman**.

The screen also has a **Sort By: Type** control the user can change. Any logic that
maps grid position to catalog index by assuming a fixed order must be removed.

---

## 4. The fixes

Every fix goes behind a flag in a new `Fixes.swift`:

```swift
enum Fixes {
    static let debugDump                = true
    static let newCardGeometry          = true
    static let hardEdgeLetterbox        = true
    // ... one per fix below
}
```

This exists so a regression can be bisected by flipping flags rather than
re-reading 8,000 lines. Keep the old path compiled and reachable when a flag is
off.

### Stage 0 — visibility

**0.1 Debug dump mode.** On each analysed frame, write to a timestamped folder:
the full frame, every card crop, raw OCR strings, and the top-5 candidate names
per card with their distances. Everything else is easier to verify once this
exists. Build this first.

### Stage 1 — geometry (`ScreenshotSpriteAnalyzer`, `ScreenCaptureService`)

**1.1** Replace card size and spacing with the measured constants in §3.

**1.2** Replace letterbox detection with hard-edge detection. Must handle a dark
navy top edge.

**1.3** Stop requiring 2+ readable "Lvl" labels before a row is trusted. A row of
locked cards has no level text at all, so the entire row is dropped today — and
because slot indices are positions in the *found rows* array, every card below it
shifts by one row. Detect card rectangles from the card edges/background, not from
text.

**1.4** Number slots by **absolute grid position**, never by index into whatever
rows happened to be found.

**1.5** Stop downscaling to 1280 px before analysis. The source is a 1080p console
feed shown fullscreen on a 2560-wide display; halving it destroys the level text,
which is the smallest thing on screen. Read at native size, or crop from the
full-resolution frame and upscale the crop.

**1.6** Remove the duplicate card-size constants. `recognizedGridLayout` shadows
`cardWidth`/`cardHeight` as pixel values (0.076 / 0.145 of viewport) while the type
properties are fractions (0.079 / 0.166). Calibrated and fallback paths therefore
crop differently. One source of truth.

**1.7** `motionFingerprint` samples fixed fractions of the **raw window**, but the
analyser works on the letterbox-trimmed picture. Move motion sampling onto the same
trimmed region.

### Stage 2 — identification

**2.1 Add colour matching.** Compute a small HSV histogram over the artwork region
and use it alongside the feature print. Shape selects the family (King), colour
selects the treatment (Gold / Gummy / Galaxy). This is the single highest-impact
change. Reference colours can come from the existing PNGs in
`Resources/SpriteImages` — those are correctly coloured.

**2.2 Rebuild references to match what is on screen.** `referenceArtworkImage`
composites a cut-out transparent PNG onto near-white. Real cards have a coloured
background, a frame, a name plate and a level strip. Composite onto a card-like
background so like is compared with like.

**2.3 Remove position-based naming.** Delete the sequence-assignment fallback that
returns `best.start + slot` for every card. Anchor the page with the right-panel
name instead. Cards that cannot be identified confidently are reported as
*unidentified*, never guessed.

**2.4 Stop collapsing detections by name.** `byName[normalize(name)] = detection`
keeps only the last card when two match the same catalog entry, silently dropping
a card from the frame. Key results by grid slot instead.

**2.5 Fail loudly on missing artwork.** `referenceFeatures` skips unreadable PNGs
silently; a partial set degrades matching and also disables other paths via a
`references.count == catalog.count` guard. Surface a real error.

### Stage 3 — level and mastery

**3.1** Move the crown region to top-centre (§3) and use threshold `> 0.04`.

**3.2** Remove the `"LEVELS" → "LEVEL5"` and `"LVLS" → "LVL5"` substitutions in
`parseLevel`. Any plural on screen currently reads as level 5, which permanently
sets mastered.

**3.3** Stop level values leaking between cards. `levelsBySlot[slot] = max(existing,
observed)` takes the highest nearby label, and `fallbackGridLayout` has **no
containment check at all** — `nearestSlot` always returns some slot, so a label
anywhere binds to a card. Require the observation to fall inside the card it is
assigned to, and do not take a max across observations.

**3.4** Replace the brightness-based owned test (`unlockedVisualScore >= 0.28`)
with the coloured-pixel rule from §3, and add the three-way pill detection
(white / black / none).

### Stage 4 — safe writes (`SpriteStore`, `LiveCaptureManager`)

**4.1 Require agreement before saving.** Today `receive` → `saveConfirmedDetections`
→ `applyDetections` writes on the first frame whose signature changed. Require the
same slot to produce the same identification across **2–3 distinct stable frames**,
or a right-panel confirmation, before committing.

**4.2 Make mastery reversible.** `mastered = mastered || detection.mastered || level == 5`
is monotonic — one false positive is permanent. Track confidence and allow a
confident negative observation to clear it.

**4.3 Do not overwrite status unconditionally.** `status = detection.status` lets a
single misread flip collected → lost.

**4.4 Fix coverage, and stop auto-completing on it.** `coveredCatalogIndexes` is
filled from `pageStart + slot` using an inferred page start, and
`checkForAutomaticCompletion` ends the session once it reaches 117 — so a scan can
declare itself finished having never read large parts of the list. Only count a
position as covered when its identity was actually confirmed.

**4.5 Add dry-run mode.** Report what *would* change without writing to the
profile. Needed for testing, since the app currently rewrites the collection on
every run and there is no way to compare against a known-good state.

### Stage 5 — overlay

**5.1** Draw a box on each detected card, darken the inside slightly, and print the
Sprite name so it is readable over the artwork. States:

- **green** — identified
- **yellow** — currently selected (name confirmed by the right panel)
- **orange** — still reading / not confident

**5.2** Small live readout in a corner of the overlay: sprites read, new this
session, elapsed time.

Rationale: OBS runs fullscreen, so the macOS menu bar is hidden while playing. The
overlay is the only thing visible mid-scan. It doubles as the debugging surface — a
misaligned box or wrong name is visible immediately.

### Stage 6 — notifications and menu bar

Most of this already exists and works. Gaps only:

**6.1** Display sprites-read-this-session. `sessionObservedSpriteCount` is already
computed and never shown.

**6.2** First scan is silent — per-sprite alerts are skipped when
`sessionInitialOwnedCount == 0`. Sensible (avoids 117 banners) but the user gets
nothing until the end. Send a periodic progress summary instead.

**6.3** Group notifications. 40 new Sprites should not be 40 banners.

**6.4** Verify the capture source name renders usefully in the menu bar rather than
a generic "Window".

---

## 5. Suggested order

`0 → 1 → 4 → 2 → 3 → 5 → 6`

Stage 4 comes early on purpose: stop the app corrupting the profile before
improving identification, otherwise every test run writes more bad data that has
to be cleaned up before the next test means anything.

---

## 6. Verifying

Ground-truth screenshots are in the project folder (2560×1664, full screen, no
crop). They cover:

- top of the collection list
- a mid-list scroll position with mixed levels (1, 2, 4, 5) and mixed crowns
- locked / undiscovered cards, a needs-summon dust card, and a selected locked card

Test against these first. Every number in §3 was measured from them, so a correct
implementation should reproduce those values.

Build target: open `FortniteSpriteTracker.xcodeproj`, run destination **My Mac**.
The `.xcodeproj` builds the real app bundle needed for macOS privacy permissions —
`Package.swift` exists only for source-layout convenience. Requires macOS 14+,
Xcode 16+, Screen Recording permission, and Accessibility permission for the global
hotkeys.

Build after each stage rather than at the end.
