import ARKit
import Combine
import Foundation
import simd

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
            "Clinical findings unlock only after the required hand pose is sustained at the spatial marker."
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

    private weak var trainingSession: TrainingSession?
    private var submitCommand: ((IncidentCommand) -> Void)?
    private let arSession = ARKitSession()
    private let provider = HandTrackingProvider()
    private var engine = SpatialAssessmentEngine()
    private var trackingTask: Task<Void, Never>?
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
                try await arSession.run([provider])
                guard !Task.isCancelled else { return }
                status = .tracking

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
        trackingTask = nil
        arSession.stop()
        engine.reset()
        activeAssessment = nil
        progress = 0
        proximityMetres = nil
        lastSubmittedKey = nil
        activeTargetKey = nil
        activeHand = nil
        status = .idle
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
