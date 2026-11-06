# Pixel-avatar design practices (the standing checklist, v5 — authored sprites)

The standing rule for every visual pass: **design in this order —
silhouette → proportions → palette → details → animation — and design for
instant recognition at the final display size**. The watch stage shows the
companion at ~10 pt per art cell; the same 20x18 grid must also survive
the picker/complication icon. The sprite must read as AUTHORED pixel art.

**v5 changes the source of truth.** v5-v12 rasterized vector primitives
into a pixel grid — vector art in a pixel costume: staircase artifacts at
~6x display scale, one flat hue per animal, and 30 fps transform motion
whose per-frame edge crawl read as jitter. v13 (measured against a decoded
reference mascot — the Mistral cat: a 16x14 logical grid, 5 colors,
19 frames at 150 ms with 2-6 cell deltas per frame) inverts the pipeline:

- **The grid is authored, not sampled.** Each animal is hand-written as
  20x18 string rows over a 5-symbol ramp in
  `Render/CompanionSprite.swift` — diffable cell-by-cell in review.
  The stage draws the grid as flat cell rects: nearest-neighbor by
  construction, no rasterizer, no snap, no antialiasing, no dither.
- **Animation is discrete poses, not transforms.** `SpriteDirector`
  schedules authored micro-frames (blink, glance, quirk, happy, sleepy)
  on a 150 ms clock — 2-8 cell patches, blinks the only bigger deltas.
  The AvatarEngine + rig + vector rasterizer stay FROZEN (schema
  untouched, goldens still pinned) as the dormant fallback.

## 0. Design order (mandatory)

1. **Silhouette first, one flat dark color.** If the animal is not
   readable as a black shape, shading and details will not fix it.
2. **Proportions for the canvas, not realism.** Chibi mass: the head is
   the biggest readable mass, the body one solid mass under it.
3. **Palette only after the shape works.** Exactly 5 tokens: `K` ink,
   `D` shade, `B` body, `W` paper, `A` accent (identity or event).
4. **Details last, only if they survive at 100% zoom.** No 1-cell-thin
   lines; accents attach to masses, never float.
5. **Animation last**, on the approved grid (§7).

## 1. Silhouette is the logo

- One reduced animal per archetype (fox / frog / fish / chameleon /
  bird), authored from ~10-14 cell-wide masses — subtraction, not
  addition.
- One identity anchor per animal, kept SEPARATED from the body by
  negative space: fox ears + white-tipped tail, frog eye domes + wide
  smile, fish fin fan, chameleon casque + coiled ring (with a
  negative-space hole in the coil), bird beak + ONE swept wing.
- Slight asymmetry (one wing, a tail on one side) reads alive.
- Verify: `testSpritesSeparateAcrossArchetypes`, `testFaceStyle-
  AcrossTheSet`, sprite golden pins.

## 2. Grid and scale

- Canvas: **20x18 cells**, all animals, all scales. The stage fills the
  screen width exactly (~9-10 pt per cell on current cases — the
  reference mascot's chunky class); the icon renders the same grid at
  3 device px/cell (60x54). One asset scale-free by construction.
- The companion occupies ~75-90% of the screen height with its face in
  the upper third (§9 glance zone); 1-2 empty cell rows of headroom are
  part of the authored frame — silence is a design element.

## 3. Palette: tight, high-contrast, value-locked

- 5 tokens: `K` ink (species-tinted near-black), `D` shade, `B` body
  (the identity hue), `W` paper (muzzle/belly/catchlight), `A` accent
  (identity detail — bird beak, chameleon casque — or event-only).
- Value rank is fixed and family-locked: ink < shade < body < paper.
  Neighboring tones differ in value FIRST, hue second (grayscale reads).
- 2-tone depth only: `D` where shapes overlap or at the underside,
  `W` at the belly. No gradients, no rim, no outline, no dither.
- Verify: `testSpritePaletteBudgetAndFamily`.

## 4. Hard edges, no contour, no smoothing

- Every cell is exactly one ramp token — cells are drawn as flat rects,
  so the silhouette boundary is a hard cut by construction.
- Icon brand rules forbid outlines/frames and interpolation
  (`interpolation(.none)`; `shouldInterpolate: false` in the PNG path).

## 5. The face is the avatar

- Uniform eye style across the set: a 2-cell-wide pupil block over 2
  rows with the `W` catchlight in the upper-left next to `K` ink (the
  chameleon's turret eye is the designed single-animal variant).
- Blink = the catchlight + upper pupil row clear to body, leaving a
  1-cell lid line; sleepy = a `D` lid row above the slit; happy =
  closed eyes + a smile patch (the accent/ink it lands on is authored
  per animal).
- Verify: `testBlinkRemovesCatchlights`, `testHappyAddsASmile`,
  `testFaceStyleAcrossTheSet`.

## 6. Motion-friendly frames

- Every non-idle frame is a hand-authored PATCH of at most 12 cells
  applied over the idle grid — a moving part is authored as cells, so
  it can never jitter, crawl, or alias (there are no interpolating
  transforms left to misbehave).
- Verify: `testPatchDeltasStaySmall`,
  `testEveryFrameDiffStaysInsidePatchBudget`.

## 7. Stage and life — the silence budget

- The director's clock is 150 ms. Idle life is sparse per-tick
  Bernoulli draws scaled by PersonalityProfile rates (blink cadence
  `blinkRatePerMin`, gaze probes `saccadeRatePerMin`, quirks
  `~0.8/min * tempoScale`): long quiet holds, a blink you can watch,
  occasional 2-tick accents. Deterministic per seed.
- Reduce Motion: L1 keeps blinks but drops idle accents; L2 shows
  idle + blink only, and body accents degrade to face-readable acts —
  the same parity contract as the engine.
- Rest / Always On: a single static sleepy frame in the dimmed rest
  palette (0.22x body, 0.30x paper), no ticks, no motes, no subsecond
  updates; the farewell beat ramps the dim over its last ticks so the
  hand-off into Always On never pops lit pixels.
- Verify: `testDirectorIsDeterministic`,
  `testDirectorBlinkRateMatchesProfileBudget`,
  `testDirectorDiscreteMotionEnergyBudget` (pinned ≤ 1.5 cells/tick),
  `testDirectorReduceMotionL2StaysStill`,
  `testDirectorFarewellBlinkThenSleepy`.

## 7.1 Sonic presence (v14) — the companion's ears

- ONE new reaction frame per animal: `perk` — the alert pose (flared
  fox ears, the frog's listening mouth, the fish's dorsal flare, the
  chameleon's sharpened casque tip, the bird's crest tuft), ≤ 4 cells,
  same authored-patch rules as every other frame.
- Sound is impure at capture, PURE at digest: the mic's RMS stream feeds
  `SoundPresenceLayer` (50 ms ticks: ambient envelope + onset detector
  with a 1.2 s refractory + sustained-voice detector arming from a quiet
  baseline, 10 s refractory). Constant ambience produces ZERO events —
  the companion reacts to change, never to loudness.
- The director maps events to acts behind a 2.4 s guard (no clap storm
  jitter): onset → `perk`; voice → the personality acknowledgment
  (ember perks, willow slow-blinks, compass ticks, prism locks the
  turret, nimbus chirps). Reduce Motion L2 degrades both to blink.
- Privacy is a design surface: a visible waveform tell while the mic is
  live, one in-context permission ask, mic life = stage life (never in
  Always On, never in the background), zero audio persisted.
- Verify: `SoundPresenceTests` — silence, utterance/refractory
  fixtures, ambience non-events, onset budgets, the reaction map,
  the act gap, the rest state.

## 7.2 Life 2.0 (v15/v16) — the life floor, mood, autonomy

- **The floor breathes**: `breathe` (a 2-cell belly patch) alternates
  every ~1.35 s; `idleA`/`idleB` drift variants rotate every ~8 s. The
  companion never sits perfectly still between acts. L2 pins the floor
  to plain idle; rest stays the single sleepy frame.
- **Mood is the independence signal**: calm/curious/bored/lonely/playful
  from interaction recency + rate (and sound events → curious). Lonely
  earns a rate-capped attention poke (perk + blink at you, ≤ 1/36 s);
  bored doubles glance-aways; playful doubles quirks. Deterministic per
  seed; memory stays an input.
- **Anticipation**: a quirk is always preceded by a 1-tick `perk`
  wind-up — acts read as chosen, not random. Long unattended stretches
  earn one `yawn` (90 s idle, 4.5 min cooldown).
- **Autonomy**: every ~30-60 s a single dim mote (25% body tone, one
  cell, stage-level) drifts in and the companion glances at it —
  self-directed play with one focal story. Never under L2 or rest.
- **Memory is visible**: interiority traces are authored overlay cells
  on the sprite (willow's sprout, compass's week grid, prism's trinket),
  composed with any frame inside the patch budget.
- Verify: `Life2Tests` — breathing floor, variant rotation, L2 static,
  mood transitions + determinism, poke/yawn rate caps, wind-up
  invariant, mote spawn/chase/fade + duty cycle, overlay budgets.

## Review workflow for any visual change

1. Unit suite green (sprite + engine golden pins updated deliberately,
   with a reason comment).
2. `Tools/visual_smoke_test.sh` — all five archetypes render on-simulator.
3. `Tools/assess_similarity.swift` on the captures — palettes separate,
   tone counts in the authored band.
4. Screenshot eyeball pass at native AND zoomed-out (thumbnail) size.
   Numbers catch regressions; only eyes catch "ugly".
