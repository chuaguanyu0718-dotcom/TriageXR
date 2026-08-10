import Foundation

enum ScenarioPhase: String, Codable, Sendable {
    case briefing = "Briefing"
    case active = "In progress"
    case complete = "After-action review"
}

enum ScenarioRules {
    static let neurologicalRiskAfter: TimeInterval = 6 * 60
    static let deathAfter: TimeInterval = 10 * 60
    static let targetCompressionRate = 110
    static let minimumDemonstrationCPRDuration: TimeInterval = 10
    static let primaryAssessments: Set<Assessment> = [.response, .breathing, .perfusion]
}

enum ScenarioPace: String, CaseIterable, Identifiable, Codable, Sendable {
    case demo
    case realtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .demo: "Demo 8x"
        case .realtime: "Realtime"
        }
    }

    var detail: String {
        switch self {
        case .demo:
            "Clinical deterioration runs at 8x; CPR hold duration remains real-time."
        case .realtime:
            "Clinical deterioration and responder actions use real elapsed time."
        }
    }

    var deteriorationMultiplier: Double {
        switch self {
        case .demo: 8
        case .realtime: 1
        }
    }

    func exerciseDuration(forRealDuration duration: TimeInterval) -> TimeInterval {
        max(0, duration) * deteriorationMultiplier
    }
}

enum TrainingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case guided
    case assessed

    var id: String { rawValue }
    var title: String { self == .guided ? "Guided training" : "Assessed run" }
}

enum ResponseMilestone: String, CaseIterable, Codable, Hashable, Sendable {
    case incidentStarted
    case sceneSurveyed
    case hazardIdentified
    case firstAssessment
    case firstTriageTag
    case resourceRequested
    case scenarioCompleted
}

struct ResponseTempo: Codable, Equatable, Sendable {
    private(set) var milestoneSeconds: [ResponseMilestone: TimeInterval] = [:]

    @discardableResult
    mutating func mark(_ milestone: ResponseMilestone, at elapsed: TimeInterval) -> Bool {
        guard milestoneSeconds[milestone] == nil else { return false }
        milestoneSeconds[milestone] = max(0, elapsed)
        return true
    }

    func elapsed(for milestone: ResponseMilestone) -> TimeInterval? {
        milestoneSeconds[milestone]
    }

    var completedMilestones: Set<ResponseMilestone> {
        Set(milestoneSeconds.keys)
    }
}

struct TrainingRunSummary: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let completedAt: Date
    let scenarioID: String
    let scenarioVersion: Int
    let trainingMode: TrainingMode
    let scenarioPace: ScenarioPace
    let exerciseElapsedSeconds: TimeInterval
    let score: ScoreBreakdown
    let responseTempo: ResponseTempo

    init(
        id: UUID = UUID(),
        completedAt: Date = Date(),
        scenarioID: String,
        scenarioVersion: Int,
        trainingMode: TrainingMode,
        scenarioPace: ScenarioPace,
        exerciseElapsedSeconds: TimeInterval,
        score: ScoreBreakdown,
        responseTempo: ResponseTempo
    ) {
        self.id = id
        self.completedAt = completedAt
        self.scenarioID = scenarioID
        self.scenarioVersion = scenarioVersion
        self.trainingMode = trainingMode
        self.scenarioPace = scenarioPace
        self.exerciseElapsedSeconds = exerciseElapsedSeconds
        self.score = score
        self.responseTempo = responseTempo
    }
}

struct TrainingHistoryArchive: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumRunCount = 10

    var schemaVersion = currentSchemaVersion
    private(set) var runs: [TrainingRunSummary] = []

    mutating func record(_ run: TrainingRunSummary) {
        runs.insert(run, at: 0)
        if runs.count > Self.maximumRunCount {
            runs.removeLast(runs.count - Self.maximumRunCount)
        }
    }

    var personalBest: Int { runs.map(\.score.total).max() ?? 0 }
    var averageScore: Int {
        guard !runs.isEmpty else { return 0 }
        return runs.reduce(0) { $0 + $1.score.total } / runs.count
    }
}

enum SurveyCheckpoint: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case forward
    case leftFlank
    case rear
    case rightFlank

    static let required = Set(allCases)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forward: "Forward sector"
        case .leftFlank: "Left flank"
        case .rear: "Rear sector"
        case .rightFlank: "Right flank"
        }
    }

    var shortTitle: String {
        switch self {
        case .forward: "Front"
        case .leftFlank: "Left"
        case .rear: "Rear"
        case .rightFlank: "Right"
        }
    }

    var spatialCue: String {
        switch self {
        case .forward: "Collision, casualties, and approach route"
        case .leftFlank: "Left shoulder and traffic approach"
        case .rear: "Rear access and secondary hazards"
        case .rightFlank: "Guardrail, verge, and escape route"
        }
    }

    var entityName: String { "survey-checkpoint-\(rawValue)" }

    static func from(entityName: String) -> SurveyCheckpoint? {
        allCases.first { $0.entityName == entityName }
    }
}

struct SceneSurveySample: Equatable, Sendable {
    let timestamp: TimeInterval
    let forward: SpatialVector3
}

struct SceneSurveyObservation: Equatable, Sendable {
    let checkpoint: SurveyCheckpoint?
    let progress: Double
    let isStable: Bool
    let newlyCompletedCheckpoint: SurveyCheckpoint?
    let newlyCoveredBins: Set<Int>
}

enum SurveyCoverage {
    static let binCount = 12
    static let allBins = Set(0..<binCount)

    static func bins(around center: Int) -> Set<Int> {
        Set([-1, 0, 1].map { positiveModulo(center + $0, binCount) })
    }

    static func completedCheckpoints(for coveredBins: Set<Int>) -> Set<SurveyCheckpoint> {
        var completed: Set<SurveyCheckpoint> = []
        let centers: [(SurveyCheckpoint, Int)] = [
            (.forward, 0),
            (.rightFlank, 3),
            (.rear, 6),
            (.leftFlank, 9)
        ]
        for (checkpoint, center) in centers where bins(around: center).isSubset(of: coveredBins) {
            completed.insert(checkpoint)
        }
        return completed
    }

    static func fractionCovered(_ coveredBins: Set<Int>) -> Double {
        Double(coveredBins.intersection(allBins).count) / Double(binCount)
    }

    fileprivate static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

/// Converts deliberate, stable head direction into scene-survey evidence. The first
/// valid heading becomes the trainee's forward direction, so the exercise works no
/// matter which way the immersive space opens.
struct SceneSurveyEngine: Sendable {
    private let dwellDuration: TimeInterval
    private static let movementThreshold: Float = 20 * .pi / 180
    private static let minimumHorizontalMagnitude: Float = 0.45

    private var referenceYaw: Float?
    private var previousYaw: Float?
    private var stableSince: TimeInterval?
    private var locallyCompleted: Set<SurveyCheckpoint> = []
    private var hostCompleted: Set<SurveyCheckpoint> = []
    private var locallyCoveredBins: Set<Int> = []

    init(dwellDuration: TimeInterval = 0.8) {
        self.dwellDuration = max(0.5, dwellDuration)
    }

    mutating func synchronizeCompleted(_ completed: Set<SurveyCheckpoint>) {
        hostCompleted = completed
    }

    mutating func observe(sample: SceneSurveySample) -> SceneSurveyObservation {
        guard let yaw = validYaw(for: sample.forward) else {
            previousYaw = nil
            stableSince = nil
            return SceneSurveyObservation(
                checkpoint: nil,
                progress: 0,
                isStable: false,
                newlyCompletedCheckpoint: nil,
                newlyCoveredBins: []
            )
        }

        if referenceYaw == nil {
            referenceYaw = yaw
        }
        let relativeYaw = normalizedAngle(yaw - (referenceYaw ?? yaw))
        let checkpoint = checkpoint(for: relativeYaw)

        let isStable: Bool
        if let previousYaw {
            let movement = abs(normalizedAngle(yaw - previousYaw))
            if movement > Self.movementThreshold {
                // Begin timing at the new heading, but do not call the turning
                // sample stable. A later sample must confirm that it settled.
                stableSince = sample.timestamp
                isStable = false
            } else {
                if stableSince == nil {
                    stableSince = sample.timestamp
                }
                isStable = true
            }
        } else {
            stableSince = sample.timestamp
            isStable = true
        }
        previousYaw = yaw

        let completed = locallyCompleted.union(hostCompleted)
        if completed.contains(checkpoint) {
            return SceneSurveyObservation(
                checkpoint: checkpoint,
                progress: 1,
                isStable: isStable,
                newlyCompletedCheckpoint: nil,
                newlyCoveredBins: []
            )
        }

        guard isStable, let stableSince else {
            return SceneSurveyObservation(
                checkpoint: checkpoint,
                progress: 0,
                isStable: isStable,
                newlyCompletedCheckpoint: nil,
                newlyCoveredBins: []
            )
        }

        let progress = min(1, max(0, (sample.timestamp - stableSince) / dwellDuration))
        guard progress >= 1 else {
            return SceneSurveyObservation(
                checkpoint: checkpoint,
                progress: progress <= 0.26 ? 0 : progress,
                isStable: true,
                newlyCompletedCheckpoint: nil,
                newlyCoveredBins: []
            )
        }

        locallyCompleted.insert(checkpoint)
        let centerBin = coverageBin(for: relativeYaw)
        let evidence = SurveyCoverage.bins(around: centerBin)
        let newBins = evidence.subtracting(locallyCoveredBins)
        locallyCoveredBins.formUnion(evidence)
        return SceneSurveyObservation(
            checkpoint: checkpoint,
            progress: 1,
            isStable: true,
            newlyCompletedCheckpoint: checkpoint,
            newlyCoveredBins: newBins
        )
    }

    private func validYaw(for forward: SpatialVector3) -> Float? {
        let horizontal = hypot(forward.x, forward.z)
        guard horizontal >= Self.minimumHorizontalMagnitude else { return nil }
        return atan2(forward.x, -forward.z)
    }

    private func checkpoint(for yaw: Float) -> SurveyCheckpoint {
        let quarterTurn = Float.pi / 4
        if yaw >= -quarterTurn, yaw < quarterTurn { return .forward }
        if yaw >= quarterTurn, yaw < 3 * quarterTurn { return .rightFlank }
        if yaw >= -3 * quarterTurn, yaw < -quarterTurn { return .leftFlank }
        return .rear
    }

    private func coverageBin(for yaw: Float) -> Int {
        let raw = Int(round(yaw / (2 * .pi) * Float(SurveyCoverage.binCount)))
        return SurveyCoverage.positiveModulo(raw, SurveyCoverage.binCount)
    }

    private func normalizedAngle(_ angle: Float) -> Float {
        var result = angle
        while result > .pi { result -= 2 * .pi }
        while result <= -.pi { result += 2 * .pi }
        return result
    }
}

enum TriagePriority: String, CaseIterable, Identifiable, Codable, Sendable {
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"
    case deceased = "Expectant"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .p1: "Immediate"
        case .p2: "Urgent"
        case .p3: "Delayed"
        case .deceased: "Expectant"
        }
    }
}

enum Assessment: String, CaseIterable, Identifiable, Codable, Sendable {
    case response = "Check response"
    case breathing = "Check breathing"
    case perfusion = "Check perfusion"
    case injuries = "Inspect injuries"

    var id: String { rawValue }

    var code: String {
        switch self {
        case .response: "response"
        case .breathing: "breathing"
        case .perfusion: "perfusion"
        case .injuries: "injuries"
        }
    }

    static func from(code: String) -> Assessment? {
        allCases.first(where: { $0.code == code })
    }

    var icon: String {
        switch self {
        case .response: "ear"
        case .breathing: "lungs.fill"
        case .perfusion: "heart.text.square.fill"
        case .injuries: "bandage.fill"
        }
    }

    var spatialInstruction: String {
        switch self {
        case .response:
            "Touch the casualty's shoulder and hold for one second while checking for a response."
        case .breathing:
            "Hold an open palm just above the chest and observe breathing for two seconds."
        case .perfusion:
            "Place a pinch at the casualty's wrist and hold for two seconds to check perfusion."
        case .injuries:
            "Move your fingertips deliberately over the visible injury area and hold for one second."
        }
    }
}

enum DeteriorationProfile: Codable, Equatable, Sendable {
    case none
    case untreatedCardiacArrest(
        neurologicalRiskAfter: TimeInterval,
        deathAfter: TimeInterval
    )

    var neurologicalRiskThreshold: TimeInterval? {
        guard case let .untreatedCardiacArrest(threshold, _) = self else { return nil }
        return threshold
    }

    var deathThreshold: TimeInterval? {
        guard case let .untreatedCardiacArrest(_, threshold) = self else { return nil }
        return threshold
    }

    var requiresCPR: Bool {
        if case .untreatedCardiacArrest = self { return true }
        return false
    }

    func stage(after untreatedSeconds: TimeInterval) -> Int {
        guard case let .untreatedCardiacArrest(neurologicalRiskAfter, deathAfter) = self else {
            return 0
        }
        if untreatedSeconds >= deathAfter { return 5 }
        if untreatedSeconds >= neurologicalRiskAfter + 120 { return 4 }
        if untreatedSeconds >= neurologicalRiskAfter { return 3 }
        if untreatedSeconds >= neurologicalRiskAfter - 60 { return 2 }
        if untreatedSeconds >= neurologicalRiskAfter - 240 { return 1 }
        return 0
    }
}

struct Casualty: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let location: String
    let initialFindings: [Assessment: String]
    let deterioratedFindings: [Assessment: String]
    let correctInitialPriority: TriagePriority
    let correctDeterioratedPriority: TriagePriority?
    let initialHealth: Double
    let deteriorationProfile: DeteriorationProfile
    var health: Double
    var completedAssessments: Set<Assessment> = []
    var assignedPriority: TriagePriority?
    var isDeteriorated = false
    var untreatedSeconds: TimeInterval = 0
    var deteriorationStage = 0
    var isReceivingCPR = false
    var effectiveCPRSeconds: TimeInterval = 0
    var activeCPRBoutSeconds: TimeInterval = 0
    var cprSessionCount = 0
    var isDeceased = false

    var primaryAssessmentComplete: Bool {
        ScenarioRules.primaryAssessments.isSubset(of: completedAssessments)
    }

    var currentCorrectPriority: TriagePriority {
        if isDeceased { return .deceased }
        return isDeteriorated ? (correctDeterioratedPriority ?? correctInitialPriority) : correctInitialPriority
    }

    var neurologicalRiskTimeRemaining: TimeInterval? {
        guard let threshold = deteriorationProfile.neurologicalRiskThreshold else { return nil }
        return max(0, threshold - untreatedSeconds)
    }

    var deathTimeRemaining: TimeInterval? {
        guard let threshold = deteriorationProfile.deathThreshold else { return nil }
        return max(0, threshold - untreatedSeconds)
    }

    var conditionLabel: String {
        if isDeceased { return "Deceased - simulation outcome" }
        if isReceivingCPR { return "Simulated CPR active" }
        if deteriorationProfile.requiresCPR { return "Cardiac arrest - untreated" }
        if health <= 50 { return "Injured - stable" }
        return "Unconscious but physiologically stable"
    }

    var visibleSymptoms: String {
        if isDeceased { return "No spontaneous breathing or signs of circulation." }
        if isReceivingCPR {
            return "No spontaneous breathing. The scenario is treating continuous compression coverage as active."
        }
        guard deteriorationProfile.requiresCPR else {
            return initialFindings[.injuries] ?? "No visible change."
        }
        switch deteriorationStage {
        case 0:
            return "Unresponsive, motionless, pale, and not breathing normally."
        case 1:
            return "Skin is becoming cool; early blue discolouration is visible around the lips."
        case 2:
            return "Blue discolouration is worsening and the casualty remains unresponsive."
        case 3:
            return "Severe oxygen-deprivation signs are visible; neurological-injury risk is critical."
        case 4:
            return "Profound blue discolouration and continued absence of spontaneous circulation."
        default:
            return "No spontaneous breathing or signs of circulation."
        }
    }

    func finding(for assessment: Assessment) -> String {
        if deteriorationProfile.requiresCPR {
            switch assessment {
            case .response:
                return isDeceased ? "No response." : "Unresponsive to voice and pain."
            case .breathing:
                return isReceivingCPR
                    ? "No spontaneous breathing; simulated CPR coverage is active."
                    : "Not breathing normally."
            case .perfusion:
                if isReceivingCPR { return "No spontaneous pulse; simulated compression coverage is active." }
                return "No palpable pulse or spontaneous circulation."
            case .injuries:
                return visibleSymptoms
            }
        }
        if isDeteriorated, let finding = deterioratedFindings[assessment] { return finding }
        return initialFindings[assessment] ?? "No finding recorded."
    }

    mutating func advanceClocks(
        realDuration: TimeInterval,
        exerciseDuration: TimeInterval
    ) -> Int? {
        guard deteriorationProfile.requiresCPR else { return nil }

        let realDuration = max(0, realDuration)
        let exerciseDuration = max(0, exerciseDuration)
        if isReceivingCPR {
            effectiveCPRSeconds += realDuration
            activeCPRBoutSeconds += realDuration
            return nil
        }

        guard !isDeceased,
              let deathAfter = deteriorationProfile.deathThreshold else {
            return nil
        }

        untreatedSeconds = min(deathAfter, untreatedSeconds + exerciseDuration)
        let elapsedFraction = untreatedSeconds / deathAfter
        health = max(0, initialHealth * (1 - elapsedFraction))

        let nextStage = deteriorationProfile.stage(after: untreatedSeconds)
        return nextStage > deteriorationStage ? nextStage : nil
    }
}

enum InventoryTool: String, CaseIterable, Identifiable, Codable, Equatable, Hashable, Sendable {
    case bandage
    case safetyCone
    case defibrillator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bandage: "Bandage"
        case .safetyCone: "Hazard cone"
        case .defibrillator: "Defibrillator"
        }
    }
}

struct SessionEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let elapsed: TimeInterval
    let category: String
    let detail: String
    let isPositive: Bool?
    let outcome: String

    init(
        id: UUID = UUID(),
        elapsed: TimeInterval,
        category: String,
        detail: String,
        isPositive: Bool?,
        outcome: String
    ) {
        self.id = id
        self.elapsed = elapsed
        self.category = category
        self.detail = detail
        self.isPositive = isPositive
        self.outcome = outcome
    }

    var timestamp: String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct ScoreBreakdown: Codable, Equatable, Sendable {
    let safety: Int
    let assessment: Int
    let triage: Int
    let treatment: Int
    let communication: Int
    var total: Int { safety + assessment + triage + treatment + communication }
}

enum ResponderRole: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case incidentCommander
    case triageOfficer
    case airwayResponder
    case instructor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .incidentCommander: "Incident Commander"
        case .triageOfficer: "Triage Officer"
        case .airwayResponder: "Airway Responder"
        case .instructor: "Instructor"
        }
    }

    var icon: String {
        switch self {
        case .incidentCommander: "person.badge.shield.checkmark.fill"
        case .triageOfficer: "tag.fill"
        case .airwayResponder: "lungs.fill"
        case .instructor: "graduationcap.fill"
        }
    }

    var responsibility: String {
        switch self {
        case .incidentCommander:
            "Scene safety, hazards, resources, and scenario control"
        case .triageOfficer:
            "Casualty assessment, prioritisation, and reassessment"
        case .airwayResponder:
            "Primary assessment and continuous CPR"
        case .instructor:
            "Observe and intervene across all roles"
        }
    }
}

enum AssessmentEvidenceSource: String, Codable, Sendable {
    case handTracking
    case simulatorSpatialTarget
    case sharedParticipant

    var title: String {
        switch self {
        case .handTracking: "Vision Pro hand tracking"
        case .simulatorSpatialTarget: "Simulator spatial target"
        case .sharedParticipant: "Shared participant evidence"
        }
    }
}

struct AssessmentEvidence: Codable, Equatable, Sendable {
    let source: AssessmentEvidenceSource
    let sustainedDuration: TimeInterval
    let proximityMetres: Double
    let gesture: String

    static func simulatorTarget(gesture: String) -> AssessmentEvidence {
        AssessmentEvidence(
            source: .simulatorSpatialTarget,
            sustainedDuration: 1,
            proximityMetres: 0,
            gesture: gesture
        )
    }
}

enum DecisionOutcome: String, CaseIterable, Identifiable, Codable, Sendable {
    case succeeded
    case needsReview
    case corrected
    case scenarioUpdate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .succeeded: "Succeeded"
        case .needsReview: "Needs review"
        case .corrected: "Corrected"
        case .scenarioUpdate: "Scenario update"
        }
    }
}

struct CasualtyReplayState: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let health: Double
    let assignedPriority: TriagePriority?
    let correctPriority: TriagePriority
    let completedAssessments: Set<Assessment>
    let isReceivingCPR: Bool
    let isDeceased: Bool
    let conditionLabel: String
}

struct IncidentReplaySnapshot: Codable, Equatable, Sendable {
    let elapsed: TimeInterval
    let scenarioPace: ScenarioPace
    let selectedCasualtyID: String?
    let sceneSurveyed: Bool
    let hazardIdentified: Bool
    let hazardCommunicated: Bool
    let resourceRequestSent: Bool
    let casualties: [CasualtyReplayState]
}

struct DecisionEvidence: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let elapsed: TimeInterval
    let category: String
    let action: String
    let actorRole: ResponderRole?
    let outcome: DecisionOutcome
    let rationale: String
    let cues: [String]
    let consequence: String
    let recommendedAction: String?
    let snapshot: IncidentReplaySnapshot

    init(
        id: UUID = UUID(),
        elapsed: TimeInterval,
        category: String,
        action: String,
        actorRole: ResponderRole?,
        outcome: DecisionOutcome,
        rationale: String,
        cues: [String],
        consequence: String,
        recommendedAction: String? = nil,
        snapshot: IncidentReplaySnapshot
    ) {
        self.id = id
        self.elapsed = elapsed
        self.category = category
        self.action = action
        self.actorRole = actorRole
        self.outcome = outcome
        self.rationale = rationale
        self.cues = cues
        self.consequence = consequence
        self.recommendedAction = recommendedAction
        self.snapshot = snapshot
    }

    var timestamp: String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Grounded AI coach

struct AICoachEventPayload: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let timestamp: String
    let elapsedSeconds: Double
    let category: String
    let action: String
    let actorRole: String?
    let outcome: String
    let rationale: String
    let cues: [String]
    let consequence: String
    let recommendedAction: String?

    init(evidence: DecisionEvidence) {
        id = evidence.id.uuidString.lowercased()
        timestamp = evidence.timestamp
        elapsedSeconds = evidence.elapsed
        category = evidence.category
        action = evidence.action
        actorRole = evidence.actorRole?.title
        outcome = evidence.outcome.rawValue
        rationale = evidence.rationale
        cues = evidence.cues
        consequence = evidence.consequence
        recommendedAction = evidence.recommendedAction
    }
}

struct AICoachRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEventCount = 80
    static let scenarioName = "Roadside mass-casualty incident simulation"

    let schemaVersion: Int
    let sessionID: String
    let scenario: String
    let trainingMode: String
    let scenarioPace: String
    let score: ScoreBreakdown
    let events: [AICoachEventPayload]

    init(
        sessionID: UUID = UUID(),
        scenario: String = Self.scenarioName,
        trainingMode: TrainingMode = .guided,
        scenarioPace: ScenarioPace,
        score: ScoreBreakdown,
        evidence: [DecisionEvidence]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID.uuidString.lowercased()
        self.scenario = scenario
        self.trainingMode = trainingMode.title
        self.scenarioPace = scenarioPace.title
        self.score = score
        events = Self.boundedEvents(evidence).map(AICoachEventPayload.init)
    }

    private static func boundedEvents(_ evidence: [DecisionEvidence]) -> [DecisionEvidence] {
        guard evidence.count > maximumEventCount else { return evidence }

        // Preserve scene entry plus the most recent decisions when an unusually long
        // session exceeds the relay contract. UUID de-duplication keeps citations stable.
        let candidates = Array(evidence.prefix(20)) + Array(evidence.suffix(maximumEventCount - 20))
        var seen: Set<UUID> = []
        return candidates.filter { seen.insert($0.id).inserted }
    }
}

struct AICoachObservation: Codable, Equatable, Sendable {
    let headline: String
    let explanation: String
    let evidenceEventIDs: [String]
}

struct AICoachReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let safetyDisclaimer = "Simulation coaching only — not clinical guidance or certification. Follow your organisation's approved protocol and instructor direction."

    let schemaVersion: Int
    let summary: String
    let strongestDecision: AICoachObservation
    let missedCue: AICoachObservation
    let nextDrill: AICoachObservation
    let disclaimer: String

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        summary: String,
        strongestDecision: AICoachObservation,
        missedCue: AICoachObservation,
        nextDrill: AICoachObservation,
        disclaimer: String = Self.safetyDisclaimer
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.strongestDecision = strongestDecision
        self.missedCue = missedCue
        self.nextDrill = nextDrill
        self.disclaimer = disclaimer
    }

    var observations: [AICoachObservation] {
        [strongestDecision, missedCue, nextDrill]
    }

    func validated(against request: AICoachRequest) throws -> AICoachReport {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.isValidText(summary, maximumLength: 300) else {
            throw AICoachValidationError.invalidReport
        }

        let knownEventIDs = Set(request.events.map(\.id))
        for observation in observations {
            guard Self.isValidText(observation.headline, maximumLength: 80),
                  Self.isValidText(observation.explanation, maximumLength: 360),
                  (1...3).contains(observation.evidenceEventIDs.count),
                  Set(observation.evidenceEventIDs).count == observation.evidenceEventIDs.count,
                  observation.evidenceEventIDs.allSatisfy(knownEventIDs.contains) else {
                throw AICoachValidationError.ungroundedObservation
            }
        }

        // The app owns the safety language even when the prose comes from the relay.
        return AICoachReport(
            summary: summary,
            strongestDecision: strongestDecision,
            missedCue: missedCue,
            nextDrill: nextDrill
        )
    }

    static func localFallback(for request: AICoachRequest) throws -> AICoachReport {
        guard let firstEvent = request.events.first else {
            throw AICoachValidationError.noEvidence
        }

        let strongest = request.events.last(where: { $0.outcome == DecisionOutcome.succeeded.rawValue })
            ?? request.events.last(where: { $0.outcome == DecisionOutcome.corrected.rawValue })
            ?? firstEvent
        let missed = request.events.last(where: { $0.outcome == DecisionOutcome.needsReview.rawValue })
            ?? request.events.last(where: { $0.outcome == DecisionOutcome.scenarioUpdate.rawValue })
            ?? firstEvent
        let drill = request.events.last(where: {
            guard let action = $0.recommendedAction else { return false }
            return !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) ?? missed

        let strongestObservation = AICoachObservation(
            headline: "Strongest recorded decision",
            explanation: strongest.rationale,
            evidenceEventIDs: [strongest.id]
        )
        let missedObservation = AICoachObservation(
            headline: missed.outcome == DecisionOutcome.needsReview.rawValue
                ? "Cue to catch earlier"
                : "Decision point to review",
            explanation: missed.consequence,
            evidenceEventIDs: [missed.id]
        )
        let nextDrillObservation = AICoachObservation(
            headline: "Next repetition",
            explanation: drill.recommendedAction
                ?? "Repeat the scenario and verbalise the visible cue before committing the next action.",
            evidenceEventIDs: [drill.id]
        )

        return try AICoachReport(
            summary: "Deterministic review of a \(request.score.total)/100 run, grounded in \(request.events.count) recorded decision events.",
            strongestDecision: strongestObservation,
            missedCue: missedObservation,
            nextDrill: nextDrillObservation
        ).validated(against: request)
    }

    private static func isValidText(_ text: String, maximumLength: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && text.count <= maximumLength
    }
}

enum AICoachValidationError: Error, Equatable {
    case noEvidence
    case invalidReport
    case ungroundedObservation
}

struct SharedIncidentSnapshot: Codable, Equatable, Sendable {
    let revision: Int
    let phase: ScenarioPhase
    let scenarioPace: ScenarioPace
    let casualties: [Casualty]
    let hazardIdentified: Bool
    let hazardCommunicated: Bool
    let surveyedCheckpoints: Set<SurveyCheckpoint>
    let resourceRequestSent: Bool
    let deteriorationTriggered: Bool
    let events: [SessionEvent]
    let decisionEvidence: [DecisionEvidence]
    let elapsed: TimeInterval
    let conditionAlert: String?
    let inventory: [InventoryTool: Int]
    let appliedEquipment: [String: Set<InventoryTool>]
    let placedSafetyConeCount: Int

    var sceneSurveyed: Bool {
        SurveyCheckpoint.required.isSubset(of: surveyedCheckpoints)
    }
}

enum IncidentSnapshotDeliveryPolicy {
    static func requiresReliableDelivery(
        previousPhase: ScenarioPhase?,
        currentPhase: ScenarioPhase
    ) -> Bool {
        currentPhase != .active || previousPhase != .active
    }
}

enum IncidentCommand: Codable, Sendable {
    case begin
    case end
    case reset
    case setScenarioPace(ScenarioPace)
    case inspectSurveyCheckpoint(SurveyCheckpoint)
    case identifyHazard
    case communicateHazard
    case requestResources
    case selectCasualty(String)
    case closeCasualty
    case performAssessment(String, Assessment, AssessmentEvidence)
    case assignPriority(String, TriagePriority)
    case beginCPR(String)
    case endCPR(String, String)
    case useEquipment(InventoryTool, String?)
    case replenishInventory

    var isLocalNavigation: Bool {
        switch self {
        case .selectCasualty, .closeCasualty:
            true
        default:
            false
        }
    }

    var targetCasualtyID: String? {
        switch self {
        case .selectCasualty(let casualtyID),
             .performAssessment(let casualtyID, _, _),
             .assignPriority(let casualtyID, _),
             .beginCPR(let casualtyID),
             .endCPR(let casualtyID, _):
            casualtyID
        case .useEquipment(_, let casualtyID):
            casualtyID
        case .begin, .end, .reset, .setScenarioPace, .inspectSurveyCheckpoint,
             .identifyHazard, .communicateHazard, .requestResources,
             .closeCasualty, .replenishInventory:
            nil
        }
    }

    var actionTitle: String {
        switch self {
        case .begin:
            "start the incident"
        case .end:
            "end the incident"
        case .reset:
            "reset the incident"
        case .setScenarioPace(let pace):
            "set the exercise pace to \(pace.title)"
        case .inspectSurveyCheckpoint(let checkpoint):
            "inspect the \(checkpoint.title.lowercased())"
        case .identifyHazard:
            "identify the fuel hazard"
        case .communicateHazard:
            "report the fuel hazard"
        case .requestResources:
            "request additional resources"
        case .selectCasualty:
            "select a casualty"
        case .closeCasualty:
            "leave the selected casualty"
        case .performAssessment(_, let assessment, _):
            assessment.rawValue.lowercased()
        case .assignPriority(_, let priority):
            "assign \(priority.rawValue) priority"
        case .beginCPR:
            "begin CPR"
        case .endCPR:
            "end CPR"
        case .useEquipment(let tool, _):
            "use \(tool.title.lowercased())"
        case .replenishInventory:
            "replenish training equipment"
        }
    }

    func isPermitted(for role: ResponderRole) -> Bool {
        if role == .instructor { return true }
        switch self {
        case .begin, .end, .reset, .setScenarioPace, .inspectSurveyCheckpoint, .identifyHazard, .communicateHazard, .requestResources:
            return role == .incidentCommander
        case .assignPriority:
            return role == .triageOfficer
        case .beginCPR, .endCPR:
            return role == .airwayResponder
        case .performAssessment:
            return role == .triageOfficer || role == .airwayResponder
        case .selectCasualty, .closeCasualty, .useEquipment, .replenishInventory:
            return true
        }
    }

    var permissionDescription: String {
        switch self {
        case .begin, .end, .reset, .setScenarioPace, .inspectSurveyCheckpoint, .identifyHazard, .communicateHazard, .requestResources:
            "This action belongs to the Incident Commander."
        case .assignPriority:
            "Priority assignment belongs to the Triage Officer."
        case .beginCPR, .endCPR:
            "CPR belongs to the Airway Responder."
        case .performAssessment:
            "Assessment belongs to the Triage Officer or Airway Responder."
        case .selectCasualty, .closeCasualty, .useEquipment, .replenishInventory:
            "This action is available to every role."
        }
    }
}

struct RoleAnnouncement: Codable, Sendable {
    let role: ResponderRole
}

enum IncidentMessage: Codable, Sendable {
    case command(IncidentCommand, ResponderRole)
    case snapshot(SharedIncidentSnapshot)
    case requestSnapshot
    case announceRole(RoleAnnouncement)
    case rejection(String)
}

struct SpatialVector3: Codable, Equatable, Sendable {
    let x: Float
    let y: Float
    let z: Float

    func distance(to other: SpatialVector3) -> Float {
        let dx = x - other.x
        let dy = y - other.y
        let dz = z - other.z
        return sqrt((dx * dx) + (dy * dy) + (dz * dz))
    }
}

struct HandPoseSample: Equatable, Sendable {
    let timestamp: TimeInterval
    let indexTip: SpatialVector3
    let thumbTip: SpatialVector3
    let middleTip: SpatialVector3
    let ringTip: SpatialVector3
    let littleTip: SpatialVector3
    let wrist: SpatialVector3

    var pinchDistance: Float {
        indexTip.distance(to: thumbTip)
    }

    var isOpenHand: Bool {
        let extendedFingerCount = [indexTip, middleTip, ringTip, littleTip]
            .filter { $0.distance(to: wrist) >= 0.11 }
            .count
        return extendedFingerCount >= 3
    }
}

struct SpatialAssessmentTarget: Equatable, Sendable {
    let casualtyID: String
    let assessment: Assessment
    let centre: SpatialVector3
    let radius: Float
    let requiredDuration: TimeInterval
    let requiresPinch: Bool
    let requiresOpenHand: Bool
    let usesWrist: Bool
}

enum SpatialAssessmentCatalog {
    private static let casualtyPositions: [String: SpatialVector3] = [
        "casualty-a": SpatialVector3(x: -1.55, y: -1.08, z: -2.25),
        "casualty-b": SpatialVector3(x: 0.1, y: -1.08, z: -3.15),
        "casualty-c": SpatialVector3(x: 1.55, y: -1.08, z: -2.2)
    ]
    private static let casualtyYaws: [String: Float] = [
        "casualty-a": -0.34,
        "casualty-b": 0.18,
        "casualty-c": 0.52
    ]

    static func target(casualtyID: String, assessment: Assessment) -> SpatialAssessmentTarget? {
        guard let base = casualtyPositions[casualtyID] else { return nil }
        let offset: SpatialVector3
        let radius: Float
        let duration: TimeInterval
        let requiresPinch: Bool
        let requiresOpenHand: Bool
        let usesWrist: Bool

        switch assessment {
        case .response:
            offset = SpatialVector3(x: -0.42, y: 0.44, z: 0)
            radius = 0.22
            duration = 1
            requiresPinch = false
            requiresOpenHand = false
            usesWrist = false
        case .breathing:
            offset = SpatialVector3(x: 0, y: 0.48, z: 0)
            radius = 0.24
            duration = 1.5
            requiresPinch = false
            requiresOpenHand = true
            usesWrist = true
        case .perfusion:
            offset = SpatialVector3(x: 0.38, y: 0.36, z: 0.14)
            radius = 0.2
            duration = 1.5
            requiresPinch = true
            requiresOpenHand = false
            usesWrist = false
        case .injuries:
            offset = SpatialVector3(x: 0.62, y: 0.3, z: -0.08)
            radius = 0.24
            duration = 1
            requiresPinch = false
            requiresOpenHand = false
            usesWrist = false
        }

        let yaw = casualtyYaws[casualtyID, default: 0]
        let rotatedOffset = SpatialVector3(
            x: offset.x * cos(yaw) + offset.z * sin(yaw),
            y: offset.y,
            z: -offset.x * sin(yaw) + offset.z * cos(yaw)
        )

        return SpatialAssessmentTarget(
            casualtyID: casualtyID,
            assessment: assessment,
            centre: SpatialVector3(
                x: base.x + rotatedOffset.x,
                y: base.y + rotatedOffset.y,
                z: base.z + rotatedOffset.z
            ),
            radius: radius,
            requiredDuration: duration,
            requiresPinch: requiresPinch,
            requiresOpenHand: requiresOpenHand,
            usesWrist: usesWrist
        )
    }

    static func localOffset(for assessment: Assessment) -> SpatialVector3 {
        guard let originTarget = target(casualtyID: "casualty-b", assessment: assessment),
              let base = casualtyPositions["casualty-b"] else {
            return SpatialVector3(x: 0, y: 0.4, z: 0)
        }
        return SpatialVector3(
            x: originTarget.centre.x - base.x,
            y: originTarget.centre.y - base.y,
            z: originTarget.centre.z - base.z
        )
    }
}

struct SpatialAssessmentObservation: Equatable, Sendable {
    let assessment: Assessment
    let poseMatches: Bool
    let progress: Double
    let proximityMetres: Double
    let completedEvidence: AssessmentEvidence?
}

struct SpatialAssessmentEngine: Sendable {
    private var activeKey: String?
    private var startedAt: TimeInterval?

    mutating func reset() {
        activeKey = nil
        startedAt = nil
    }

    mutating func observe(
        sample: HandPoseSample,
        target: SpatialAssessmentTarget
    ) -> SpatialAssessmentObservation {
        let trackedPoint = target.usesWrist ? sample.wrist : sample.indexTip
        let proximity = trackedPoint.distance(to: target.centre)
        let poseMatches = proximity <= target.radius
            && (!target.requiresPinch || sample.pinchDistance <= 0.045)
            && (!target.requiresOpenHand || sample.isOpenHand)
        let key = "\(target.casualtyID)-\(target.assessment.code)"

        guard poseMatches else {
            reset()
            return SpatialAssessmentObservation(
                assessment: target.assessment,
                poseMatches: false,
                progress: 0,
                proximityMetres: Double(proximity),
                completedEvidence: nil
            )
        }

        if activeKey != key {
            activeKey = key
            startedAt = sample.timestamp
        }

        let duration = max(0, sample.timestamp - (startedAt ?? sample.timestamp))
        let progress = min(1, duration / target.requiredDuration)
        let evidence: AssessmentEvidence?
        if progress >= 1 {
            evidence = AssessmentEvidence(
                source: .handTracking,
                sustainedDuration: duration,
                proximityMetres: Double(proximity),
                gesture: target.requiresPinch
                    ? "sustained fingertip pinch"
                    : target.requiresOpenHand
                        ? "sustained open-palm placement"
                        : "sustained hand placement"
            )
            reset()
        } else {
            evidence = nil
        }

        return SpatialAssessmentObservation(
            assessment: target.assessment,
            poseMatches: true,
            progress: progress,
            proximityMetres: Double(proximity),
            completedEvidence: evidence
        )
    }
}
