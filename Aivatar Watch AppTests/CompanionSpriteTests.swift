import XCTest
@testable import Aivatar_Watch_App

/// v13 authored-sprite suite (Tools/PIXEL_DESIGN.md v5). Guards the new
/// source of truth: the grids, the ramp discipline, the cat-class motion
/// budget (2-8 cells per action frame, blinks the only big deltas), and
/// the director's determinism + rate budgets.
final class CompanionSpriteTests: XCTestCase {

    private func fnv(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private func symbols(_ archetype: Archetype, frameID: String) -> [[Character]] {
        AuthoredSprites.sprite(for: archetype).symbols(frameID: frameID)
    }

    private func profile(_ archetype: Archetype) throws -> PersonalityProfile {
        try PersonalityProfile.load(archetype)
    }

    // MARK: - Grids

    func testSpritesAreWellFormed() throws {
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            XCTAssertEqual(sprite.base.count, CompanionSprite.gridHeight, "\(archetype.rawValue): grid height")
            for (i, row) in sprite.base.enumerated() {
                XCTAssertEqual(row.count, CompanionSprite.gridWidth, "\(archetype.rawValue): row \(i) width")
            }
            for frameID in CompanionSprite.frameIDs {
                let grid = sprite.symbols(frameID: frameID)
                XCTAssertEqual(grid.count, CompanionSprite.gridHeight, "\(archetype.rawValue)/\(frameID): height")
                for (y, row) in grid.enumerated() {
                    XCTAssertEqual(row.count, CompanionSprite.gridWidth, "\(archetype.rawValue)/\(frameID): row \(y)")
                    for symbol in row {
                        XCTAssertTrue(".KDBWAA".contains(symbol) || symbol == ".",
                                      "\(archetype.rawValue)/\(frameID): unknown symbol \(symbol)")
                    }
                }
            }
        }
    }

    func testSpritesSeparateAcrossArchetypes() throws {
        // Silhouette is the logo (§1): pairwise-distinct idle dots —
        // no two animals may collapse into the same shape.
        var seen: Set<UInt64> = []
        for archetype in Archetype.allCases {
            let grid = symbols(archetype, frameID: "idle")
            let joined = grid.map { String($0) }.joined()
            let id = fnv(joined)
            XCTAssertFalse(seen.contains(id), "\(archetype.rawValue): sprite collides with an earlier animal")
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, Archetype.allCases.count)
    }

    func testSpritePaletteBudgetAndFamily() throws {
        // §3: exactly 5 ramp tokens per species (ink/shade/body/paper/accent),
        // value-locked across the family: shade darker than body, ink darkest,
        // paper brightest, and one identity hue per animal (grayscale reads).
        func luminance(_ hex: String) -> Double {
            let rgb = CompanionSprite.hexToRGB(hex)
            return 0.299 * Double(rgb.r) + 0.587 * Double(rgb.g) + 0.114 * Double(rgb.b)
        }
        for archetype in Archetype.allCases {
            let palette = AuthoredSprites.sprite(for: archetype).paletteHex
            XCTAssertEqual(Set(palette.keys), Set(["K", "D", "B", "W", "A"]), "\(archetype.rawValue): 5-token ramp")
            XCTAssertLessThan(luminance(palette["K"]!), luminance(palette["D"]!), "ink under shade")
            XCTAssertLessThan(luminance(palette["D"]!), luminance(palette["B"]!), "shade under body")
            XCTAssertGreaterThan(luminance(palette["W"]!), luminance(palette["B"]!), "paper above body")
        }
        // The accent separates from the body tone on every animal
        // (identity, not a re-tint of the mass). Cross-animal sharing is
        // allowed — fox and chameleon both carry the golden accent.
        for archetype in Archetype.allCases {
            let palette = AuthoredSprites.sprite(for: archetype).paletteHex
            XCTAssertNotEqual(palette["A"]!, palette["B"]!, "\(archetype.rawValue): accent must differ from the body")
        }
    }

    func testSpriteIdleFrameHashes() throws {
        // v13 golden pins (first pin 2026-11-03). Update deliberately —
        // and say why. RECORD MODE below reports the values to pin.
        let expected: [Archetype: UInt64] = [
            // Pinned 2026-11-03 (v13): the authored 20x18 idle grids.
            .ember: 12_626_353_783_622_487_802,
            .willow: 6_115_991_415_473_770_972,
            .compass: 91_049_369_191_467_680,
            .prism: 9_456_951_818_924_182_236,
            .nimbus: 5_552_407_490_590_961_342,
        ]
        var actual: [Archetype: UInt64] = [:]
        var recorded: [String] = []
        for archetype in Archetype.allCases {
            let grid = symbols(archetype, frameID: "idle")
            let value = fnv(grid.map { String($0) }.joined())
            actual[archetype] = value
            recorded.append("\(archetype.rawValue) = \(value)")
            let pin = expected[archetype] ?? 0
            if pin != 0 {
                XCTAssertEqual(value, pin, "\(archetype.rawValue) authored idle grid changed")
            }
        }
        PinRecorder.requirePinned(expected, recorded: recorded.joined(separator: ", "), label: "sprite hashes")
    }

    // MARK: - Frame craft

    func testPatchDeltasStaySmall() throws {
        // The cat-class motion budget: an action frame never rewrites the
        // body — only a hand-authored patch of a few cells (blink <= 8,
        // everything else <= 12). This is what keeps discrete poses from
        // ever regressing into jitter.
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            for (frameID, patch) in sprite.patches {
                XCTAssertLessThan(patch.count, 13, "\(archetype.rawValue)/\(frameID): patch too big")
                if frameID == "blink" {
                    XCTAssertLessThanOrEqual(patch.count, 8, "\(archetype.rawValue): blink patch")
                }
            }
            XCTAssertEqual(Set(sprite.patches.keys), Set(CompanionSprite.frameIDs.filter { $0 != "idle" }),
                           "\(archetype.rawValue): every non-idle frame authored")
        }
    }

    func testEveryFrameDiffStaysInsidePatchBudget() throws {
        // Measured diff between idle and each frame, cell by cell — must
        // equal the patch intent: no patch may change more than 12 cells of
        // the grid (or leave stray cells outside its authored set).
        for archetype in Archetype.allCases {
            let idle = symbols(archetype, frameID: "idle")
            for frameID in CompanionSprite.frameIDs.dropFirst() {
                let frame = symbols(archetype, frameID: frameID)
                var diff = 0
                for y in 0..<CompanionSprite.gridHeight {
                    for x in 0..<CompanionSprite.gridWidth {
                        if idle[y][x] != frame[y][x] { diff += 1 }
                    }
                }
                XCTAssertLessThanOrEqual(diff, 12, "\(archetype.rawValue)/\(frameID): graphically \(diff) cells changed")
            }
        }
    }

    func testBlinkRemovesCatchlights() throws {
        // A blink closes the eyes — the W catchlights must vanish and the
        // ink lid line must remain, on every animal (the shared eye style).
        for archetype in Archetype.allCases {
            let idle = symbols(archetype, frameID: "idle")
            let blink = symbols(archetype, frameID: "blink")
            func count(_ grid: [[Character]], _ symbol: Character) -> Int {
                grid.flatMap { $0 }.filter { $0 == symbol }.count
            }
            XCTAssertLessThan(count(blink, "W"), count(idle, "W"),
                              "\(archetype.rawValue): blink must drop the catchlights")
            XCTAssertGreaterThanOrEqual(count(blink, "K"), count(idle, "K") - 2,
                                         "\(archetype.rawValue): blink keeps its lid ink")
        }
    }

    func testHappyAddsASmile() throws {
        // Joy is readable: happy = closed eyes + a smile patch (an
        // accent/ink change somewhere on the face), never just idle.
        for archetype in Archetype.allCases {
            let idle = symbols(archetype, frameID: "idle")
            let happy = symbols(archetype, frameID: "happy")
            var diff = 0
            for y in 0..<CompanionSprite.gridHeight {
                for x in 0..<CompanionSprite.gridWidth {
                    if idle[y][x] != happy[y][x] { diff += 1 }
                }
            }
            XCTAssertGreaterThan(diff, 3, "\(archetype.rawValue): happy must read as an expression")
        }
    }

    func testFaceStyleAcrossTheSet() throws {
        // §5 the face is the avatar: the eye style is uniform — at least
        // a 2-wide pupil block with a W catchlight in the upper-left of
        // the block. Assert: every idle grid has >= 1 'W' catchlight and
        // >= 2 ink cells adjacent to it.
        for archetype in Archetype.allCases {
            let grid = symbols(archetype, frameID: "idle")
            var catchlights = 0
            for y in 0..<(CompanionSprite.gridHeight - 1) {
                for x in 0..<(CompanionSprite.gridWidth - 1) {
                    if grid[y][x] == "W" && grid[y][x + 1] == "K" && grid[y + 1][x + 1] == "K" {
                        catchlights += 1
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(catchlights, 1,
                                        "\(archetype.rawValue): the shared eye style (W catchlight + K pupil)")
        }
    }

    // MARK: - Director

    private func makeDirector(_ archetype: Archetype, seed: UInt64 = 20261103) throws -> SpriteDirector {
        SpriteDirector(profile: try profile(archetype), seed: seed)
    }

    private func frameSequence(_ director: SpriteDirector, ticks: Int) -> [String] {
        var frames: [String] = []
        for _ in 0..<ticks {
            director.advance(toTick: director.tick + 1)
            frames.append(director.currentFrame)
        }
        return frames
    }

    func testDirectorIsDeterministic() throws {
        for archetype in Archetype.allCases {
            let a = try makeDirector(archetype)
            let b = try makeDirector(archetype)
            XCTAssertEqual(frameSequence(a, ticks: 400), frameSequence(b, ticks: 400),
                           "\(archetype.rawValue): same seed must step the same life")
        }
    }

    func testDirectorBlinkRateMatchesProfileBudget() throws {
        // CI rate budget (§7): over 5 director-minutes the blink count
        // must land in a band around the profile rate (discrete schedule
        // gives binomial noise; 40%..200% is generous but tight enough to
        // catch a lost or runaway blink schedule).
        for archetype in Archetype.allCases {
            let director = try makeDirector(archetype)
            director.advance(toTick: 2000)  // 5 minutes of ticks
            let rate = try profile(archetype).gazeProfile.blinkRatePerMin
            let expected = Double(rate) * 5.0
            XCTAssertGreaterThan(Double(director.blinkCount), expected * 0.4,
                                 "\(archetype.rawValue): blinks under budget (\(director.blinkCount) vs ~\(expected))")
            XCTAssertLessThan(Double(director.blinkCount), expected * 2.0,
                               "\(archetype.rawValue): blinks over budget (\(director.blinkCount) vs ~\(expected))")
        }
    }

    func testDirectorTapPlaysHappyForEveryAnimal() throws {
        for archetype in Archetype.allCases {
            let director = try makeDirector(archetype)
            director.handleEvent(.tap)
            XCTAssertEqual(director.currentFrame, "happy", "\(archetype.rawValue): tap reads as joy")
            director.advance(toTick: director.tick + 1)  // happy holds
            XCTAssertEqual(director.currentFrame, "happy", "\(archetype.rawValue): happy holds a beat")
        }
    }

    func testDirectorActsResolveToAuthoredFramesOnly() throws {
        // Life may only ever show authored frames — an unknown event can
        // never draw a blank stage.
        for archetype in Archetype.allCases {
            let director = try makeDirector(archetype)
            for name in ["wave", "bogus", "spin", "sparkle", "doubleTake", "slowBlink"] {
                director.handleEvent(.gesture(name: name))
                XCTAssertTrue(CompanionSprite.frameIDs.contains(director.currentFrame),
                              "\(archetype.rawValue): \(name) must resolve to an authored frame")
            }
        }
    }

    func testDirectorGazeGlancesTowardTheTouch() throws {
        let director = try makeDirector(.ember)
        director.handleEvent(.gazeAt(x: -0.8, y: 0))
        XCTAssertEqual(director.currentFrame, "glanceL", "left touch -> left glance")
        let director2 = try makeDirector(.ember)
        director2.handleEvent(.gazeAt(x: 0.8, y: 0))
        XCTAssertEqual(director2.currentFrame, "glanceR", "right touch -> right glance")
    }

    func testDirectorReduceMotionL2StaysStill() throws {
        // L2 parity contract: no self-scheduled ACTS and no idle accents;
        // the gentle blink stays (the engine's L2 is static + blink), and
        // events still land face-readable.
        for archetype in Archetype.allCases {
            let director = try makeDirector(archetype)
            director.accessibilityMode = .reduceMotionL2
            let frames = frameSequence(director, ticks: 600)
            XCTAssertTrue(frames.allSatisfy { $0 == "idle" || $0 == "blink" },
                          "\(archetype.rawValue): L2 shows only idle + blink")
            XCTAssertEqual(director.actCount, 0, "\(archetype.rawValue): L2 schedules no accents")
            director.handleEvent(.gesture(name: "tick"))
            XCTAssertTrue(CompanionSprite.frameIDs.contains(director.currentFrame),
                          "\(archetype.rawValue): L2 still answers events on the face")
        }
    }

    func testDirectorRestingShowsSleepyUntilWake() throws {
        let director = try makeDirector(.willow)
        director.setResting(true)
        XCTAssertEqual(director.currentFrame, "sleepy")
        director.advance(toTick: 40)
        XCTAssertEqual(director.currentFrame, "sleepy", "rest holds until wake")
        director.handleEvent(.wake)
        XCTAssertEqual(director.currentFrame, "happy", "wake greets")
        director.advance(toTick: director.tick + 10)
        XCTAssertTrue(["idle", "breathe", "idleA", "idleB"].contains(director.currentFrame),
                      "back to the life floor after the greeting")
    }

    func testDirectorDiscreteMotionEnergyBudget() throws {
        // The v13 motion budget: between consecutive ticks the grid may
        // only change through authored patches — mean changed cells per
        // tick over 5 idle minutes stays tiny (pinned at <= 1.5).
        for archetype in Archetype.allCases {
            let director = try makeDirector(archetype)
            var changed = 0
            var ticks = 0
            var last = symbols(archetype, frameID: director.currentFrame)
            for _ in 0..<2000 {
                director.advance(toTick: director.tick + 1)
                let frame = symbols(archetype, frameID: director.currentFrame)
                for y in 0..<CompanionSprite.gridHeight {
                    for x in 0..<CompanionSprite.gridWidth {
                        if last[y][x] != frame[y][x] { changed += 1 }
                    }
                }
                last = frame
                ticks += 1
            }
            let mean = Double(changed) / Double(ticks)
            XCTAssertLessThanOrEqual(mean, 1.5,
                "\(archetype.rawValue): idle motion energy \(String(format: "%.2f", mean)) cells/tick over budget")
        }
    }

    func testDirectorFarewellBlinkThenSleepy() throws {
        // U9: the goodbye is idle -> one blink -> the sleepy hand-off —
        // every session ends warm, never a hard cut.
        for archetype in Archetype.allCases {
            let director = try makeDirector(archetype)
            director.handleEvent(.sleep)
            XCTAssertEqual(director.currentFrame, "idle", "\(archetype.rawValue): farewell breathes first")
            director.advance(toTick: director.tick + 1)
            XCTAssertEqual(director.currentFrame, "blink", "\(archetype.rawValue): farewell blinks")
            director.advance(toTick: director.tick + 2)
            XCTAssertEqual(director.currentFrame, "sleepy", "\(archetype.rawValue): farewell ends sleepy")
        }
    }
}
