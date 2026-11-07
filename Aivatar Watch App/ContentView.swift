//
//  ContentView.swift
//  Aivatar Watch App
//

import SwiftUI
import os

/// Route root for Phase A milestones. Launch arguments drive the A0 spike:
/// `-spike canvas` / `-spike spritekit`, optionally `-spike-frames <n>`,
/// `-spike-seed <u64>` for reproducible measurement runs.
struct ContentView: View {
    var body: some View {
        let args = ProcessInfo.processInfo.arguments
        let renderer = value(after: "-spike", in: args)
        let frames = Int(value(after: "-spike-frames", in: args) ?? "") ?? 450
        let seed = UInt64(value(after: "-spike-seed", in: args) ?? "") ?? 20261010

        return Group {
            // v26: spike views are debug-only — never routable in release.
            #if DEBUG
            switch renderer {
            case "canvas":
                CanvasGreyboxSpikeView(seed: seed, frameBudget: frames)
            case "spritekit":
                SpriteKitGreyboxSpikeView(seed: seed, frameBudget: frames)
            default:
                AvatarStageView(archetype: launchArchetype(args))
            }
            #else
            AvatarStageView(archetype: launchArchetype(args))
            #endif
        }
        .onAppear {
            spikeLogger.log("AIVATAR-SPIKE: root appear args=\(args.joined(separator: "|"), privacy: .public) renderer=\(renderer ?? "nil", privacy: .public)")
        }
    }

    /// Debug/CI override only; nil in normal launches, where the persisted
    /// companion selection wins (ArchetypeSelection precedence).
    private func launchArchetype(_ args: [String]) -> Archetype? {
        ArchetypeSelection.fromLaunchArguments(args)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
