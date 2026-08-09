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
}
