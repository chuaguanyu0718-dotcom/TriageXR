import Foundation
import Testing
@testable import TriageXRCore

struct SceneSurveyEngineTests {
    @Test
    func stableDwellCompletesForwardSectorWithoutAnInteraction() {
        var engine = SceneSurveyEngine()

        let first = engine.observe(sample: sample(at: 10, yawDegrees: 0))
        #expect(first.checkpoint == .forward)
        #expect(first.progress == 0)

        let completed = engine.observe(sample: sample(at: 10.9, yawDegrees: 0))
        #expect(completed.newlyCompletedCheckpoint == .forward)
        #expect(completed.progress == 1)

        // A shared host snapshot can lag behind the locally completed sample.
        engine.synchronizeCompleted([])
        let duplicate = engine.observe(sample: sample(at: 12, yawDegrees: 0))
        #expect(duplicate.newlyCompletedCheckpoint == nil)
        #expect(duplicate.progress == 1)
    }

    @Test
    func arbitraryStartingHeadingDefinesTheForwardSector() {
        var engine = SceneSurveyEngine()

        _ = engine.observe(sample: sample(at: 20, yawDegrees: 67))
        let completed = engine.observe(sample: sample(at: 20.9, yawDegrees: 67))

        #expect(completed.newlyCompletedCheckpoint == .forward)
    }

    @Test
    func relativeHeadingsMapToAllFourSceneSectors() {
        var engine = SceneSurveyEngine()

        complete(yawDegrees: 15, startingAt: 30, engine: &engine)
        #expect(
            complete(yawDegrees: -75, startingAt: 32, engine: &engine)
                == .leftFlank
        )
        #expect(
            complete(yawDegrees: 195, startingAt: 34, engine: &engine)
                == .rear
        )
        #expect(
            complete(yawDegrees: 105, startingAt: 36, engine: &engine)
                == .rightFlank
        )
    }

    @Test
    func fastTurnMustSettleBeforeDwellCanBegin() {
        var engine = SceneSurveyEngine()
        complete(yawDegrees: 0, startingAt: 40, engine: &engine)

        let moving = engine.observe(sample: sample(at: 41, yawDegrees: 90))
        #expect(moving.checkpoint == .rightFlank)
        #expect(!moving.isStable)
        #expect(moving.progress == 0)

        let settled = engine.observe(sample: sample(at: 41.2, yawDegrees: 90))
        #expect(settled.isStable)
        #expect(settled.progress == 0)

        let completed = engine.observe(sample: sample(at: 42.1, yawDegrees: 90))
        #expect(completed.newlyCompletedCheckpoint == .rightFlank)
    }

    @Test
    func steepVerticalGlanceDoesNotCountAsSurveyEvidence() {
        var engine = SceneSurveyEngine()

        _ = engine.observe(
            sample: SceneSurveySample(
                timestamp: 50,
                forward: SpatialVector3(x: 0, y: 0.95, z: -0.2)
            )
        )
        let result = engine.observe(
            sample: SceneSurveySample(
                timestamp: 51,
                forward: SpatialVector3(x: 0, y: 0.95, z: -0.2)
            )
        )

        #expect(result.checkpoint == nil)
        #expect(result.newlyCompletedCheckpoint == nil)
    }

    private func complete(
        yawDegrees: Float,
        startingAt timestamp: TimeInterval,
        engine: inout SceneSurveyEngine
    ) -> SurveyCheckpoint? {
        _ = engine.observe(sample: sample(at: timestamp, yawDegrees: yawDegrees))
        let second = engine.observe(
            sample: sample(at: timestamp + 0.9, yawDegrees: yawDegrees)
        )
        if let completed = second.newlyCompletedCheckpoint {
            return completed
        }
        return engine.observe(
            sample: sample(at: timestamp + 1.8, yawDegrees: yawDegrees)
        ).newlyCompletedCheckpoint
    }

    private func sample(
        at timestamp: TimeInterval,
        yawDegrees: Float
    ) -> SceneSurveySample {
        let yaw = yawDegrees * .pi / 180
        return SceneSurveySample(
            timestamp: timestamp,
            forward: SpatialVector3(
                x: sin(yaw),
                y: 0,
                z: -cos(yaw)
            )
        )
    }
}
