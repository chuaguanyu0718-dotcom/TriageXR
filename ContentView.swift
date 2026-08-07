import SwiftUI
import RealityKit
import UIKit
import AVFoundation

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

struct Casualty: Identifiable {
    let id: String
    let name: String
    let location: String
    let initialFindings: [Assessment: String]
    let deterioratedFindings: [Assessment: String]
    let correctInitialPriority: TriagePriority
    let correctDeterioratedPriority: TriagePriority?
    var completedAssessments: Set<Assessment> = []
    var assignedPriority: TriagePriority?
    var isDeteriorated = false

    var currentCorrectPriority: TriagePriority {
        isDeteriorated ? (correctDeterioratedPriority ?? correctInitialPriority) : correctInitialPriority
    }

    func finding(for assessment: Assessment) -> String {
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

    var timestamp: String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct ScoreBreakdown {
    let safety: Int
    let assessment: Int
    let triage: Int
    let communication: Int
    var total: Int { safety + assessment + triage + communication }
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

    private var startedAt: Date?
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
        phase = .active
        startedAt = Date()
        record("Scenario", "Road traffic collision scenario started.")
        startTimer()
    }

    func end() {
        guard phase == .active else { return }
        record("Scenario", "Scenario ended with \(taggedCount) of \(casualties.count) casualties tagged.")
        timer?.invalidate()
        timer = nil
        phase = .complete
        selectedCasualtyID = nil
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        phase = .briefing
        selectedCasualtyID = nil
        elapsed = 0
    }

    func markSurveyComplete() {
        guard phase == .active, !sceneSurveyed else { return }
        sceneSurveyed = true
        record("Safety", "Completed a 360° scene survey before casualty assessment.", positive: true)
    }

    func identifyHazard() {
        guard phase == .active, !hazardIdentified else { return }
        hazardIdentified = true
        record("Safety", "Identified the leaking-fuel hazard and established an exclusion zone.", positive: true)
    }

    func communicateHazard() {
        guard phase == .active, hazardIdentified, !hazardCommunicated else { return }
        hazardCommunicated = true
        record("Communication", "Reported the fuel hazard to incident command.", positive: true)
    }

    func requestResources() {
        guard phase == .active, !resourceRequestSent else { return }
        resourceRequestSent = true
        record("Communication", "Requested fire suppression and additional medical resources.", positive: true)
    }

    func selectCasualty(_ id: String) {
        guard phase == .active else { return }
        selectedCasualtyID = id
        if let casualty = casualties.first(where: { $0.id == id }) {
            record("Navigation", "Approached \(casualty.name) at \(casualty.location).")
        }
    }

    func closeCasualty() {
        selectedCasualtyID = nil
    }

    func perform(_ assessment: Assessment) {
        guard phase == .active,
              let id = selectedCasualtyID,
              let index = casualties.firstIndex(where: { $0.id == id }) else { return }
        let wasNew = casualties[index].completedAssessments.insert(assessment).inserted
        if wasNew {
            record("Assessment", "\(assessment.rawValue) for \(casualties[index].name): \(casualties[index].finding(for: assessment))", positive: true)
        }
    }

    func assign(_ priority: TriagePriority) {
        guard phase == .active,
              let id = selectedCasualtyID,
              let index = casualties.firstIndex(where: { $0.id == id }) else { return }
        let previous = casualties[index].assignedPriority
        casualties[index].assignedPriority = priority
        let correct = priority == casualties[index].currentCorrectPriority
        let action = previous == nil ? "Tagged" : "Retagged"
        record("Triage", "\(action) \(casualties[index].name) as \(priority.rawValue) — \(priority.title).", positive: correct)
    }

    var score: ScoreBreakdown {
        let safety = (sceneSurveyed ? 10 : 0) + (hazardIdentified ? 15 : 0)
        let assessmentTotal = casualties.reduce(0) { $0 + $1.completedAssessments.count }
        let assessment = Int((Double(assessmentTotal) / Double(casualties.count * Assessment.allCases.count) * 30).rounded())
        let correctTags = casualties.filter { $0.assignedPriority == $0.currentCorrectPriority }.count
        let triage = Int((Double(correctTags) / Double(casualties.count) * 30).rounded())
        let communication = (hazardCommunicated ? 8 : 0) + (resourceRequestSent ? 7 : 0)
        return ScoreBreakdown(safety: safety, assessment: assessment, triage: triage, communication: communication)
    }

    var coachReview: [String] {
        var review: [String] = []
        if sceneSurveyed && hazardIdentified {
            review.append("You prioritised scene safety by surveying the incident and identifying the fuel leak before completing triage.")
        } else if !hazardIdentified {
            review.append("The leaking-fuel hazard was not identified. In your next attempt, pause for a full scene survey before approaching casualties.")
        } else {
            review.append("You found the primary hazard, but did not explicitly complete the scene survey. Use a deliberate 360° scan at the outset.")
        }
        if hazardIdentified && !hazardCommunicated {
            review.append("You identified the fuel leak but did not report it to incident command. Hazard recognition and communication are separate operational actions.")
        }
        let missedAssessments = casualties.reduce(0) { $0 + (Assessment.allCases.count - $1.completedAssessments.count) }
        if missedAssessments == 0 {
            review.append("All four assessment categories were completed for every casualty, giving your triage decisions a strong evidence base.")
        } else {
            review.append("\(missedAssessments) assessment step\(missedAssessments == 1 ? " was" : "s were") omitted. Complete response, breathing, perfusion, and injury checks consistently.")
        }
        let incorrect = casualties.filter { $0.assignedPriority != $0.currentCorrectPriority }
        if incorrect.isEmpty {
            review.append("All final triage priorities matched the casualties’ condition at scenario end.")
        } else {
            review.append("Review the final priority for \(incorrect.map(\.name).joined(separator: ", ")). Conditions can change, so reassessment matters.")
        }
        if deteriorationTriggered {
            let casualty = casualties.first(where: { $0.id == "casualty-b" })!
            if casualty.assignedPriority == casualty.currentCorrectPriority {
                review.append("You responded correctly to Jordan’s deterioration and left an appropriate final priority.")
            } else {
                review.append("Jordan deteriorated at \(deteriorationTimestamp); the final tag was not updated to P1. Revisit casualties when new audio or visual cues appear.")
            }
        }
        if !resourceRequestSent {
            review.append("No additional resources were requested. Communicate early when incident scale or hazards exceed the initial response capacity.")
        }
        return review
    }

    private var deteriorationTimestamp: String {
        events.first(where: { $0.category == "Deterioration" })?.timestamp ?? "the midpoint"
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt, self.phase == .active else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                if self.elapsed >= 75, !self.deteriorationTriggered {
                    self.triggerDeterioration()
                }
            }
        }
    }

    private func triggerDeterioration() {
        guard let index = casualties.firstIndex(where: { $0.id == "casualty-b" }) else { return }
        deteriorationTriggered = true
        casualties[index].isDeteriorated = true
        casualties[index].completedAssessments = []
        record("Deterioration", "Jordan’s breathing became laboured and responsiveness decreased. Reassessment required.", positive: nil)
        let announcement = AVSpeechUtterance(string: "Condition change. Casualty B requires reassessment.")
        announcement.rate = 0.48
        announcement.volume = 0.9
        voice.speak(announcement)
    }

    private func record(_ category: String, _ detail: String, positive: Bool? = nil) {
        let eventElapsed = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        events.append(SessionEvent(elapsed: eventElapsed, category: category, detail: detail, isPositive: positive))
    }

    static func makeCasualties() -> [Casualty] {
        [
            Casualty(
                id: "casualty-a", name: "Alex", location: "Near the blue marker",
                initialFindings: [
                    .response: "Alert and follows commands.", .breathing: "24 breaths/minute.",
                    .perfusion: "Radial pulse present; capillary refill 2 seconds.", .injuries: "Open lower-leg fracture with controlled bleeding."
                ], deterioratedFindings: [:], correctInitialPriority: .p2, correctDeterioratedPriority: nil
            ),
            Casualty(
                id: "casualty-b", name: "Jordan", location: "Beside the purple marker",
                initialFindings: [
                    .response: "Responds to voice but appears confused.", .breathing: "22 breaths/minute.",
                    .perfusion: "Radial pulse present; skin cool.", .injuries: "Blunt chest injury and bruising."
                ],
                deterioratedFindings: [
                    .response: "Responds only to pain.", .breathing: "34 breaths/minute and laboured.",
                    .perfusion: "Weak radial pulse; capillary refill 4 seconds.", .injuries: "Chest movement is asymmetrical."
                ], correctInitialPriority: .p2, correctDeterioratedPriority: .p1
            ),
            Casualty(
                id: "casualty-c", name: "Sam", location: "Near the teal marker",
                initialFindings: [
                    .response: "Alert, anxious, and able to walk.", .breathing: "18 breaths/minute.",
                    .perfusion: "Strong radial pulse; capillary refill under 2 seconds.", .injuries: "Superficial forearm lacerations."
                ], deterioratedFindings: [:], correctInitialPriority: .p3, correctDeterioratedPriority: nil
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
                        Text("3. Assign and revise triage priorities")
                        Text("4. Communicate risks and resource requirements")
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

                HStack(spacing: 14) {
                    ScoreCard(title: "Safety", score: session.score.safety, maximum: 25)
                    ScoreCard(title: "Assessment", score: session.score.assessment, maximum: 30)
                    ScoreCard(title: "Triage", score: session.score.triage, maximum: 30)
                    ScoreCard(title: "Communication", score: session.score.communication, maximum: 15)
                }

                GroupBox("AI coach summary") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(session.coachReview.enumerated()), id: \.offset) { _, item in
                            Label(item, systemImage: "sparkles")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Decision timeline") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(session.events) { EventRow(event: $0) }
                    }
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

    var body: some View {
        RealityView { content, attachments in
            content.add(makeScene())
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
            if casualty.id == "casualty-b", let marker = root.findEntity(named: "condition-casualty-b") as? ModelEntity {
                marker.isEnabled = casualty.isDeteriorated
            }
        }
    }

    private func makeScene() -> Entity {
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

        root.addChild(makeVehicle(position: [-2.4, -0.75, -4.2], colour: .systemBlue, rotation: -0.22))
        root.addChild(makeVehicle(position: [2.0, -0.75, -4.4], colour: .darkGray, rotation: 0.3))

        root.addChild(makeCasualty(id: "casualty-a", locatorColour: .systemBlue, position: [-1.55, -1.08, -2.25]))
        root.addChild(makeCasualty(id: "casualty-b", locatorColour: .systemPurple, position: [0.1, -1.08, -3.15]))
        root.addChild(makeCasualty(id: "casualty-c", locatorColour: .systemTeal, position: [1.55, -1.08, -2.2]))
        root.addChild(makeHazard())
        return root
    }

    private func makeVehicle(position: SIMD3<Float>, colour: UIColor, rotation: Float) -> Entity {
        let vehicle = Entity()
        vehicle.position = position
        vehicle.orientation = simd_quatf(angle: rotation, axis: [0, 1, 0])
        let body = ModelEntity(mesh: .generateBox(width: 1.7, height: 0.75, depth: 0.85, cornerRadius: 0.12), materials: [SimpleMaterial(color: colour, isMetallic: true)])
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

    private func makeCasualty(id: String, locatorColour: UIColor, position: SIMD3<Float>) -> Entity {
        let casualty = Entity()
        casualty.name = id
        casualty.position = position
        casualty.components.set(InputTargetComponent())
        casualty.components.set(CollisionComponent(shapes: [.generateBox(size: [1.65, 0.55, 0.6])]))
        casualty.components.set(HoverEffectComponent())

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
        let locatorMaterial = SimpleMaterial(color: locatorColour, isMetallic: false)
        let pole = ModelEntity(mesh: .generateBox(width: 0.025, height: 0.55, depth: 0.025), materials: [locatorMaterial])
        pole.position = [0, 0.42, 0]
        let locator = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [locatorMaterial])
        locator.position = [0, 0.72, 0]
        casualty.addChild(pole); casualty.addChild(locator)

        let tag = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.2, depth: 0.025, cornerRadius: 0.025), materials: [SimpleMaterial(color: .white, isMetallic: false)])
        tag.name = "tag-\(id)"
        tag.position = [0, 0.25, 0]
        tag.isEnabled = false
        casualty.addChild(tag)

        let alert = ModelEntity(mesh: .generateSphere(radius: 0.09), materials: [SimpleMaterial(color: .systemRed, isMetallic: false)])
        alert.name = "condition-\(id)"
        alert.position = [-0.68, 0.38, 0]
        alert.isEnabled = false
        casualty.addChild(alert)
        return casualty
    }

    private func uiColour(_ priority: TriagePriority) -> UIColor {
        switch priority {
        case .p1: .systemRed
        case .p2: .systemOrange
        case .p3: .systemGreen
        case .deceased: .black
        }
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
                if session.deteriorationTriggered {
                    Label("A casualty’s condition has changed", systemImage: "waveform.path.ecg")
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
}
