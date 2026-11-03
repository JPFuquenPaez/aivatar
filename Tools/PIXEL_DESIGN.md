# Pixel-avatar design practices (the standing checklist, v4 — quiet stage)

The standing rule for every visual pass: **design in this order —
silhouette → proportions → palette → details → animation — and design for
instant recognition at the final display size** (the watch stage shows the
avatar at ~50 sprite-rows tall; it must also survive the app icon and
notification scale). The sprite must read as AUTHORED pixel art, never as
vector art downsampled.

v3 changes the subject: each archetype is **one reduced animal** from its
category (Ember = fox / land-fire, Willow = frog / amphibian, Compass =
fish / water, Nimbus = bird / air, Prism = chameleon / reptile), built
from 3-5 flat solid shapes plus the shared face rig. Animal icons are
FLAT (Mistral DNA): no gradients, no rim light, no blush, no outline —
the icon separates from the black stage by its own solid color.

## 0. Design order (mandatory)

1. **Silhouette first, one flat dark color.** If role/personality/pose are
   not readable as a black shape, shading and details will not fix it.
   Test: fill the silhouette solid, squint / view at thumbnail size.
2. **Proportions for the canvas, not realism.** At 32-48 px display, a
   2-3-heads-tall chibi body is most legible: the head gets room for
   expression, the body stays one readable mass.
3. **Palette only after the shape works.** ONE flat body hue + ink + white
   negative space; transient accents only for tells (sparks, flicker).
4. **Details last, only if they survive at 100% zoom.** A 1-2 px stripe
   that turns to noise is removed or enlarged (sub-pixel rig details are
   banned: a sprite pixel is ~2.7 rig units, so nothing thinner than
   ~3 rig units may be authored).
5. **Animation last**, on the approved shape (see §7 below).

## 1. Silhouette is the logo

- One reduced animal per category, 3-5 solid shapes + the shared face rig
  (`AnimalPlan`; hidden slots paint nothing). Subtract, don't add.
- One memorable identity anchor per animal, kept SEPARATED from the body
  so it never merges into the mass: fox ears, frog eye domes, fish dorsal
  fin, bird beak + single wing, chameleon casque + curled tail.
- Use negative space: the gap between the ears, between body and anchor —
  never a solid blob. White negative-space details (muzzle, tail tip)
  are the `paper` role.
- Slight asymmetry (one ear a touch larger/tilted, one wing) reads alive
  and is easier to distinguish than perfect symmetry.
- Verify: `testSilhouetteShowsIdentityAnchor` (separated runs or a
  top/bottom spike), `testSilhouetteIsConnected`, `testThumbnailStillReads`,
  `testAnimalShapeBudget` (3-5 shapes + face).

## 2. Proportions and canvas

- Canvas class: the avatar displays at ~32-48 px → chibi floor: a big
  readable head on every animal (the frog's wide flat dome is the one
  designed exception), body as one flat mass under it.
- Verify: `testAnimalHeadIsTheBigMass`.

## 3. Palette: tight, high-contrast, FLAT

- Flat fills only (Mistral DNA): every shape is ONE solid LUT color. No
  gradient ramps, no rim highlight, no blush — `testFlatIconsHaveNoRimOrGloss`,
  `testFlatIconsHaveNoRampTones`.
- LUT budget ≤ 8 active colors: the ONE body accent hue, ink (`face`:
  eyes/mouth/brows + beak/nose anchors), white `paper`, catchlight, and
  the transient tell accents (accentA/accentB flicker swap, sparks). The
  mote stage tone sits outside the budget.
- Distinct jobs per color; neighboring tones must differ in value FIRST,
  hue second (readable in grayscale). No light direction needed — there
  is no ramp to shade.
- Verify: `testPaletteBudget`, `testPixelPalettesAreVivid`,
  `testTintSeparatesArchetypes`.

## 4. Chunky pixels, hard edges, NO contour, NO dither

- Every lit pixel is EXACTLY a LUT color (`testPixelColorsSnapToLUT`) —
  including edge pixels: the silhouette boundary is a hard LUT cut, never
  a dim antialiased fringe (`testSilhouetteEdgeIsHardLUTCut`).
- The snap's coverage gate is 50%: a grid pixel is painted only when a
  shape covers at least half of it, so antialiased boundaries produce
  regular staircases with no orphan fringe pixels
  (`testNoSpeckleOrphans` — zero isolated lit pixels anywhere).
- NO dithering at all (v4): the flat palette gives every painted pixel
  an exact LUT color, so ordered dither is dead weight that can only
  create between-tone speckle. Nearest-LUT snap only.
- Displayed scale: the 64x78 grid is drawn edge-to-edge, so one art pixel
  is exactly `screenWidth / 64` device points (~5.7-6.2 px on current
  cases) — the authored pixel scale is pinned by construction. (The
  StageComposition zoom constant applies ONLY to the vector fallback.)
- Icon brand rules forbid outlines/frames and smoothing. The icon
  separates by its own flat color on the OLED black stage.
- No "doubles" (thick L-shaped diagonal clusters), no single-pixel-thin
  details (Derek Yu's chunky-pixels rule), no automatic AA.
- Verify: golden hash pins.

## 5. The face is the avatar

- Same face rig on every animal: big eyes (≥ ~1/6 head width, pupils
  1.4x) with a white catchlight upper-left; eye spacing AND vertical
  position tuned per animal via the face inset (the frog's dome eyes sit
  ON TOP of the head — faceInsetY); joy = ^-^ lid squint.
- Verify: `testPupilsScaleUpForCuteness`, `testFaceInsetFollowsAnimal`,
  `testJoySquintsLidsClosed`.

## 6. Motion-friendly shape

- Moving parts on separate bones (engine layers already do this); 1-2 px
  of padding around the sprite so gestures never clip the grid edge —
  tested across the widest pose (a full spin), not just idle.
- Verify: `testSpritePaddingAcrossWidestPose`.

## 7. Stage and life — the silence budget

- Sparse frame-driven mote field — at most THREE dim (22% body) motes,
  drifting slowly — the ONLY stage addition; punctuation, not weather.
  Deterministic in the frame index, absent in the rest LOD (OLED power).
- Motion budget (v4): life floor = breathing + blinks + gaze + posture
  wander (always on); expressive motion = idle gestures + tells
  (scheduled, rare); NO tremor on the head — the focal point must be
  still between blinks and gaze shifts. Mean changed non-stage pixels per
  idle frame is pinned by `testIdleMotionEnergyBudget` so a future
  "alive" pass cannot silently turn the companion into jitter.
- Verify: `testMotesAreDeterministicFrameDrivenAndRestFree`,
  `testIdleMotionEnergyBudget`.

## Review workflow for any visual change

1. Unit suite green (golden hashes re-pinned deliberately, with a reason).
2. `Tools/visual_smoke_test.sh` — all five archetypes render on-simulator.
3. `Tools/assess_similarity.swift` on the captures — palettes separate,
   tone counts in the authored band.
4. Screenshot eyeball pass at native AND zoomed-out (thumbnail) size.
   Numbers catch regressions; only eyes catch "ugly".
