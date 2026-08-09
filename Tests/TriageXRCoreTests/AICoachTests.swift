import Foundation
import Testing
@testable import TriageXRCore

struct AICoachTests {
    @Test
    func requestMapsReplayEvidenceIntoStableCitationIDs() throws {
        let evidence = makeEvidence(outcome: .succeeded)
        let request = makeRequest(evidence: [evidence])

        let event = try #require(request.events.first)
        #expect(event.id == evidence.id.uuidString.lowercased())
        #expect(event.timestamp == "00:12")
        #expect(event.actorRole == ResponderRole.incidentCommander.title)
        #expect(event.cues == ["Fuel visible beside vehicle"])
    }

    @Test
    func reportRejectsUnknownEvidenceReferences() {
        let request = makeRequest(evidence: [makeEvidence(outcome: .succeeded)])
        let fabricated = AICoachObservation(
            headline: "Unsupported claim",
            explanation: "This citation was never recorded.",
            evidenceEventIDs: [UUID().uuidString.lowercased()]
        )
        let report = AICoachReport(
            summary: "Invalid report",
            strongestDecision: fabricated,
            missedCue: fabricated,
            nextDrill: fabricated
        )

        #expect(throws: AICoachValidationError.ungroundedObservation) {
            try report.validated(against: request)
        }
    }

    @Test
    func localFallbackIsGroundedAndPreservesTheDeterministicScore() throws {
        let positive = makeEvidence(outcome: .succeeded)
        let missed = makeEvidence(
            elapsed: 28,
            outcome: .needsReview,
            recommendedAction: "Report the hazard before entering the casualty area."
        )
        let request = makeRequest(evidence: [positive, missed])

        let report = try AICoachReport.localFallback(for: request)
        let validated = try report.validated(against: request)
        let knownIDs = Set(request.events.map(\.id))

        #expect(request.score.total == 68)
        #expect(validated.observations.flatMap(\.evidenceEventIDs).allSatisfy(knownIDs.contains))
        #expect(validated.nextDrill.explanation == "Report the hazard before entering the casualty area.")
        #expect(validated.disclaimer == AICoachReport.safetyDisclaimer)
    }

    private func makeRequest(evidence: [DecisionEvidence]) -> AICoachRequest {
        AICoachRequest(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            scenarioPace: .demo,
            score: ScoreBreakdown(
                safety: 12,
                assessment: 20,
                triage: 18,
                treatment: 10,
                communication: 8
            ),
            evidence: evidence
        )
    }

    private func makeEvidence(
        elapsed: TimeInterval = 12,
        outcome: DecisionOutcome,
        recommendedAction: String? = nil
    ) -> DecisionEvidence {
        DecisionEvidence(
            elapsed: elapsed,
            category: "Safety",
            action: "Inspected the fuel hazard",
            actorRole: .incidentCommander,
            outcome: outcome,
            rationale: "The hazard was visible before casualty contact.",
            cues: ["Fuel visible beside vehicle"],
            consequence: "The entry route remained controlled.",
            recommendedAction: recommendedAction,
            snapshot: IncidentReplaySnapshot(
                elapsed: elapsed,
                scenarioPace: .demo,
                selectedCasualtyID: nil,
                sceneSurveyed: true,
                hazardIdentified: true,
                hazardCommunicated: false,
                resourceRequestSent: false,
                casualties: []
            )
        )
    }
}
