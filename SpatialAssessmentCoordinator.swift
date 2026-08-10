import ARKit
import Combine
import Foundation
import simd
import QuartzCore

enum HandTrackingStatus: Equatable {
    case idle
    case starting
    case tracking
    case simulator
    case unavailable(String)

    var title: String {
        switch self {
        case .idle: "Spatial verification idle"
        case .starting: "Starting hand tracking"
        case .tracking: "Hand tracking active"
        case .simulator: "Simulator spatial targets active"
        case .unavailable: "Hand tracking unavailable"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "Enter the incident to start spatial assessment verification."
        case .starting:
            "Waiting for Vision Pro hand-anchor data."
        case .tracking:
            "Clinical findings unlock after the required hand action is sustained at the correct anatomical area."
        case .simulator:
            "Pinch the highlighted 3D marker to provide simulated spatial evidence."
        case .unavailable(let message):
            message
        }
    }

    var usesHandTracking: Bool {
        if case .tracking = self { return true }
        return false
    }
}

@MainActor
final class SpatialAssessmentCoordinator: ObservableObject {
    @Published private(set) var status: HandTrackingStatus = .idle
    @Published private(set) var activeAssessment: Assessment?
    @Published private(set) var progress: Double = 0
    @Published private(set) var proximityMetres: Double?
    @Published private(set) var devicePosition: SIMD3<Float>?
    @Published private(set) var deviceYaw: Float = 0

    private weak var trainingSession: TrainingSession?
    private var submitCommand: ((IncidentCommand) -> Void)?
    private let arSession = ARKitSession()
    private let provider = HandTrackingProvider()
    private let worldProvider = WorldTrackingProvider()
    private var engine = SpatialAssessmentEngine()
    private var trackingTask: Task<Void, Never>?
    private var surveyTask: Task<Void, Never>?
    private var initialSurveyYaw: Float?
    private var observedSurveySectors: Set<SurveyCheckpoint> = []
    private var lastSubmittedKey: String?
    private var activeTargetKey: String?
    private var activeHand: HandAnchor.Chirality?

    init(trainingSession: TrainingSession) {
        self.trainingSession = trainingSession
    }

    func installCommandSubmitter(_ submitter: @escaping (IncidentCommand) -> Void) {
        submitCommand = submitter
    }

    func start() {
        guard trackingTask == nil else { return }

#if targetEnvironment(simulator)
        status = .simulator
        return
#else
        guard HandTrackingProvider.isSupported else {
            status = .unavailable("This Vision Pro does not support ARKit hand tracking.")
            return
        }

        status = .starting
        trackingTask = Task { [weak self] in
            guard let self else { return }
            defer { trackingTask = nil }
            do {
                try await arSession.run([provider, worldProvider])
                guard !Task.isCancelled else { return }
                status = .tracking
                startSurveyTracking()

                for await update in provider.anchorUpdates {
                    guard !Task.isCancelled else { return }
                    process(anchor: update.anchor)
                }
                guard !Task.isCancelled else { return }
                arSession.stop()
                status = .unavailable(
                    "The hand-anchor stream ended. Retry spatial verification."
                )
            } catch is CancellationError {
                return
            } catch {
                arSession.stop()
                status = .unavailable(
                    "Vision Pro could not provide hand anchors. Check hand-tracking permission, then retry."
                )
            }
        }
#endif
    }

    func stop() {
        trackingTask?.cancel()
        surveyTask?.cancel()
        trackingTask = nil
        surveyTask = nil
        arSession.stop()
        engine.reset()
        activeAssessment = nil
        progress = 0
        proximityMetres = nil
        devicePosition = nil
        deviceYaw = 0
        lastSubmittedKey = nil
        activeTargetKey = nil
        activeHand = nil
        status = .idle
        initialSurveyYaw = nil
        observedSurveySectors = []
    }

    private func startSurveyTracking() {
        surveyTask?.cancel()
        surveyTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                observeHeadDirection()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func observeHeadDirection() {
        guard let trainingSession,
              trainingSession.phase == .active,
              let anchor = worldProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              anchor.isTracked else { return }

        let transform = anchor.originFromAnchorTransform
        devicePosition = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        guard !trainingSession.sceneSurveyed else { return }
        let forward = -SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        )
        let yaw = atan2(forward.x, forward.z)
        deviceYaw = yaw
        guard let initialSurveyYaw else {
            self.initialSurveyYaw = yaw
            submitSurveySector(.forward)
            return
        }

        let delta = normalizedAngle(yaw - initialSurveyYaw)
        let degrees = delta * 180 / .pi
        let sector: SurveyCheckpoint
        switch degrees {
        case -45..<45: sector = .forward
        case 45..<135: sector = .leftFlank
        case -135 ..< -45: sector = .rightFlank
        default: sector = .rear
        }
        submitSurveySector(sector)
    }

    func isWithinTreatmentReach(
        of targetPosition: SIMD3<Float>,
        maximumDistance: Float = 1.25
    ) -> Bool {
#if targetEnvironment(simulator)
        true
#else
        guard let devicePosition else { return false }
        let horizontalOffset = SIMD2<Float>(
            devicePosition.x - targetPosition.x,
            devicePosition.z - targetPosition.z
        )
        return simd_length(horizontalOffset) <= maximumDistance
#endif
    }

    private func submitSurveySector(_ sector: SurveyCheckpoint) {
        guard observedSurveySectors.insert(sector).inserted else { return }
        submitCommand?(.inspectSurveyCheckpoint(sector))
    }

    private func normalizedAngle(_ angle: Float) -> Float {
        var result = angle
        while result > .pi { result -= 2 * .pi }
        while result < -.pi { result += 2 * .pi }
        return result
    }

    func simulatorVerify(_ assessment: Assessment, casualtyID: String) {
        guard status == .simulator,
              trainingSession?.selectedCasualtyID == casualtyID else {
            return
        }
        submitCommand?(
            .performAssessment(
                casualtyID,
                assessment,
                .simulatorTarget(gesture: "pinched highlighted 3D \(assessment.code) marker")
            )
        )
    }

    private func process(anchor: HandAnchor) {
        guard let trainingSession,
              trainingSession.phase == .active,
              let casualty = trainingSession.selectedCasualty,
              let assessment = Assessment.allCases.first(where: {
                  !casualty.completedAssessments.contains($0)
              }),
              let target = SpatialAssessmentCatalog.target(
                  casualtyID: casualty.id,
                  assessment: assessment
              ) else {
            resetTrackingProgress()
            return
        }

        let key = "\(casualty.id)-\(assessment.code)"
        if activeTargetKey != key {
            engine.reset()
            activeTargetKey = key
            activeHand = nil
            lastSubmittedKey = nil
            progress = 0
            proximityMetres = nil
        }

        guard activeHand == nil || activeHand == anchor.chirality else { return }

        guard anchor.isTracked,
              let skeleton = anchor.handSkeleton,
              let sample = poseSample(anchor: anchor, skeleton: skeleton) else {
            engine.reset()
            activeHand = nil
            progress = 0
            proximityMetres = nil
            return
        }

        activeAssessment = assessment
        let observation = engine.observe(sample: sample, target: target)
        progress = observation.progress
        proximityMetres = observation.proximityMetres

        if observation.poseMatches {
            activeHand = anchor.chirality
        } else {
            activeHand = nil
        }

        guard let evidence = observation.completedEvidence,
              lastSubmittedKey != key else {
            return
        }

        lastSubmittedKey = key
        activeHand = nil
        submitCommand?(.performAssessment(casualty.id, assessment, evidence))
    }

    private func resetTrackingProgress() {
        engine.reset()
        activeTargetKey = nil
        activeHand = nil
        activeAssessment = nil
        progress = 0
        proximityMetres = nil
        lastSubmittedKey = nil
    }

    private func poseSample(
        anchor: HandAnchor,
        skeleton: HandSkeleton
    ) -> HandPoseSample? {
        let index = skeleton.joint(.indexFingerTip)
        let thumb = skeleton.joint(.thumbTip)
        let middle = skeleton.joint(.middleFingerTip)
        let ring = skeleton.joint(.ringFingerTip)
        let little = skeleton.joint(.littleFingerTip)
        let wrist = skeleton.joint(.wrist)
        guard index.isTracked,
              thumb.isTracked,
              middle.isTracked,
              ring.isTracked,
              little.isTracked,
              wrist.isTracked else {
            return nil
        }

        return HandPoseSample(
            timestamp: ProcessInfo.processInfo.systemUptime,
            indexTip: worldPosition(anchor: anchor, joint: index),
            thumbTip: worldPosition(anchor: anchor, joint: thumb),
            middleTip: worldPosition(anchor: anchor, joint: middle),
            ringTip: worldPosition(anchor: anchor, joint: ring),
            littleTip: worldPosition(anchor: anchor, joint: little),
            wrist: worldPosition(anchor: anchor, joint: wrist)
        )
    }

    private func worldPosition(
        anchor: HandAnchor,
        joint: HandSkeleton.Joint
    ) -> SpatialVector3 {
        let transform = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
        return SpatialVector3(
            x: transform.columns.3.x,
            y: transform.columns.3.y,
            z: transform.columns.3.z
        )
    }
}
