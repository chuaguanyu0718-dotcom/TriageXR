import SwiftUI
import RealityKit
import UIKit
import AVFoundation
import Combine
import ARKit
import GroupActivities

// MARK: - App

@main
struct TriageXRApp: App {
    @StateObject private var session: TrainingSession
    @StateObject private var collaboration: IncidentCollaborationCoordinator
    @StateObject private var spatialAssessment: SpatialAssessmentCoordinator
    @StateObject private var aiCoach: AICoachCoordinator

    init() {
        let session = TrainingSession()
        let collaboration = IncidentCollaborationCoordinator(trainingSession: session)
        let spatialAssessment = SpatialAssessmentCoordinator(trainingSession: session)
        spatialAssessment.installCommandSubmitter { [weak collaboration] command in
            collaboration?.submit(command)
        }
        _session = StateObject(wrappedValue: session)
        _collaboration = StateObject(wrappedValue: collaboration)
        _spatialAssessment = StateObject(wrappedValue: spatialAssessment)
        _aiCoach = StateObject(wrappedValue: AICoachCoordinator())
    }

    var body: some SwiftUI.Scene {
        WindowGroup(id: "MainWindow") {
            ContentView()
                .environmentObject(session)
                .environmentObject(collaboration)
                .environmentObject(spatialAssessment)
                .environmentObject(aiCoach)
        }
        .defaultSize(width: 920, height: 720)

        ImmersiveSpace(id: "TriageScene") {
            ImmersiveTriageView()
                .environmentObject(session)
                .environmentObject(collaboration)
                .environmentObject(spatialAssessment)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

// MARK: - Domain model

extension TriagePriority {
    var colour: Color {
        switch self {
        case .p1: .red
        case .p2: .orange
        case .p3: .green
        case .deceased: .black
        }
    }
}

extension Casualty {
    var conditionColour: Color {
        if isDeceased { return .gray }
        if isReceivingCPR { return .green }
        if deteriorationProfile.requiresCPR { return health <= 25 ? .red : .orange }
        return health <= 50 ? .orange : .blue
    }
}

struct RecommendedAction {
    let title: String
    let detail: String
    let icon: String
    let colour: Color
}

@MainActor
final class TrainingSession: ObservableObject {
    @Published var phase: ScenarioPhase = .briefing
    @Published var scenarioPace: ScenarioPace = .demo
    @Published var casualties: [Casualty] = TrainingSession.makeCasualties()
    @Published var selectedCasualtyID: String?
    @Published var hazardIdentified = false
    @Published var hazardCommunicated = false
    @Published var surveyedCheckpoints: Set<SurveyCheckpoint> = []
    @Published var resourceRequestSent = false
    @Published var deteriorationTriggered = false
    @Published var events: [SessionEvent] = []
    @Published var decisionEvidence: [DecisionEvidence] = []
    @Published var elapsed: TimeInterval = 0
    @Published var conditionAlert: String? = nil
    @Published var inventory: [InventoryTool: Int] = TrainingSession.defaultInventory
    @Published var appliedEquipment: [String: Set<InventoryTool>] = [:]
    @Published var placedSafetyConeCount = 0
    @Published private(set) var revision = 0

    private var lastTickAt: Date?
    private var timer: Timer?
    private let voice = AVSpeechSynthesizer()
    private var currentActorRole: ResponderRole = .incidentCommander
    var didChange: ((SharedIncidentSnapshot) -> Void)?

    static let defaultInventory: [InventoryTool: Int] = [
        .bandage: 4,
        .safetyCone: 4,
        .defibrillator: 1
    ]

    var selectedCasualty: Casualty? {
        guard let id = selectedCasualtyID else { return nil }
        return casualties.first(where: { $0.id == id })
    }

    var assessedCount: Int {
        casualties.filter { !$0.completedAssessments.isEmpty }.count
    }

    var taggedCount: Int {
        casualties.filter { $0.assignedPriority != nil }.count
    }

    var canComplete: Bool { taggedCount == casualties.count }

    var sceneSurveyed: Bool {
        SurveyCheckpoint.required.isSubset(of: surveyedCheckpoints)
    }

    var nextRecommendedAction: RecommendedAction {
        if !sceneSurveyed {
            return RecommendedAction(
                title: "Survey the scene",
                detail: "Turn naturally through the front, left, rear, and right sectors (\(surveyedCheckpoints.count)/\(SurveyCheckpoint.required.count)).",
                icon: "view.360",
                colour: .orange
            )
        }
        if !hazardIdentified {
            return RecommendedAction(
                title: "Identify the hazard",
                detail: "Locate and pinch the yellow fuel spill near the vehicles.",
                icon: "exclamationmark.triangle.fill",
                colour: .orange
            )
        }
        if let jordan = casualties.first(where: { $0.id == "casualty-b" }),
           !jordan.primaryAssessmentComplete {
            return RecommendedAction(
                title: "Assess Jordan",
                detail: "Check response, breathing, and perfusion to confirm the immediate threat.",
                icon: "stethoscope",
                colour: .red
            )
        }
        if let jordan = casualties.first(where: { $0.id == "casualty-b" }),
           !jordan.isDeceased,
           jordan.effectiveCPRSeconds < ScenarioRules.minimumDemonstrationCPRDuration {
            return RecommendedAction(
                title: jordan.isReceivingCPR ? "Maintain simulated CPR" : "Start simulated CPR for Jordan",
                detail: jordan.isReceivingCPR
                    ? "Keep holding the compression target; \(ScenarioRules.targetCompressionRate)/min is a reference rhythm, not a measured rate."
                    : "Pinch and hold the red target to represent continuous compression coverage; deterioration resumes when released.",
                icon: "heart.fill",
                colour: .red
            )
        }
        if let casualty = casualties.first(where: { !$0.primaryAssessmentComplete }) {
            return RecommendedAction(
                title: "Assess \(casualty.name)",
                detail: "Complete response, breathing, and perfusion before assigning a tag.",
                icon: "waveform.path.ecg",
                colour: .blue
            )
        }
        if let casualty = casualties.first(where: { $0.assignedPriority == nil }) {
            return RecommendedAction(
                title: "Tag \(casualty.name)",
                detail: "Use the completed primary assessment to assign a triage priority.",
                icon: "tag.fill",
                colour: .purple
            )
        }
        if !hazardCommunicated {
            return RecommendedAction(
                title: "Report the fuel hazard",
                detail: "Communicate the exclusion zone to incident command.",
                icon: "radio",
                colour: .orange
            )
        }
        if !resourceRequestSent {
            return RecommendedAction(
                title: "Request resources",
                detail: "Ask for fire suppression and additional medical support.",
                icon: "person.3.fill",
                colour: .blue
            )
        }
        return RecommendedAction(
            title: "Finish and review",
            detail: "All casualties are tagged. End the scenario to view the decision timeline.",
            icon: "checkmark.seal.fill",
            colour: .green
        )
    }

    var debriefEvents: [SessionEvent] {
        events.filter { $0.category != "Navigation" }
    }

    func apply(_ command: IncidentCommand, actorRole: ResponderRole) {
        if phase == .active {
            advanceClock()
        }
        currentActorRole = actorRole
        defer { currentActorRole = .incidentCommander }

        switch command {
        case .begin:
            begin()
        case .end:
            end()
        case .reset:
            reset()
        case .setScenarioPace(let pace):
            setScenarioPace(pace)
        case .inspectSurveyCheckpoint(let checkpoint):
            inspectSurveyCheckpoint(checkpoint)
        case .identifyHazard:
            identifyHazard()
        case .communicateHazard:
            communicateHazard()
        case .requestResources:
            requestResources()
        case .selectCasualty(let id):
            selectCasualty(id)
        case .closeCasualty:
            closeCasualty()
        case .performAssessment(let casualtyID, let assessment, let evidence):
            perform(assessment, for: casualtyID, evidence: evidence)
        case .assignPriority(let casualtyID, let priority):
            assign(priority, to: casualtyID)
        case .beginCPR(let casualtyID):
            beginCPR(for: casualtyID)
        case .endCPR(let casualtyID, let reason):
            endCPR(for: casualtyID, reason: reason)
        case .useEquipment(let tool, let casualtyID):
            useEquipment(tool, casualtyID: casualtyID)
        case .replenishInventory:
            replenishInventory()
        }
    }

    func recordRoleRejection(_ command: IncidentCommand, actorRole: ResponderRole) {
        guard phase == .active else { return }
        advanceClock()
        currentActorRole = actorRole
        defer { currentActorRole = .incidentCommander }

        record(
            "Command",
            "\(actorRole.title) attempted to \(command.actionTitle) outside the assigned role.",
            positive: false,
            outcome: "Role boundary protected",
            evidenceOutcome: .needsReview,
            rationale: command.permissionDescription,
            cues: [
                "Assigned responsibility: \(actorRole.responsibility)",
                "Requested action: \(command.actionTitle)"
            ],
            consequence: "The command was rejected and the incident state did not change.",
            recommendedAction: "Hand the action to the responsible role or change roles before attempting it again.",
            replayFocusCasualtyID: command.targetCasualtyID
        )
    }

    func sharedSnapshot() -> SharedIncidentSnapshot {
        SharedIncidentSnapshot(
            revision: revision,
            phase: phase,
            scenarioPace: scenarioPace,
            casualties: casualties,
            hazardIdentified: hazardIdentified,
            hazardCommunicated: hazardCommunicated,
            surveyedCheckpoints: surveyedCheckpoints,
            resourceRequestSent: resourceRequestSent,
            deteriorationTriggered: deteriorationTriggered,
            events: events,
            decisionEvidence: decisionEvidence,
            elapsed: elapsed,
            conditionAlert: conditionAlert,
            inventory: inventory,
            appliedEquipment: appliedEquipment,
            placedSafetyConeCount: placedSafetyConeCount
        )
    }

    func applySharedSnapshot(_ snapshot: SharedIncidentSnapshot, force: Bool = false) {
        guard force || snapshot.revision >= revision else { return }
        timer?.invalidate()
        timer = nil
        revision = snapshot.revision
        phase = snapshot.phase
        scenarioPace = snapshot.scenarioPace
        casualties = snapshot.casualties
        if snapshot.phase != .active {
            selectedCasualtyID = nil
        }
        hazardIdentified = snapshot.hazardIdentified
        hazardCommunicated = snapshot.hazardCommunicated
        surveyedCheckpoints = snapshot.surveyedCheckpoints
        resourceRequestSent = snapshot.resourceRequestSent
        deteriorationTriggered = snapshot.deteriorationTriggered
        events = snapshot.events
        decisionEvidence = snapshot.decisionEvidence
        elapsed = snapshot.elapsed
        conditionAlert = snapshot.conditionAlert
        inventory = snapshot.inventory
        appliedEquipment = snapshot.appliedEquipment
        placedSafetyConeCount = snapshot.placedSafetyConeCount
        lastTickAt = nil
    }

    func begin() {
        casualties = Self.makeCasualties()
        selectedCasualtyID = nil
        hazardIdentified = false
        hazardCommunicated = false
        surveyedCheckpoints = []
        resourceRequestSent = false
        deteriorationTriggered = false
        events = []
        decisionEvidence = []
        elapsed = 0
        conditionAlert = nil
        inventory = Self.defaultInventory
        appliedEquipment = [:]
        placedSafetyConeCount = 0
        phase = .active
        lastTickAt = Date()
        record(
            "Scenario",
            "Road traffic collision scenario started.",
            outcome: "Scenario active",
            evidenceOutcome: .scenarioUpdate,
            rationale: "The briefing establishes three casualties, an unknown roadside hazard, and a time-critical cardiac arrest.",
            cues: [
                "Three reported casualties",
                "Hazards initially unknown",
                "One condition may change",
                "Exercise pace: \(scenarioPace.title)"
            ],
            consequence: "The incident clock and untreated deterioration clock started."
        )
        startTimer()
    }

    func setScenarioPace(_ pace: ScenarioPace) {
        guard phase == .briefing, scenarioPace != pace else { return }
        scenarioPace = pace
        conditionAlert = nil
        commitChange()
    }

    func end() {
        guard phase == .active else { return }
        for index in casualties.indices where casualties[index].isReceivingCPR {
            casualties[index].isReceivingCPR = false
            casualties[index].activeCPRBoutSeconds = 0
        }
        record(
            "Scenario",
            "Scenario ended with \(taggedCount) of \(casualties.count) casualties tagged.",
            outcome: "Debrief generated",
            evidenceOutcome: canComplete ? .succeeded : .needsReview,
            rationale: canComplete
                ? "Every casualty had a recorded priority when the scenario ended."
                : "Ending before every casualty is tagged leaves incident command without a complete priority picture.",
            cues: ["\(taggedCount) of \(casualties.count) casualties tagged"],
            consequence: "The evidence replay and after-action review were generated.",
            recommendedAction: canComplete
                ? nil
                : "Complete the primary assessments and assign a priority to every casualty before ending the incident."
        )
        timer?.invalidate()
        timer = nil
        lastTickAt = nil
        phase = .complete
        selectedCasualtyID = nil
        commitChange()
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        lastTickAt = nil
        phase = .briefing
        selectedCasualtyID = nil
        elapsed = 0
        conditionAlert = nil
        revision += 1
        didChange?(sharedSnapshot())
    }

    func inspectSurveyCheckpoint(_ checkpoint: SurveyCheckpoint) {
        guard phase == .active else { return }
        let wasNew = surveyedCheckpoints.insert(checkpoint).inserted
        guard wasNew else { return }
        let inspectedCount = surveyedCheckpoints.count
        let isComplete = sceneSurveyed
        record(
            "Safety",
            isComplete
                ? "Inspected the \(checkpoint.title.lowercased()) and completed the 360° scene survey."
                : "Inspected the \(checkpoint.title.lowercased()) during the 360° scene survey.",
            positive: true,
            outcome: isComplete
                ? "Scene entry safe"
                : "Survey \(inspectedCount) of \(SurveyCheckpoint.required.count)",
            evidenceOutcome: .succeeded,
            rationale: "A deliberate physical scan reduces the chance of entering an unmanaged hazard or missing casualties and access routes.",
            cues: [checkpoint.spatialCue, "\(inspectedCount) of \(SurveyCheckpoint.required.count) sectors inspected"],
            consequence: isComplete
                ? "The full scene perimeter and approach routes were checked before patient contact."
                : "The \(checkpoint.title.lowercased()) was added to the verified scene survey.",
            recommendedAction: isComplete
                ? nil
                : "Continue turning through the scene and inspect every remaining blue sector beacon."
        )
    }

    func identifyHazard() {
        guard phase == .active, !hazardIdentified else { return }
        hazardIdentified = true
        record(
            "Safety",
            "Identified the leaking-fuel hazard and established an exclusion zone.",
            positive: true,
            outcome: "Correct recognition",
            evidenceOutcome: .succeeded,
            rationale: "The yellow spill beside the damaged vehicle indicates a flammable liquid hazard.",
            cues: ["Yellow liquid at vehicle", "Collision damage", "No fire crew on scene"],
            consequence: "The fuel area was treated as an exclusion zone."
        )
    }

    func communicateHazard() {
        guard phase == .active, hazardIdentified, !hazardCommunicated else { return }
        hazardCommunicated = true
        record(
            "Communication",
            "Reported the fuel hazard to incident command.",
            positive: true,
            outcome: "Hazard reported",
            evidenceOutcome: .succeeded,
            rationale: "Recognising a hazard does not protect other responders until it is communicated.",
            cues: ["Fuel hazard already identified", "Other responders may enter the scene"],
            consequence: "Incident command received the exclusion-zone warning."
        )
    }

    func requestResources() {
        guard phase == .active, !resourceRequestSent else { return }
        resourceRequestSent = true
        record(
            "Communication",
            "Requested fire suppression and additional medical resources.",
            positive: true,
            outcome: "Escalation complete",
            evidenceOutcome: .succeeded,
            rationale: "Three casualties plus a fuel leak exceed the capability of a single responder.",
            cues: ["Three casualties", "Active fuel hazard", "Cardiac arrest requires continuous care"],
            consequence: "Fire suppression and additional medical support were dispatched."
        )
    }

    func selectCasualty(_ id: String) {
        guard phase == .active,
              casualties.contains(where: { $0.id == id }) else { return }
        selectedCasualtyID = id
        if let casualty = casualties.first(where: { $0.id == id }) {
            record(
                "Navigation",
                "Approached \(casualty.name) at \(casualty.location).",
                includeInReplay: false
            )
        }
    }

    func closeCasualty() {
        selectedCasualtyID = nil
        commitChange()
    }

    func applyLocalNavigation(_ command: IncidentCommand) {
        guard phase == .active else { return }
        switch command {
        case .selectCasualty(let casualtyID):
            guard casualties.contains(where: { $0.id == casualtyID }) else { return }
            selectedCasualtyID = casualtyID
        case .closeCasualty:
            selectedCasualtyID = nil
        default:
            assertionFailure("Expected a local navigation command")
        }
    }

    func perform(
        _ assessment: Assessment,
        for casualtyID: String,
        evidence: AssessmentEvidence
    ) {
        guard phase == .active,
              let index = casualties.firstIndex(where: { $0.id == casualtyID }) else { return }
        let wasNew = casualties[index].completedAssessments.insert(assessment).inserted
        if wasNew {
            let casualty = casualties[index]
            let finding = casualty.finding(for: assessment)
            record(
                "Assessment",
                "\(assessment.rawValue) for \(casualty.name): \(finding)",
                positive: true,
                outcome: "Spatially verified",
                evidenceOutcome: .succeeded,
                rationale: "The \(evidence.source.title.lowercased()) verified \(evidence.gesture) for \(String(format: "%.1f", evidence.sustainedDuration)) seconds before revealing the finding.",
                cues: [finding, "Hand proximity \(String(format: "%.2f", evidence.proximityMetres)) m"],
                consequence: assessmentConsequence(assessment, casualty: casualty),
                replayFocusCasualtyID: casualtyID
            )
        }
    }

    func assign(_ priority: TriagePriority, to casualtyID: String) {
        guard phase == .active,
              let index = casualties.firstIndex(where: { $0.id == casualtyID }) else { return }

        guard casualties[index].primaryAssessmentComplete else {
            let message = "Complete response, breathing, and perfusion checks before tagging \(casualties[index].name)."
            conditionAlert = message
            record(
                "Triage",
                message,
                positive: false,
                outcome: "Assessment incomplete",
                evidenceOutcome: .needsReview,
                rationale: "Priority assignment without response, breathing, and perfusion evidence is not defensible.",
                cues: missingPrimaryAssessmentCues(for: casualties[index]),
                consequence: "The tag was blocked until the primary assessment is complete.",
                recommendedAction: "Complete every missing primary assessment, then assign the priority from those findings.",
                replayFocusCasualtyID: casualtyID
            )
            return
        }

        let previous = casualties[index].assignedPriority
        casualties[index].assignedPriority = priority
        let correct = priority == casualties[index].currentCorrectPriority
        let action = previous == nil ? "Tagged" : "Retagged"
        let corrected = previous != nil && previous != casualties[index].currentCorrectPriority && correct
        let casualty = casualties[index]
        record(
            "Triage",
            "\(action) \(casualty.name) as \(priority.rawValue) - \(priority.title).",
            positive: correct,
            outcome: correct ? "Correct priority" : "Priority mismatch",
            evidenceOutcome: corrected ? .corrected : correct ? .succeeded : .needsReview,
            rationale: triageRationale(for: casualty, assigned: priority, correct: correct),
            cues: primaryFindingCues(for: casualty),
            consequence: correct
                ? "The casualty entered the correct treatment priority queue."
                : "The mismatch could delay care or divert scarce resources.",
            recommendedAction: correct
                ? nil
                : "Re-read the response, breathing, and perfusion evidence, then retag \(casualty.name) as \(casualty.currentCorrectPriority.rawValue).",
            replayFocusCasualtyID: casualtyID
        )
    }

    func beginCPR(for casualtyID: String) {
        guard phase == .active,
              let index = casualties.firstIndex(where: { $0.id == casualtyID }),
              casualties[index].deteriorationProfile.requiresCPR,
              !casualties[index].isReceivingCPR,
              !casualties[index].isDeceased else { return }
        casualties[index].isReceivingCPR = true
        casualties[index].activeCPRBoutSeconds = 0
        casualties[index].cprSessionCount += 1
        let pausedAt = casualties[index].neurologicalRiskTimeRemaining ?? 0
        conditionAlert = "Simulated CPR started for \(casualties[index].name). Keep holding to represent continuous compression coverage."
        record(
            "Treatment",
            "Simulated CPR coverage commenced for \(casualties[index].name) with \(Self.formatCountdown(pausedAt)) remaining to neurological risk.",
            positive: true,
            outcome: "Deterioration paused",
            evidenceOutcome: .succeeded,
            rationale: "Unresponsiveness, abnormal breathing, and absent circulation triggered the scenario's CPR response. The spatial hold represents continuous team coverage; it does not measure physical compression quality.",
            cues: primaryFindingCues(for: casualties[index]),
            consequence: "Untreated deterioration paused while simulated compression coverage continued.",
            replayFocusCasualtyID: casualtyID
        )

        let announcement = AVSpeechUtterance(
            string: "CPR simulation started. Maintain the hold; the displayed rhythm is a reference."
        )
        announcement.rate = 0.48
        announcement.volume = 0.9
        voice.speak(announcement)
    }

    func endCPR(for casualtyID: String, reason: String = "Compression simulation hold released") {
        guard phase == .active else { return }
        guard let index = casualties.firstIndex(where: { $0.id == casualtyID }),
              casualties[index].isReceivingCPR else { return }

        let boutDuration = casualties[index].activeCPRBoutSeconds
        casualties[index].isReceivingCPR = false
        casualties[index].activeCPRBoutSeconds = 0

        let remaining = casualties[index].neurologicalRiskTimeRemaining
            ?? casualties[index].deathTimeRemaining
            ?? 0
        let metDemonstrationTarget = boutDuration >= ScenarioRules.minimumDemonstrationCPRDuration
        conditionAlert = "CPR simulation stopped for \(casualties[index].name). Untreated deterioration has resumed."
        record(
            "Treatment",
            "\(reason) after \(Self.formatDuration(boutDuration)) of simulated CPR coverage; untreated countdown resumed at \(Self.formatCountdown(remaining)).",
            positive: metDemonstrationTarget,
            outcome: metDemonstrationTarget ? "CPR coverage recorded" : "CPR simulation interrupted early",
            evidenceOutcome: metDemonstrationTarget ? .succeeded : .needsReview,
            rationale: metDemonstrationTarget
                ? "The spatial hold met the demonstration threshold and represented continuous team coverage during the recorded bout. It did not assess physical compression mechanics."
                : "The spatial hold ended before the demonstration threshold, interrupting the simulated coverage period.",
            cues: ["Simulated coverage \(Self.formatDuration(boutDuration))", "Reference rhythm \(ScenarioRules.targetCompressionRate)/min"],
            consequence: "Untreated deterioration resumed as soon as compressions stopped.",
            recommendedAction: metDemonstrationTarget
                ? nil
                : "Re-establish the compression hold and maintain it continuously for at least \(Int(ScenarioRules.minimumDemonstrationCPRDuration)) real seconds.",
            replayFocusCasualtyID: casualtyID
        )
    }

    func useEquipment(_ tool: InventoryTool, casualtyID: String?) {
        guard phase == .active, inventory[tool, default: 0] > 0 else {
            conditionAlert = "No \(tool.title.lowercased()) units are available."
            return
        }

        if tool == .safetyCone {
            guard placedSafetyConeCount < Self.defaultInventory[.safetyCone, default: 4] else {
                conditionAlert = "The hazard perimeter already has all available cones."
                return
            }
            inventory[tool, default: 0] -= 1
            placedSafetyConeCount += 1
            hazardIdentified = true
            conditionAlert = "Hazard cone placed (\(placedSafetyConeCount)/4)."
            record(
                "Equipment",
                "Placed a safety cone around the fuel hazard.",
                positive: true,
                outcome: "Hazard perimeter expanded",
                cues: ["Fuel spill visible", "\(inventory[tool, default: 0]) cones remaining"],
                consequence: "The exclusion zone became more visible to the response team."
            )
            return
        }

        guard let casualtyID,
              let casualty = casualties.first(where: { $0.id == casualtyID }) else {
            conditionAlert = "Select a casualty before applying \(tool.title.lowercased())."
            return
        }
        guard appliedEquipment[casualtyID, default: []].contains(tool) == false else {
            conditionAlert = "\(casualty.name) already has a \(tool.title.lowercased()) applied."
            return
        }

        inventory[tool, default: 0] -= 1
        appliedEquipment[casualtyID, default: []].insert(tool)
        let appropriate = tool != .defibrillator || casualty.deteriorationProfile.requiresCPR
        conditionAlert = "\(tool.title) applied to \(casualty.name)."
        record(
            "Equipment",
            "Applied \(tool.title.lowercased()) to \(casualty.name).",
            positive: appropriate,
            outcome: appropriate ? "Equipment applied" : "Clinical indication needs review",
            cues: [casualty.conditionLabel, "\(inventory[tool, default: 0]) remaining"],
            consequence: appropriate
                ? "The equipment is now visible on the casualty and recorded in inventory."
                : "The equipment was consumed, but the casualty did not show the simulated indication.",
            replayFocusCasualtyID: casualtyID
        )
    }

    func reportTreatmentOutOfReach(_ tool: InventoryTool, casualtyID: String) {
        guard let casualty = casualties.first(where: { $0.id == casualtyID }) else { return }
        conditionAlert = "Move within arm's reach of \(casualty.name), then pinch again to apply the \(tool.title.lowercased())."
    }

    func reportHazardEquipmentOutOfReach() {
        conditionAlert = "Approach the spill perimeter before placing a safety cone. Keep clear of the visible fuel surface."
    }

    func replenishInventory() {
        guard phase == .active else { return }
        inventory = Self.defaultInventory
        conditionAlert = "Training inventory replenished."
        record(
            "Equipment",
            "Replenished the equipment toolbar.",
            positive: true,
            outcome: "Inventory restored",
            consequence: "All training equipment quantities returned to their starting levels."
        )
    }

    var score: ScoreBreakdown {
        let safety = (sceneSurveyed ? 8 : 0) + (hazardIdentified ? 12 : 0)
        let assessmentTotal = casualties.reduce(0) { $0 + $1.completedAssessments.count }
        let assessment = Int((Double(assessmentTotal) / Double(casualties.count * Assessment.allCases.count) * 25).rounded())
        let correctTags = casualties.filter { $0.assignedPriority == $0.currentCorrectPriority }.count
        let triage = Int((Double(correctTags) / Double(casualties.count) * 25).rounded())
        let effectiveCPRSeconds = casualties.first(where: { $0.id == "casualty-b" })?.effectiveCPRSeconds ?? 0
        let treatment = min(
            15,
            Int((effectiveCPRSeconds / ScenarioRules.minimumDemonstrationCPRDuration * 15).rounded())
        )
        let communication = (hazardCommunicated ? 8 : 0) + (resourceRequestSent ? 7 : 0)
        return ScoreBreakdown(
            safety: safety,
            assessment: assessment,
            triage: triage,
            treatment: treatment,
            communication: communication
        )
    }

    var coachReview: [String] {
        var review: [String] = []
        let jordan = casualties.first(where: { $0.id == "casualty-b" })

        if sceneSurveyed && hazardIdentified {
            review.append("Strong scene entry: you completed the 360° survey and identified the fuel leak before finishing triage.")
        } else if !sceneSurveyed {
            review.append("Next attempt, begin with the 360° survey. Approaching casualties before surveying the collision exposes both responder and patients to an unmanaged hazard.")
        } else {
            review.append("You surveyed the scene but missed the fuel leak. Scan around both vehicles before entering the casualty area.")
        }

        if let jordan, jordan.effectiveCPRSeconds == 0 {
            review.append("Jordan received no simulated CPR coverage. After confirming unresponsiveness, abnormal breathing, and absent perfusion, pinch and continuously hold the compression target.")
        } else if let jordan,
                  jordan.effectiveCPRSeconds < ScenarioRules.minimumDemonstrationCPRDuration {
            review.append("Jordan received only \(Self.formatDuration(jordan.effectiveCPRSeconds)) of simulated CPR coverage. Maintain the hold continuously; deterioration resumes as soon as the simulation stops.")
        } else if let jordan {
            review.append("You maintained \(Self.formatDuration(jordan.effectiveCPRSeconds)) of simulated CPR coverage across \(jordan.cprSessionCount) attempt\(jordan.cprSessionCount == 1 ? "" : "s"), pausing untreated deterioration only while the hold continued.")
        }

        let missedAssessments = casualties.reduce(0) { $0 + (Assessment.allCases.count - $1.completedAssessments.count) }
        let incorrect = casualties.filter { $0.assignedPriority != $0.currentCorrectPriority }
        if missedAssessments > 0 && review.count < 2 {
            review.append("\(missedAssessments) assessment step\(missedAssessments == 1 ? " was" : "s were") omitted. Complete response, breathing, perfusion, and injury checks consistently.")
        } else if !incorrect.isEmpty && review.count < 2 {
            review.append("Review the final priority for \(incorrect.map(\.name).joined(separator: ", ")). Use the recorded response, breathing, and perfusion findings before tagging.")
        } else if !hazardCommunicated && review.count < 2 {
            review.append("You identified the fuel leak but did not report it. Hazard recognition and communication are separate operational actions.")
        }

        return Array(review.prefix(2))
    }

    private func startTimer() {
        timer?.invalidate()

        timer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .active else { return }
                self.advanceClock()
                self.commitChange()
            }
        }
    }

    func resumeLocalClockIfNeeded() {
        guard phase == .active, timer == nil else { return }
        lastTickAt = Date()
        startTimer()
    }

    private func advanceClock(to now: Date = Date()) {
        guard phase == .active else { return }
        guard let lastTickAt else {
            self.lastTickAt = now
            return
        }

        let realDelta = max(0, now.timeIntervalSince(lastTickAt))
        guard realDelta > 0 else { return }
        self.lastTickAt = now

        let exerciseDelta = scenarioPace.exerciseDuration(forRealDuration: realDelta)
        elapsed += exerciseDelta
        updatePatientDeterioration(
            byExerciseDelta: exerciseDelta,
            realDelta: realDelta
        )
    }

    private func updatePatientDeterioration(
        byExerciseDelta exerciseDelta: TimeInterval,
        realDelta: TimeInterval
    ) {
        guard exerciseDelta > 0, realDelta > 0 else { return }

        for index in casualties.indices {
            if let newStage = casualties[index].advanceClocks(
                realDuration: realDelta,
                exerciseDuration: exerciseDelta
            ) {
                applyDeteriorationStage(newStage, to: index)
            }
        }
    }

    private func applyDeteriorationStage(_ stage: Int, to index: Int) {
        casualties[index].deteriorationStage = stage
        casualties[index].isDeteriorated = stage > 0
        casualties[index].completedAssessments = []
        deteriorationTriggered = true

        let name = casualties[index].name
        let message: String
        let spokenMessage: String

        switch stage {
        case 1:
            message = "\(name): visible oxygen-deprivation signs are developing. Four minutes remain to the neurological-risk threshold."
            spokenMessage = "Condition change. Four minutes remain on the untreated cardiac arrest timer."
        case 2:
            message = "\(name): condition worsening. One minute remains to the neurological-risk threshold."
            spokenMessage = "Urgent. One minute remains on the untreated cardiac arrest timer."
        case 3:
            message = "\(name): the six-minute untreated neurological-risk threshold has been reached."
            spokenMessage = "Critical warning. The six minute untreated threshold has been reached."
        case 4:
            message = "\(name): profound deterioration. Two minutes remain to the scenario death threshold."
            spokenMessage = "Critical warning. Two minutes remain to the scenario death threshold."
        default:
            casualties[index].isDeceased = true
            casualties[index].health = 0
            message = "\(name): the ten-minute untreated scenario threshold was reached. Casualty marked deceased in this simulation."
            spokenMessage = "Scenario update. The untreated casualty has reached the simulated death threshold."
        }

        conditionAlert = message
        record(
            "Deterioration",
            message,
            positive: false,
            outcome: "Condition worsened",
            evidenceOutcome: .scenarioUpdate,
            rationale: "Untreated cardiac arrest continued while no simulated CPR coverage was active.",
            cues: ["Untreated time \(Self.formatDuration(casualties[index].untreatedSeconds))", casualties[index].visibleSymptoms],
            consequence: stage >= 5
                ? "The casualty reached the simulation death threshold."
                : "Previous assessment findings were invalidated and reassessment became necessary.",
            recommendedAction: stage >= 5
                ? "Use the replay to identify where earlier CPR or reassessment could have changed the outcome."
                : "Reassess Jordan immediately and maintain continuous CPR while other roles continue incident command.",
            replayFocusCasualtyID: casualties[index].id,
            recordAsSystem: true
        )

        let announcement = AVSpeechUtterance(string: spokenMessage)
        announcement.rate = 0.48
        announcement.volume = 0.9
        voice.speak(announcement)
    }

    private func record(
        _ category: String,
        _ detail: String,
        positive: Bool? = nil,
        outcome: String? = nil,
        evidenceOutcome: DecisionOutcome? = nil,
        rationale: String? = nil,
        cues: [String] = [],
        consequence: String? = nil,
        recommendedAction: String? = nil,
        replayFocusCasualtyID: String? = nil,
        recordAsSystem: Bool = false,
        includeInReplay: Bool = true
    ) {
        let eventElapsed = elapsed
        let resolvedOutcome = outcome ?? {
            if positive == true { return "Completed" }
            if positive == false { return "Needs review" }
            return "Recorded"
        }()
        events.append(
            SessionEvent(
                elapsed: eventElapsed,
                category: category,
                detail: detail,
                isPositive: positive,
                outcome: resolvedOutcome
            )
        )

        if includeInReplay {
            let resolvedEvidenceOutcome = evidenceOutcome
                ?? (positive == true ? .succeeded : positive == false ? .needsReview : .scenarioUpdate)
            decisionEvidence.append(
                DecisionEvidence(
                    elapsed: eventElapsed,
                    category: category,
                    action: detail,
                    actorRole: recordAsSystem ? nil : currentActorRole,
                    outcome: resolvedEvidenceOutcome,
                    rationale: rationale ?? "This event changed the incident state recorded for the after-action review.",
                    cues: cues,
                    consequence: consequence ?? resolvedOutcome,
                    recommendedAction: recommendedAction,
                    snapshot: replaySnapshot(
                        at: eventElapsed,
                        focusCasualtyID: replayFocusCasualtyID
                    )
                )
            )
        }
        commitChange()
    }

    private func commitChange() {
        revision += 1
        didChange?(sharedSnapshot())
    }

    private func replaySnapshot(
        at elapsed: TimeInterval,
        focusCasualtyID: String? = nil
    ) -> IncidentReplaySnapshot {
        IncidentReplaySnapshot(
            elapsed: elapsed,
            scenarioPace: scenarioPace,
            selectedCasualtyID: focusCasualtyID ?? selectedCasualtyID,
            sceneSurveyed: sceneSurveyed,
            hazardIdentified: hazardIdentified,
            hazardCommunicated: hazardCommunicated,
            resourceRequestSent: resourceRequestSent,
            casualties: casualties.map { casualty in
                CasualtyReplayState(
                    id: casualty.id,
                    name: casualty.name,
                    health: casualty.health,
                    assignedPriority: casualty.assignedPriority,
                    correctPriority: casualty.currentCorrectPriority,
                    completedAssessments: casualty.completedAssessments,
                    isReceivingCPR: casualty.isReceivingCPR,
                    isDeceased: casualty.isDeceased,
                    conditionLabel: casualty.conditionLabel
                )
            }
        )
    }

    private func primaryFindingCues(for casualty: Casualty) -> [String] {
        Assessment.allCases
            .filter { casualty.completedAssessments.contains($0) }
            .map { "\($0.rawValue): \(casualty.finding(for: $0))" }
    }

    private func missingPrimaryAssessmentCues(for casualty: Casualty) -> [String] {
        ScenarioRules.primaryAssessments
            .filter { !casualty.completedAssessments.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
            .map { "Missing: \($0.rawValue)" }
    }

    private func assessmentConsequence(_ assessment: Assessment, casualty: Casualty) -> String {
        switch assessment {
        case .response:
            "The casualty's responsiveness became available for triage reasoning."
        case .breathing:
            casualty.finding(for: assessment).contains("Not breathing")
                ? "An immediate airway and resuscitation threat was exposed."
                : "Respiratory status became available for priority assignment."
        case .perfusion:
            casualty.finding(for: assessment).contains("No palpable")
                ? "Absent spontaneous circulation confirmed the need for CPR."
                : "Perfusion status became available for priority assignment."
        case .injuries:
            "Visible injury evidence was added to the casualty picture."
        }
    }

    private func triageRationale(
        for casualty: Casualty,
        assigned priority: TriagePriority,
        correct: Bool
    ) -> String {
        let expected = casualty.currentCorrectPriority
        if correct {
            return "\(priority.rawValue) matches the current response, breathing, perfusion, and deterioration evidence for \(casualty.name)."
        }
        return "\(priority.rawValue) does not match the current evidence. \(casualty.name) requires \(expected.rawValue) - \(expected.title)."
    }

    private static func formatCountdown(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded(.up)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func formatDuration(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded()))
        return seconds < 60
            ? "\(seconds) second\(seconds == 1 ? "" : "s")"
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func makeCasualties() -> [Casualty] {
        [
            Casualty(
                id: "casualty-a", name: "Alex", location: "Near the blue marker",
                initialFindings: [
                    .response: "Unresponsive to voice and pain.", .breathing: "12 breaths/minute and regular.",
                    .perfusion: "Radial pulse present; skin warm.", .injuries: "No visible external injury."
                ],
                deterioratedFindings: [:],
                correctInitialPriority: .p1,
                correctDeterioratedPriority: nil,
                initialHealth: 100,
                deteriorationProfile: .none,
                health: 100
            ),
            Casualty(
                id: "casualty-b", name: "Jordan", location: "Beside the purple marker",
                initialFindings: [
                    .response: "Unresponsive to voice and pain.", .breathing: "Not breathing normally.",
                    .perfusion: "No palpable pulse or spontaneous circulation.", .injuries: "No obvious external injury."
                ],
                deterioratedFindings: [
                    .response: "Unresponsive to voice and pain.", .breathing: "Not breathing normally.",
                    .perfusion: "No palpable pulse or spontaneous circulation.", .injuries: "Visible oxygen-deprivation signs are worsening."
                ],
                correctInitialPriority: .p1,
                correctDeterioratedPriority: .p1,
                initialHealth: 60,
                deteriorationProfile: .untreatedCardiacArrest(
                    neurologicalRiskAfter: ScenarioRules.neurologicalRiskAfter,
                    deathAfter: ScenarioRules.deathAfter
                ),
                health: 60
            ),
            Casualty(
                id: "casualty-c", name: "Sam", location: "Near the teal marker",
                initialFindings: [
                    .response: "Alert and follows commands.", .breathing: "20 breaths/minute and regular.",
                    .perfusion: "Radial pulse present; capillary refill 2 seconds.", .injuries: "Visible limb injury with controlled bleeding."
                ],
                deterioratedFindings: [:],
                correctInitialPriority: .p2,
                correctDeterioratedPriority: nil,
                initialHealth: 50,
                deteriorationProfile: .none,
                health: 50
            )
        ]
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject private var session: TrainingSession
    @EnvironmentObject private var collaboration: IncidentCollaborationCoordinator
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var immersiveSpaceIsOpen = false
    @State private var immersiveSpaceIsOpening = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .briefing: BriefingView(beginAction: beginScenario)
                case .active: ScenarioActiveView()
                case .complete: AfterActionReviewView(restartAction: restart)
                }
            }
            .navigationTitle("TriageXR")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Label(session.phase.rawValue, systemImage: phaseIcon)
                        .foregroundStyle(session.phase == .active ? .orange : .secondary)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let statusMessage {
                Text(statusMessage)
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                }
        }
        .onChange(of: session.phase) { _, phase in
            guard phase == .active,
                  !immersiveSpaceIsOpen,
                  !immersiveSpaceIsOpening else {
                return
            }
            Task { await openScenarioSpace() }
        }
    }

    private var phaseIcon: String {
        switch session.phase {
        case .briefing: "doc.text.fill"
        case .active: "waveform.path.ecg"
        case .complete: "chart.bar.doc.horizontal.fill"
        }
    }

    private func beginScenario() {
        statusMessage = nil
        collaboration.submit(.begin)
    }

    private func restart() {
        collaboration.submit(.reset)
    }

    private func openScenarioSpace() async {
        immersiveSpaceIsOpening = true
        defer { immersiveSpaceIsOpening = false }

        let result = await openImmersiveSpace(id: "TriageScene")
        switch result {
        case .opened:
            immersiveSpaceIsOpen = true
            dismissWindow(id: "MainWindow")
        case .userCancelled:
            collaboration.submit(.reset)
            statusMessage = "Scenario opening was cancelled."
        case .error:
            collaboration.submit(.reset)
            statusMessage = "The immersive scene could not be opened."
        @unknown default:
            collaboration.submit(.reset)
            statusMessage = "An unexpected error occurred."
        }
    }
}

struct ScenarioActiveView: View {
    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
            Text("Immersive scenario in progress").font(.title2.bold())
            Text("Return to the immersive space to continue training.")
                .foregroundStyle(.secondary)
        }
    }
}

struct BriefingView: View {
    @EnvironmentObject private var collaboration: IncidentCollaborationCoordinator
    let beginAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 20) {
                    Image(systemName: "cross.case.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Road Traffic Collision")
                            .font(.largeTitle.bold())
                        Text("Mass-casualty triage • Foundation scenario")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Dispatch information") {
                    VStack(alignment: .leading, spacing: 12) {
                        BriefingRow(icon: "car.side.fill", text: "Two-vehicle collision with three reported casualties")
                        BriefingRow(icon: "location.fill", text: "Rural roadside; emergency services not yet on scene")
                        BriefingRow(icon: "exclamationmark.triangle.fill", text: "Hazards are unknown - survey before approaching")
                        BriefingRow(icon: "clock.fill", text: "One casualty may change condition during the exercise")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                GroupBox("Your objectives") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Survey the scene and identify hazards")
                        Text("2. Assess all three casualties")
                        Text("3. Initiate and maintain simulated CPR coverage when indicated")
                        Text("4. Assign and revise triage priorities")
                        Text("5. Communicate risks and resource requirements")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                CollaborationLobbyView()

                HStack {
                    Label("Training aid only - follow your organisation’s approved protocols.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: beginAction) {
                        Label("Enter Incident", systemImage: "visionpro.fill")
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!collaboration.canBeginIncident)
                }
            }
            .padding(32)
        }
    }
}

struct CollaborationLobbyView: View {
    @EnvironmentObject private var session: TrainingSession
    @EnvironmentObject private var collaboration: IncidentCollaborationCoordinator

    var body: some View {
        GroupBox("Team incident command") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: collaboration.isShared ? "shareplay" : "person.2.wave.2.fill")
                        .font(.title2)
                        .foregroundStyle(collaboration.isShared ? .green : .blue)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(collaboration.status.title)
                            .font(.headline)
                        Text(
                            collaboration.isShared
                                ? "\(collaboration.participantCount) responder\(collaboration.participantCount == 1 ? "" : "s") share one incident state."
                                : "Run solo or invite nearby and FaceTime Vision Pro responders through SharePlay."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if collaboration.isShared {
                        Button("Leave", role: .destructive) {
                            collaboration.leaveSharePlay()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            Task { await collaboration.activateSharePlay() }
                        } label: {
                            Label("Start SharePlay", systemImage: "shareplay")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(collaboration.status == .preparing)
                    }
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your responder role")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(collaboration.localRole.responsibility)
                            .font(.caption)
                    }
                    Spacer()
                    Picker("Responder role", selection: $collaboration.localRole) {
                        ForEach(ResponderRole.allCases) { role in
                            Label(role.title, systemImage: role.icon)
                                .tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                }

                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Exercise pace")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(session.scenarioPace.detail)
                            .font(.caption)
                    }
                    Spacer()
                    Picker(
                        "Exercise pace",
                        selection: Binding(
                            get: { session.scenarioPace },
                            set: { collaboration.submit(.setScenarioPace($0)) }
                        )
                    ) {
                        ForEach(ScenarioPace.allCases) { pace in
                            Text(pace.title).tag(pace)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                    .disabled(!collaboration.canBeginIncident)
                }

                if !collaboration.participantRoles.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(
                            collaboration.participantRoles.values.sorted { $0.title < $1.title },
                            id: \.self
                        ) { role in
                            Label(role.title, systemImage: role.icon)
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                }

                if let notice = collaboration.notice {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }

                if collaboration.isShared && !collaboration.canBeginIncident {
                    Label(
                        "Waiting for the shared-incident host in the Incident Commander or Instructor role to enter the incident.",
                        systemImage: "hourglass"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct BriefingRow: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.headline)
    }
}

struct SurveyProgressView: View {
    let completed: Set<SurveyCheckpoint>
    let simulatorMode: Bool
    let inspectAction: (SurveyCheckpoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Spatial scene survey", systemImage: "view.360")
                    .font(.headline)
                Spacer()
                Text("\(completed.count)/\(SurveyCheckpoint.required.count)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(SurveyCheckpoint.allCases) { checkpoint in
                    let isComplete = completed.contains(checkpoint)
                    Button { inspectAction(checkpoint) } label: {
                        Label(
                            checkpoint.shortTitle,
                            systemImage: isComplete ? "checkmark.circle.fill" : "circle.dashed"
                        )
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(isComplete ? .green : .cyan)
                    .disabled(isComplete || !simulatorMode)
                }
            }

            if !SurveyCheckpoint.required.isSubset(of: completed) {
                Text(
                    simulatorMode
                        ? "Simulator: use these compact sector controls to test survey completion."
                        : "Turn naturally through the full scene. Headset direction is recorded automatically."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct LiveDashboardView: View {
    @EnvironmentObject private var session: TrainingSession
    @EnvironmentObject private var collaboration: IncidentCollaborationCoordinator
    let endAction: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                MetricCard(value: session.sceneSurveyed ? "Done" : "Pending", label: "Scene survey", colour: session.sceneSurveyed ? .green : .orange)
                MetricCard(value: session.hazardIdentified ? "1" : "0", label: "Hazards found", colour: session.hazardIdentified ? .green : .orange)
                MetricCard(value: "\(session.assessedCount)/3", label: "Casualties assessed", colour: .blue)
                MetricCard(value: "\(session.taggedCount)/3", label: "Casualties tagged", colour: .purple)
                MetricCard(value: format(session.elapsed), label: "Elapsed", colour: .secondary)
            }

            NextActionCard(action: session.nextRecommendedAction)

            HStack(spacing: 16) {
                Label(
                    session.sceneSurveyed
                        ? "Survey complete"
                        : "Survey \(session.surveyedCheckpoints.count)/\(SurveyCheckpoint.required.count)",
                    systemImage: session.sceneSurveyed ? "view.360.circle.fill" : "view.360"
                )
                .foregroundStyle(session.sceneSurveyed ? .green : .orange)

                Button { collaboration.submit(.communicateHazard) } label: {
                    Label(session.hazardCommunicated ? "Hazard reported" : "Report hazard", systemImage: "radio")
                }
                .disabled(!session.hazardIdentified || session.hazardCommunicated)

                Button { collaboration.submit(.requestResources) } label: {
                    Label(session.resourceRequestSent ? "Resources requested" : "Request resources", systemImage: "person.3.fill")
                }
                .disabled(session.resourceRequestSent)

                Spacer()
                Button(role: .destructive, action: endAction) {
                    Label(session.canComplete ? "Finish scenario" : "End early", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            GroupBox("Live event log") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.events.reversed()) { event in
                            EventRow(event: event)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(28)
    }

    private func format(_ time: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60)
    }
}

struct MetricCard: View {
    let value: String
    let label: String
    let colour: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title2.bold()).foregroundStyle(colour)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct NextActionCard: View {
    let action: RecommendedAction
    var compact = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: action.icon)
                .font(compact ? .title3 : .title2)
                .foregroundStyle(action.colour)
                .frame(width: compact ? 28 : 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Next recommended action")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(action.title)
                    .font(compact ? .headline : .title3.bold())
                Text(action.detail)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 12 : 16)
        .background(action.colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(action.colour.opacity(0.35), lineWidth: 1)
        }
    }
}

struct EventRow: View {
    let event: SessionEvent
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(event.timestamp).monospacedDigit().foregroundStyle(.secondary)
            Image(systemName: event.isPositive == false ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(event.isPositive == false ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.category).font(.caption.bold()).foregroundStyle(.secondary)
                Text(event.detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AfterActionReviewView: View {
    @EnvironmentObject private var session: TrainingSession
    @EnvironmentObject private var aiCoach: AICoachCoordinator
    let restartAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("After-Action Review").font(.largeTitle.bold())
                        Text("Evidence-based feedback from your recorded decisions")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(.secondary.opacity(0.2), lineWidth: 12)
                        Circle().trim(from: 0, to: Double(session.score.total) / 100)
                            .stroke(scoreColour, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack { Text("\(session.score.total)").font(.largeTitle.bold()); Text("/ 100").font(.caption) }
                    }
                    .frame(width: 130, height: 130)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                    ScoreCard(title: "Safety", score: session.score.safety, maximum: 20)
                    ScoreCard(title: "Assessment", score: session.score.assessment, maximum: 25)
                    ScoreCard(title: "Triage", score: session.score.triage, maximum: 25)
                    ScoreCard(title: "Treatment", score: session.score.treatment, maximum: 15)
                    ScoreCard(title: "Communication", score: session.score.communication, maximum: 15)
                }

                GroundedAICoachView()

                GroupBox("Evidence replay") {
                    DecisionReplayView(evidence: session.decisionEvidence)
                        .padding(.vertical, 8)
                }

                HStack {
                    Text("Focus for next attempt: scene safety, systematic assessment, reassessment, and concise communication.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: restartAction) {
                        Label("Run Again", systemImage: "arrow.counterclockwise")
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(30)
        }
        .task(id: coachingTaskID) {
            await aiCoach.generate(for: session)
        }
    }

    private var scoreColour: Color {
        session.score.total >= 80 ? .green : session.score.total >= 60 ? .orange : .red
    }

    private var coachingTaskID: String {
        let lastID = session.decisionEvidence.last?.id.uuidString ?? "none"
        return "\(session.decisionEvidence.count)-\(lastID)-\(session.score.total)"
    }
}

struct GroundedAICoachView: View {
    @EnvironmentObject private var session: TrainingSession
    @EnvironmentObject private var aiCoach: AICoachCoordinator

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Label(aiCoach.source.title, systemImage: aiCoach.source.systemImage)
                        .font(.subheadline.bold())
                        .foregroundStyle(aiCoach.source == .groundedAI ? .purple : .blue)
                    if aiCoach.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    if aiCoach.relayIsConfigured && !aiCoach.isLoading {
                        Button("Regenerate") {
                            Task { await aiCoach.generate(for: session, force: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let report = aiCoach.report {
                    Text(report.summary)
                        .font(.headline)

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        CoachObservationCard(
                            eyebrow: "Strongest decision",
                            icon: "checkmark.circle.fill",
                            colour: .green,
                            observation: report.strongestDecision,
                            evidence: session.decisionEvidence
                        )
                        CoachObservationCard(
                            eyebrow: "Missed cue",
                            icon: "eye.trianglebadge.exclamationmark.fill",
                            colour: .orange,
                            observation: report.missedCue,
                            evidence: session.decisionEvidence
                        )
                        CoachObservationCard(
                            eyebrow: "Next drill",
                            icon: "scope",
                            colour: .blue,
                            observation: report.nextDrill,
                            evidence: session.decisionEvidence
                        )
                    }

                    Divider()
                    Text(report.disclaimer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(aiCoach.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } label: {
            Label("Grounded coach", systemImage: "sparkles.rectangle.stack.fill")
        }
    }
}

struct CoachObservationCard: View {
    let eyebrow: String
    let icon: String
    let colour: Color
    let observation: AICoachObservation
    let evidence: [DecisionEvidence]

    private var citedEvents: [DecisionEvidence] {
        let citedIDs = Set(observation.evidenceEventIDs)
        return evidence.filter { citedIDs.contains($0.id.uuidString.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(eyebrow.uppercased(), systemImage: icon)
                .font(.caption2.bold())
                .foregroundStyle(colour)
            Text(observation.headline)
                .font(.headline)
            Text(observation.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 2)
            ForEach(citedEvents) { event in
                HStack(spacing: 6) {
                    Image(systemName: "link")
                    Text(event.timestamp)
                        .monospacedDigit()
                    Text(event.category)
                        .lineLimit(1)
                }
                .font(.caption.bold())
                .foregroundStyle(colour)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(colour.opacity(0.12), in: Capsule())
                .accessibilityLabel("Evidence at \(event.timestamp), \(event.category)")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(colour.opacity(0.18), lineWidth: 1)
        }
    }
}

struct DecisionReplayView: View {
    let evidence: [DecisionEvidence]
    @State private var selectedIndex = 0
    @State private var isPlaying = false

    private var selectedEvidence: DecisionEvidence? {
        guard evidence.indices.contains(selectedIndex) else { return nil }
        return evidence[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let selectedEvidence {
                ReplayOutcomeSummary(evidence: evidence)

                HStack(spacing: 14) {
                    Button {
                        isPlaying = false
                        selectedIndex = max(0, selectedIndex - 1)
                    } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedIndex == 0)
                    .accessibilityLabel("Previous decision")

                    Button {
                        if selectedIndex == evidence.count - 1 { selectedIndex = 0 }
                        isPlaying.toggle()
                    } label: {
                        Label(isPlaying ? "Pause" : "Replay", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        isPlaying = false
                        selectedIndex = min(evidence.count - 1, selectedIndex + 1)
                    } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedIndex == evidence.count - 1)
                    .accessibilityLabel("Next decision")

                    Slider(
                        value: Binding(
                            get: { Double(selectedIndex) },
                            set: { selectedIndex = Int($0.rounded()) }
                        ),
                        in: 0...Double(max(1, evidence.count - 1)),
                        step: 1
                    ) {
                        Text("Decision replay position")
                    } minimumValueLabel: {
                        Text("00:00").font(.caption.monospacedDigit())
                    } maximumValueLabel: {
                        Text(evidence.last?.timestamp ?? "00:00").font(.caption.monospacedDigit())
                    }
                    .disabled(evidence.count <= 1)
                    .accessibilityValue(
                        "Decision \(selectedIndex + 1) of \(evidence.count), \(selectedEvidence.category), \(selectedEvidence.outcome.title)"
                    )

                    Text("\(selectedIndex + 1) / \(evidence.count)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                IncidentReplayMap(snapshot: selectedEvidence.snapshot)
                    .frame(height: 270)

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(selectedEvidence.outcome.title, systemImage: outcomeIcon(selectedEvidence.outcome))
                                .font(.headline)
                                .foregroundStyle(outcomeColour(selectedEvidence.outcome))
                            Spacer()
                            if let actorRole = selectedEvidence.actorRole {
                                Label(actorRole.title, systemImage: actorRole.icon)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                            } else {
                                Label("Incident system", systemImage: "waveform.path.ecg")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                            }
                            Text(selectedEvidence.timestamp)
                                .font(.caption.bold().monospacedDigit())
                        }

                        Text(selectedEvidence.action)
                            .font(.title3.bold())

                        VStack(alignment: .leading, spacing: 5) {
                            Text("WHY")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Text(selectedEvidence.rationale)
                                .font(.subheadline)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("CONSEQUENCE")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Text(selectedEvidence.consequence)
                                .font(.subheadline)
                        }

                        if let recommendedAction = selectedEvidence.recommendedAction {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("NEXT BEST ACTION")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.orange)
                                Text(recommendedAction)
                                    .font(.subheadline.bold())
                            }
                            .padding(12)
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("EVIDENCE AVAILABLE")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        if selectedEvidence.cues.isEmpty {
                            Text("Scenario state transition")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(selectedEvidence.cues, id: \.self) { cue in
                                Label(cue, systemImage: "eye.fill")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(14)
                    .frame(width: 300, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            } else {
                ContentUnavailableView(
                    "No decision evidence",
                    systemImage: "timeline.selection",
                    description: Text("Complete an incident to generate a causal replay.")
                )
            }
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while !Task.isCancelled && selectedIndex < evidence.count - 1 {
                try? await Task.sleep(for: .seconds(1.25))
                guard !Task.isCancelled, isPlaying else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    selectedIndex += 1
                }
            }
            if !Task.isCancelled { isPlaying = false }
        }
        .onChange(of: evidence.count) { _, count in
            selectedIndex = min(selectedIndex, max(0, count - 1))
        }
    }

    private func outcomeIcon(_ outcome: DecisionOutcome) -> String {
        switch outcome {
        case .succeeded: "checkmark.seal.fill"
        case .needsReview: "exclamationmark.triangle.fill"
        case .corrected: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .scenarioUpdate: "waveform.path.ecg"
        }
    }

    private func outcomeColour(_ outcome: DecisionOutcome) -> Color {
        switch outcome {
        case .succeeded: .green
        case .needsReview: .orange
        case .corrected: .blue
        case .scenarioUpdate: .secondary
        }
    }
}

struct ReplayOutcomeSummary: View {
    let evidence: [DecisionEvidence]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DecisionOutcome.allCases) { outcome in
                Label(
                    "\(count(for: outcome)) \(outcome.title)",
                    systemImage: icon(for: outcome)
                )
                .font(.caption.bold())
                .foregroundStyle(colour(for: outcome))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(colour(for: outcome).opacity(0.1), in: Capsule())
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replay outcome summary")
    }

    private func count(for outcome: DecisionOutcome) -> Int {
        evidence.lazy.filter { $0.outcome == outcome }.count
    }

    private func icon(for outcome: DecisionOutcome) -> String {
        switch outcome {
        case .succeeded: "checkmark.seal.fill"
        case .needsReview: "exclamationmark.triangle.fill"
        case .corrected: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .scenarioUpdate: "waveform.path.ecg"
        }
    }

    private func colour(for outcome: DecisionOutcome) -> Color {
        switch outcome {
        case .succeeded: .green
        case .needsReview: .orange
        case .corrected: .blue
        case .scenarioUpdate: .secondary
        }
    }
}

struct IncidentReplayMap: View {
    let snapshot: IncidentReplaySnapshot

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.black.opacity(0.82))

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 4)
                Rectangle()
                    .fill(Color.yellow.opacity(0.75))
                    .frame(width: 3, height: geometry.size.height * 0.72)
                    .mask {
                        VStack(spacing: 10) {
                            ForEach(0..<8, id: \.self) { _ in
                                Rectangle().frame(height: 12)
                            }
                        }
                    }

                replayVehicle(colour: .gray)
                    .rotationEffect(.degrees(-14))
                    .position(x: geometry.size.width * 0.34, y: geometry.size.height * 0.52)
                replayVehicle(colour: .blue.opacity(0.7))
                    .rotationEffect(.degrees(17))
                    .position(x: geometry.size.width * 0.66, y: geometry.size.height * 0.56)

                Circle()
                    .fill(snapshot.hazardIdentified ? Color.red : Color.yellow)
                    .frame(width: 38, height: 24)
                    .overlay {
                        Image(systemName: snapshot.hazardIdentified ? "exclamationmark.triangle.fill" : "drop.fill")
                            .font(.caption2)
                            .foregroundStyle(.black)
                    }
                    .position(x: geometry.size.width * 0.42, y: geometry.size.height * 0.66)

                ForEach(snapshot.casualties) { casualty in
                    casualtyNode(casualty)
                        .position(position(for: casualty.id, in: geometry.size))
                }

                VStack {
                    HStack {
                        Label(
                            snapshot.sceneSurveyed ? "Scene surveyed" : "Survey pending",
                            systemImage: snapshot.sceneSurveyed ? "view.360.circle.fill" : "view.360"
                        )
                        .foregroundStyle(snapshot.sceneSurveyed ? .green : .orange)
                        Spacer()
                        Label(snapshot.scenarioPace.title, systemImage: "speedometer")
                            .foregroundStyle(.secondary)
                        Text(String(format: "%02d:%02d", Int(snapshot.elapsed) / 60, Int(snapshot.elapsed) % 60))
                            .monospacedDigit()
                    }
                    .font(.caption.bold())
                    .padding(12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                    Spacer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Top-down incident replay at \(Int(snapshot.elapsed)) seconds")
        .accessibilityValue(accessibilitySummary)
    }

    private func replayVehicle(colour: Color) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(colour)
            .frame(width: 88, height: 42)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.white.opacity(0.35), lineWidth: 2)
                    .padding(7)
            }
    }

    private func casualtyNode(_ casualty: CasualtyReplayState) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(conditionColour(casualty))
                    .frame(width: 40, height: 40)
                Image(systemName: casualty.isReceivingCPR ? "heart.fill" : "person.fill")
                    .foregroundStyle(.white)
            }
            .overlay {
                Circle()
                    .stroke(
                        snapshot.selectedCasualtyID == casualty.id ? Color.white : Color.clear,
                        lineWidth: 4
                    )
                    .padding(-5)
            }
            HStack(spacing: 4) {
                Text(casualty.name)
                if let priority = casualty.assignedPriority {
                    Text(priority.rawValue)
                        .foregroundStyle(priority.colour)
                }
            }
            .font(.caption2.bold())
            .foregroundStyle(.white)
        }
    }

    private func conditionColour(_ casualty: CasualtyReplayState) -> Color {
        if casualty.isDeceased { return .gray }
        if casualty.isReceivingCPR { return .green }
        if casualty.health <= 25 { return .red }
        if casualty.health <= 60 { return .orange }
        return .blue
    }

    private func position(for casualtyID: String, in size: CGSize) -> CGPoint {
        switch casualtyID {
        case "casualty-a": CGPoint(x: size.width * 0.2, y: size.height * 0.42)
        case "casualty-b": CGPoint(x: size.width * 0.5, y: size.height * 0.72)
        default: CGPoint(x: size.width * 0.8, y: size.height * 0.4)
        }
    }

    private var accessibilitySummary: String {
        let pace = "exercise pace \(snapshot.scenarioPace.title)"
        let scene = snapshot.sceneSurveyed ? "scene surveyed" : "scene survey pending"
        let hazard = snapshot.hazardIdentified ? "fuel hazard identified" : "fuel hazard not identified"
        let casualtyStates = snapshot.casualties.map { casualty in
            let priority = casualty.assignedPriority?.rawValue ?? "untagged"
            return "\(casualty.name), health \(Int(casualty.health.rounded())) percent, \(priority)"
        }
        return ([pace, scene, hazard] + casualtyStates).joined(separator: "; ")
    }
}

struct DebriefTimeline: View {
    let events: [SessionEvent]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                Text("Time")
                Text("Event")
                Text("Outcome")
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)

            Divider().gridCellUnsizedAxes(.horizontal)

            ForEach(events) { event in
                GridRow(alignment: .top) {
                    Text(event.timestamp)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.category)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(event.detail)
                    }
                    Label(
                        event.outcome,
                        systemImage: event.isPositive == false
                            ? "exclamationmark.circle.fill"
                            : event.isPositive == true
                                ? "checkmark.circle.fill"
                                : "circle.fill"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(
                        event.isPositive == false
                            ? .orange
                            : event.isPositive == true ? .green : .secondary
                    )
                }
                Divider().gridCellUnsizedAxes(.horizontal)
            }
        }
    }
}

struct ScoreCard: View {
    let title: String
    let score: Int
    let maximum: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text("\(score) / \(maximum)").font(.title2.bold())
            ProgressView(value: Double(score), total: Double(maximum))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Immersive scene

struct ImmersiveTriageView: View {
    @EnvironmentObject private var session: TrainingSession
    @EnvironmentObject private var collaboration: IncidentCollaborationCoordinator
    @EnvironmentObject private var spatialAssessment: SpatialAssessmentCoordinator
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var spatialCPRIsHeld = false
    @State private var isClosingForDebrief = false
    @State private var selectedInventoryTool: InventoryTool?
    @StateObject private var incidentAudio = IncidentAudioCoordinator()

    var body: some View {
        RealityView { content, attachments in
            content.add(await makeScene())
            if let controls = attachments.entity(for: "controls") {
                controls.position = controlPosition
                content.add(controls)
            }
            if let inventory = attachments.entity(for: "inventory") {
                inventory.position = [-1.02, 0.38, -1.15]
                content.add(inventory)
            }
        } update: { content, attachments in
            updateScene(content: content)
            if let controls = attachments.entity(for: "controls") {
                controls.position = controlPosition
                if controls.parent == nil { content.add(controls) }
            }
            if let inventory = attachments.entity(for: "inventory"), inventory.parent == nil {
                inventory.position = [-1.02, 0.38, -1.15]
                content.add(inventory)
            }
        } attachments: {
            Attachment(id: "controls") {
                SpatialControlPanel()
                    .onFinish { finishScenario() }
                    .environmentObject(session)
            }
            Attachment(id: "inventory") {
                InventoryToolbar(
                    selectedTool: $selectedInventoryTool,
                    replenishAction: { collaboration.submit(.replenishInventory) }
                )
                .environmentObject(session)
            }
        }
        .gesture(
            TapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    let name = value.entity.name
                    if name.hasPrefix("casualty-") {
                        if let tool = selectedInventoryTool, tool != .safetyCone {
                            let targetPosition = value.entity.position(relativeTo: nil)
                            if spatialAssessment.isWithinTreatmentReach(of: targetPosition) {
                                collaboration.submit(.useEquipment(tool, name))
                                selectedInventoryTool = nil
                            } else {
                                session.reportTreatmentOutOfReach(tool, casualtyID: name)
                            }
                        } else {
                            collaboration.submit(.selectCasualty(name))
                        }
                    } else if name == "fuel-hazard" {
                        if selectedInventoryTool == .safetyCone {
                            let targetPosition = value.entity.position(relativeTo: nil)
                            if spatialAssessment.isWithinTreatmentReach(
                                of: targetPosition,
                                maximumDistance: 1.5
                            ) {
                                collaboration.submit(.useEquipment(.safetyCone, nil))
                                selectedInventoryTool = nil
                            } else {
                                session.reportHazardEquipmentOutOfReach()
                            }
                        } else {
                            collaboration.submit(.identifyHazard)
                        }
                    } else {
                        verifySimulatorAssessmentTarget(named: name)
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .targetedToAnyEntity()
                .onChanged { value in
                    guard value.entity.name == "cpr-target-casualty-b",
                          !spatialCPRIsHeld,
                          session.casualties.first(where: { $0.id == "casualty-b" })?.isReceivingCPR != true else {
                        return
                    }
                    let command = IncidentCommand.beginCPR("casualty-b")
                    guard !collaboration.isShared
                            || command.isPermitted(for: collaboration.localRole) else {
                        collaboration.submit(command)
                        return
                    }
                    spatialCPRIsHeld = true
                    collaboration.submit(command)
                }
                .onEnded { value in
                    guard value.entity.name == "cpr-target-casualty-b",
                          spatialCPRIsHeld else { return }
                    spatialCPRIsHeld = false
                    collaboration.submit(.endCPR("casualty-b", "Spatial compression simulation hold released"))
                }
        )
        .task {
            spatialAssessment.start()
            incidentAudio.start()
            while !Task.isCancelled && session.phase == .active {
                if let devicePosition = spatialAssessment.devicePosition {
                    incidentAudio.updateListener(
                        position: devicePosition,
                        yawRadians: spatialAssessment.deviceYaw
                    )
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        .onDisappear {
            spatialAssessment.stop()
            incidentAudio.stop()
        }
        .onChange(of: session.phase) { _, phase in
            guard phase == .complete else { return }
            closeForDebrief()
        }
    }

    private var controlPosition: SIMD3<Float> {
        switch session.selectedCasualtyID {
        case "casualty-a": [-0.75, -0.25, -1.95]
        case "casualty-b": [0.85, -0.25, -2.8]
        case "casualty-c": [0.75, -0.25, -1.9]
        default: [0, 0.55, -1.35]
        }
    }

    private func finishScenario() {
        guard session.phase == .active else { return }
        collaboration.submit(.end)
        guard session.phase == .complete else { return }
        closeForDebrief()
    }

    private func closeForDebrief() {
        guard !isClosingForDebrief else { return }
        isClosingForDebrief = true
        Task {
            await dismissImmersiveSpace()
            openWindow(id: "MainWindow")
        }
    }

    private func verifySimulatorAssessmentTarget(named entityName: String) {
        guard spatialAssessment.status == .simulator else { return }
        for assessment in Assessment.allCases {
            let prefix = "assessment-target-\(assessment.code)-"
            guard entityName.hasPrefix(prefix) else { continue }
            let casualtyID = String(entityName.dropFirst(prefix.count))
            spatialAssessment.simulatorVerify(assessment, casualtyID: casualtyID)
            return
        }
    }

    private func updateScene(content: RealityViewContent) {
        guard let root = content.entities.first(where: { $0.name == "scene-root" }) else { return }
        if let hazard = root.findEntity(named: "fuel-hazard") as? ModelEntity {
            hazard.components.set(HoverEffectComponent())
            root.findEntity(named: "hazard-confirmation")?.isEnabled = session.hazardIdentified
        }
        for index in 0..<4 {
            root.findEntity(named: "inventory-cone-\(index)")?.isEnabled = index < session.placedSafetyConeCount
        }
        for casualty in session.casualties {
            guard let tag = root.findEntity(named: "tag-\(casualty.id)") as? ModelEntity else { continue }
            tag.isEnabled = casualty.assignedPriority != nil
            if let priority = casualty.assignedPriority {
                tag.model?.materials = [SimpleMaterial(color: uiColour(priority), isMetallic: false)]
            }
            if let marker = root.findEntity(named: "condition-\(casualty.id)") as? ModelEntity {
                marker.isEnabled = casualty.deteriorationProfile.requiresCPR
                marker.model?.materials = [
                    SimpleMaterial(color: uiConditionColour(casualty), isMetallic: false)
                ]
                let pulseScale: Float = casualty.isReceivingCPR ? 1.25 : casualty.isDeceased ? 0.85 : 1
                marker.scale = [pulseScale, pulseScale, pulseScale]
            }
            if let cprTarget = root.findEntity(named: "cpr-target-\(casualty.id)") as? ModelEntity {
                let targetIsAvailable = casualty.deteriorationProfile.requiresCPR
                    && casualty.primaryAssessmentComplete
                    && !casualty.isDeceased
                cprTarget.isEnabled = targetIsAvailable
                cprTarget.model?.materials = [
                    SimpleMaterial(
                        color: casualty.isReceivingCPR ? .systemGreen : .systemRed,
                        isMetallic: false
                    )
                ]
                let targetScale: Float = casualty.isReceivingCPR ? 1.18 : 1
                cprTarget.scale = [targetScale, targetScale, targetScale]
            }
            root.findEntity(named: "equipment-bandage-\(casualty.id)")?.isEnabled =
                session.appliedEquipment[casualty.id, default: []].contains(.bandage)
            root.findEntity(named: "equipment-defibrillator-\(casualty.id)")?.isEnabled =
                session.appliedEquipment[casualty.id, default: []].contains(.defibrillator)
            let nextAssessment = Assessment.allCases.first {
                !casualty.completedAssessments.contains($0)
            }
            for assessment in Assessment.allCases {
                guard let target = root.findEntity(
                    named: "assessment-target-\(assessment.code)-\(casualty.id)"
                ) as? ModelEntity else {
                    continue
                }
                let isActive = spatialAssessment.status == .simulator
                    && session.selectedCasualtyID == casualty.id
                    && nextAssessment == assessment
                target.isEnabled = isActive
                target.model?.materials = [
                    SimpleMaterial(
                        color: uiAssessmentColour(assessment),
                        roughness: 0.25,
                        isMetallic: false
                    )
                ]
                let progressScale = isActive && spatialAssessment.activeAssessment == assessment
                    ? Float(1 + (spatialAssessment.progress * 0.3))
                    : 1
                target.scale = [progressScale, progressScale, progressScale]
            }
        }
    }

    private func makeScene() async -> Entity {
        let root = Entity()
        root.name = "scene-root"

        if let texture = try? await TextureResource(named: "RoadsidePanorama") {
            var panoramaMaterial = UnlitMaterial()
            panoramaMaterial.color = .init(texture: .init(texture))
            panoramaMaterial.faceCulling = .front
            let panorama = ModelEntity(mesh: .generateSphere(radius: 32), materials: [panoramaMaterial])
            panorama.name = "roadside-panorama"
            panorama.position = [0, 2.2, -3]
            root.addChild(panorama)
        }

        addRoadEnvironment(to: root)

        root.addChild(await makeVehicle(position: [-2.4, -1.28, -4.2], rotation: -0.22))
        root.addChild(await makeVehicle(position: [2.0, -1.28, -4.4], rotation: 0.3))

        root.addChild(await makeCasualty(
            id: "casualty-a",
            assetName: "CasualtyAlex",
            position: [-1.55, -1.08, -2.25],
            staging: .init(yaw: -0.34, bodyLift: 0.21, bandageAnchor: [0.14, 0.13, 0.58])
        ))
        root.addChild(await makeCasualty(
            id: "casualty-b",
            assetName: "CasualtyJordan",
            position: [0.1, -1.08, -3.15],
            staging: .init(yaw: 0.18, bodyLift: 0.23, bandageAnchor: [-0.15, 0.13, 0.56])
        ))
        root.addChild(await makeCasualty(
            id: "casualty-c",
            assetName: "CasualtySam",
            position: [1.55, -1.08, -2.2],
            staging: .init(yaw: 0.52, bodyLift: 0.22, bandageAnchor: [0.16, 0.14, 0.55])
        ))
        root.addChild(makeHazard())
        let conePositions: [SIMD3<Float>] = [
            [-2.25, -1.12, -3.15], [-1.05, -1.12, -3.15],
            [-2.25, -1.12, -4.25], [-1.05, -1.12, -4.25]
        ]
        for (index, position) in conePositions.enumerated() {
            let cone = makeTrafficCone(position: position)
            cone.name = "inventory-cone-\(index)"
            cone.isEnabled = false
            root.addChild(cone)
        }
        return root
    }

    private func sceneAsset(named name: String) async -> Entity? {
        try? await Entity(named: name, in: .main)
    }

    private func addRoadEnvironment(to root: Entity) {
        let grass = ModelEntity(
            mesh: .generatePlane(width: 54, depth: 70),
            materials: [SimpleMaterial(color: UIColor(red: 0.23, green: 0.34, blue: 0.15, alpha: 1), roughness: 1, isMetallic: false)]
        )
        grass.position = [0, -1.39, -27]
        root.addChild(grass)

        let road = ModelEntity(
            mesh: .generatePlane(width: 7.2, depth: 70),
            materials: [SimpleMaterial(color: UIColor(red: 0.105, green: 0.115, blue: 0.12, alpha: 1), roughness: 0.92, isMetallic: false)]
        )
        road.position = [0, -1.35, -27]
        root.addChild(road)

        let gravel = SimpleMaterial(color: UIColor(red: 0.34, green: 0.31, blue: 0.26, alpha: 1), roughness: 1, isMetallic: false)
        for x: Float in [-4.55, 4.55] {
            let shoulder = ModelEntity(mesh: .generatePlane(width: 1.9, depth: 70), materials: [gravel])
            shoulder.position = [x, -1.365, -27]
            root.addChild(shoulder)
        }

        let white = SimpleMaterial(color: UIColor(white: 0.9, alpha: 1), isMetallic: false)
        let yellow = SimpleMaterial(color: UIColor(red: 0.94, green: 0.68, blue: 0.08, alpha: 1), isMetallic: false)
        for x: Float in [-3.25, 3.25] {
            let edgeLine = ModelEntity(mesh: .generateBox(width: 0.10, height: 0.012, depth: 70), materials: [white])
            edgeLine.position = [x, -1.335, -27]
            root.addChild(edgeLine)
        }
        for z in stride(from: Float(-1.5), through: Float(-61), by: -4.2) {
            let dash = ModelEntity(mesh: .generateBox(width: 0.11, height: 0.014, depth: 2.3), materials: [yellow])
            dash.position = [0, -1.33, z]
            root.addChild(dash)
        }

        addGuardrail(to: root, x: 5.75)
        for (x, z) in [(-2.8 as Float, -1.8 as Float), (-2.35, -2.25), (2.8, -2.5), (2.45, -3.05)] {
            root.addChild(makeTrafficCone(position: [x, -1.12, z]))
        }
        addCrashEvidence(to: root)
    }

    private func addCrashEvidence(to root: Entity) {
        let rubber = SimpleMaterial(
            color: UIColor(white: 0.025, alpha: 0.82),
            roughness: 0.98,
            isMetallic: false
        )
        for (x, rotation) in [(-1.22 as Float, -0.09 as Float), (1.08, 0.08)] {
            let skid = ModelEntity(
                mesh: .generateBox(width: 0.12, height: 0.008, depth: 4.4, cornerRadius: 0.025),
                materials: [rubber]
            )
            skid.position = [x, -1.326, -5.2]
            skid.orientation = simd_quatf(angle: rotation, axis: [0, 1, 0])
            root.addChild(skid)
        }

        let darkPlastic = SimpleMaterial(
            color: UIColor(red: 0.055, green: 0.065, blue: 0.07, alpha: 1),
            roughness: 0.56,
            isMetallic: false
        )
        let safetyGlass = SimpleMaterial(
            color: UIColor(red: 0.38, green: 0.62, blue: 0.66, alpha: 0.72),
            roughness: 0.14,
            isMetallic: true
        )
        let debris: [(SIMD3<Float>, SIMD3<Float>, Float, Bool)] = [
            ([-0.72, -1.305, -3.84], [0.2, 0.025, 0.08], -0.32, false),
            ([0.78, -1.306, -4.02], [0.14, 0.018, 0.1], 0.48, false),
            ([-0.18, -1.304, -4.38], [0.1, 0.012, 0.07], 0.18, true),
            ([0.35, -1.304, -3.72], [0.08, 0.01, 0.06], -0.54, true)
        ]
        for (position, size, rotation, isGlass) in debris {
            let fragment = ModelEntity(
                mesh: .generateBox(width: size.x, height: size.y, depth: size.z, cornerRadius: 0.008),
                materials: [isGlass ? safetyGlass : darkPlastic]
            )
            fragment.position = position
            fragment.orientation = simd_quatf(angle: rotation, axis: [0, 1, 0])
            root.addChild(fragment)
        }
    }

    private func addGuardrail(to root: Entity, x: Float) {
        let metal = SimpleMaterial(color: UIColor(red: 0.45, green: 0.48, blue: 0.49, alpha: 1), roughness: 0.45, isMetallic: true)
        let rail = ModelEntity(mesh: .generateBox(width: 0.14, height: 0.24, depth: 24), materials: [metal])
        rail.position = [x, -0.78, -14]
        root.addChild(rail)
        for z in stride(from: Float(-2), through: Float(-26), by: -2.5) {
            let post = ModelEntity(mesh: .generateBox(width: 0.12, height: 1.05, depth: 0.12), materials: [metal])
            post.position = [x, -0.92, z]
            root.addChild(post)
        }
    }

    private func makeTrafficCone(position: SIMD3<Float>) -> Entity {
        let cone = Entity()
        cone.position = position
        let orange = SimpleMaterial(
            color: UIColor(red: 0.96, green: 0.28, blue: 0.035, alpha: 1),
            roughness: 0.68,
            isMetallic: false
        )
        let wornOrange = SimpleMaterial(
            color: UIColor(red: 0.78, green: 0.19, blue: 0.025, alpha: 1),
            roughness: 0.84,
            isMetallic: false
        )
        let rubber = SimpleMaterial(
            color: UIColor(red: 0.035, green: 0.04, blue: 0.042, alpha: 1),
            roughness: 0.96,
            isMetallic: false
        )
        let reflective = SimpleMaterial(
            color: UIColor(white: 0.9, alpha: 1),
            roughness: 0.22,
            isMetallic: true
        )

        let base = ModelEntity(
            mesh: .generateBox(width: 0.4, height: 0.058, depth: 0.4, cornerRadius: 0.028),
            materials: [rubber]
        )
        base.position.y = 0.029
        cone.addChild(base)

        let raisedBase = ModelEntity(
            mesh: .generateBox(width: 0.31, height: 0.035, depth: 0.31, cornerRadius: 0.045),
            materials: [wornOrange]
        )
        raisedBase.position.y = 0.072
        cone.addChild(raisedBase)

        let body = ModelEntity(
            mesh: .generateCone(height: 0.5, radius: 0.145),
            materials: [orange]
        )
        body.position.y = 0.32
        cone.addChild(body)

        let lowerBand = ModelEntity(
            mesh: .generateCylinder(height: 0.058, radius: 0.112),
            materials: [reflective]
        )
        lowerBand.position.y = 0.245
        cone.addChild(lowerBand)

        let upperBand = ModelEntity(
            mesh: .generateCylinder(height: 0.045, radius: 0.082),
            materials: [reflective]
        )
        upperBand.position.y = 0.35
        cone.addChild(upperBand)

        let tip = ModelEntity(
            mesh: .generateCylinder(height: 0.035, radius: 0.018),
            materials: [wornOrange]
        )
        tip.position.y = 0.586
        cone.addChild(tip)

        // Shallow tread blocks break up the silhouette like a weighted road cone base.
        for offset: Float in [-0.135, 0.135] {
            let tread = ModelEntity(
                mesh: .generateBox(width: 0.055, height: 0.008, depth: 0.35, cornerRadius: 0.012),
                materials: [SimpleMaterial(color: UIColor(white: 0.085, alpha: 1), roughness: 1, isMetallic: false)]
            )
            tread.position = [offset, 0.062, 0]
            cone.addChild(tread)
        }
        return cone
    }

    private func makeVehicle(position: SIMD3<Float>, rotation: Float) async -> Entity {
        let vehicle = Entity()
        vehicle.name = "vehicle-collision"
        vehicle.position = position
        vehicle.orientation = simd_quatf(angle: rotation, axis: [0, 1, 0])

        if let asset = await sceneAsset(named: "CollisionVehicle") {
            asset.scale = [0.42, 0.42, 0.42]
            asset.position = [0, 0.08, 0]
            vehicle.addChild(asset)
            return vehicle
        }

        vehicle.position.y += 0.53
        let paint = SimpleMaterial(color: .darkGray, roughness: 0.28, isMetallic: true)
        let body = ModelEntity(mesh: .generateBox(width: 1.85, height: 0.62, depth: 0.9, cornerRadius: 0.12), materials: [paint])
        vehicle.addChild(body)
        let cabin = ModelEntity(mesh: .generateBox(width: 0.9, height: 0.48, depth: 0.78, cornerRadius: 0.09), materials: [paint])
        cabin.position = [-0.25, 0.48, 0]
        vehicle.addChild(cabin)
        let glass = SimpleMaterial(color: UIColor(red: 0.08, green: 0.14, blue: 0.17, alpha: 0.92), roughness: 0.15, isMetallic: true)
        for z: Float in [-0.405, 0.405] {
            let window = ModelEntity(mesh: .generateBox(width: 0.72, height: 0.28, depth: 0.018, cornerRadius: 0.025), materials: [glass])
            window.position = [-0.25, 0.5, z]
            vehicle.addChild(window)
        }
        let bumper = ModelEntity(mesh: .generateBox(width: 0.12, height: 0.15, depth: 0.94), materials: [SimpleMaterial(color: .darkGray, isMetallic: true)])
        bumper.position = [0.96, -0.18, 0]
        bumper.orientation = simd_quatf(angle: 0.15, axis: [0, 0, 1])
        vehicle.addChild(bumper)
        for x: Float in [-0.55, 0.55] {
            for z: Float in [-0.47, 0.47] {
                let wheel = ModelEntity(mesh: .generateCylinder(height: 0.16, radius: 0.18), materials: [SimpleMaterial(color: .black, isMetallic: false)])
                wheel.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                wheel.position = [x, -0.35, z]
                vehicle.addChild(wheel)
            }
        }
        return vehicle
    }

    private func makeHazard() -> Entity {
        let oil = SimpleMaterial(
            color: UIColor(red: 0.025, green: 0.035, blue: 0.03, alpha: 0.96),
            roughness: 0.08,
            isMetallic: true
        )
        let hazard = ModelEntity(
            mesh: .generateCylinder(height: 0.012, radius: 0.52),
            materials: [oil]
        )
        hazard.name = "fuel-hazard"
        hazard.position = [-1.65, -1.31, -3.75]
        hazard.scale = [1.35, 1, 0.72]

        let lobeSpecs: [(SIMD3<Float>, SIMD3<Float>, UIColor)] = [
            ([-0.38, 0, 0.12], [0.72, 1, 0.46], UIColor(red: 0.03, green: 0.045, blue: 0.04, alpha: 0.94)),
            ([0.37, 0, -0.1], [0.66, 1, 0.5], UIColor(red: 0.045, green: 0.035, blue: 0.055, alpha: 0.92)),
            ([0.08, 0, 0.34], [0.48, 1, 0.3], UIColor(red: 0.025, green: 0.055, blue: 0.05, alpha: 0.9)),
            ([-0.12, 0, -0.35], [0.54, 1, 0.28], UIColor(red: 0.055, green: 0.045, blue: 0.025, alpha: 0.9))
        ]
        for (position, scale, colour) in lobeSpecs {
            let lobe = ModelEntity(
                mesh: .generateCylinder(height: 0.009, radius: 0.48),
                materials: [SimpleMaterial(color: colour, roughness: 0.1, isMetallic: true)]
            )
            lobe.position = position
            lobe.scale = scale
            hazard.addChild(lobe)
        }

        let sheenColours: [UIColor] = [
            UIColor(red: 0.18, green: 0.28, blue: 0.22, alpha: 0.62),
            UIColor(red: 0.24, green: 0.16, blue: 0.28, alpha: 0.58),
            UIColor(red: 0.28, green: 0.24, blue: 0.12, alpha: 0.5)
        ]
        for (index, colour) in sheenColours.enumerated() {
            let sheen = ModelEntity(
                mesh: .generateCylinder(height: 0.006, radius: 0.13 + Float(index) * 0.035),
                materials: [SimpleMaterial(color: colour, roughness: 0.04, isMetallic: true)]
            )
            sheen.position = [Float(index) * 0.2 - 0.2, 0.012, Float(index % 2) * 0.18 - 0.08]
            sheen.scale = [1.8, 1, 0.32]
            hazard.addChild(sheen)
        }

        let confirmation = Entity()
        confirmation.name = "hazard-confirmation"
        for angle in stride(from: Float(0), to: Float.pi * 2, by: Float.pi / 2) {
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 0.035),
                materials: [SimpleMaterial(color: .systemOrange, roughness: 0.15, isMetallic: false)]
            )
            marker.position = [cos(angle) * 0.72, 0.08, sin(angle) * 0.52]
            confirmation.addChild(marker)
        }
        confirmation.isEnabled = false
        hazard.addChild(confirmation)
        hazard.components.set(InputTargetComponent())
        hazard.components.set(CollisionComponent(shapes: [.generateBox(size: [1.55, 0.08, 1.1])]))
        hazard.components.set(HoverEffectComponent())
        return hazard
    }

    private struct CasualtyStaging {
        let yaw: Float
        let bodyLift: Float
        let bandageAnchor: SIMD3<Float>
    }

    private func makeCasualty(
        id: String,
        assetName: String,
        position: SIMD3<Float>,
        staging: CasualtyStaging
    ) async -> Entity {
        let casualty = Entity()
        casualty.name = id
        casualty.position = position
        casualty.orientation = simd_quatf(angle: staging.yaw, axis: [0, 1, 0])
        casualty.components.set(InputTargetComponent())
        casualty.components.set(CollisionComponent(shapes: [.generateBox(size: [0.82, 0.65, 1.95])]))
        casualty.components.set(HoverEffectComponent())

        if let asset = await sceneAsset(named: assetName) {
            asset.position = [0, staging.bodyLift, 0]
            casualty.addChild(asset)
        } else {
            addFallbackCasualtyGeometry(to: casualty)
        }

        let tag = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.2, depth: 0.025, cornerRadius: 0.025), materials: [SimpleMaterial(color: .white, isMetallic: false)])
        tag.name = "tag-\(id)"
        tag.position = [-0.34, 0.27, 0.18]
        tag.isEnabled = false
        casualty.addChild(tag)

        let alert = ModelEntity(mesh: .generateSphere(radius: 0.09), materials: [SimpleMaterial(color: .systemRed, isMetallic: false)])
        alert.name = "condition-\(id)"
        alert.position = [0, 0.5, 0]
        alert.isEnabled = false
        casualty.addChild(alert)

        let cprTarget = ModelEntity(
            mesh: .generateCylinder(height: 0.035, radius: 0.18),
            materials: [SimpleMaterial(color: .systemRed, isMetallic: false)]
        )
        cprTarget.name = "cpr-target-\(id)"
        cprTarget.position = [0, 0.34, 0]
        cprTarget.components.set(InputTargetComponent())
        cprTarget.components.set(
            CollisionComponent(shapes: [.generateBox(size: [0.48, 0.09, 0.48])])
        )
        cprTarget.components.set(HoverEffectComponent())
        cprTarget.isEnabled = false
        casualty.addChild(cprTarget)

        for assessment in Assessment.allCases {
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 0.105),
                materials: [
                    SimpleMaterial(
                        color: uiAssessmentColour(assessment),
                        roughness: 0.25,
                        isMetallic: false
                    )
                ]
            )
            marker.name = "assessment-target-\(assessment.code)-\(id)"
            let offset = SpatialAssessmentCatalog.localOffset(for: assessment)
            marker.position = [offset.x, offset.y, offset.z]
            marker.components.set(InputTargetComponent())
            marker.components.set(
                CollisionComponent(shapes: [.generateSphere(radius: 0.16)])
            )
            marker.components.set(HoverEffectComponent())
            marker.isEnabled = false
            casualty.addChild(marker)
        }

        let bandage = Entity()
        bandage.name = "equipment-bandage-\(id)"
        bandage.position = staging.bandageAnchor
        bandage.orientation = simd_quatf(angle: 0.04, axis: [0, 1, 0])
        let fabric = SimpleMaterial(
            color: UIColor(red: 0.88, green: 0.85, blue: 0.74, alpha: 1),
            roughness: 0.98,
            isMetallic: false
        )
        for x: Float in [-0.09, -0.03, 0.03, 0.09] {
            let wrap = ModelEntity(
                mesh: .generateCylinder(height: 0.052, radius: 0.125),
                materials: [fabric]
            )
            wrap.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            wrap.position.x = x
            bandage.addChild(wrap)
        }
        let seamMaterial = SimpleMaterial(
            color: UIColor(red: 0.7, green: 0.67, blue: 0.58, alpha: 1),
            roughness: 1,
            isMetallic: false
        )
        for x: Float in [-0.12, -0.06, 0, 0.06, 0.12] {
            let seam = ModelEntity(
                mesh: .generateCylinder(height: 0.009, radius: 0.128),
                materials: [seamMaterial]
            )
            seam.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            seam.position.x = x
            bandage.addChild(seam)
        }
        let dressing = ModelEntity(
            mesh: .generateBox(width: 0.22, height: 0.035, depth: 0.13, cornerRadius: 0.018),
            materials: [SimpleMaterial(color: UIColor(white: 0.97, alpha: 1), roughness: 1, isMetallic: false)]
        )
        dressing.position = [0, 0.115, 0]
        bandage.addChild(dressing)
        let looseTail = ModelEntity(
            mesh: .generateBox(width: 0.28, height: 0.018, depth: 0.1, cornerRadius: 0.012),
            materials: [fabric]
        )
        looseTail.position = [0.19, 0.09, 0.055]
        looseTail.orientation = simd_quatf(angle: -0.28, axis: [0, 1, 0])
        bandage.addChild(looseTail)
        let clasp = ModelEntity(
            mesh: .generateBox(width: 0.055, height: 0.018, depth: 0.055, cornerRadius: 0.008),
            materials: [SimpleMaterial(color: UIColor(white: 0.65, alpha: 1), roughness: 0.3, isMetallic: true)]
        )
        clasp.position = [0.075, 0.142, 0]
        bandage.addChild(clasp)
        bandage.isEnabled = false
        casualty.addChild(bandage)

        let defibrillator = Entity()
        defibrillator.name = "equipment-defibrillator-\(id)"
        defibrillator.position = [0, 0.36, 0]
        let casingMaterial = SimpleMaterial(color: UIColor(red: 0.92, green: 0.74, blue: 0.08, alpha: 1), roughness: 0.48, isMetallic: false)
        let casing = ModelEntity(
            mesh: .generateBox(width: 0.34, height: 0.24, depth: 0.14, cornerRadius: 0.035),
            materials: [casingMaterial]
        )
        casing.position = [0.42, -0.1, 0.34]
        defibrillator.addChild(casing)
        let screen = ModelEntity(
            mesh: .generateBox(width: 0.19, height: 0.105, depth: 0.012, cornerRadius: 0.015),
            materials: [SimpleMaterial(color: UIColor(red: 0.04, green: 0.13, blue: 0.15, alpha: 1), roughness: 0.12, isMetallic: true)]
        )
        screen.position = [0.42, -0.08, 0.266]
        defibrillator.addChild(screen)
        let handle = ModelEntity(
            mesh: .generateBox(width: 0.18, height: 0.045, depth: 0.045, cornerRadius: 0.018),
            materials: [SimpleMaterial(color: .darkGray, roughness: 0.6, isMetallic: false)]
        )
        handle.position = [0.42, 0.055, 0.34]
        defibrillator.addChild(handle)
        let statusLight = ModelEntity(
            mesh: .generateSphere(radius: 0.018),
            materials: [SimpleMaterial(color: .systemGreen, roughness: 0.1, isMetallic: false)]
        )
        statusLight.position = [0.52, -0.155, 0.265]
        defibrillator.addChild(statusLight)

        let padMaterial = SimpleMaterial(color: UIColor(red: 0.9, green: 0.94, blue: 0.88, alpha: 1), roughness: 0.72, isMetallic: false)
        let padPositions: [SIMD3<Float>] = [[-0.17, 0, -0.08], [0.16, 0, 0.09]]
        for (index, position) in padPositions.enumerated() {
            let pad = ModelEntity(
                mesh: .generateBox(width: 0.17, height: 0.022, depth: 0.14, cornerRadius: 0.035),
                materials: [padMaterial]
            )
            pad.position = position
            pad.orientation = simd_quatf(angle: index == 0 ? -0.18 : 0.18, axis: [0, 1, 0])
            defibrillator.addChild(pad)
            let lead = ModelEntity(
                mesh: .generateCylinder(height: 0.42, radius: 0.009),
                materials: [SimpleMaterial(color: .darkGray, roughness: 0.7, isMetallic: false)]
            )
            lead.position = [(position.x + 0.42) / 2, -0.05, (position.z + 0.34) / 2]
            lead.orientation = simd_quatf(angle: .pi / 2.4, axis: [0, 0, 1])
            defibrillator.addChild(lead)
        }
        defibrillator.isEnabled = false
        casualty.addChild(defibrillator)
        return casualty
    }

    private func addFallbackCasualtyGeometry(to casualty: Entity) {
        let uniform = SimpleMaterial(color: .systemIndigo, isMetallic: false)
        let skin = SimpleMaterial(color: UIColor(red: 0.72, green: 0.50, blue: 0.38, alpha: 1), isMetallic: false)
        let torso = ModelEntity(mesh: .generateCylinder(height: 0.9, radius: 0.22), materials: [uniform])
        torso.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        let head = ModelEntity(mesh: .generateSphere(radius: 0.23), materials: [skin])
        head.position = [-0.68, 0, 0]
        casualty.addChild(torso); casualty.addChild(head)
        for z: Float in [-0.11, 0.11] {
            let leg = ModelEntity(mesh: .generateCylinder(height: 0.65, radius: 0.09), materials: [uniform])
            leg.orientation = torso.orientation
            leg.position = [0.68, 0, z]
            casualty.addChild(leg)
        }
    }

    private func uiColour(_ priority: TriagePriority) -> UIColor {
        switch priority {
        case .p1: .systemRed
        case .p2: .systemOrange
        case .p3: .systemGreen
        case .deceased: .black
        }
    }

    private func uiConditionColour(_ casualty: Casualty) -> UIColor {
        if casualty.isDeceased { return .black }
        if casualty.isReceivingCPR { return .systemGreen }
        if casualty.health <= 25 { return .systemRed }
        return .systemOrange
    }

    private func uiAssessmentColour(_ assessment: Assessment) -> UIColor {
        switch assessment {
        case .response: .systemBlue
        case .breathing: .systemTeal
        case .perfusion: .systemPink
        case .injuries: .systemOrange
        }
    }
}

struct InventoryToolbar: View {
    @EnvironmentObject private var session: TrainingSession
    @Binding var selectedTool: InventoryTool?
    let replenishAction: () -> Void
    @State private var isExpanded = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.left" : "cross.case.fill")
                        .font(.title2)
                    Text(isExpanded ? "Hide" : "Kit")
                        .font(.caption2.bold())
                }
                .frame(width: 50, height: 50)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(isExpanded ? "Close equipment toolbar" : "Open equipment toolbar")

            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("Equipment", systemImage: "cross.case.fill")
                            .font(.headline)
                        Spacer()
                        Button(action: replenishAction) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Replenish equipment")
                    }

                    ForEach(InventoryTool.allCases) { tool in
                        Button {
                            selectedTool = selectedTool == tool ? nil : tool
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: tool))
                                    .font(.title3)
                                    .foregroundStyle(colour(for: tool))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.title).font(.subheadline.bold())
                                    Text(instruction(for: tool))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("×\(session.inventory[tool, default: 0])")
                                    .font(.headline.monospacedDigit())
                                    .contentTransition(.numericText())
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedTool == tool ? colour(for: tool) : .secondary)
                        .disabled(session.inventory[tool, default: 0] == 0)
                        .accessibilityLabel("\(tool.title), \(session.inventory[tool, default: 0]) available")
                    }

                    if let selectedTool {
                        Label("\(selectedTool.title) selected", systemImage: "hand.point.up.left.fill")
                            .font(.caption.bold())
                            .foregroundStyle(colour(for: selectedTool))
                    }
                }
                .frame(width: 290)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(12)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 22))
    }

    private func icon(for tool: InventoryTool) -> String {
        switch tool {
        case .bandage: "bandage.fill"
        case .safetyCone: "exclamationmark.triangle.fill"
        case .defibrillator: "bolt.heart.fill"
        }
    }

    private func colour(for tool: InventoryTool) -> Color {
        switch tool {
        case .bandage: .blue
        case .safetyCone: .orange
        case .defibrillator: .red
        }
    }

    private func instruction(for tool: InventoryTool) -> String {
        switch tool {
        case .bandage: "Select, then pinch a casualty"
        case .safetyCone: "Select, then pinch the hazard"
        case .defibrillator: "Select, then pinch a casualty"
        }
    }
}

struct SpatialControlPanel: View {
    @EnvironmentObject private var session: TrainingSession
    @EnvironmentObject private var collaboration: IncidentCollaborationCoordinator
    @EnvironmentObject private var spatialAssessment: SpatialAssessmentCoordinator
    private var finishAction: () -> Void = {}

    func onFinish(_ action: @escaping () -> Void) -> SpatialControlPanel {
        var copy = self
        copy.finishAction = action
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(collaboration.localRole.title, systemImage: collaboration.localRole.icon)
                    .font(.caption.bold())
                Label(session.scenarioPace.title, systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if collaboration.isShared {
                    Label("\(collaboration.participantCount) live", systemImage: "shareplay")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                } else {
                    Label("Solo", systemImage: "person.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }

            if let notice = collaboration.notice {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            if session.selectedCasualty == nil {
                NextActionCard(action: session.nextRecommendedAction, compact: true)
                if !session.sceneSurveyed {
                    SurveyProgressView(
                        completed: session.surveyedCheckpoints,
                        simulatorMode: spatialAssessment.status == .simulator,
                        inspectAction: { checkpoint in
                            guard spatialAssessment.status == .simulator else { return }
                            collaboration.submit(.inspectSurveyCheckpoint(checkpoint))
                        }
                    )
                }
            }

            if let casualty = session.selectedCasualty {
                HStack {
                    VStack(alignment: .leading) {
                        Text(casualty.name).font(.title.bold())
                        Text(casualty.isDeteriorated ? "Condition changed - reassess" : casualty.location)
                            .foregroundStyle(casualty.isDeteriorated ? .red : .secondary)
                    }
                    Spacer()
                    Button { collaboration.submit(.closeCasualty) } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Close casualty details")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(casualty.conditionLabel, systemImage: casualty.isReceivingCPR ? "waveform.path.ecg" : "heart.fill")
                            .foregroundStyle(casualty.conditionColour)
                            .font(.headline)
                        Spacer()
                        Text("Health \(Int(casualty.health.rounded()))%")
                            .monospacedDigit()
                            .font(.headline)
                    }

                    ProgressView(value: casualty.health, total: 100)
                        .tint(casualty.conditionColour)

                    Label(casualty.visibleSymptoms, systemImage: "eye.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if casualty.deteriorationProfile.requiresCPR {
                        if casualty.isReceivingCPR {
                            Label(
                                "Simulated CPR coverage is active. Untreated deterioration is paused only while you hold.",
                                systemImage: "pause.circle.fill"
                            )
                            .foregroundStyle(.green)
                            .font(.headline)
                        } else if casualty.isDeceased {
                            Label(
                                "Ten-minute untreated scenario threshold reached.",
                                systemImage: "xmark.octagon.fill"
                            )
                            .foregroundStyle(.red)
                            .font(.headline)
                        } else if let remaining = casualty.neurologicalRiskTimeRemaining,
                                  remaining > 0 {
                            HStack {
                                Label("Untreated neurological-risk timer", systemImage: "timer")
                                Spacer()
                                Text(formatCountdown(remaining))
                                    .font(.title2.bold())
                                    .monospacedDigit()
                                    .foregroundStyle(remaining <= 60 ? .red : .orange)
                            }
                        } else if let remaining = casualty.deathTimeRemaining {
                            HStack {
                                Label("Scenario death threshold", systemImage: "exclamationmark.triangle.fill")
                                Spacer()
                                Text(formatCountdown(remaining))
                                    .font(.title2.bold())
                                    .monospacedDigit()
                                    .foregroundStyle(.red)
                            }
                        }

                        if !casualty.isDeceased && casualty.primaryAssessmentComplete {
                            CPRHoldControl(casualtyID: casualty.id)
                        } else if !casualty.isDeceased {
                            Label(
                                "Complete the primary assessment to activate the simulated CPR target.",
                                systemImage: "lock.fill"
                            )
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                if let conditionAlert = session.conditionAlert {
                    Label(conditionAlert, systemImage: "waveform.path.ecg")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }

                SpatialAssessmentGuideView(casualty: casualty)

                Divider()
                Text("Assign triage priority").font(.headline)
                if !casualty.primaryAssessmentComplete {
                    Label(
                        "Complete response, breathing, and perfusion checks to unlock triage tags.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                }
                HStack {
                    ForEach(TriagePriority.allCases) { priority in
                        Button {
                            collaboration.submit(.assignPriority(casualty.id, priority))
                        } label: {
                            VStack(spacing: 2) {
                                Text(priority.rawValue).bold()
                                Text(priority.title).font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(priority.colour)
                        .opacity(casualty.assignedPriority == priority ? 1 : 0.72)
                        .disabled(!casualty.primaryAssessmentComplete)
                    }
                }
            } else {
                HStack {
                    Label("Incident controls", systemImage: "cross.case.fill").font(.title2.bold())
                    Spacer()
                    Text(String(format: "%02d:%02d", Int(session.elapsed) / 60, Int(session.elapsed) % 60))
                        .monospacedDigit()
                }
                Text("Survey the scene, then look at a casualty or the yellow fuel spill and pinch.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button { collaboration.submit(.communicateHazard) } label: {
                        Label(session.hazardCommunicated ? "Reported" : "Report hazard", systemImage: "radio")
                    }
                    .disabled(!session.hazardIdentified || session.hazardCommunicated)
                    Button { collaboration.submit(.requestResources) } label: {
                        Label(session.resourceRequestSent ? "Requested" : "Resources", systemImage: "person.3.fill")
                    }
                    .disabled(session.resourceRequestSent)
                }
                .buttonStyle(.bordered)
                if let conditionAlert = session.conditionAlert {
                    Label(conditionAlert, systemImage: "waveform.path.ecg")
                        .foregroundStyle(.red)
                        .font(.headline)
                }
                HStack {
                    Text("\(session.taggedCount)/3 casualties tagged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive, action: finishAction) {
                        Label(session.canComplete ? "Finish & Debrief" : "End early", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: session.selectedCasualtyID == nil ? 540 : 620)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28))
    }

    private func formatCountdown(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded(.up)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct SpatialAssessmentGuideView: View {
    @EnvironmentObject private var spatialAssessment: SpatialAssessmentCoordinator
    let casualty: Casualty

    private var nextAssessment: Assessment? {
        Assessment.allCases.first { !casualty.completedAssessments.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(spatialAssessment.status.title, systemImage: statusIcon)
                    .font(.headline)
                    .foregroundStyle(statusColour)
                Spacer()
                Text("\(casualty.completedAssessments.count)/\(Assessment.allCases.count) verified")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            Text(spatialAssessment.status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if case .unavailable = spatialAssessment.status {
                Button {
                    spatialAssessment.start()
                } label: {
                    Label("Retry hand tracking", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            if let nextAssessment {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(nextAssessment.rawValue, systemImage: nextAssessment.icon)
                            .font(.headline)
                        Spacer()
                        Text("NEXT")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue, in: Capsule())
                    }
                    Text(nextAssessment.spatialInstruction)
                        .font(.caption)
                    ProgressView(
                        value: spatialAssessment.activeAssessment == nextAssessment
                            ? spatialAssessment.progress
                            : 0
                    )
                    .tint(.blue)
                    if let proximity = spatialAssessment.proximityMetres,
                       spatialAssessment.activeAssessment == nextAssessment {
                        Text("Tracked hand is \(String(format: "%.2f", proximity)) m from the assessment area")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Assessment.allCases) { assessment in
                    HStack(alignment: .top, spacing: 10) {
                        Image(
                            systemName: casualty.completedAssessments.contains(assessment)
                                ? "checkmark.seal.fill"
                                : "circle.dashed"
                        )
                        .foregroundStyle(casualty.completedAssessments.contains(assessment) ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(assessment.rawValue)
                                .font(.subheadline.bold())
                            if casualty.completedAssessments.contains(assessment) {
                                Text(casualty.finding(for: assessment))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Awaiting verified spatial evidence")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusIcon: String {
        switch spatialAssessment.status {
        case .tracking: "hand.raised.fingers.spread.fill"
        case .simulator: "visionpro.fill"
        case .unavailable: "hand.raised.slash.fill"
        case .starting: "waveform.path"
        case .idle: "hand.raised.fill"
        }
    }

    private var statusColour: Color {
        switch spatialAssessment.status {
        case .tracking: .green
        case .simulator: .blue
        case .unavailable: .red
        case .starting: .orange
        case .idle: .secondary
        }
    }
}

struct CPRHoldControl: View {
    @EnvironmentObject private var session: TrainingSession
    @EnvironmentObject private var collaboration: IncidentCollaborationCoordinator
    let casualtyID: String
    @State private var isHolding = false

    private var casualty: Casualty? {
        session.casualties.first(where: { $0.id == casualtyID })
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let beatDuration = 60.0 / Double(ScenarioRules.targetCompressionRate)
            let beatProgress = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: beatDuration) / beatDuration
            let pulseScale = isHolding ? 0.92 + (0.1 * beatProgress) : 1

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.45), lineWidth: 3)
                        .frame(width: 46, height: 46)
                        .scaleEffect(CGFloat(pulseScale))
                    Image(systemName: "heart.fill")
                        .font(.title2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(isHolding ? "Maintain simulated coverage" : "Hold to simulate CPR coverage")
                        .font(.headline)
                    if let casualty {
                        Text(
                            isHolding
                                ? "Reference \(ScenarioRules.targetCompressionRate)/min • \(format(casualty.activeCPRBoutSeconds)) held"
                                : "Total simulated coverage: \(format(casualty.effectiveCPRSeconds))"
                        )
                        .font(.caption)
                    }
                }
                Spacer()
                Image(systemName: isHolding ? "hand.pinch.fill" : "hand.pinch")
                    .font(.title2)
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(isHolding ? Color.green : Color.red, in: RoundedRectangle(cornerRadius: 16))
            .scaleEffect(CGFloat(pulseScale))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        startCPR()
                    }
                    .onEnded { _ in
                        stopCPR()
                    }
            )
            .accessibilityLabel("Simulated CPR coverage target")
            .accessibilityHint("Pinch and hold to represent continuous CPR coverage; physical compression quality is not measured")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Start CPR simulation") {
                startCPR()
            }
            .accessibilityAction(named: "Stop CPR simulation") {
                stopCPR()
            }
        }
        .onDisappear {
            guard isHolding else { return }
            stopCPR()
        }
    }

    private func startCPR() {
        let command = IncidentCommand.beginCPR(casualtyID)
        guard !isHolding, casualty?.isReceivingCPR != true else { return }
        guard !collaboration.isShared || command.isPermitted(for: collaboration.localRole) else {
            collaboration.submit(command)
            return
        }
        isHolding = true
        collaboration.submit(command)
    }

    private func stopCPR() {
        guard isHolding else { return }
        isHolding = false
        collaboration.submit(.endCPR(casualtyID, "Compression simulation hold released"))
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

#if DEBUG
private enum TriagePreviewFixtures {
    static let replayEvidence: [DecisionEvidence] = {
        let initialCasualties = replayCasualties(jordanPriority: nil)
        let incorrectSnapshot = IncidentReplaySnapshot(
            elapsed: 28,
            scenarioPace: .demo,
            selectedCasualtyID: "casualty-b",
            sceneSurveyed: true,
            hazardIdentified: true,
            hazardCommunicated: false,
            resourceRequestSent: false,
            casualties: initialCasualties
        )
        let correctedSnapshot = IncidentReplaySnapshot(
            elapsed: 36,
            scenarioPace: .demo,
            selectedCasualtyID: "casualty-b",
            sceneSurveyed: true,
            hazardIdentified: true,
            hazardCommunicated: true,
            resourceRequestSent: true,
            casualties: replayCasualties(jordanPriority: .p1)
        )

        return [
            DecisionEvidence(
                elapsed: 28,
                category: "Triage",
                action: "Tagged Jordan as P3 - Delayed.",
                actorRole: .triageOfficer,
                outcome: .needsReview,
                rationale: "P3 does not match absent breathing and perfusion evidence. Jordan requires P1 - Immediate.",
                cues: [
                    "Check response: Unresponsive to voice and pain.",
                    "Check breathing: Not breathing normally.",
                    "Check perfusion: No palpable pulse."
                ],
                consequence: "The mismatch could delay life-saving care.",
                recommendedAction: "Retag Jordan as P1 and maintain continuous CPR.",
                snapshot: incorrectSnapshot
            ),
            DecisionEvidence(
                elapsed: 36,
                category: "Triage",
                action: "Retagged Jordan as P1 - Immediate.",
                actorRole: .triageOfficer,
                outcome: .corrected,
                rationale: "P1 matches the verified response, breathing, and perfusion evidence.",
                cues: ["Absent spontaneous breathing", "Absent spontaneous circulation"],
                consequence: "Jordan entered the immediate treatment queue.",
                snapshot: correctedSnapshot
            )
        ]
    }()

    private static func replayCasualties(
        jordanPriority: TriagePriority?
    ) -> [CasualtyReplayState] {
        [
            CasualtyReplayState(
                id: "casualty-a",
                name: "Alex",
                health: 100,
                assignedPriority: .p1,
                correctPriority: .p1,
                completedAssessments: Set(Assessment.allCases),
                isReceivingCPR: false,
                isDeceased: false,
                conditionLabel: "Unconscious but physiologically stable"
            ),
            CasualtyReplayState(
                id: "casualty-b",
                name: "Jordan",
                health: 48,
                assignedPriority: jordanPriority,
                correctPriority: .p1,
                completedAssessments: ScenarioRules.primaryAssessments,
                isReceivingCPR: true,
                isDeceased: false,
                conditionLabel: "Simulated CPR active"
            ),
            CasualtyReplayState(
                id: "casualty-c",
                name: "Sam",
                health: 50,
                assignedPriority: .p2,
                correctPriority: .p2,
                completedAssessments: Set(Assessment.allCases),
                isReceivingCPR: false,
                isDeceased: false,
                conditionLabel: "Injured - stable"
            )
        ]
    }
}

#Preview("Evidence replay") {
    ScrollView {
        DecisionReplayView(evidence: TriagePreviewFixtures.replayEvidence)
            .padding(30)
    }
    .frame(width: 920, height: 720)
}

#Preview("Evidence replay empty") {
    DecisionReplayView(evidence: [])
        .padding(30)
        .frame(width: 920, height: 720)
}
#endif
