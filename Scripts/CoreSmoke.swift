import Foundation

@main
struct CoreSmoke {
    static func main() throws {
        let scenario = try ScenarioCatalog.roadsideFoundation.validated()
        precondition(scenario.makeCasualties().count == 3)

        var engine = SceneSurveyEngine()
        var coverage: Set<Int> = []
        for (index, yaw) in [Float(0), 90, 180, -90].enumerated() {
            let start = 10 + Double(index * 2)
            _ = engine.observe(sample: sample(at: start, yawDegrees: yaw))
            coverage.formUnion(
                engine.observe(sample: sample(at: start + 0.9, yawDegrees: yaw))
                    .newlyCoveredBins
            )
        }
        precondition(coverage == SurveyCoverage.allBins)
        precondition(SurveyCoverage.completedCheckpoints(for: coverage) == SurveyCheckpoint.required)

        var tempo = ResponseTempo()
        precondition(tempo.mark(.incidentStarted, at: 0))
        precondition(tempo.mark(.sceneSurveyed, at: 12))
        precondition(!tempo.mark(.sceneSurveyed, at: 15))
        precondition(tempo.elapsed(for: .sceneSurveyed) == 12)

        var history = TrainingHistoryArchive()
        history.record(
            TrainingRunSummary(
                scenarioID: scenario.id,
                scenarioVersion: scenario.version,
                trainingMode: .guided,
                scenarioPace: .demo,
                exerciseElapsedSeconds: 75,
                score: ScoreBreakdown(
                    safety: 20,
                    assessment: 25,
                    triage: 25,
                    treatment: 15,
                    communication: 15
                ),
                responseTempo: tempo
            )
        )
        precondition(history.personalBest == 100)
        let historyData = try JSONEncoder().encode(history)
        let decodedHistory = try JSONDecoder().decode(
            TrainingHistoryArchive.self,
            from: historyData
        )
        precondition(decodedHistory == history)

        let command = IncidentCommand.setScenarioPaused(true)
        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(IncidentCommand.self, from: encoded)
        precondition(decoded.actionTitle == command.actionTitle)

        print("Core smoke checks passed: scenario, 360° coverage, tempo, history, and shared command round-trip.")
    }

    private static func sample(at timestamp: TimeInterval, yawDegrees: Float) -> SceneSurveySample {
        let yaw = yawDegrees * .pi / 180
        return SceneSurveySample(
            timestamp: timestamp,
            forward: SpatialVector3(x: sin(yaw), y: 0, z: -cos(yaw))
        )
    }
}
