import SwiftUI
import RealityKit
import UIKit
import AVFoundation
import Combine

// MARK: - App

@main
struct TriageXRApp: App {
    @StateObject private var session = TrainingSession()

    var body: some SwiftUI.Scene {
        WindowGroup(id: "MainWindow") {
            ContentView()
                .environmentObject(session)
        }
        .defaultSize(width: 920, height: 720)

        ImmersiveSpace(id: "TriageScene") {
            ImmersiveTriageView()
                .environmentObject(session)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

// MARK: - Domain model

enum ScenarioPhase: String {
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

enum TriagePriority: String, CaseIterable, Identifiable, Codable {
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

    var colour: Color {
        switch self {
        case .p1: .red
        case .p2: .orange
        case .p3: .green
        case .deceased: .black
        }
    }
}

enum Assessment: String, CaseIterable, Identifiable, Codable {
    case response = "Check response"
    case breathing = "Check breathing"
    case perfusion = "Check perfusion"
    case injuries = "Inspect injuries"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .response: "ear"
        case .breathing: "lungs.fill"
        case .perfusion: "heart.text.square.fill"
        case .injuries: "bandage.fill"
        }
    }
}

enum DeteriorationProfile {
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
}

struct Casualty: Identifiable {
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
        if isDeceased { return "Deceased — simulation outcome" }
        if isReceivingCPR { return "CPR in progress" }
        if deteriorationProfile.requiresCPR { return "Cardiac arrest — untreated" }
        if health <= 50 { return "Injured — stable" }
        return "Unconscious but physiologically stable"
    }

    var conditionColour: Color {
        if isDeceased { return .gray }
        if isReceivingCPR { return .green }
        if deteriorationProfile.requiresCPR { return health <= 25 ? .red : .orange }
        return health <= 50 ? .orange : .blue
    }

    var visibleSymptoms: String {
        if isDeceased { return "No spontaneous breathing or signs of circulation." }
        if isReceivingCPR {
            return "No spontaneous breathing. External circulation is being supported by chest compressions."
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
                    ? "No spontaneous breathing; CPR is in progress."
                    : "Not breathing normally."
            case .perfusion:
                if isReceivingCPR { return "No spontaneous pulse; circulation supported by compressions." }
                return "No palpable pulse or spontaneous circulation."
            case .injuries:
                return visibleSymptoms
            }
        }
        if isDeteriorated, let finding = deterioratedFindings[assessment] { return finding }
        return initialFindings[assessment] ?? "No finding recorded."
    }
}

struct SessionEvent: Identifiable {
    let id = UUID()
    let elapsed: TimeInterval
    let category: String
    let detail: String
    let isPositive: Bool?
    let outcome: String

    var timestamp: String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct ScoreBreakdown {
    let safety: Int
    let assessment: Int
    let triage: Int
    let treatment: Int
    let communication: Int
    var total: Int { safety + assessment + triage + treatment + communication }
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
    @Published var casualties: [Casualty] = TrainingSession.makeCasualties()
    @Published var selectedCasualtyID: String?
    @Published var hazardIdentified = false
    @Published var hazardCommunicated = false
    @Published var sceneSurveyed = false
    @Published var resourceRequestSent = false
    @Published var deteriorationTriggered = false
    @Published var events: [SessionEvent] = []
    @Published var elapsed: TimeInterval = 0
    @Published var conditionAlert: String? = nil

    private var startedAt: Date?
    private var lastTickAt: Date?
    private var timer: Timer?
    private let voice = AVSpeechSynthesizer()

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

    var nextRecommendedAction: RecommendedAction {
        if !sceneSurveyed {
            return RecommendedAction(
                title: "Survey the scene",
                detail: "Complete a deliberate 360° scan before approaching casualties.",
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
                title: jordan.isReceivingCPR ? "Maintain effective CPR" : "Start CPR for Jordan",
                detail: jordan.isReceivingCPR
                    ? "Keep holding the compression target and follow the \(ScenarioRules.targetCompressionRate)/min rhythm."
                    : "Pinch and hold the red compression target; deterioration resumes when released.",
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

    func begin() {
        casualties = Self.makeCasualties()
        selectedCasualtyID = nil
        hazardIdentified = false
        hazardCommunicated = false
        sceneSurveyed = false
        resourceRequestSent = false
        deteriorationTriggered = false
        events = []
        elapsed = 0
        conditionAlert = nil
        phase = .active
        startedAt = Date()
        lastTickAt = startedAt
        record("Scenario", "Road traffic collision scenario started.", outcome: "Scenario active")
        startTimer()
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
            outcome: "Debrief generated"
        )
        timer?.invalidate()
        timer = nil
        lastTickAt = nil
        phase = .complete
        selectedCasualtyID = nil
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        lastTickAt = nil
        phase = .briefing
        selectedCasualtyID = nil
        elapsed = 0
        conditionAlert = nil
    }

    func markSurveyComplete() {
        guard phase == .active, !sceneSurveyed else { return }
        sceneSurveyed = true
        record(
            "Safety",
            "Completed a 360° scene survey before casualty assessment.",
            positive: true,
            outcome: "Scene entry safe"
        )
    }

    func identifyHazard() {
        guard phase == .active, !hazardIdentified else { return }
        hazardIdentified = true
        record(
            "Safety",
            "Identified the leaking-fuel hazard and established an exclusion zone.",
            positive: true,
            outcome: "Correct recognition"
        )
    }

    func communicateHazard() {
        guard phase == .active, hazardIdentified, !hazardCommunicated else { return }
        hazardCommunicated = true
        record(
            "Communication",
            "Reported the fuel hazard to incident command.",
            positive: true,
            outcome: "Hazard reported"
        )
    }

    func requestResources() {
        guard phase == .active, !resourceRequestSent else { return }
        resourceRequestSent = true
        record(
            "Communication",
            "Requested fire suppression and additional medical resources.",
            positive: true,
            outcome: "Escalation complete"
        )
    }

    func selectCasualty(_ id: String) {
        guard phase == .active else { return }
        if let selectedCasualtyID, selectedCasualtyID != id {
            endCPR(for: selectedCasualtyID, reason: "Moved to another casualty")
        }
        selectedCasualtyID = id
        if let casualty = casualties.first(where: { $0.id == id }) {
            record("Navigation", "Approached \(casualty.name) at \(casualty.location).")
        }
    }

    func closeCasualty() {
        if let selectedCasualtyID {
            endCPR(for: selectedCasualtyID, reason: "Compression hold released")
        }
        selectedCasualtyID = nil
    }

    func perform(_ assessment: Assessment) {
        guard phase == .active,
              let id = selectedCasualtyID,
              let index = casualties.firstIndex(where: { $0.id == id }) else { return }
        let wasNew = casualties[index].completedAssessments.insert(assessment).inserted
        if wasNew {
            record(
                "Assessment",
                "\(assessment.rawValue) for \(casualties[index].name): \(casualties[index].finding(for: assessment))",
                positive: true,
                outcome: "Finding recorded"
            )
        }
    }

    func assign(_ priority: TriagePriority) {
        guard phase == .active,
              let id = selectedCasualtyID,
              let index = casualties.firstIndex(where: { $0.id == id }) else { return }

        guard casualties[index].primaryAssessmentComplete else {
            let message = "Complete response, breathing, and perfusion checks before tagging \(casualties[index].name)."
            conditionAlert = message
            record("Triage", message, positive: false, outcome: "Assessment incomplete")
            return
        }

        let previous = casualties[index].assignedPriority
        casualties[index].assignedPriority = priority
        let correct = priority == casualties[index].currentCorrectPriority
        let action = previous == nil ? "Tagged" : "Retagged"
        record(
            "Triage",
            "\(action) \(casualties[index].name) as \(priority.rawValue) — \(priority.title).",
            positive: correct,
            outcome: correct ? "Correct priority" : "Priority mismatch"
        )
    }

    func beginCPR(for casualtyID: String? = nil) {
        guard phase == .active,
              let id = casualtyID ?? selectedCasualtyID,
              let index = casualties.firstIndex(where: { $0.id == id }),
              casualties[index].deteriorationProfile.requiresCPR,
              !casualties[index].isReceivingCPR,
              !casualties[index].isDeceased else { return }

        selectedCasualtyID = id
        casualties[index].isReceivingCPR = true
        casualties[index].activeCPRBoutSeconds = 0
        casualties[index].cprSessionCount += 1
        let pausedAt = casualties[index].neurologicalRiskTimeRemaining ?? 0
        conditionAlert = "Effective CPR started for \(casualties[index].name). Keep holding to pause deterioration."
        record(
            "Treatment",
            "CPR commenced for \(casualties[index].name) with \(Self.formatCountdown(pausedAt)) remaining to neurological risk.",
            positive: true,
            outcome: "Deterioration paused"
        )

        let announcement = AVSpeechUtterance(
            string: "Effective CPR started. Maintain compressions at the indicated rhythm."
        )
        announcement.rate = 0.48
        announcement.volume = 0.9
        voice.speak(announcement)
    }

    func endCPR(for casualtyID: String? = nil, reason: String = "Compression hold released") {
        guard phase == .active else { return }

        let id = casualtyID
            ?? casualties.first(where: { $0.isReceivingCPR })?.id
            ?? selectedCasualtyID
        guard let id,
              let index = casualties.firstIndex(where: { $0.id == id }),
              casualties[index].isReceivingCPR else { return }

        let boutDuration = casualties[index].activeCPRBoutSeconds
        casualties[index].isReceivingCPR = false
        casualties[index].activeCPRBoutSeconds = 0

        let remaining = casualties[index].neurologicalRiskTimeRemaining
            ?? casualties[index].deathTimeRemaining
            ?? 0
        let metDemonstrationTarget = boutDuration >= ScenarioRules.minimumDemonstrationCPRDuration
        conditionAlert = "CPR stopped for \(casualties[index].name). Untreated deterioration has resumed."
        record(
            "Treatment",
            "\(reason) after \(Self.formatDuration(boutDuration)) of effective CPR; untreated countdown resumed at \(Self.formatCountdown(remaining)).",
            positive: metDemonstrationTarget,
            outcome: metDemonstrationTarget ? "Effective CPR recorded" : "CPR interrupted early"
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
            review.append("Jordan received no effective CPR. After confirming unresponsiveness, abnormal breathing, and absent perfusion, pinch and continuously hold the compression target.")
        } else if let jordan,
                  jordan.effectiveCPRSeconds < ScenarioRules.minimumDemonstrationCPRDuration {
            review.append("Jordan received only \(Self.formatDuration(jordan.effectiveCPRSeconds)) of effective CPR. Maintain the hold and follow the \(ScenarioRules.targetCompressionRate)/min rhythm; deterioration resumes as soon as compressions stop.")
        } else if let jordan {
            review.append("You delivered \(Self.formatDuration(jordan.effectiveCPRSeconds)) of effective CPR across \(jordan.cprSessionCount) attempt\(jordan.cprSessionCount == 1 ? "" : "s"), pausing untreated deterioration only while compressions were maintained.")
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

    private var deteriorationTimestamp: String {
        events.first(where: { $0.category == "Deterioration" })?.timestamp ?? "the midpoint"
    }

    private func startTimer() {
        timer?.invalidate()

        timer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let startedAt = self.startedAt,
                      self.phase == .active else {
                    return
                }

                let now = Date()
                let delta = max(
                    0,
                    now.timeIntervalSince(self.lastTickAt ?? now)
                )

                self.lastTickAt = now
                self.elapsed = now.timeIntervalSince(startedAt)
                self.updatePatientDeterioration(by: delta)
            }
        }
    }

    private func updatePatientDeterioration(by delta: TimeInterval) {
        guard delta > 0 else { return }

        for index in casualties.indices {
            guard case let .untreatedCardiacArrest(neurologicalRiskAfter, deathAfter) = casualties[index].deteriorationProfile else {
                continue
            }

            if casualties[index].isReceivingCPR {
                casualties[index].effectiveCPRSeconds += delta
                casualties[index].activeCPRBoutSeconds += delta
                continue
            }

            guard !casualties[index].isDeceased else { continue }

            casualties[index].untreatedSeconds = min(
                deathAfter,
                casualties[index].untreatedSeconds + delta
            )

            let elapsedFraction = casualties[index].untreatedSeconds / deathAfter
            casualties[index].health = max(
                0,
                casualties[index].initialHealth * (1 - elapsedFraction)
            )

            let newStage = deteriorationStage(
                untreatedSeconds: casualties[index].untreatedSeconds,
                neurologicalRiskAfter: neurologicalRiskAfter,
                deathAfter: deathAfter
            )

            if newStage > casualties[index].deteriorationStage {
                applyDeteriorationStage(newStage, to: index)
            }
        }
    }

    private func deteriorationStage(
        untreatedSeconds: TimeInterval,
        neurologicalRiskAfter: TimeInterval,
        deathAfter: TimeInterval
    ) -> Int {
        if untreatedSeconds >= deathAfter { return 5 }
        if untreatedSeconds >= neurologicalRiskAfter + 120 { return 4 }
        if untreatedSeconds >= neurologicalRiskAfter { return 3 }
        if untreatedSeconds >= neurologicalRiskAfter - 60 { return 2 }
        if untreatedSeconds >= neurologicalRiskAfter - 240 { return 1 }
        return 0
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
        record("Deterioration", message, positive: false, outcome: "Condition worsened")

        let announcement = AVSpeechUtterance(string: spokenMessage)
        announcement.rate = 0.48
        announcement.volume = 0.9
        voice.speak(announcement)
    }

    private func record(
        _ category: String,
        _ detail: String,
        positive: Bool? = nil,
        outcome: String? = nil
    ) {
        let eventElapsed = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
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
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var immersiveSpaceIsOpen = false
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
    }

    private var phaseIcon: String {
        switch session.phase {
        case .briefing: "doc.text.fill"
        case .active: "waveform.path.ecg"
        case .complete: "chart.bar.doc.horizontal.fill"
        }
    }

    private func beginScenario() {
        Task {
            statusMessage = nil
            session.begin()
            let result = await openImmersiveSpace(id: "TriageScene")
            switch result {
            case .opened: immersiveSpaceIsOpen = true
                dismissWindow(id: "MainWindow")
            case .userCancelled:
                session.reset()
                statusMessage = "Scenario opening was cancelled."
            case .error:
                session.reset()
                statusMessage = "The immersive scene could not be opened."
            @unknown default:
                session.reset()
                statusMessage = "An unexpected error occurred."
            }
        }
    }

    private func restart() {
        session.reset()
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
                        BriefingRow(icon: "location.fill", text: "Urban roadside; emergency services not yet on scene")
                        BriefingRow(icon: "exclamationmark.triangle.fill", text: "Hazards are unknown — survey before approaching")
                        BriefingRow(icon: "clock.fill", text: "One casualty may change condition during the exercise")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                GroupBox("Your objectives") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Survey the scene and identify hazards")
                        Text("2. Assess all three casualties")
                        Text("3. Deliver effective CPR when indicated")
                        Text("4. Assign and revise triage priorities")
                        Text("5. Communicate risks and resource requirements")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                HStack {
                    Label("Training aid only — follow your organisation’s approved protocols.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: beginAction) {
                        Label("Enter Incident", systemImage: "visionpro.fill")
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(32)
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

struct LiveDashboardView: View {
    @EnvironmentObject private var session: TrainingSession
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
                Button { session.markSurveyComplete() } label: {
                    Label(session.sceneSurveyed ? "Survey complete" : "Complete 360° survey", systemImage: "view.360")
                }
                .disabled(session.sceneSurveyed)

                Button { session.communicateHazard() } label: {
                    Label(session.hazardCommunicated ? "Hazard reported" : "Report hazard", systemImage: "radio")
                }
                .disabled(!session.hazardIdentified || session.hazardCommunicated)

                Button { session.requestResources() } label: {
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

                GroupBox("Coach priorities") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(session.coachReview.enumerated()), id: \.offset) { _, item in
                            Label(item, systemImage: "sparkles")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Decision timeline") {
                    DebriefTimeline(events: session.debriefEvents)
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
    }

    private var scoreColour: Color {
        session.score.total >= 80 ? .green : session.score.total >= 60 ? .orange : .red
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
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var spatialCPRIsHeld = false

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
                        session.selectCasualty(name)
                    } else if name == "fuel-hazard" {
                        session.identifyHazard()
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .targetedToAnyEntity()
                .onChanged { value in
                    guard value.entity.name == "cpr-target-casualty-b",
                          !spatialCPRIsHeld else { return }
                    spatialCPRIsHeld = true
                    session.beginCPR(for: "casualty-b")
                }
                .onEnded { value in
                    guard value.entity.name == "cpr-target-casualty-b",
                          spatialCPRIsHeld else { return }
                    spatialCPRIsHeld = false
                    session.endCPR(for: "casualty-b")
                }
        )
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
        session.end()
        Task {
            await dismissImmersiveSpace()
            openWindow(id: "MainWindow")
        }
    }

    private func updateScene(content: RealityViewContent) {
        guard let root = content.entities.first(where: { $0.name == "scene-root" }) else { return }
        if let hazard = root.findEntity(named: "fuel-hazard") as? ModelEntity {
            hazard.model?.materials = [SimpleMaterial(color: session.hazardIdentified ? .systemRed : .systemYellow, isMetallic: false)]
            hazard.scale = session.hazardIdentified ? [1.2, 1.2, 1.2] : [1, 1, 1]
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
        }
    }

    private func makeScene() async -> Entity {
        let root = Entity()
        root.name = "scene-root"

        let floor = ModelEntity(
            mesh: .generatePlane(width: 8, depth: 8),
            materials: [SimpleMaterial(color: UIColor(white: 0.22, alpha: 0.55), isMetallic: false)]
        )
        floor.position = [0, -1.35, -3.1]
        root.addChild(floor)

        let roadLine = ModelEntity(mesh: .generateBox(width: 0.12, height: 0.01, depth: 6.5), materials: [SimpleMaterial(color: .white, isMetallic: false)])
        roadLine.position = [0, -1.33, -3.1]
        root.addChild(roadLine)

        root.addChild(await makeVehicle(position: [-2.4, -1.28, -4.2], rotation: -0.22))
        root.addChild(await makeVehicle(position: [2.0, -1.28, -4.4], rotation: 0.3))

        root.addChild(await makeCasualty(id: "casualty-a", assetName: "CasualtyAlex", locatorColour: .systemBlue, position: [-1.55, -1.08, -2.25]))
        root.addChild(await makeCasualty(id: "casualty-b", assetName: "CasualtyJordan", locatorColour: .systemPurple, position: [0.1, -1.08, -3.15]))
        root.addChild(await makeCasualty(id: "casualty-c", assetName: "CasualtySam", locatorColour: .systemTeal, position: [1.55, -1.08, -2.2]))
        root.addChild(makeHazard())
        return root
    }

    private func sceneAsset(named name: String) async -> Entity? {
        try? await Entity(named: name, in: .main)
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
        let body = ModelEntity(mesh: .generateBox(width: 1.7, height: 0.75, depth: 0.85, cornerRadius: 0.12), materials: [SimpleMaterial(color: .darkGray, isMetallic: true)])
        vehicle.addChild(body)
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
        let hazard = ModelEntity(mesh: .generateCylinder(height: 0.025, radius: 0.55), materials: [SimpleMaterial(color: .systemYellow, isMetallic: false)])
        hazard.name = "fuel-hazard"
        hazard.position = [-1.65, -1.31, -3.75]
        hazard.components.set(InputTargetComponent())
        hazard.components.set(CollisionComponent(shapes: [.generateBox(size: [1.2, 0.08, 1.2])]))
        hazard.components.set(HoverEffectComponent())
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
        let locator = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [locatorMaterial])
        locator.position = [0, 0.94, 0]
        casualty.addChild(pole); casualty.addChild(locator)

        let tag = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.2, depth: 0.025, cornerRadius: 0.025), materials: [SimpleMaterial(color: .white, isMetallic: false)])
        tag.name = "tag-\(id)"
        tag.position = [0, 1.18, 0]
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
}

struct SpatialControlPanel: View {
    @EnvironmentObject private var session: TrainingSession
    private var finishAction: () -> Void = {}

    func onFinish(_ action: @escaping () -> Void) -> SpatialControlPanel {
        var copy = self
        copy.finishAction = action
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NextActionCard(action: session.nextRecommendedAction, compact: true)

            if let casualty = session.selectedCasualty {
                HStack {
                    VStack(alignment: .leading) {
                        Text(casualty.name).font(.title.bold())
                        Text(casualty.isDeteriorated ? "Condition changed — reassess" : casualty.location)
                            .foregroundStyle(casualty.isDeteriorated ? .red : .secondary)
                    }
                    Spacer()
                    Button { session.closeCasualty() } label: { Image(systemName: "xmark.circle.fill") }
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
                                "Effective CPR is active. Untreated deterioration is paused only while you hold.",
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
                                "Complete the primary assessment to activate the CPR compression target.",
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

                ForEach(Assessment.allCases) { assessment in
                    Button { session.perform(assessment) } label: {
                        HStack {
                            Label(assessment.rawValue, systemImage: assessment.icon)
                            Spacer()
                            if casualty.completedAssessments.contains(assessment) {
                                Text(casualty.finding(for: assessment)).font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }

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
                            session.assign(priority)
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
                    Button { session.markSurveyComplete() } label: {
                        Label(session.sceneSurveyed ? "Surveyed" : "360° survey", systemImage: "view.360")
                    }
                    .disabled(session.sceneSurveyed)
                    Button { session.communicateHazard() } label: {
                        Label(session.hazardCommunicated ? "Reported" : "Report hazard", systemImage: "radio")
                    }
                    .disabled(!session.hazardIdentified || session.hazardCommunicated)
                    Button { session.requestResources() } label: {
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

struct CPRHoldControl: View {
    @EnvironmentObject private var session: TrainingSession
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
                    Text(isHolding ? "Maintain compressions" : "Pinch and hold for CPR")
                        .font(.headline)
                    if let casualty {
                        Text(
                            isHolding
                                ? "Target \(ScenarioRules.targetCompressionRate)/min • \(format(casualty.activeCPRBoutSeconds)) effective"
                                : "Total effective CPR: \(format(casualty.effectiveCPRSeconds))"
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
                        guard !isHolding else { return }
                        isHolding = true
                        session.beginCPR(for: casualtyID)
                    }
                    .onEnded { _ in
                        guard isHolding else { return }
                        isHolding = false
                        session.endCPR(for: casualtyID)
                    }
            )
            .accessibilityLabel("CPR compression target")
            .accessibilityHint("Pinch and hold to maintain effective CPR")
            .accessibilityAddTraits(.isButton)
        }
        .onDisappear {
            guard isHolding || casualty?.isReceivingCPR == true else { return }
            isHolding = false
            session.endCPR(for: casualtyID)
        }
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
