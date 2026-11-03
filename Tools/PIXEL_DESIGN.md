# Pixel-avatar design practices (the standing checklist, v2 — épuré)

The standing rule for every visual pass: **design in this order —
silhouette → proportions → palette → details → animation — and design for
instant recognition at the final display size** (the watch stage shows the
avatar at ~50 sprite-rows tall; it must also survive the app icon and
notification scale). The sprite must read as AUTHORED pixel art, never as
vector art downsampled.

## 0. Design order (mandatory)

1. **Silhouette first, one flat dark color.** If role/personality/pose are
   not readable as a black shape, shading and details will not fix it.
   Test: fill the silhouette solid, squint / view at thumbnail size.
2. **Proportions for the canvas, not realism.** At 32-48 px display, a
   2-3-heads-tall chibi body is most legible: the head gets room for
   expression, the body stays one readable mass.
3. **Palette only after the shape works.** Base + shadow + highlight per
   material; ONE accent color on ONE focal item (tuft, emblem, visor).
4. **Details last, only if they survive at 100% zoom.** A 1-2 px stripe
   that turns to noise is removed or enlarged (sub-pixel rig details are
   banned: a sprite pixel is ~2.7 rig units, so nothing thinner than
   ~3 rig units may be authored).
5. **Animation last**, on the approved shape (see §7 below).

## 1. Silhouette is the logo

- One memorable protrusion per character (flame tuft, leaf, gem, horn,
  cloud nub) + the ear pair; keep protrusions SEPARATED from the body so
  they never merge into the torso mass.
- Use negative space: the gap between the ears, between body and
  protrusion — never a solid blob.
- Slight asymmetry (one ear a touch larger/tilted) reads alive and is
  easier to distinguish than perfect symmetry.
- All five archetypes share ONE chibi body plan (big round head, single
  pear torso) — identity carries on tint + protrusion + face, not on five
  competing anatomies. Pairwise identity is guarded by the tint-separation
  and distinct-frame tests, not by silhouette IoU alone.
- Verify: `testSilhouetteHasEarProtrusions` (top region shows separated
  runs), `testSilhouetteIsConnected`, `testThumbnailStillReads`.

## 2. Proportions and canvas

- Canvas class: the avatar displays at ~32-48 px → chibi: head height
  scale ≥ 1.0, torso stack smaller than the head.
- Verify: `testChibiProportions`.

## 3. Palette: tight, high-contrast, one light direction

- 6-12 colors per character TOTAL in the active snap set; 2-3 shades per
  material (base/shadow/highlight). One material (the body) carries the
  gradient ramp; everything else is flat. Stage tones (halo/motes) sit
  outside the budget.
- Distinct jobs per color; neighboring tones must differ in value FIRST,
  hue second (readable in grayscale).
- ONE light direction (top-left): a single top→bottom ramp per mass. No
  pillow shading, no per-puff bounce lifts beyond the one rim crescent.
- Reserve the bright accent for a single focal feature.
- Code: `buildGradientPairs` shades only `.primary`; everything else flat.
- Verify: `testPaletteBudget` (active snap candidates ≤ 12),
  `testPixelPalettesAreVivid`, `testTintSeparatesArchetypes`.

## 4. Chunky pixels, clean edges, 1-px contour

- Every lit pixel is EXACTLY a LUT color (`testPixelColorsSnapToLUT`).
- Bayer 4x4 ordered dithering ONLY between ramp tones inside a mass;
  antialiased boundaries snap clean (no speckled fringe).
- The contour is a dithered 1-px halo in a dim ACCENT-tinted tone (on the
  OLED black stage the outline must be light to read).
- No "doubles" (thick L-shaped diagonal clusters), no single-pixel-thin
  details (Derek Yu's chunky-pixels rule), no automatic AA.
- Verify: `testHaloRingIsOnePixelContour`, golden hash pins.

## 5. The face is the avatar

- Big eyes (≥ ~1/6 head width), ~40% catchlight upper-left; eye spacing
  tuned per head width via the face inset; joy = ^-^ lid squint; blush on
  warm/joy.
- Verify: `testPupilsScaleUpForCuteness`, `testFaceInsetFollowsHeadWidth`,
  `testBlushCheeksFollowExpressionWeights`, `testJoySquintsLidsClosed`.

## 6. Motion-friendly shape

- Moving parts on separate bones (engine layers already do this); 1-2 px
  of padding around the sprite so gestures never clip the grid edge —
  tested across the widest pose (a full spin), not just idle.
- Verify: `testSpritePaddingAcrossWidestPose`.

## 7. Stage and life

- Sparse frame-driven mote field (dim accent dust), deterministic in the
  frame index, absent in the rest LOD (OLED power). The stage is a scene,
  not a void.
- Verify: `testMotesAreDeterministicFrameDrivenAndRestFree`.

## Review workflow for any visual change

1. Unit suite green (golden hashes re-pinned deliberately, with a reason).
2. `Tools/visual_smoke_test.sh` — all five archetypes render on-simulator.
3. `Tools/assess_similarity.swift` on the captures — palettes separate,
   tone counts in the authored band, halo + motes minor.
4. Screenshot eyeball pass at native AND zoomed-out (thumbnail) size.
   Numbers catch regressions; only eyes catch "ugly".
