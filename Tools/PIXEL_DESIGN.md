# Pixel-avatar design practices (the standing checklist)

The rule for every visual pass on the avatar stage: **the sprite must read as
authored pixel art, not as vector art downsampled.** This file is the
checklist every future style/dynamics session starts from. Each principle
names where it lives in the code and how it is verified.

## 1. Authored palette ramps, not incidental snaps

The gradient fills produce continuous colors; the LUT must contain the
AUTHORED ramp (role color, lifted top stop, deepened bottom stop) so ramps
quantize to 3-4 intentional tones per mass. If a stop is missing from the
LUT, gradient pixels snap to whatever palette color happens to be nearest
and the body reads as noise.

- Code: `AvatarSpritePainter.gradientPairs` -> `rampTonesForRasterizer`;
  `PixelStageRasterizer` merges them into the LUT + active snap candidates.
- Verify: `testLUTContainsAuthoredRampTones`.

## 2. Dither only interior ramps; edges stay clean

Ordered (Bayer 4x4) dithering belongs BETWEEN ramp tones inside a mass —
the classic hi-bit texture. Antialiased shape boundaries must snap to the
nearest tone with no dither, or the silhouette grows a speckled fringe.

- Code: `PixelStageRasterizer.snapToLUT` — pixels with partial alpha
  coverage (shape edges) snap clean; full-coverage pixels may dither.
- Verify: pixel golden hashes (deliberate pins) + screenshot review.

## 3. The face is the avatar: big eyes, tuned spacing

- Eyes >= ~1/6 of the head width each; catchlight ~40% of the pupil, upper-
  left. Small pupils read cold (U2); pupils never shrink below the base.
- Eye spacing is NOT fixed: it is tuned per head width via the face inset
  (`speciesFaceInset`) so a narrow head (Ember) pulls eyes in and a wide
  head (Willow) pushes them out. Fixed spacing on divergent head plans
  reads as a bug, not a style.
- Code: `speciesSlotScale("pupilL"/"pupilR")` (size),
  `speciesFaceInset` (spacing), catchlight spec in the painter.
- Verify: `testPupilsScaleUpForCuteness`, `testFaceInsetFollowsHeadWidth`.

## 4. Creature cues beat abstraction

A mascot needs instant biological recognition: ears are the cheapest
cuteness device in pixel art. Every species carries a two-ear cluster
(shaped per temperament: flame, leaf, crystal, triangle, cloud nubs),
body-colored with the same volumetric ramp as the head so they read as
part of the anatomy, never stickers.

- Code: `buildSpeciesDecorations` ear block, id `"ear"`.
- Verify: `testSpeciesCarryEars`.

## 5. One silhouette, one accent, contour on black

- Identity = tint + ONE trait token; extra accents read as clutter.
- On a pure-black OLED stage the outline must be LIGHT to read: the halo
  is a dithered 1-px dilation in a dim ACCENT-tinted tone (not gray), so
  the contour belongs to the palette family.
- Code: `.halo` role derived from accentA; `applyHalo` (Bayer-dashed).
- Verify: `testHaloRingIsOnePixelContour`, `testPixelPalettesAreVivid`
  (stage tones excluded from the body-tint measurement).

## 6. Chunky intentional pixels

The grid (64x78) is a floor for detail, not a target: fat crisp rects,
no sub-pixel features, no antialiased blurs. Every lit pixel is EXACTLY a
LUT color — the snap is what makes it pixel art.

- Verify: `testPixelColorsSnapToLUT` (every lit pixel is LUT-exact).

## 7. Motion is part of the art (the 12 principles stay in force)

Squash & stretch on big clips, anticipation before, settle after;
breathing/blink/gaze always on; touch directs gaze (the eyes answer the
finger). Accessibility floors (Reduce Motion L1/L2) override everything.

- Verify: engine test suite (blink/gesture/reaction budgets, wake, L1/L2).

## 8. The stage is a scene, not a void

A sparse frame-driven mote field (dim accent dust) keeps the stage alive;
it is a pure function of the frame index (determinism) and disappears in
the rest LOD (OLED power).

- Verify: `testMotesAreDeterministicFrameDrivenAndRestFree`.

## Review workflow for any visual change

1. Unit suite green (golden hashes re-pinned deliberately, with a reason).
2. `Tools/visual_smoke_test.sh` — all five archetypes render on-simulator.
3. `Tools/assess_similarity.swift` on the captures — silhouettes separate
   (IoU), palettes separate, tone counts in the 60-100 band (dithered,
   not banded), halo + motes present but minor.
4. Screenshot eyeball pass. Numbers catch regressions; only eyes catch
   "ugly".
