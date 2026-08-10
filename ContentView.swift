import SwiftUI
import RealityKit
import UIKit
import AVFoundation
import Combine
import ARKit
import GroupActivities
import UniformTypeIdentifiers
import os

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
        spatialAssessment.installSurveyPermissionProvider { [weak collaboration] in
            guard let collaboration else { return false }
            return !collaboration.isShared
                || IncidentCommand.recordSurveyCoverage([])
                    .isPermitted(for: collaboration.localRole)
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
        if deteriorationProfile.requiresCPR { return deteriorationStage >= 3 ? .red : .orange }
        return conditionLabel.localizedCaseInsensitiveContains("stable") ? .blue : .orange
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
    private static let historyStorageKey = "TriageXR.training-history.v1"

    let scenario = ScenarioCatalog.roadsideFoundation
    @Published var phase: ScenarioPhase = .briefing
    @Published var trainingMode: TrainingMode = .guided
    @Published var scenarioPace: ScenarioPace = .demo
    @Published var isPaused = false
    @Published var casualties: [Casualty] = TrainingSession.makeCasualties()
    @Published var selectedCasualtyID: String?
    @Published var hazardIdentified = false
    @Published var hazardCommunicated = false
    @Published var surveyedCheckpoints: Set<SurveyCheckpoint> = []
    @Published var surveyCoverageBins: Set<Int> = []
    @Published var resourceRequestSent = false
    @Published var deteriorationTriggered = false
    @Published var events: [SessionEvent] = []
    @Published var decisionEvidence: [DecisionEvidence] = []
    @Published var responseTempo = ResponseTempo()
    @Published var elapsed: TimeInterval = 0
    @Published var conditionAlert: String? = nil
    @Published private(set) var revision = 0
    @Published private(set) var historyArchive = TrainingHistoryArchive()

    private var lastTickAt: Date?
    private var timer: Timer?
    private let voice = AVSpeechSynthesizer()
    private var cuePlayer: AVAudioPlayer?
    private var currentActorRole: ResponderRole = .incidentCommander
    private let historyDefaults: UserDefaults
    var didChange: ((SharedIncidentSnapshot) -> Void)?

    init(historyDefaults: UserDefaults = .standard) {
        self.historyDefaults = historyDefaults
        guard let data = historyDefaults.data(forKey: Self.historyStorageKey),
              let archive = try? JSONDecoder().decode(TrainingHistoryArchive.self, from: data),
              archive.schemaVersion == TrainingHistoryArchive.currentSchemaVersion else {
            return
        }
        historyArchive = archive
    }

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
        SurveyCoverage.allBins.isSubset(of: surveyCoverageBins)
    }

    var surveyCoverageFraction: Double {
        SurveyCoverage.fractionCovered(surveyCoverageBins)
    }

    var nextRecommendedAction: RecommendedAction {
        if !sceneSurveyed {
            return RecommendedAction(
                title: "Survey the scene",
                detail: "Turn naturally and hold a level view. Headset direction fills the coverage map automatically (\(Int((surveyCoverageFraction * 100).rounded()))%).",
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

        if phase == .active, isPaused {
            switch command {
            case .setScenarioPaused(false), .end, .reset, .selectCasualty, .closeCasualty:
                break
            default:
                conditionAlert = "Exercise paused — resume the incident clock before recording operational actions."
                commitChange()
                return
            }
        }

        switch command {
        case .begin:
            begin()
        case .end:
            end()
        case .reset:
            reset()
        case .setTrainingMode(let mode):
            setTrainingMode(mode)
        case .setScenarioPace(let pace):
            setScenarioPace(pace)
        case .setScenarioPaused(let paused):
            setScenarioPaused(paused)
        case .inspectSurveyCheckpoint(let checkpoint):
            inspectSurveyCheckpoint(checkpoint)
        case .recordSurveyCoverage(let bins):
            recordSurveyCoverage(bins)
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
            trainingMode: trainingMode,
            scenarioPace: scenarioPace,
            isPaused: isPaused,
            casualties: casualties,
            hazardIdentified: hazardIdentified,
            hazardCommunicated: hazardCommunicated,
            surveyedCheckpoints: surveyedCheckpoints,
            surveyCoverageBins: surveyCoverageBins,
            resourceRequestSent: resourceRequestSent,
            deteriorationTriggered: deteriorationTriggered,
            events: events,
            decisionEvidence: decisionEvidence,
            responseTempo: responseTempo,
            elapsed: elapsed,
            conditionAlert: conditionAlert
        )
    }

    func applySharedSnapshot(_ snapshot: SharedIncidentSnapshot, force: Bool = false) {
        guard force || snapshot.revision >= revision else { return }
        let wasComplete = phase == .complete
        timer?.invalidate()
        timer = nil
        revision = snapshot.revision
        phase = snapshot.phase
        trainingMode = snapshot.trainingMode
        scenarioPace = snapshot.scenarioPace
        isPaused = snapshot.isPaused
        casualties = snapshot.casualties
        if snapshot.phase != .active {
            selectedCasualtyID = nil
        }
        hazardIdentified = snapshot.hazardIdentified
        hazardCommunicated = snapshot.hazardCommunicated
        surveyedCheckpoints = snapshot.surveyedCheckpoints
        surveyCoverageBins = snapshot.surveyCoverageBins
        resourceRequestSent = snapshot.resourceRequestSent
        deteriorationTriggered = snapshot.deteriorationTriggered
        events = snapshot.events
        decisionEvidence = snapshot.decisionEvidence
        responseTempo = snapshot.responseTempo
        elapsed = snapshot.elapsed
        conditionAlert = snapshot.conditionAlert
        lastTickAt = nil
        if snapshot.phase == .complete && !wasComplete {
            saveCompletedRun()
        }
    }

    func begin() {
        casualties = Self.makeCasualties()
        selectedCasualtyID = nil
        hazardIdentified = false
        hazardCommunicated = false
        surveyedCheckpoints = []
        surveyCoverageBins = []
        resourceRequestSent = false
        deteriorationTriggered = false
        isPaused = false
        events = []
        decisionEvidence = []
        responseTempo = ResponseTempo()
        elapsed = 0
        conditionAlert = nil
        phase = .active
        lastTickAt = Date()
        responseTempo.mark(.incidentStarted, at: 0)
        record(
            "Scenario",
            "\(scenario.title) started (content v\(scenario.version)).",
            outcome: "Scenario active",
            evidenceOutcome: .scenarioUpdate,
            rationale: "The briefing establishes three casualties, an unknown roadside hazard, and a time-critical cardiac arrest.",
            cues: [
                "Three reported casualties",
                "Hazards initially unknown",
                "One condition may change",
                "Training mode: \(trainingMode.title)",
                "Exercise pace: \(scenarioPace.title)"
            ],
            consequence: "The incident clock and untreated deterioration clock started."
        )
        speak("Dispatch. Three casualties reported. Survey the scene before approach.")
        startTimer()
    }

    func setTrainingMode(_ mode: TrainingMode) {
        guard phase == .briefing, trainingMode != mode else { return }
        trainingMode = mode
        conditionAlert = nil
        commitChange()
    }

    func setScenarioPace(_ pace: ScenarioPace) {
        guard phase == .briefing, scenarioPace != pace else { return }
        scenarioPace = pace
        conditionAlert = nil
        commitChange()
    }

    func setScenarioPaused(_ paused: Bool) {
        guard phase == .active, isPaused != paused else { return }
        if paused {
            for index in casualties.indices where casualties[index].isReceivingCPR {
                casualties[index].isReceivingCPR = false
                casualties[index].activeCPRBoutSeconds = 0
            }
        }
        isPaused = paused
        lastTickAt = paused ? nil : Date()
        conditionAlert = paused
            ? "Exercise paused by \(currentActorRole.title). Incident time and deterioration are frozen."
            : "Exercise resumed by \(currentActorRole.title)."
        record(
            "Instructor control",
            paused ? "Paused the exercise clock." : "Resumed the exercise clock.",
            outcome: paused ? "Scenario frozen" : "Scenario active",
            evidenceOutcome: .scenarioUpdate,
            rationale: "The host-authoritative exercise clock keeps every participant on the same instructor-controlled timeline.",
            cues: ["Control used by \(currentActorRole.title)"],
            consequence: paused
                ? "Incident time and deterioration stopped advancing; active simulated CPR holds were released."
                : "Incident time and casualty state progression resumed."
        )
    }

    func end() {
        guard phase == .active else { return }
        responseTempo.mark(.scenarioCompleted, at: elapsed)
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
        isPaused = false
        phase = .complete
        selectedCasualtyID = nil
        commitChange()
        saveCompletedRun()
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        lastTickAt = nil
        isPaused = false
        phase = .briefing
        selectedCasualtyID = nil
        elapsed = 0
        conditionAlert = nil
        responseTempo = ResponseTempo()
        revision += 1
        didChange?(sharedSnapshot())
    }

    func inspectSurveyCheckpoint(_ checkpoint: SurveyCheckpoint) {
        recordSurveyCoverage(Array(SurveyCoverage.requiredBins(for: checkpoint)))
    }

    func recordSurveyCoverage(_ bins: [Int]) {
        guard phase == .active else { return }
        let validBins = Set(bins).intersection(SurveyCoverage.allBins)
        let newlyCovered = validBins.subtracting(surveyCoverageBins)
        guard !newlyCovered.isEmpty else { return }

        let previousCheckpoints = surveyedCheckpoints
        surveyCoverageBins.formUnion(newlyCovered)
        surveyedCheckpoints.formUnion(
            SurveyCoverage.completedCheckpoints(for: surveyCoverageBins)
        )
        let newlyCompleted = surveyedCheckpoints.subtracting(previousCheckpoints)
        let isComplete = sceneSurveyed
        if isComplete {
            responseTempo.mark(.sceneSurveyed, at: elapsed)
        }
        let percent = Int((surveyCoverageFraction * 100).rounded())
        let completedTitles = newlyCompleted
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.shortTitle)
            .joined(separator: ", ")
        record(
            "Safety",
            isComplete
                ? "Head-direction coverage completed the deliberate 360° scene survey."
                : completedTitles.isEmpty
                    ? "Head direction added detail to the continuous scene-coverage map."
                    : "Head direction verified the \(completedTitles) survey zone\(newlyCompleted.count == 1 ? "" : "s").",
            positive: true,
            outcome: isComplete
                ? "360° coverage verified"
                : "Survey coverage \(percent)%",
            evidenceOutcome: .succeeded,
            rationale: "Stable, level headset orientation provides observable evidence of deliberate head movement before scene entry; it does not claim eye-gaze or object recognition.",
            cues: [
                "\(newlyCovered.count) new 30-degree coverage segment\(newlyCovered.count == 1 ? "" : "s")",
                "Stable view held for at least \(String(format: "%.1f", SceneSurveyEngine.requiredDwellDuration)) seconds",
                "\(surveyCoverageBins.count) of \(SurveyCoverage.binCount) segments covered"
            ],
            consequence: isComplete
                ? "All head-direction segments received deliberate coverage before patient contact."
                : "The coverage map advanced automatically without a survey button.",
            recommendedAction: isComplete
                ? nil
                : "Continue turning through uncovered directions and briefly hold a level view."
        )
        playCue(named: isComplete ? "SurveyComplete" : "SurveyConfirm")
    }

    func identifyHazard() {
        guard phase == .active, !hazardIdentified else { return }
        hazardIdentified = true
        responseTempo.mark(.hazardIdentified, at: elapsed)
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
        playCue(named: "HazardAlert")
    }

    func communicateHazard() {
        guard phase == .active, hazardIdentified, !hazardCommunicated else { return }
        hazardCommunicated = true
        responseTempo.mark(.hazardCommunicated, at: elapsed)
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
        responseTempo.mark(.resourcesRequested, at: elapsed)
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
        responseTempo.mark(.firstCasualtyContact, at: elapsed)
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
            responseTempo.mark(.firstAssessment, at: elapsed)
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
        if correct {
            responseTempo.mark(.firstCorrectTag, at: elapsed)
        }
        if taggedCount == casualties.count {
            responseTempo.mark(.allCasualtiesTagged, at: elapsed)
        }
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
              !isPaused,
              let index = casualties.firstIndex(where: { $0.id == casualtyID }),
              casualties[index].deteriorationProfile.requiresCPR,
              !casualties[index].isReceivingCPR,
              !casualties[index].isDeceased else { return }
        casualties[index].isReceivingCPR = true
        casualties[index].activeCPRBoutSeconds = 0
        casualties[index].cprSessionCount += 1
        responseTempo.mark(.cprStarted, at: elapsed)
        let pausedAt = casualties[index].neurologicalRiskTimeRemaining ?? 0
        conditionAlert = "Simulated CPR started for \(casualties[index].name). Keep holding to represent continuous compression coverage."
        record(
            "Treatment",
            "Simulated CPR coverage commenced for \(casualties[index].name) with \(Self.formatCountdown(pausedAt)) remaining to the fictional escalation threshold.",
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

    var instructorReport: InstructorSessionReport {
        let assessmentCount = casualties.reduce(0) { $0 + $1.completedAssessments.count }
        let assessmentMaximum = casualties.count * Assessment.allCases.count
        let correctTags = casualties.filter { $0.assignedPriority == $0.currentCorrectPriority }.count
        let coordinationComplete = hazardCommunicated && resourceRequestSent
        return InstructorSessionReport(
            schemaVersion: InstructorSessionReport.schemaVersion,
            scenarioID: scenario.id,
            scenarioVersion: scenario.version,
            scenarioTitle: scenario.title,
            trainingMode: trainingMode,
            scenarioPace: scenarioPace,
            exerciseElapsedSeconds: elapsed,
            score: score,
            responseTempo: responseTempo,
            surveyCoveragePercent: Int((surveyCoverageFraction * 100).rounded()),
            coveredSurveyBins: surveyCoverageBins.sorted(),
            competencies: [
                InstructorCompetencyResult(
                    id: "scene-safety",
                    title: "Scene safety",
                    status: sceneSurveyed && hazardIdentified ? "Demonstrated" : "Needs review",
                    evidence: "\(surveyCoverageBins.count)/\(SurveyCoverage.binCount) head-direction segments; hazard \(hazardIdentified ? "identified" : "not identified")."
                ),
                InstructorCompetencyResult(
                    id: "systematic-assessment",
                    title: "Systematic assessment",
                    status: assessmentCount == assessmentMaximum ? "Demonstrated" : "Developing",
                    evidence: "\(assessmentCount)/\(assessmentMaximum) spatial assessment steps verified."
                ),
                InstructorCompetencyResult(
                    id: "triage-reasoning",
                    title: "Triage reasoning",
                    status: correctTags == casualties.count ? "Demonstrated" : "Needs review",
                    evidence: "\(correctTags)/\(casualties.count) final priorities matched scenario evidence."
                ),
                InstructorCompetencyResult(
                    id: "coordination",
                    title: "Communication and coordination",
                    status: coordinationComplete ? "Demonstrated" : "Developing",
                    evidence: "Hazard report \(hazardCommunicated ? "sent" : "missing"); resource request \(resourceRequestSent ? "sent" : "missing")."
                )
            ],
            casualties: casualties.map {
                InstructorCasualtyResult(
                    id: $0.id,
                    name: $0.name,
                    assignedPriority: $0.assignedPriority,
                    expectedPriority: $0.currentCorrectPriority,
                    completedAssessments: $0.completedAssessments,
                    effectiveCPRSeconds: $0.effectiveCPRSeconds,
                    outcome: $0.conditionLabel
                )
            },
            events: debriefEvents,
            decisionEvidence: decisionEvidence,
            trainingBoundary: scenario.trainingBoundary
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
                guard let self, self.phase == .active, !self.isPaused else { return }
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
        guard phase == .active, !isPaused else {
            lastTickAt = nil
            return
        }
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
            message = trainingMode.showsExactCountdowns
                ? "\(name): visible oxygen-deprivation signs are developing. Four exercise minutes remain to the fictional escalation threshold."
                : "\(name): visible oxygen-deprivation signs are developing. Reassess the casualty."
            spokenMessage = trainingMode.showsExactCountdowns
                ? "Condition change. Four exercise minutes remain on the fictional escalation timer."
                : "Condition change. Visible deterioration requires reassessment."
        case 2:
            message = trainingMode.showsExactCountdowns
                ? "\(name): condition worsening. One exercise minute remains to the fictional escalation threshold."
                : "\(name): condition worsening. Immediate reassessment is required."
            spokenMessage = trainingMode.showsExactCountdowns
                ? "Urgent. One exercise minute remains on the fictional escalation timer."
                : "Urgent condition change. Immediate reassessment is required."
        case 3:
            message = "\(name): the fictional six-minute untreated escalation threshold has been reached."
            spokenMessage = "Critical warning. The fictional six minute escalation threshold has been reached."
        case 4:
            message = trainingMode.showsExactCountdowns
                ? "\(name): profound deterioration. Two minutes remain to the scenario death threshold."
                : "\(name): profound deterioration. The scenario outcome is at immediate risk."
            spokenMessage = trainingMode.showsExactCountdowns
                ? "Critical warning. Two minutes remain to the scenario death threshold."
                : "Critical warning. The scenario outcome is at immediate risk."
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

    private func playCue(named name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return }
        do {
            cuePlayer = try AVAudioPlayer(contentsOf: url)
            cuePlayer?.volume = 0.7
            cuePlayer?.prepareToPlay()
            cuePlayer?.play()
        } catch {
            // Audio feedback supplements the visual state; training continues safely.
        }
    }

    private func speak(_ message: String) {
        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = 0.48
        utterance.volume = 0.88
        voice.speak(utterance)
    }

    private func saveCompletedRun() {
        let run = TrainingRunSummary(
            scenarioID: scenario.id,
            scenarioVersion: scenario.version,
            trainingMode: trainingMode,
            scenarioPace: scenarioPace,
            exerciseElapsedSeconds: elapsed,
            score: score,
            responseTempo: responseTempo
        )
        historyArchive.record(run)
        guard let data = try? JSONEncoder().encode(historyArchive) else { return }
        historyDefaults.set(data, forKey: Self.historyStorageKey)
    }

    static func makeCasualties() -> [Casualty] {
        ScenarioCatalog.roadsideFoundation.makeCasualties()
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
    @EnvironmentObject private var session: TrainingSession
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
                        Text(session.scenario.title)
                            .font(.largeTitle.bold())
                        Text(session.scenario.subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Dispatch information") {
                    VStack(alignment: .leading, spacing: 12) {
                        BriefingRow(icon: "antenna.radiowaves.left.and.right", text: session.scenario.dispatch)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                GroupBox("Your objectives") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(session.scenario.objectives.enumerated()), id: \.element.id) { index, objective in
                            Label("\(index + 1). \(objective.title) — \(objective.detail)", systemImage: objective.icon)
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                GroupBox("Training boundary") {
                    Label(
                        session.scenario.trainingBoundary,
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                DemoReadinessView()

                TrainingHistoryView()

                CollaborationLobbyView()

                HStack {
                    Label("Simulation only — follow your instructor and organisation’s approved protocol.", systemImage: "info.circle")
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

struct DemoReadinessView: View {
    @EnvironmentObject private var aiCoach: AICoachCoordinator
    @EnvironmentObject private var collaboration: IncidentCollaborationCoordinator

    var body: some View {
        GroupBox("Demo readiness") {
            HStack(spacing: 12) {
                ReadinessItem(
                    title: "Spatial runtime",
                    detail: spatialDetail,
                    icon: spatialReady ? "checkmark.circle.fill" : "visionpro",
                    colour: spatialReady ? .green : .orange
                )
                ReadinessItem(
                    title: "Scenario assets",
                    detail: assetsReady ? "Models and earcons loaded" : "A bundled asset is missing",
                    icon: assetsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    colour: assetsReady ? .green : .red
                )
                ReadinessItem(
                    title: "Coach",
                    detail: aiCoach.relayIsConfigured ? "Grounded AI relay configured" : "Evidence-grounded local coach",
                    icon: aiCoach.relayIsConfigured ? "sparkles" : "lock.shield.fill",
                    colour: aiCoach.relayIsConfigured ? .purple : .blue
                )
                ReadinessItem(
                    title: "Incident mode",
                    detail: collaboration.isShared ? "SharePlay · \(collaboration.participantCount) live" : "Solo · ready",
                    icon: collaboration.isShared ? "shareplay" : "person.fill",
                    colour: collaboration.isShared ? .green : .blue
                )
            }
            .padding(.vertical, 8)
        }
    }

    private var assetsReady: Bool {
        let models = ["CollisionVehicle", "CasualtyAlex", "CasualtyJordan", "CasualtySam"]
        let audio = ["SurveyConfirm", "SurveyComplete", "HazardAlert"]
        return models.allSatisfy { Bundle.main.url(forResource: $0, withExtension: "usdz") != nil }
            && audio.allSatisfy { Bundle.main.url(forResource: $0, withExtension: "wav") != nil }
    }

    private var spatialReady: Bool {
#if targetEnvironment(simulator)
        false
#else
        HandTrackingProvider.isSupported && WorldTrackingProvider.isSupported
#endif
    }

    private var spatialDetail: String {
#if targetEnvironment(simulator)
        "Simulator workflow only"
#else
        spatialReady ? "Hands and headset pose supported" : "Check Vision Pro capability"
#endif
    }
}

struct ReadinessItem: View {
    let title: String
    let detail: String
    let icon: String
    let colour: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(colour)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                        Text("Training mode")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(session.trainingMode.detail)
                            .font(.caption)
                    }
                    Spacer()
                    Picker(
                        "Training mode",
                        selection: Binding(
                            get: { session.trainingMode },
                            set: { collaboration.submit(.setTrainingMode($0)) }
                        )
                    ) {
                        ForEach(TrainingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                    .disabled(!collaboration.canBeginIncident)
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

struct TrainingHistoryView: View {
    @EnvironmentObject private var session: TrainingSession

    private var archive: TrainingHistoryArchive { session.historyArchive }

    var body: some View {
        GroupBox("Training history") {
            if archive.runs.isEmpty {
                Label(
                    "Complete a run to establish a personal best and compare response tempo over time.",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        HistoryMetric(
                            title: "Personal best",
                            value: "\(archive.personalBest ?? 0)",
                            icon: "trophy.fill",
                            colour: .yellow
                        )
                        HistoryMetric(
                            title: "Average",
                            value: "\(archive.averageScore ?? 0)",
                            icon: "chart.bar.fill",
                            colour: .blue
                        )
                        HistoryMetric(
                            title: "Completed",
                            value: "\(archive.runs.count)",
                            icon: "checkmark.seal.fill",
                            colour: .green
                        )
                    }

                    ForEach(archive.runs.prefix(3)) { run in
                        HStack(spacing: 12) {
                            Text("\(run.score.total)")
                                .font(.title3.bold().monospacedDigit())
                                .frame(width: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.trainingMode.title)
                                    .font(.subheadline.bold())
                                Text(run.completedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label(run.scenarioPace.title, systemImage: "gauge.with.dots.needle.50percent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

struct HistoryMetric: View {
    let title: String
    let value: String
    let icon: String
    let colour: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(colour)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
    @EnvironmentObject private var spatialAssessment: SpatialAssessmentCoordinator
    let completed: Set<SurveyCheckpoint>
    let coverageBins: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Spatial scene survey", systemImage: "view.360")
                    .font(.headline)
                Spacer()
                Text("\(Int((SurveyCoverage.fractionCovered(coverageBins) * 100).rounded()))%")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                ForEach(0..<SurveyCoverage.binCount, id: \.self) { bin in
                    Capsule()
                        .fill(coverageBins.contains(bin) ? Color.green : Color.cyan.opacity(0.18))
                        .frame(height: 8)
                        .accessibilityLabel("Coverage segment \(bin + 1)")
                        .accessibilityValue(coverageBins.contains(bin) ? "covered" : "uncovered")
                }
            }

            HStack(spacing: 8) {
                ForEach(SurveyCheckpoint.allCases) { checkpoint in
                    let isComplete = completed.contains(checkpoint)
                    let isCurrent = spatialAssessment.surveyCurrentCheckpoint == checkpoint
                    Label(
                        checkpoint.shortTitle,
                        systemImage: isComplete
                            ? "checkmark.circle.fill"
                            : isCurrent ? "scope" : "circle.dashed"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(isComplete ? .green : isCurrent ? .white : .cyan)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(
                        (isComplete ? Color.green : Color.cyan)
                            .opacity(isCurrent && !isComplete ? 0.45 : 0.1),
                        in: Capsule()
                    )
                }
            }

            if !SurveyCoverage.allBins.isSubset(of: coverageBins) {
                Label(spatialAssessment.surveyStatus.title, systemImage: surveyStatusIcon)
                    .font(.caption.bold())
                    .foregroundStyle(surveyStatusColour)
                Text(spatialAssessment.surveyStatus.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if case .unavailable = spatialAssessment.surveyStatus {
                    Button {
                        spatialAssessment.restart()
                    } label: {
                        Label("Retry headset tracking", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let checkpoint = spatialAssessment.surveyCurrentCheckpoint,
                   !completed.contains(checkpoint) {
                    HStack {
                        Text(
                            spatialAssessment.surveyIsStable
                                ? "Hold on \(checkpoint.shortTitle)…"
                                : "Slow your turn to verify \(checkpoint.shortTitle)"
                        )
                        .font(.caption.bold())
                        Spacer()
                        Text("\(Int((spatialAssessment.surveyProgress * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                    }
                    ProgressView(value: spatialAssessment.surveyProgress)
                        .tint(.cyan)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var surveyStatusIcon: String {
        switch spatialAssessment.surveyStatus {
        case .tracking: "viewfinder.circle.fill"
        case .temporarilyLost: "eye.slash.fill"
        case .simulatorUnavailable: "visionpro"
        case .unavailable: "exclamationmark.triangle.fill"
        case .starting: "ellipsis.circle.fill"
        case .idle: "view.360"
        }
    }

    private var surveyStatusColour: Color {
        switch spatialAssessment.surveyStatus {
        case .tracking: .green
        case .temporarilyLost: .orange
        case .simulatorUnavailable, .unavailable: .orange
        case .starting: .cyan
        case .idle: .secondary
        }
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
    @State private var isExportingReport = false
    @State private var exportStatus: String?

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

                ResponseTempoView(tempo: session.responseTempo)

                InstructorCompetencyView(results: session.instructorReport.competencies)

                GroundedAICoachView()

                GroupBox("Evidence replay") {
                    DecisionReplayView(evidence: session.decisionEvidence)
                        .padding(.vertical, 8)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Focus for next attempt: scene safety, systematic assessment, reassessment, and concise communication.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let exportStatus {
                            Text(exportStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        isExportingReport = true
                    } label: {
                        Label("Export instructor report", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
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
        .fileExporter(
            isPresented: $isExportingReport,
            document: InstructorReportDocument(report: session.instructorReport),
            contentType: .json,
            defaultFilename: "TriageXR-\(session.scenario.id)-report"
        ) { result in
            switch result {
            case .success:
                exportStatus = "Instructor report exported with replay evidence and training boundary."
            case .failure:
                exportStatus = "The report could not be exported. Choose another destination and try again."
            }
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

struct ResponseTempoView: View {
    let tempo: ResponseTempo

    private let displayedMilestones: [ResponseMilestone] = [
        .sceneSurveyed,
        .hazardIdentified,
        .firstCasualtyContact,
        .firstAssessment,
        .firstCorrectTag,
        .cprStarted,
        .hazardCommunicated,
        .resourcesRequested,
        .allCasualtiesTagged,
        .scenarioCompleted
    ]

    var body: some View {
        GroupBox("Response tempo") {
            VStack(alignment: .leading, spacing: 12) {
                Text("First-occurrence timestamps from the authoritative exercise clock. These are descriptive training evidence, not clinical performance thresholds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(displayedMilestones) { milestone in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: milestone))
                                .foregroundStyle(tempo.elapsed(for: milestone) == nil ? .secondary : colour(for: milestone))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(milestone.title)
                                    .font(.subheadline.bold())
                                Text(formattedTime(for: milestone))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: tempo.elapsed(for: milestone) == nil ? "minus.circle" : "checkmark.circle.fill")
                                .foregroundStyle(tempo.elapsed(for: milestone) == nil ? .secondary : .green)
                        }
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func formattedTime(for milestone: ResponseMilestone) -> String {
        guard let elapsed = tempo.elapsed(for: milestone) else { return "Not captured" }
        let seconds = max(0, Int(elapsed.rounded()))
        return String(format: "%02d:%02d exercise time", seconds / 60, seconds % 60)
    }

    private func icon(for milestone: ResponseMilestone) -> String {
        switch milestone {
        case .incidentStarted: "play.circle.fill"
        case .sceneSurveyed: "view.360"
        case .hazardIdentified: "exclamationmark.triangle.fill"
        case .firstCasualtyContact: "figure.walk.arrival"
        case .firstAssessment: "waveform.path.ecg"
        case .firstCorrectTag: "tag.fill"
        case .cprStarted: "heart.fill"
        case .hazardCommunicated: "radio"
        case .resourcesRequested: "person.3.fill"
        case .allCasualtiesTagged: "checkmark.seal.fill"
        case .scenarioCompleted: "flag.checkered"
        }
    }

    private func colour(for milestone: ResponseMilestone) -> Color {
        switch milestone {
        case .hazardIdentified, .hazardCommunicated: .orange
        case .cprStarted: .red
        case .sceneSurveyed, .scenarioCompleted, .allCasualtiesTagged: .green
        case .firstCorrectTag: .purple
        default: .blue
        }
    }
}

struct InstructorCompetencyView: View {
    let results: [InstructorCompetencyResult]

    var body: some View {
        GroupBox("Instructor competency summary") {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(result.title)
                                .font(.headline)
                            Spacer()
                            Text(result.status)
                                .font(.caption.bold())
                                .foregroundStyle(result.status == "Demonstrated" ? .green : .orange)
                        }
                        Text(result.evidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct InstructorReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    private let data: Data

    init(report: InstructorSessionReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = (try? encoder.encode(report)) ?? Data("{}".utf8)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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
        if casualty.conditionLabel.localizedCaseInsensitiveContains("cardiac arrest") { return .orange }
        if casualty.conditionLabel.localizedCaseInsensitiveContains("stable") { return .blue }
        return .orange
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
            return "\(casualty.name), \(casualty.conditionLabel), \(priority)"
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
    private static let assetLogger = Logger(
        subsystem: "com.triagexr.training",
        category: "scene-assets"
    )
    @EnvironmentObject private var session: TrainingSession
    @EnvironmentObject private var collaboration: IncidentCollaborationCoordinator
    @EnvironmentObject private var spatialAssessment: SpatialAssessmentCoordinator
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var spatialCPRIsHeld = false
    @State private var isClosingForDebrief = false

    var body: some View {
        RealityView { content, attachments in
            content.add(await makeScene())
            if let controls = attachments.entity(for: "controls") {
                controls.position = controlPosition
                content.add(controls)
            }
        } update: { content, attachments in
            updateScene(content: content)
            if let controls = attachments.entity(for: "controls") {
                controls.position = controlPosition
                if controls.parent == nil { content.add(controls) }
            }
        } attachments: {
            Attachment(id: "controls") {
                SpatialControlPanel()
                    .onFinish { finishScenario() }
                    .environmentObject(session)
            }
        }
        .gesture(
            TapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    let name = value.entity.name
                    if name.hasPrefix("casualty-") {
                        collaboration.submit(.selectCasualty(name))
                    } else if name == "fuel-hazard" {
                        collaboration.submit(.identifyHazard)
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
        }
        .onDisappear {
            spatialAssessment.stop()
        }
        .onChange(of: session.phase) { _, phase in
            guard phase == .complete else { return }
            closeForDebrief()
        }
        .onChange(of: session.isPaused) { _, isPaused in
            if isPaused {
                spatialCPRIsHeld = false
            }
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
        for checkpoint in SurveyCheckpoint.allCases {
            guard let guide = root.findEntity(named: checkpoint.entityName) else {
                continue
            }
            let isInspected = session.surveyedCheckpoints.contains(checkpoint)
            let isCurrent = spatialAssessment.surveyCurrentCheckpoint == checkpoint
            guide.isEnabled = !session.sceneSurveyed
            setMaterialColour(
                on: guide,
                colour: isInspected ? .systemGreen : isCurrent ? .white : .systemCyan,
                roughness: 0.18
            )
            let dwellPulse = isCurrent && !isInspected
                ? Float(1 + (spatialAssessment.surveyProgress * 0.18))
                : 1
            let scale: Float = isInspected ? 0.82 : dwellPulse
            guide.scale = [scale, scale, scale]
        }
        if let hazard = root.findEntity(named: "fuel-hazard") {
            setMaterialColour(
                on: hazard,
                colour: session.hazardIdentified ? .systemRed : .systemYellow,
                roughness: 0.7
            )
            hazard.scale = session.hazardIdentified ? [1.2, 1.2, 1.2] : [1, 1, 1]
        }
        for casualty in session.casualties {
            guard let tag = root.findEntity(named: "tag-\(casualty.id)") as? ModelEntity else { continue }
            tag.isEnabled = casualty.assignedPriority != nil
            if let priority = casualty.assignedPriority {
                tag.model?.materials = [SimpleMaterial(color: uiColour(priority), isMetallic: false)]
            }
            if let marker = root.findEntity(named: "condition-\(casualty.id)") {
                marker.isEnabled = casualty.deteriorationProfile.requiresCPR
                setMaterialColour(on: marker, colour: uiConditionColour(casualty))
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
            let nextAssessment = Assessment.allCases.first {
                !casualty.completedAssessments.contains($0)
            }
            for assessment in Assessment.allCases {
                guard let target = root.findEntity(
                    named: "assessment-target-\(assessment.code)-\(casualty.id)"
                ) as? ModelEntity else {
                    continue
                }
                let isActive = session.selectedCasualtyID == casualty.id
                    && !session.isPaused
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
            panorama.position = .zero
            root.addChild(panorama)
        }

        addRoadEnvironment(to: root)
        addSurveyGuides(to: root)

        root.addChild(await makeVehicle(position: [-2.4, -1.28, -4.2], rotation: -0.22))
        root.addChild(await makeVehicle(position: [2.0, -1.28, -4.4], rotation: 0.3))

        root.addChild(await makeCasualty(id: "casualty-a", assetName: "CasualtyAlex", locatorColour: .systemBlue, position: [-1.55, -1.08, -2.25]))
        root.addChild(await makeCasualty(id: "casualty-b", assetName: "CasualtyJordan", locatorColour: .systemPurple, position: [0.1, -1.08, -3.15]))
        root.addChild(await makeCasualty(id: "casualty-c", assetName: "CasualtySam", locatorColour: .systemTeal, position: [1.55, -1.08, -2.2]))
        root.addChild(makeHazard())
        return root
    }

    private func addSurveyGuides(to root: Entity) {
        let positions: [SurveyCheckpoint: SIMD3<Float>] = [
            .forward: [0, 0.55, -5.3],
            .leftFlank: [-3.7, 0.5, -1.2],
            .rear: [0, 0.5, 2.8],
            .rightFlank: [3.7, 0.5, -1.2]
        ]

        for checkpoint in SurveyCheckpoint.allCases {
            guard let position = positions[checkpoint] else { continue }
            let guide = makeSurveyGuide(named: checkpoint.entityName)
            guide.position = position
            let directionToUser = SIMD3<Float>(-position.x, 0, -position.z)
            guide.orientation = simd_quatf(
                angle: atan2(directionToUser.x, directionToUser.z),
                axis: [0, 1, 0]
            )
            root.addChild(guide)
        }
    }

    private func makeSurveyGuide(named name: String) -> Entity {
        let guide = Entity()
        guide.name = name
        let material = SimpleMaterial(
            color: UIColor.systemCyan.withAlphaComponent(0.78),
            roughness: 0.18,
            isMetallic: false
        )

        for x: Float in [-0.3, 0.3] {
            let rail = ModelEntity(
                mesh: .generateBox(width: 0.028, height: 0.52, depth: 0.028, cornerRadius: 0.01),
                materials: [material]
            )
            rail.position = [x, 0, 0]
            guide.addChild(rail)
        }
        for y: Float in [-0.25, 0.25] {
            let cap = ModelEntity(
                mesh: .generateBox(width: 0.62, height: 0.028, depth: 0.028, cornerRadius: 0.01),
                materials: [material]
            )
            cap.position = [0, y, 0]
            guide.addChild(cap)
        }
        for angle: Float in [-.pi / 4, .pi / 4] {
            let chevron = ModelEntity(
                mesh: .generateBox(width: 0.19, height: 0.035, depth: 0.04, cornerRadius: 0.01),
                materials: [material]
            )
            chevron.position = [angle < 0 ? -0.065 : 0.065, 0, 0]
            chevron.orientation = simd_quatf(angle: angle, axis: [0, 0, 1])
            guide.addChild(chevron)
        }
        return guide
    }

    private func sceneAsset(named name: String) async -> Entity? {
        do {
            let asset = try await Entity(named: name, in: .main)
            if let embeddedEnvironmentLight = asset.findEntity(named: "env_light") {
                embeddedEnvironmentLight.removeFromParent()
            }
            return asset
        } catch {
            Self.assetLogger.error(
                "Failed to load scene asset \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
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
        let orange = SimpleMaterial(color: .systemOrange, roughness: 0.75, isMetallic: false)
        let rubber = SimpleMaterial(color: UIColor(white: 0.07, alpha: 1), roughness: 0.95, isMetallic: false)
        let base = ModelEntity(mesh: .generateBox(width: 0.34, height: 0.055, depth: 0.34, cornerRadius: 0.025), materials: [rubber])
        let body = ModelEntity(mesh: .generateCone(height: 0.48, radius: 0.15), materials: [orange])
        body.position.y = 0.26
        cone.addChild(base)
        cone.addChild(body)
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
            addCollisionDamage(to: vehicle)
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
        addCollisionDamage(to: vehicle)
        return vehicle
    }

    private func addCollisionDamage(to vehicle: Entity) {
        let crushedMetal = SimpleMaterial(
            color: UIColor(red: 0.12, green: 0.13, blue: 0.14, alpha: 1),
            roughness: 0.82,
            isMetallic: true
        )
        let impactPanel = ModelEntity(
            mesh: .generateBox(width: 0.34, height: 0.3, depth: 0.82, cornerRadius: 0.04),
            materials: [crushedMetal]
        )
        impactPanel.position = [0.82, 0.03, 0]
        impactPanel.orientation = simd_quatf(angle: 0.22, axis: [0, 0, 1])
        vehicle.addChild(impactPanel)

        let reflector = SimpleMaterial(
            color: UIColor.systemOrange.withAlphaComponent(0.86),
            roughness: 0.2,
            isMetallic: false
        )
        for z: Float in [-0.3, 0.3] {
            let brokenLamp = ModelEntity(
                mesh: .generateBox(width: 0.04, height: 0.11, depth: 0.18, cornerRadius: 0.018),
                materials: [reflector]
            )
            brokenLamp.position = [1.0, 0.05, z]
            brokenLamp.orientation = simd_quatf(angle: z < 0 ? -0.25 : 0.25, axis: [1, 0, 0])
            vehicle.addChild(brokenLamp)
        }

        for index in 0..<4 {
            let shard = ModelEntity(
                mesh: .generateBox(width: 0.12, height: 0.018, depth: 0.055, cornerRadius: 0.006),
                materials: [crushedMetal]
            )
            shard.position = [
                0.72 + (Float(index) * 0.13),
                -0.46,
                -0.42 + (Float(index % 2) * 0.78)
            ]
            shard.orientation = simd_quatf(angle: Float(index) * 0.55, axis: [0, 1, 0])
            vehicle.addChild(shard)
        }
    }

    private func makeHazard() -> Entity {
        let hazard = Entity()
        hazard.name = "fuel-hazard"
        hazard.position = [-1.65, -1.31, -3.75]
        hazard.components.set(InputTargetComponent())
        hazard.components.set(CollisionComponent(shapes: [.generateBox(size: [1.2, 0.08, 1.2])]))
        hazard.components.set(HoverEffectComponent())

        let material = SimpleMaterial(color: UIColor.systemYellow.withAlphaComponent(0.82), roughness: 0.7, isMetallic: false)
        for (offset, scale) in [
            (SIMD3<Float>(0, 0, 0), SIMD3<Float>(1.0, 1.0, 0.7)),
            (SIMD3<Float>(0.34, 0.004, 0.12), SIMD3<Float>(0.62, 1.0, 0.42)),
            (SIMD3<Float>(-0.28, 0.008, -0.17), SIMD3<Float>(0.48, 1.0, 0.58))
        ] {
            let lobe = ModelEntity(
                mesh: .generateCylinder(height: 0.025, radius: 0.55),
                materials: [material]
            )
            lobe.position = offset
            lobe.scale = scale
            hazard.addChild(lobe)
        }
        return hazard
    }

    private func makeCasualty(
        id: String,
        assetName: String,
        locatorColour: UIColor,
        position: SIMD3<Float>
    ) async -> Entity {
        let casualty = Entity()
        casualty.name = id
        casualty.position = position
        casualty.components.set(InputTargetComponent())
        casualty.components.set(CollisionComponent(shapes: [.generateBox(size: [0.82, 0.65, 1.95])]))
        casualty.components.set(HoverEffectComponent())

        if let asset = await sceneAsset(named: assetName) {
            asset.position = [0, 0.22, 0]
            casualty.addChild(asset)
        } else {
            addFallbackCasualtyGeometry(to: casualty)
        }

        let locatorMaterial = SimpleMaterial(color: locatorColour, isMetallic: false)
        let pole = ModelEntity(mesh: .generateBox(width: 0.025, height: 0.55, depth: 0.025), materials: [locatorMaterial])
        pole.position = [0, 0.64, 0]
        let locator = ModelEntity(
            mesh: .generateBox(width: 0.17, height: 0.17, depth: 0.045, cornerRadius: 0.025),
            materials: [locatorMaterial]
        )
        locator.position = [0, 0.94, 0]
        locator.orientation = simd_quatf(angle: .pi / 4, axis: [0, 0, 1])
        casualty.addChild(pole); casualty.addChild(locator)

        let tag = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.2, depth: 0.025, cornerRadius: 0.025), materials: [SimpleMaterial(color: .white, isMetallic: false)])
        tag.name = "tag-\(id)"
        tag.position = [0, 1.18, 0]
        tag.isEnabled = false
        casualty.addChild(tag)

        let alert = ModelEntity(
            mesh: .generateBox(width: 0.065, height: 0.18, depth: 0.045, cornerRadius: 0.018),
            materials: [SimpleMaterial(color: .systemRed, isMetallic: false)]
        )
        alert.name = "condition-\(id)"
        alert.position = [0, 0.54, 0]
        let alertDot = ModelEntity(
            mesh: .generateCylinder(height: 0.045, radius: 0.04),
            materials: [SimpleMaterial(color: .systemRed, isMetallic: false)]
        )
        alertDot.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        alertDot.position = [0, -0.13, 0]
        alert.addChild(alertDot)
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
            let marker = makeAssessmentMarker(assessment: assessment, casualtyID: id)
            marker.name = "assessment-target-\(assessment.code)-\(id)"
            let offset = SpatialAssessmentCatalog.localOffset(for: assessment)
            let horizontalCorrection: Float = assessment == .breathing ? -0.065 : 0
            marker.position = [offset.x + horizontalCorrection, offset.y, offset.z]
            marker.isEnabled = false
            casualty.addChild(marker)
        }
        return casualty
    }

    private func makeAssessmentMarker(
        assessment: Assessment,
        casualtyID: String
    ) -> ModelEntity {
        let colour = uiAssessmentColour(assessment)
        let material = SimpleMaterial(
            color: colour,
            roughness: 0.25,
            isMetallic: false
        )
        let marker: ModelEntity

        switch assessment {
        case .response:
            marker = ModelEntity(
                mesh: .generateBox(width: 0.18, height: 0.035, depth: 0.18, cornerRadius: 0.025),
                materials: [material]
            )
            marker.orientation = simd_quatf(angle: .pi / 4, axis: [0, 1, 0])
        case .breathing:
            marker = ModelEntity(
                mesh: .generateBox(width: 0.11, height: 0.035, depth: 0.19, cornerRadius: 0.05),
                materials: [material]
            )
            let secondLung = ModelEntity(
                mesh: .generateBox(width: 0.11, height: 0.035, depth: 0.19, cornerRadius: 0.05),
                materials: [material]
            )
            secondLung.position.x = 0.13
            marker.addChild(secondLung)
        case .perfusion:
            marker = ModelEntity(
                mesh: .generateCylinder(height: 0.035, radius: 0.105),
                materials: [material]
            )
            let pulseBar = ModelEntity(
                mesh: .generateBox(width: 0.14, height: 0.045, depth: 0.03, cornerRadius: 0.012),
                materials: [material]
            )
            pulseBar.position.y = 0.04
            marker.addChild(pulseBar)
        case .injuries:
            marker = ModelEntity(
                mesh: .generateBox(width: 0.22, height: 0.04, depth: 0.065, cornerRadius: 0.015),
                materials: [material]
            )
            let crossBar = ModelEntity(
                mesh: .generateBox(width: 0.065, height: 0.04, depth: 0.22, cornerRadius: 0.015),
                materials: [material]
            )
            marker.addChild(crossBar)
        }

        marker.name = "assessment-target-\(assessment.code)-\(casualtyID)"
        marker.components.set(InputTargetComponent())
        marker.components.set(
            CollisionComponent(shapes: [.generateBox(size: [0.32, 0.12, 0.32])])
        )
        marker.components.set(HoverEffectComponent())
        return marker
    }

    private func addFallbackCasualtyGeometry(to casualty: Entity) {
        let uniform = SimpleMaterial(color: .systemIndigo, isMetallic: false)
        let skin = SimpleMaterial(color: UIColor(red: 0.72, green: 0.50, blue: 0.38, alpha: 1), isMetallic: false)
        let torso = ModelEntity(mesh: .generateCylinder(height: 0.9, radius: 0.22), materials: [uniform])
        torso.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        let head = ModelEntity(
            mesh: .generateBox(width: 0.38, height: 0.46, depth: 0.35, cornerRadius: 0.16),
            materials: [skin]
        )
        head.position = [-0.68, 0, 0]
        casualty.addChild(torso); casualty.addChild(head)
        for z: Float in [-0.11, 0.11] {
            let leg = ModelEntity(mesh: .generateCylinder(height: 0.65, radius: 0.09), materials: [uniform])
            leg.orientation = torso.orientation
            leg.position = [0.68, 0, z]
            casualty.addChild(leg)
        }
    }

    private func setMaterialColour(
        on entity: Entity,
        colour: UIColor,
        roughness: MaterialScalarParameter = 0.25
    ) {
        if let model = entity as? ModelEntity {
            model.model?.materials = [
                SimpleMaterial(
                    color: colour,
                    roughness: roughness,
                    isMetallic: false
                )
            ]
        }
        for child in entity.children {
            setMaterialColour(on: child, colour: colour, roughness: roughness)
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
        if casualty.deteriorationStage >= 3 { return .systemRed }
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
                Spacer()
                if IncidentCommand.setScenarioPaused(!session.isPaused)
                    .isPermitted(for: collaboration.localRole) {
                    Button {
                        collaboration.submit(.setScenarioPaused(!session.isPaused))
                    } label: {
                        Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(session.isPaused ? .green : .orange)
                }
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

            HStack(spacing: 14) {
                Label(session.scenarioPace.title, systemImage: "gauge.with.dots.needle.50percent")
                Label(
                    session.trainingMode.title,
                    systemImage: session.trainingMode == .guided
                        ? "lightbulb.fill"
                        : "checkmark.shield.fill"
                )
                Spacer()
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)

            if session.isPaused {
                Label(
                    "Exercise paused — incident time, deterioration, and treatment coverage are frozen for every participant.",
                    systemImage: "pause.circle.fill"
                )
                .font(.caption.bold())
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            if session.scenarioPace == .demo && session.trainingMode.showsGuidance {
                JudgeDemoProgressView()
            }

            if let notice = collaboration.notice {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            if session.selectedCasualty == nil {
                if session.trainingMode.showsGuidance {
                    NextActionCard(action: session.nextRecommendedAction, compact: true)
                } else {
                    Label(
                        "Assessed run — prompts are reduced. Use scene evidence and your assigned role.",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                }
                if !session.sceneSurveyed {
                    SurveyProgressView(
                        completed: session.surveyedCheckpoints,
                        coverageBins: session.surveyCoverageBins
                    )
                }
                IncidentCommandBoardView()
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
                    }

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
                        } else if session.trainingMode.showsExactCountdowns,
                                  let remaining = casualty.neurologicalRiskTimeRemaining,
                                  remaining > 0 {
                            HStack {
                                Label("Fictional escalation timer", systemImage: "timer")
                                Spacer()
                                Text(formatCountdown(remaining))
                                    .font(.title2.bold())
                                    .monospacedDigit()
                                    .foregroundStyle(remaining <= 60 ? .red : .orange)
                            }
                        } else if session.trainingMode.showsExactCountdowns,
                                  let remaining = casualty.deathTimeRemaining {
                            HStack {
                                Label("Scenario death threshold", systemImage: "exclamationmark.triangle.fill")
                                Spacer()
                                Text(formatCountdown(remaining))
                                    .font(.title2.bold())
                                    .monospacedDigit()
                                    .foregroundStyle(.red)
                            }
                        } else if !casualty.isDeceased {
                            Label(
                                casualty.deteriorationStage >= 3
                                    ? "Critical fictional escalation threshold reached"
                                    : "Time-critical condition — exact countdown hidden in assessed mode",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.headline)
                            .foregroundStyle(casualty.deteriorationStage >= 3 ? .red : .orange)
                        }

                        if !casualty.isDeceased && casualty.primaryAssessmentComplete {
                            CPRHoldControl(casualtyID: casualty.id)
                                .id("cpr-\(casualty.id)-\(session.isPaused)")
                                .allowsHitTesting(!session.isPaused)
                                .opacity(session.isPaused ? 0.55 : 1)
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
                        .disabled(!casualty.primaryAssessmentComplete || session.isPaused)
                    }
                }
            } else {
                HStack {
                    Label("Incident controls", systemImage: "cross.case.fill").font(.title2.bold())
                    Spacer()
                    Text(String(format: "%02d:%02d", Int(session.elapsed) / 60, Int(session.elapsed) % 60))
                        .monospacedDigit()
                }
                Text(
                    session.trainingMode.showsGuidance
                        ? "Turn to survey the full scene automatically. Then look at a casualty or the fuel spill and pinch to select it."
                        : "Use the spatial scene, shared command board, and your assigned role to manage the incident."
                )
                .foregroundStyle(.secondary)
                HStack {
                    Button { collaboration.submit(.communicateHazard) } label: {
                        Label(session.hazardCommunicated ? "Reported" : "Report hazard", systemImage: "radio")
                    }
                    .disabled(session.isPaused || !session.hazardIdentified || session.hazardCommunicated)
                    Button { collaboration.submit(.requestResources) } label: {
                        Label(session.resourceRequestSent ? "Requested" : "Resources", systemImage: "person.3.fill")
                    }
                    .disabled(session.isPaused || session.resourceRequestSent)
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

struct IncidentCommandBoardView: View {
    @EnvironmentObject private var session: TrainingSession
    @EnvironmentObject private var collaboration: IncidentCollaborationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Shared casualty board", systemImage: "rectangle.3.group.fill")
                    .font(.headline)
                Spacer()
                Text("\(session.taggedCount)/\(session.casualties.count) tagged")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(session.casualties) { casualty in
                Button {
                    collaboration.submit(.selectCasualty(casualty.id))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: statusIcon(for: casualty))
                            .font(.title3)
                            .foregroundStyle(casualty.conditionColour)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(casualty.name)
                                    .font(.headline)
                                if casualty.isDeteriorated && !casualty.isDeceased {
                                    Text("REASSESS")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.red, in: Capsule())
                                }
                            }
                            Text(casualty.conditionLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Label(
                            "\(casualty.completedAssessments.count)/\(Assessment.allCases.count)",
                            systemImage: "checklist"
                        )
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.secondary)

                        if let priority = casualty.assignedPriority {
                            Text(priority.rawValue)
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(priority.colour, in: Capsule())
                                .accessibilityLabel("Priority \(priority.rawValue), \(priority.title)")
                        } else {
                            Text("UNTAGGED")
                                .font(.caption2.bold())
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.orange.opacity(0.12), in: Capsule())
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open spatial assessment and triage controls for \(casualty.name)")
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statusIcon(for casualty: Casualty) -> String {
        if casualty.isDeceased { return "xmark.octagon.fill" }
        if casualty.isReceivingCPR { return "heart.circle.fill" }
        if casualty.isDeteriorated { return "exclamationmark.triangle.fill" }
        return casualty.completedAssessments.isEmpty ? "person.crop.circle" : "checkmark.circle.fill"
    }
}

struct JudgeDemoProgressView: View {
    @EnvironmentObject private var session: TrainingSession

    private var beats: [(String, String, Bool)] {
        let jordan = session.casualties.first(where: { $0.id == "casualty-b" })
        return [
            ("1", "Survey", session.sceneSurveyed),
            ("2", "Hazard", session.hazardIdentified),
            ("3", "Stabilise", (jordan?.effectiveCPRSeconds ?? 0) >= ScenarioRules.minimumDemonstrationCPRDuration),
            ("4", "Debrief", session.canComplete)
        ]
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(beats.enumerated()), id: \.offset) { _, beat in
                HStack(spacing: 5) {
                    Image(systemName: beat.2 ? "checkmark.circle.fill" : "\(beat.0).circle")
                    Text(beat.1)
                }
                .font(.caption2.bold())
                .foregroundStyle(beat.2 ? .green : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background((beat.2 ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Judge demo progress")
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
                    spatialAssessment.restart()
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
                        Text("Tracked hand is \(String(format: "%.2f", proximity)) m from the marker")
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
