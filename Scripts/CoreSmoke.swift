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

        let command = IncidentCommand.recordSurveyCoverage(coverage.sorted())
        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(IncidentCommand.self, from: encoded)
        precondition(decoded.actionTitle == command.actionTitle)

        print("Core smoke checks passed: scenario, 360° coverage, and shared command round-trip.")
    }

    private static func sample(at timestamp: TimeInterval, yawDegrees: Float) -> SceneSurveySample {
        let yaw = yawDegrees * .pi / 180
        return SceneSurveySample(
            timestamp: timestamp,
            forward: SpatialVector3(x: sin(yaw), y: 0, z: -cos(yaw))
        )
    }
}
