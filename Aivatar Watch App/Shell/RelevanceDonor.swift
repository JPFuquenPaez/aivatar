import Foundation
#if canImport(Intents)
import Intents
#endif

/// RelevanceDonor (Aivatar 2.0, platform adoption pass): donates a fitness
/// relevance clue while a workout is live or a split is pending. Called ONLY
/// from CompanionWidgetPublisher.publish — i.e. on real state changes
/// (visit/wake/workout events), never by polling (G9). The widget's shipped
/// pure relevance score (TimelineEntryRelevance) remains the primary Smart
/// Stack signal; this adds the Siri/Smart-Stack interaction donation where
/// the Intents framework is available.
nonisolated enum RelevanceDonor {
    static func donateIfNeeded(lastEventKind: LifeKind?) {
        #if canImport(Intents)
        guard let kind = lastEventKind,
              kind == .workoutLive || kind == .split else { return }
        let intent = INStartWorkoutIntent()
        intent.workoutLocation = .outdoor
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        INInteractionCenter.shared.donateInteraction(interaction) { _ in }
        #else
        _ = lastEventKind
        #endif
    }
}
