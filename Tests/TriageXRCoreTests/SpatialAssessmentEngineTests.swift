import Foundation
import Testing
@testable import TriageXRCore

struct SpatialAssessmentEngineTests {
    @Test
    func sustainedPlacementProducesVerifiedEvidence() throws {
        let target = try #require(
            SpatialAssessmentCatalog.target(
                casualtyID: "casualty-a",
                assessment: .response
            )
        )
        var engine = SpatialAssessmentEngine()

        let initial = engine.observe(
            sample: sample(at: 10, target: target, trackedPoint: target.centre),
            target: target
        )
        #expect(initial.progress == 0)
        #expect(initial.completedEvidence == nil)

        let completed = engine.observe(
            sample: sample(at: 11.1, target: target, trackedPoint: target.centre),
            target: target
        )
        #expect(completed.progress == 1)
        #expect(completed.completedEvidence?.source == .handTracking)
        #expect(completed.completedEvidence?.sustainedDuration ?? 0 >= 1)
    }

    @Test
    func leavingTheTargetResetsSustainedDuration() throws {
        let target = try #require(
            SpatialAssessmentCatalog.target(
                casualtyID: "casualty-b",
                assessment: .breathing
            )
        )
        var engine = SpatialAssessmentEngine()

        _ = engine.observe(
            sample: sample(at: 20, target: target, trackedPoint: target.centre),
            target: target
        )
        let outside = SpatialVector3(
            x: target.centre.x + target.radius + 0.2,
            y: target.centre.y,
            z: target.centre.z
        )
        let interrupted = engine.observe(
            sample: sample(at: 21, target: target, trackedPoint: outside),
            target: target
        )
        #expect(interrupted.progress == 0)

        let restarted = engine.observe(
            sample: sample(at: 21.2, target: target, trackedPoint: target.centre),
            target: target
        )
        #expect(restarted.progress == 0)
        #expect(restarted.completedEvidence == nil)
    }

    @Test
    func perfusionRequiresPinchInsideTheTarget() throws {
        let target = try #require(
            SpatialAssessmentCatalog.target(
                casualtyID: "casualty-c",
                assessment: .perfusion
            )
        )
        var engine = SpatialAssessmentEngine()

        _ = engine.observe(
            sample: sample(at: 30, target: target, trackedPoint: target.centre),
            target: target
        )
        let noPinch = engine.observe(
            sample: sample(at: 32, target: target, trackedPoint: target.centre),
            target: target
        )
        #expect(noPinch.progress == 0)
        #expect(noPinch.completedEvidence == nil)

        _ = engine.observe(
            sample: sample(at: 33, target: target, trackedPoint: target.centre, pinching: true),
            target: target
        )
        let pinched = engine.observe(
            sample: sample(at: 34.6, target: target, trackedPoint: target.centre, pinching: true),
            target: target
        )
        #expect(pinched.completedEvidence?.gesture == "sustained fingertip pinch")
    }

    @Test
    func breathingRequiresAnOpenHandInsideTheTarget() throws {
        let target = try #require(
            SpatialAssessmentCatalog.target(
                casualtyID: "casualty-b",
                assessment: .breathing
            )
        )
        var engine = SpatialAssessmentEngine()

        _ = engine.observe(
            sample: sample(
                at: 40,
                target: target,
                trackedPoint: target.centre,
                openHand: false
            ),
            target: target
        )
        let closedHand = engine.observe(
            sample: sample(
                at: 42,
                target: target,
                trackedPoint: target.centre,
                openHand: false
            ),
            target: target
        )
        #expect(!closedHand.poseMatches)
        #expect(closedHand.completedEvidence == nil)

        _ = engine.observe(
            sample: sample(at: 43, target: target, trackedPoint: target.centre),
            target: target
        )
        let openHand = engine.observe(
            sample: sample(at: 44.6, target: target, trackedPoint: target.centre),
            target: target
        )
        #expect(openHand.poseMatches)
        #expect(openHand.completedEvidence?.gesture == "sustained open-palm placement")
    }

    private func sample(
        at timestamp: TimeInterval,
        target: SpatialAssessmentTarget,
        trackedPoint: SpatialVector3,
        pinching: Bool = false,
        openHand: Bool = true
    ) -> HandPoseSample {
        let extensionDistance: Float = openHand ? 0.14 : 0.05
        let wrist = target.usesWrist
            ? trackedPoint
            : SpatialVector3(
                x: trackedPoint.x - extensionDistance,
                y: trackedPoint.y,
                z: trackedPoint.z
            )
        let index = target.usesWrist
            ? SpatialVector3(
                x: wrist.x + extensionDistance,
                y: wrist.y,
                z: wrist.z
            )
            : trackedPoint
        let thumb = SpatialVector3(
            x: index.x + (pinching ? 0.02 : 0.10),
            y: index.y,
            z: index.z
        )
        return HandPoseSample(
            timestamp: timestamp,
            indexTip: index,
            thumbTip: thumb,
            middleTip: SpatialVector3(
                x: wrist.x + extensionDistance,
                y: wrist.y + 0.025,
                z: wrist.z
            ),
            ringTip: SpatialVector3(
                x: wrist.x + extensionDistance,
                y: wrist.y,
                z: wrist.z + 0.025
            ),
            littleTip: SpatialVector3(
                x: wrist.x + extensionDistance,
                y: wrist.y - 0.025,
                z: wrist.z + 0.04
            ),
            wrist: wrist
        )
    }
}
