import Foundation
import Testing
@testable import TriageXRCore

struct IncidentCollaborationTests {
    @Test
    func rolesPermitOnlyTheirOperationalActions() {
        #expect(IncidentCommand.inspectSurveyCheckpoint(.forward).isPermitted(for: .incidentCommander))
        #expect(!IncidentCommand.inspectSurveyCheckpoint(.forward).isPermitted(for: .triageOfficer))
        #expect(IncidentCommand.recordSurveyCoverage([0, 1]).isPermitted(for: .incidentCommander))
        #expect(!IncidentCommand.recordSurveyCoverage([0, 1]).isPermitted(for: .airwayResponder))
        #expect(IncidentCommand.setScenarioPace(.demo).isPermitted(for: .incidentCommander))
        #expect(!IncidentCommand.setScenarioPace(.demo).isPermitted(for: .triageOfficer))
        #expect(IncidentCommand.setTrainingMode(.assessed).isPermitted(for: .incidentCommander))
        #expect(!IncidentCommand.setTrainingMode(.assessed).isPermitted(for: .triageOfficer))
        #expect(IncidentCommand.setScenarioPaused(true).isPermitted(for: .incidentCommander))
        #expect(!IncidentCommand.setScenarioPaused(true).isPermitted(for: .triageOfficer))

        #expect(IncidentCommand.assignPriority("casualty-a", .p1).isPermitted(for: .triageOfficer))
        #expect(!IncidentCommand.assignPriority("casualty-a", .p1).isPermitted(for: .airwayResponder))

        #expect(IncidentCommand.beginCPR("casualty-b").isPermitted(for: .airwayResponder))
        #expect(!IncidentCommand.beginCPR("casualty-b").isPermitted(for: .incidentCommander))

        for role in ResponderRole.allCases {
            #expect(IncidentCommand.selectCasualty("casualty-a").isPermitted(for: role))
        }
    }

    @Test
    func everyCommandHasAReplaySafeActionTitle() {
        let evidence = AssessmentEvidence.simulatorTarget(gesture: "test")
        let commands: [IncidentCommand] = [
            .begin,
            .end,
            .reset,
            .setTrainingMode(.assessed),
            .setScenarioPace(.demo),
            .setScenarioPaused(true),
            .inspectSurveyCheckpoint(.leftFlank),
            .recordSurveyCoverage([11, 0, 1]),
            .identifyHazard,
            .communicateHazard,
            .requestResources,
            .selectCasualty("casualty-a"),
            .closeCasualty,
            .performAssessment("casualty-a", .response, evidence),
            .assignPriority("casualty-a", .p1),
            .beginCPR("casualty-b"),
            .endCPR("casualty-b", "test")
        ]

        for command in commands {
            #expect(!command.actionTitle.isEmpty)
            #expect(command.actionTitle.first?.isLowercase == true)
        }
    }

    @Test
    func casualtyCommandsCarryTheirAuthoritativeTarget() {
        let evidence = AssessmentEvidence.simulatorTarget(gesture: "test")
        let commands: [IncidentCommand] = [
            .selectCasualty("casualty-b"),
            .performAssessment("casualty-b", .breathing, evidence),
            .assignPriority("casualty-b", .p1),
            .beginCPR("casualty-b"),
            .endCPR("casualty-b", "test")
        ]

        for command in commands {
            #expect(command.targetCasualtyID == "casualty-b")
        }
        #expect(IncidentCommand.selectCasualty("casualty-b").isLocalNavigation)
        #expect(IncidentCommand.closeCasualty.isLocalNavigation)
        #expect(!IncidentCommand.beginCPR("casualty-b").isLocalNavigation)
    }

    @Test
    func onlyReplaceableActiveUpdatesUseBestEffortDelivery() {
        #expect(
            IncidentSnapshotDeliveryPolicy.requiresReliableDelivery(
                previousPhase: .briefing,
                currentPhase: .briefing
            )
        )
        #expect(
            IncidentSnapshotDeliveryPolicy.requiresReliableDelivery(
                previousPhase: .briefing,
                currentPhase: .active
            )
        )
        #expect(
            !IncidentSnapshotDeliveryPolicy.requiresReliableDelivery(
                previousPhase: .active,
                currentPhase: .active
            )
        )
        #expect(
            IncidentSnapshotDeliveryPolicy.requiresReliableDelivery(
                previousPhase: .active,
                currentPhase: .complete
            )
        )
    }

    @Test
    func instructorCanInterveneAcrossEveryCommand() {
        let evidence = AssessmentEvidence.simulatorTarget(gesture: "test")
        let commands: [IncidentCommand] = [
            .begin,
            .end,
            .reset,
            .setTrainingMode(.guided),
            .setScenarioPace(.realtime),
            .setScenarioPaused(false),
            .inspectSurveyCheckpoint(.rear),
            .recordSurveyCoverage([5, 6, 7]),
            .identifyHazard,
            .communicateHazard,
            .requestResources,
            .selectCasualty("casualty-a"),
            .closeCasualty,
            .performAssessment("casualty-a", .response, evidence),
            .assignPriority("casualty-a", .p1),
            .beginCPR("casualty-b"),
            .endCPR("casualty-b", "test")
        ]

        for command in commands {
            #expect(command.isPermitted(for: .instructor))
        }
    }

    @Test
    func sharedMessagesRoundTripWithoutLosingEvidence() throws {
        let casualty = Casualty(
            id: "casualty-a",
            name: "Alex",
            location: "Marker",
            initialFindings: [.response: "Unresponsive"],
            deterioratedFindings: [:],
            correctInitialPriority: .p1,
            correctDeterioratedPriority: nil,
            initialHealth: 100,
            deteriorationProfile: .none,
            health: 100
        )
        let replay = IncidentReplaySnapshot(
            elapsed: 12,
            scenarioPace: .demo,
            selectedCasualtyID: casualty.id,
            sceneSurveyed: true,
            hazardIdentified: true,
            hazardCommunicated: false,
            resourceRequestSent: false,
            casualties: [
                CasualtyReplayState(
                    id: casualty.id,
                    name: casualty.name,
                    health: casualty.health,
                    assignedPriority: .p1,
                    correctPriority: .p1,
                    completedAssessments: [.response],
                    isReceivingCPR: false,
                    isDeceased: false,
                    conditionLabel: casualty.conditionLabel
                )
            ]
        )
        let evidence = DecisionEvidence(
            elapsed: 12,
            category: "Triage",
            action: "Tagged Alex as P1",
            actorRole: .triageOfficer,
            outcome: .succeeded,
            rationale: "Evidence matched P1.",
            cues: ["Unresponsive"],
            consequence: "Immediate queue",
            snapshot: replay
        )
        let systemEvidence = DecisionEvidence(
            elapsed: 18,
            category: "Deterioration",
            action: "Condition worsened",
            actorRole: nil,
            outcome: .scenarioUpdate,
            rationale: "Untreated cardiac arrest continued.",
            cues: ["Untreated time increased"],
            consequence: "Reassessment became necessary.",
            recommendedAction: "Reassess immediately.",
            snapshot: replay
        )
        let snapshot = SharedIncidentSnapshot(
            revision: 4,
            phase: .active,
            trainingMode: .assessed,
            scenarioPace: .demo,
            isPaused: true,
            casualties: [casualty],
            hazardIdentified: true,
            hazardCommunicated: false,
            surveyedCheckpoints: SurveyCheckpoint.required,
            surveyCoverageBins: SurveyCoverage.allBins,
            resourceRequestSent: false,
            deteriorationTriggered: false,
            events: [],
            decisionEvidence: [evidence, systemEvidence],
            responseTempo: responseTempo(at: 12),
            elapsed: 12,
            conditionAlert: nil
        )

        let encoded = try JSONEncoder().encode(IncidentMessage.snapshot(snapshot))
        let decoded = try JSONDecoder().decode(IncidentMessage.self, from: encoded)

        guard case .snapshot(let decodedSnapshot) = decoded else {
            Issue.record("Expected a snapshot message")
            return
        }
        #expect(decodedSnapshot == snapshot)
        #expect(decodedSnapshot.trainingMode == .assessed)
        #expect(decodedSnapshot.isPaused)
        #expect(decodedSnapshot.scenarioPace == .demo)
        #expect(decodedSnapshot.sceneSurveyed)
        #expect(decodedSnapshot.surveyedCheckpoints == SurveyCheckpoint.required)
        #expect(decodedSnapshot.surveyCoverageBins == SurveyCoverage.allBins)
        #expect(decodedSnapshot.decisionEvidence.first?.actorRole == .triageOfficer)
        #expect(decodedSnapshot.decisionEvidence.first?.cues == ["Unresponsive"])
        #expect(decodedSnapshot.decisionEvidence.last?.actorRole == nil)
        #expect(decodedSnapshot.decisionEvidence.last?.outcome == .scenarioUpdate)
        #expect(decodedSnapshot.decisionEvidence.last?.recommendedAction == "Reassess immediately.")
        #expect(decodedSnapshot.responseTempo.elapsed(for: .hazardIdentified) == 12)
    }

    @Test
    func spatialSurveyRequiresEverySector() {
        var completed: Set<SurveyCheckpoint> = [.forward, .leftFlank, .rightFlank]

        #expect(!SurveyCheckpoint.required.isSubset(of: completed))
        #expect(SurveyCheckpoint.from(entityName: "survey-checkpoint-rear") == .rear)

        completed.insert(.rear)
        #expect(SurveyCheckpoint.required.isSubset(of: completed))
    }

    @Test
    func continuousCoverageRequiresAllTwelveSegments() {
        let almostComplete = Set(0..<11)
        #expect(SurveyCoverage.fractionCovered(almostComplete) < 1)
        #expect(
            SurveyCoverage.completedCheckpoints(for: almostComplete)
                != SurveyCheckpoint.required
        )
        #expect(SurveyCoverage.fractionCovered(SurveyCoverage.allBins) == 1)
        #expect(
            SurveyCoverage.completedCheckpoints(for: SurveyCoverage.allBins)
                == SurveyCheckpoint.required
        )
    }

    private func responseTempo(at elapsed: TimeInterval) -> ResponseTempo {
        var tempo = ResponseTempo()
        tempo.mark(.incidentStarted, at: 0)
        tempo.mark(.hazardIdentified, at: elapsed)
        return tempo
    }
}
