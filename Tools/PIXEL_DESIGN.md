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

## 7.3 Ritual bonding (v16, Ambient Life F1) — bond is felt, never metered

- **Rituals, not resources**: bond grows only through micro-rituals —
  the long-press slow blink, the day's first greeting, the acknowledged
  farewell (once per session), the one-time naming ceremony, and daily
  presence (opening the app once a day). There is no hunger, no decay,
  no death — absence never reduces anything (G4 is structural: bond XP
  is monotonic, there is no code path that subtracts).
- **Levels are invisible on the stage**: no XP bar, no numbers, no
  streak flame. What changes is behavior — L2+: the signature quirk
  joins the idle rotation (rate ×1.5→×3), L3+: the companion glances
  away less (it looks at you more), L4+: the farewell bloom holds
  longer, L5 ("confidant"): a one-cell accent memento below the body
  (cell 9,16 — pinned empty in every base grid) and the About line
  "· old friends".
- **Every ritual answers within one tick** (150 ms): slow blink →
  the watchable slow blink, greetings/naming → happy, farewell → the
  acknowledging blink. Under Reduce Motion L2 the ritual is a
  VoiceOver custom action ("Share a slow blink") — never gesture-only.
- **Announcements, not UI**: a level-up plays the two-step bond haptic
  and posts one VoiceOver announcement ("Ember trusts you more").
- **Memory schema v3 is additive**: `bondXP`, `lifeLog` (ring of 20
  hashed entries), and the two once-per-day gates decode with defaults
  from v15 payloads (G8); `SchemaFreezeTests` pins the contract.
- Verify: `BondRulesTests` — XP table, thresholds, monotonicity,
  once-per-day gates, level-up crossing, legacy decode, ring cap,
  director bond bias + determinism, memento cell, sequence goldens.

## 7.4 Life sense (v17, Ambient Life F2) — reactions, never nags

- **The pet notices your real day**: on visit/wake/foreground only, the
  bridges poll once (never a loop — zero rest-state cost) and translate
  calendar-soon / workout-done / slept-with-watch into content-free
  `LifeEvent`s (hashes + bands, never titles or numbers — G5).
- **Motion budget**: a life event is an Expressive-tier act — at most ONE
  per wake, a 10-min per-kind cooldown, nothing while resting, and under
  L2 a face-readable blink only. The per-archetype answer (Nimbus's alert
  perk, Willow's settle-blink, Compass's week-grid quirk) is the
  personality, not a notification light.
- **Caps are structural**: <= 3 calendar reactions/day (the bridge reads
  the lifeLog ring, not the clock); re-opens never re-celebrate old
  workouts (anchored query); sleep reports once per day.
- **Consent = dormancy**: both Settings toggles off -> no polling, no
  permission ask, app indistinguishable from one without the feature.
- Verify: `LifeSenseTests` — window/cap/banding pure cores, hash-only
  payloads, mapping parity across archetypes, one-per-wake + cooldown +
  L2/rest behavior, determinism.

## 7.5 Watch-face presence icons (v18, Ambient Life F4)

- **One asset, three states**: the complication renders the same authored
  idle grid as the stage, per presence state — `awake` is the normal LUT,
  `asleep` is the rest-LOD dim (paper x0.30, all else x0.22 — identical
  factors to the stage's rest frame, so the face and the stage agree),
  `event` highlights accent cells in the species' paper tone.
- **State is never animated in the complication** — the state change
  across the day is the animation. Text families (inline/rectangular)
  carry the state in words; VoiceOver reads "Ember, napping", never art.
- **The schedule is data**: the widget timeline's hourly anchors include
  the awake/event EXPIRY times (hard cap 12 entries, G9), and each entry's
  presence is derived from snapshot timestamps — the face reverts to
  asleep on its own; the app only republishes on its own state changes.
- Verify: `WidgetPresenceTests` — lenient snapshot v2 decode, presence
  priority/windows, copy table (<= 8 words), timeline cap under
  adversarial inputs, icon variants, kind-hash parity app<->widget.

## 7.6 Weather-aware personality (v18, Ambient Life F3)

- **The pet's element meets the real element**: current conditions are
  fetched on visit only (60-min cache, never a background poll; WeatherKit
  watchOS 11+, dormant on 10), classified ON-DEVICE into a closed set
  (sunny/gray/rain/wind/cold/hot/unknown). The engine sees only the class
  hash — goldens inject classes, never live weather.
- **Dials, not new concepts**: profile schema v3 `weatherDials` maps each
  class to tempo/amplitude/accent/hue multipliers consumed by the EXISTING
  idle schedule (quirk rate, glance rate, mote density). Absent block =
  neutral (v2 profiles unchanged). Per-archetype answers: rain makes the
  frog glad, wind makes the bird preen, gray makes the fox cozy.
- **Hue shift stays inside the LUT budget**: render-time HSV hue rotation
  (saturation/value preserved, <= 20 deg, Prism only) — the pinned grids
  and palette-family tests are untouched; luminance ordering is pinned by
  test. Weather never encodes meaning in color alone: motion/tempo changes
  always accompany it, and copy stays in words.
- **Emission is once per (class, day)** and the complication carries the
  weather note via the existing event state ("checked the sky").
- Verify: `WeatherSenseTests` + `SchemaFreezeTests` v3 pins — classify
  table, hash round-trip, emission rule, dials parity/fallback, director
  bias determinism, reaction parity, hue rotation purity.

## 7.7 Morning life beats (v19, Ambient Life F5)

- **The first glance of the day is a greeting, not a dashboard**: once per
  day, a pure selector picks ONE beat — life event (18 h lookback) >
  weather line > the companion's own memory trace > warm — and the
  director plays it as one queued act run (existing vocabulary only).
- **Budget and skip**: the whole beat is <= 5 s (pinned via
  `pendingActTicks`); any input replaces the queue, so the skip path is
  one tap = <= 150 ms. Later visits the same day get the short wake only.
- **Copy is typography, never pixels**: the caption is a Dynamic Type
  `Text` overlay (<= 8 words, house voice) and rides the stage's
  accessibility label for VoiceOver; under L2 the beat flattens to
  face-only frames and the caption still shows.
- Verify: `WakeBeatTests` — selector priority/gates/lookback, caption
  lint, act mapping, sequence order + budget + skip + L2 + determinism.

## 7.8 Workout mode (v21, Ambient Life F6) — presence during the run

- **One focal story while running**: workout mode swaps the life floor to
  a run cycle (idleA/idleB alternating at the pace-band cadence) and
  suspends quirks, glances, motes, lonely pokes — the run IS the motion.
  Splits are the only acts: one cheer + one haptic, hard-capped at 1/45 s.
- **Bands, never numbers**: live metrics are polled at a 10 s cadence into
  pace bands 0...5 (pure mapping) — the engine stays numeric-free. The only
  number on the stage is elapsed mm:ss (system monospaced digits).
- **Honest recovery**: the HKWorkoutSession cannot survive a force-quit;
  a persisted in-progress marker is finished as a partial workout (or
  discarded under 60 s) on next launch — pure decision, unit-tested.
- **Power**: metrics at 10 s cadence, no streams, no background polling;
  L2 flattens the run to static + blink (splits announced by VoiceOver).
- Verify: `WorkoutModeTests` — pace bands, split detection, recovery
  decisions, run grammar/cadence, split caps, L2, determinism.

## 7.9 Haptic language (v22, Ambient Life F7) — felt, never noisy

- **One vocabulary**: `HapticMoment` (ack/bond/lifeEvent/split/farewell/
  greet/wake) -> `WKHapticType` per archetype. Same moment = same SHAPE
  everywhere (one tick, the rising pair, one soft stop); only the flavor
  differs. No CoreHaptics on watchOS — the WKInterfaceDevice set is the
  honest ceiling, and haptics mark state transitions only, never loops.
- **Caps are structural**: `HapticRateLimiter` (pure, clock-injected) —
  <= 6/hour rolling, >= 1.5 s between any two — proven under adversarial
  bursts. Every haptic is redundant with visual + VoiceOver.
- Verify: `HapticsAndPostcardTests` — grammar parity/shape consistency,
  limiter caps, postcard pins.

## 7.10 Postcards (v22, Ambient Life F8) — determinism as the artifact

- **A card of the REAL companion**: `PostcardComposer` runs a seed-picked
  two-act moment through the same director+sprite path as the live stage;
  identical (archetype, seed, memory snapshot) -> identical frame hashes
  (pinned per archetype). Corrupt inputs degrade to the warm greeting —
  a postcard never fails to compose. Captions are name/day/bond/weather
  words only, <= 8 words, never life-log content.
- **Export lands with the iPhone companion shell** (this project has no iOS
  target yet); the watch-side preview (Settings -> About -> Postcard)
  renders the real card. No server, no account, no feed.
- Verify: `HapticsAndPostcardTests` — determinism + golden pins, seed
  sensitivity, caption lint/privacy, corrupt fallback, grid integrity.

## 7.11 Sprite craft + stage composition (v28) — the second audit's fixes

From the 4-subagent design audit (stage composition, sprite craft, motion
grammar, widget/chrome). The cat-class evidence: authored cells, discrete
poses, one focal story.

- **Identity anchors are literal, not implied**: ember's white tail tip sits
  at the tail's literal tip cell (x=18) and rides the wag in quirk/idleA —
  a floating accent was the old bug. Compass keeps a 2-cell mouth in the BASE
  row (it survives downsampling to the complication icon) and idleB no longer
  erases it. Nimbus idleB steps one foot (edge-cell swap), never a plank;
  the crest perk is a 2-cell tuft with no detached pixel. Prism's quirk is a
  coil-tighten (distinct from glanceR); its breathe stays off the coil ring.
  Willow's yawn is a clean 4-cell cavity, no orphaned ink.
- **Expressions must read at a glance**: happy = closed eyes + a 2-cell open
  mouth (>= 4 real diffs vs idle — `testHappyAddsASmile` enforces > 3).
- **The profile grammar shapes the live stage**: blink holds
  `SpriteDirector.blinkTicks(durationScale:)` (>= 2 ticks = 300 ms floor;
  willow 1.8 -> 4 ticks, a watchable blink) with a 3-tick refractory; quirk
  wind-ups follow `perkWindupTicks(anticipation:)` — any nonzero anticipation
  earns >= 1 perk tick, exactly zero (willow) means no wind-up; looks are
  2-tick darts, not 600 ms stares; breathe holds 4 of every 24 ticks (~25%
  duty). A same-tick tap after a gaze plays dart-then-happy as one run.
- **One focal story**: `play()` clears the self-play mote on any act except
  the chase look — and a cleared mote gets a cooldown, never an instant
  respawn (otherwise act-heavy high-bond idle would spawn motes faster than
  low-bond idle and invert the gaze-bias bond signal).
- **Stage composition**: corner tells (elapsed, listening waveform) respect
  the bezel safe area; hints/caption/name/state live in ONE bottom block so
  they can never collide; the farewell dim ramps over the LAST bloom ticks
  (peak-end), keeping the goodbye warm through idle+blink; the Canvas skips
  redraws when nothing visible changed (frame+overlay+mote+hue+ramp bucket
  key) — OLED/battery discipline on long idle holds; companion switch
  rebuilds the renderer via `.id(ObjectIdentifier(director))`.
- Golden pins re-pinned deliberately with reason comments (idle hashes for
  the two changed base grids; bond sequences and postcard first-frames for
  the new act grammar). Verify: `CompanionSpriteTests`, `SpriteFixTests`,
  `Life2Tests`, `BondRulesTests`, `WakeBeatTests`, `HapticsAndPostcardTests`.

## Review workflow for any visual change

1. Unit suite green (sprite + engine golden pins updated deliberately,
   with a reason comment).
2. `Tools/visual_smoke_test.sh` — all five archetypes render on-simulator
   (v23: fresh boot per attempt, capture in the launch+3s..+21s lit window,
   up to 3 boots per archetype; analyzer coverage floor is 10% — the dimmed
   watch face reads ~3.4% and must not pass as an avatar).
3. `Tools/assess_similarity.swift` on the captures — palettes separate,
   tone counts in the authored band.
4. Screenshot eyeball pass at native AND zoomed-out (thumbnail) size.
   Numbers catch regressions; only eyes catch "ugly".
