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
            switch renderer {
            case "canvas":
                CanvasGreyboxSpikeView(seed: seed, frameBudget: frames)
            case "spritekit":
                SpriteKitGreyboxSpikeView(seed: seed, frameBudget: frames)
            default:
                AvatarStageView(archetype: stageArchetype(args))
            }
        }
        .onAppear {
            spikeLogger.log("AIVATAR-SPIKE: root appear args=\(args.joined(separator: "|"), privacy: .public) renderer=\(renderer ?? "nil", privacy: .public)")
        }
    }

    private func stageArchetype(_ args: [String]) -> Archetype {
        guard let index = args.firstIndex(of: "-archetype"), index + 1 < args.count,
              let archetype = Archetype(rawValue: args[index + 1]) else {
            return .ember
        }
        return archetype
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

/// Interim stage placeholder; replaced by `AvatarStageView` in A2.
private struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Aivatar")
                .font(.title3)
        }
    }
}
