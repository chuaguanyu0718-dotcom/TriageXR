import ARKit
import Combine
import Foundation
import QuartzCore
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
        case .simulator: "Simulator assessment fallback"
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
            "Scenario findings unlock only after the required hand pose is sustained at the spatial marker."
        case .simulator:
            "ARKit hand tracking is unavailable in Simulator. Pinch the highlighted assessment marker to exercise the remaining flow."
        case .unavailable(let message):
            message
        }
    }

    var usesHandTracking: Bool {
        if case .tracking = self { return true }
        return false
    }
}

enum SceneSurveyTrackingStatus: Equatable {
    case idle
    case starting
    case tracking
    case temporarilyLost
    case simulatorUnavailable
    case unavailable(String)

    var title: String {
        switch self {
        case .idle: "Automatic survey idle"
        case .starting: "Starting headset tracking"
        case .tracking: "Automatic survey active"
        case .temporarilyLost: "Headset pose temporarily lost"
        case .simulatorUnavailable: "Headset survey requires Vision Pro"
        case .unavailable: "Automatic survey unavailable"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "Enter the incident to begin automatic scene-survey verification."
        case .starting:
            "Waiting for a tracked Vision Pro device pose."
        case .tracking:
            "Turn naturally and hold a level view. Headset direction fills a 12-segment coverage map automatically; no selection is required."
        case .temporarilyLost:
            "Tracking paused. Look forward, remain within the mapped space, and wait for the coverage indicator to resume."
        case .simulatorUnavailable:
            "Simulator does not provide ARKit device-pose data. Test the workflow here, then verify the automatic survey on Vision Pro hardware."
        case .unavailable(let message):
            message
        }
    }
}

@MainActor
final class SpatialAssessmentCoordinator: ObservableObject {
    @Published private(set) var status: HandTrackingStatus = .idle
    @Published private(set) var activeAssessment: Assessment?
    @Published private(set) var progress: Double = 0
    @Published private(set) var proximityMetres: Double?
    @Published private(set) var surveyStatus: SceneSurveyTrackingStatus = .idle
    @Published private(set) var surveyCurrentCheckpoint: SurveyCheckpoint?
    @Published private(set) var surveyProgress: Double = 0
    @Published private(set) var surveyIsStable = false

    private weak var trainingSession: TrainingSession?
    private var submitCommand: ((IncidentCommand) -> Void)?
    private var canSubmitSurveyEvidence: (() -> Bool)?
    private let arSession = ARKitSession()
    private let handProvider = HandTrackingProvider()
    private let worldProvider = WorldTrackingProvider()
    private var engine = SpatialAssessmentEngine()
    private var surveyEngine = SceneSurveyEngine()
    private var sessionTask: Task<Void, Never>?
    private var handTrackingTask: Task<Void, Never>?
    private var surveyTrackingTask: Task<Void, Never>?
    private var lastSubmittedKey: String?
    private var activeTargetKey: String?
    private var activeHand: HandAnchor.Chirality?
    private var missingDevicePoseSince: TimeInterval?

    init(trainingSession: TrainingSession) {
        self.trainingSession = trainingSession
    }

    func installCommandSubmitter(_ submitter: @escaping (IncidentCommand) -> Void) {
        submitCommand = submitter
    }

    func installSurveyPermissionProvider(_ provider: @escaping () -> Bool) {
        canSubmitSurveyEvidence = provider
    }

    func start() {
        guard sessionTask == nil else { return }

#if targetEnvironment(simulator)
        status = .simulator
        surveyStatus = .simulatorUnavailable
        return
#else
        let supportsHands = HandTrackingProvider.isSupported
        let supportsWorldTracking = WorldTrackingProvider.isSupported

        status = supportsHands
            ? .starting
            : .unavailable("This Vision Pro does not support ARKit hand tracking.")
        surveyStatus = supportsWorldTracking
            ? .starting
            : .unavailable("This device cannot provide the world-tracking pose required for an automatic scene survey.")

        guard supportsHands || supportsWorldTracking else {
            return
        }

        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                if supportsHands && supportsWorldTracking {
                    try await arSession.run([handProvider, worldProvider])
                } else if supportsHands {
                    try await arSession.run([handProvider])
                } else {
                    try await arSession.run([worldProvider])
                }
                guard !Task.isCancelled else { return }

                if supportsHands {
                    status = .tracking
                    handTrackingTask = Task { [weak self] in
                        await self?.consumeHandAnchors()
                    }
                }
                if supportsWorldTracking {
                    surveyStatus = .tracking
                    surveyTrackingTask = Task { [weak self] in
                        await self?.consumeDevicePose()
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                arSession.stop()
                if supportsHands {
                    status = .unavailable(
                        "Vision Pro could not provide hand anchors. Check hand-tracking permission, then re-enter the incident."
                    )
                }
                if supportsWorldTracking {
                    surveyStatus = .unavailable(
                        "Vision Pro could not provide a device pose. Check world-sensing permission, then re-enter the incident."
                    )
                }
                sessionTask = nil
            }
        }
#endif
    }

    func stop() {
        sessionTask?.cancel()
        handTrackingTask?.cancel()
        surveyTrackingTask?.cancel()
        sessionTask = nil
        handTrackingTask = nil
        surveyTrackingTask = nil
        arSession.stop()
        engine.reset()
        surveyEngine.reset()
        activeAssessment = nil
        progress = 0
        proximityMetres = nil
        surveyCurrentCheckpoint = nil
        surveyProgress = 0
        surveyIsStable = false
        missingDevicePoseSince = nil
        lastSubmittedKey = nil
        activeTargetKey = nil
        activeHand = nil
        status = .idle
        surveyStatus = .idle
    }

    func restart() {
        stop()
        start()
    }

    private func consumeHandAnchors() async {
        for await update in handProvider.anchorUpdates {
            guard !Task.isCancelled else { return }
            process(anchor: update.anchor)
        }
        guard !Task.isCancelled else { return }
        status = .unavailable(
            "The hand-anchor stream ended. Re-enter the incident to retry spatial assessment verification."
        )
    }

    private func consumeDevicePose() async {
        while !Task.isCancelled {
            let timestamp = CACurrentMediaTime()
            if let anchor = worldProvider.queryDeviceAnchor(atTimestamp: timestamp),
               anchor.isTracked {
                missingDevicePoseSince = nil
                surveyStatus = .tracking
                process(deviceAnchor: anchor, timestamp: timestamp)
            } else {
                resetSurveyProgress(keepReference: true)
                if missingDevicePoseSince == nil {
                    missingDevicePoseSince = timestamp
                } else if timestamp - (missingDevicePoseSince ?? timestamp) >= 1 {
                    surveyStatus = .temporarilyLost
                }
            }

            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    private func process(deviceAnchor: DeviceAnchor, timestamp: TimeInterval) {
        guard let trainingSession,
              trainingSession.phase == .active else {
            resetSurveyProgress()
            return
        }

        guard !trainingSession.isPaused else {
            resetSurveyProgress(keepReference: true)
            return
        }

        guard canSubmitSurveyEvidence?() ?? true else {
            resetSurveyProgress(keepReference: true)
            return
        }

        surveyEngine.synchronizeCompleted(trainingSession.surveyedCheckpoints)
        surveyEngine.synchronizeCoverage(trainingSession.surveyCoverageBins)
        let transform = deviceAnchor.originFromAnchorTransform
        let observation = surveyEngine.observe(
            sample: SceneSurveySample(
                timestamp: timestamp,
                forward: SpatialVector3(
                    x: -transform.columns.2.x,
                    y: -transform.columns.2.y,
                    z: -transform.columns.2.z
                )
            )
        )
        surveyCurrentCheckpoint = observation.checkpoint
        surveyProgress = observation.progress
        surveyIsStable = observation.isStable

        if !observation.newlyCoveredBins.isEmpty {
            submitCommand?(.recordSurveyCoverage(Array(observation.newlyCoveredBins).sorted()))
        }
    }

    private func resetSurveyProgress(keepReference: Bool = false) {
        if keepReference {
            surveyEngine.interruptDwell()
        } else {
            surveyEngine.reset()
        }
        surveyCurrentCheckpoint = nil
        surveyProgress = 0
        surveyIsStable = false
    }

    func simulatorVerify(_ assessment: Assessment, casualtyID: String) {
        guard status == .simulator,
              trainingSession?.isPaused == false,
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
              !trainingSession.isPaused,
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
