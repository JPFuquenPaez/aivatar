import Foundation
#if canImport(Intents) && !os(watchOS)
import Intents
#endif

/// RelevanceDonor (Aivatar 2.0, platform adoption pass): donates a fitness
/// relevance clue while a workout is live or a split is pending. Called ONLY
/// from CompanionWidgetPublisher.publish — on real state changes (visit/wake/
/// workout events), never by polling (G9).
///
/// Platform note (verified against the watchOS SDK): the Siri donation APIs
/// (INInteractionCenter / INRelevantShortcutCenter) do not exist on watchOS —
/// there, Smart Stack relevance is driven by WidgetKit's TimelineEntryRelevance,
/// which Aivatar already ships (CompanionStateDerivation.relevanceScore, v31).
/// So on watchOS this donor is the documented hook point (and a no-op), and
/// the pure relevance score remains the shipped signal; on platforms where the
/// Intents donation APIs exist, the fitness clue is donated for real.
nonisolated enum RelevanceDonor {
    static func donateIfNeeded(lastEventKind: LifeKind?) {
        guard let kind = lastEventKind,
              kind == .workoutLive || kind == .split else { return }
        #if canImport(Intents) && !os(watchOS)
        let intent = INStartWorkoutIntent()
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        INInteractionCenter.shared.donateInteraction(interaction) { _ in }
        #endif
    }
}
