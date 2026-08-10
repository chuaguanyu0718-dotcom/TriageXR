import Foundation
import Testing
@testable import TriageXRCore

struct ScenarioDefinitionTests {
    @Test
    func bundledScenarioIsValidAndBuildsIndependentCasualties() throws {
        let scenario = try ScenarioCatalog.roadsideFoundation.validated()
        var firstRun = scenario.makeCasualties()
        let secondRun = scenario.makeCasualties()

        #expect(firstRun.count == 3)
        #expect(Set(firstRun.map(\.id)).count == firstRun.count)
        #expect(firstRun.allSatisfy { Set($0.initialFindings.keys) == Set(Assessment.allCases) })

        firstRun[0].health = 1
        #expect(secondRun[0].health == secondRun[0].initialHealth)
    }

    @Test
    func malformedScenarioFailsValidation() {
        let source = ScenarioCatalog.roadsideFoundation
        let invalid = ScenarioDefinition(
            id: source.id,
            version: source.version,
            title: source.title,
            subtitle: source.subtitle,
            dispatch: source.dispatch,
            objectives: source.objectives,
            casualties: [source.casualties[0], source.casualties[0]],
            trainingBoundary: source.trainingBoundary
        )

        #expect(throws: ScenarioDefinitionError.invalidContent) {
            try invalid.validated()
        }
    }

    @Test
    func responseTempoPreservesOnlyTheFirstOccurrence() {
        var tempo = ResponseTempo()

        let recordedFirstOccurrence = tempo.mark(.firstAssessment, at: 18)
        let recordedDuplicate = tempo.mark(.firstAssessment, at: 42)

        #expect(recordedFirstOccurrence)
        #expect(!recordedDuplicate)
        #expect(tempo.elapsed(for: .firstAssessment) == 18)
        #expect(tempo.completedMilestones == [.firstAssessment])
    }

    @Test
    func trainingHistoryIsBoundedAndCalculatesProgressMetrics() {
        var archive = TrainingHistoryArchive()
        for score in 1...15 {
            archive.record(
                TrainingRunSummary(
                    id: UUID(),
                    completedAt: Date(timeIntervalSince1970: TimeInterval(score)),
                    scenarioID: "test",
                    scenarioVersion: 1,
                    trainingMode: score.isMultiple(of: 2) ? .assessed : .guided,
                    scenarioPace: .demo,
                    exerciseElapsedSeconds: 60,
                    score: ScoreBreakdown(
                        safety: min(20, score),
                        assessment: 0,
                        triage: 0,
                        treatment: 0,
                        communication: 0
                    ),
                    responseTempo: ResponseTempo()
                )
            )
        }

        #expect(archive.runs.count == TrainingHistoryArchive.maximumRunCount)
        #expect(archive.runs.first?.score.total == 15)
        #expect(archive.personalBest == 15)
        #expect(archive.averageScore == 10)
    }
}
