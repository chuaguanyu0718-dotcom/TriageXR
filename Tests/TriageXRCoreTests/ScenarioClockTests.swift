import Foundation
import Testing
@testable import TriageXRCore

struct ScenarioClockTests {
    @Test
    func demoPaceReachesNeurologicalRiskAfterFortyFiveRealSeconds() {
        var casualty = cardiacArrestCasualty()
        let realDuration: TimeInterval = 45

        let stage = casualty.advanceClocks(
            realDuration: realDuration,
            exerciseDuration: ScenarioPace.demo.exerciseDuration(
                forRealDuration: realDuration
            )
        )

        #expect(casualty.untreatedSeconds == ScenarioRules.neurologicalRiskAfter)
        #expect(stage == 3)
        #expect(casualty.effectiveCPRSeconds == 0)
    }

    @Test
    func cprCreditRemainsRealtimeAtDemoPace() {
        var casualty = cardiacArrestCasualty()
        casualty.isReceivingCPR = true
        let realDuration: TimeInterval = 10

        let stage = casualty.advanceClocks(
            realDuration: realDuration,
            exerciseDuration: ScenarioPace.demo.exerciseDuration(
                forRealDuration: realDuration
            )
        )

        #expect(stage == nil)
        #expect(casualty.effectiveCPRSeconds == realDuration)
        #expect(casualty.activeCPRBoutSeconds == realDuration)
        #expect(casualty.untreatedSeconds == 0)
    }

    @Test
    func demoPaceReachesScenarioDeathThresholdAfterSeventyFiveRealSeconds() {
        var casualty = cardiacArrestCasualty()
        let realDuration: TimeInterval = 75

        let stage = casualty.advanceClocks(
            realDuration: realDuration,
            exerciseDuration: ScenarioPace.demo.exerciseDuration(
                forRealDuration: realDuration
            )
        )

        #expect(casualty.untreatedSeconds == ScenarioRules.deathAfter)
        #expect(casualty.health == 0)
        #expect(stage == 5)
    }

    private func cardiacArrestCasualty() -> Casualty {
        Casualty(
            id: "casualty-b",
            name: "Jordan",
            location: "Purple marker",
            initialFindings: [:],
            deterioratedFindings: [:],
            correctInitialPriority: .p1,
            correctDeterioratedPriority: .p1,
            initialHealth: 60,
            deteriorationProfile: .untreatedCardiacArrest(
                neurologicalRiskAfter: ScenarioRules.neurologicalRiskAfter,
                deathAfter: ScenarioRules.deathAfter
            ),
            health: 60
        )
    }
}
