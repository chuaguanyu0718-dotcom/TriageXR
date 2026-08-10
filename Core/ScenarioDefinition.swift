import Foundation

struct ScenarioObjective: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
}

struct CasualtyTemplate: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let location: String
    let initialFindings: [Assessment: String]
    let deterioratedFindings: [Assessment: String]
    let correctInitialPriority: TriagePriority
    let correctDeterioratedPriority: TriagePriority?
    let initialHealth: Double
    let deteriorationProfile: DeteriorationProfile

    func makeCasualty() -> Casualty {
        Casualty(
            id: id,
            name: name,
            location: location,
            initialFindings: initialFindings,
            deterioratedFindings: deterioratedFindings,
            correctInitialPriority: correctInitialPriority,
            correctDeterioratedPriority: correctDeterioratedPriority,
            initialHealth: initialHealth,
            deteriorationProfile: deteriorationProfile,
            health: initialHealth
        )
    }
}

struct ScenarioDefinition: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let version: Int
    let title: String
    let subtitle: String
    let dispatch: String
    let objectives: [ScenarioObjective]
    let casualties: [CasualtyTemplate]
    let trainingBoundary: String

    func validated() throws -> ScenarioDefinition {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              version > 0,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dispatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !objectives.isEmpty,
              !casualties.isEmpty,
              Set(casualties.map(\.id)).count == casualties.count,
              casualties.allSatisfy({ (0...100).contains($0.initialHealth) }),
              casualties.allSatisfy({ Set($0.initialFindings.keys) == Set(Assessment.allCases) }),
              casualties.allSatisfy(Self.hasValidDeteriorationThresholds) else {
            throw ScenarioDefinitionError.invalidContent
        }
        return self
    }

    func makeCasualties() -> [Casualty] {
        casualties.map { $0.makeCasualty() }
    }

    private static func hasValidDeteriorationThresholds(_ casualty: CasualtyTemplate) -> Bool {
        guard case let .untreatedCardiacArrest(neurologicalRiskAfter, deathAfter)
            = casualty.deteriorationProfile else {
            return true
        }
        return neurologicalRiskAfter > 0 && deathAfter > neurologicalRiskAfter
    }
}

enum ScenarioDefinitionError: Error, Equatable {
    case invalidContent
}

enum ScenarioCatalog {
    static let roadsideFoundation = ScenarioDefinition(
        id: "roadside-foundation",
        version: 1,
        title: "Roadside multi-casualty response",
        subtitle: "Spatial incident command, triage, and team coordination",
        dispatch: "Road traffic collision. Three casualties reported. Fuel is leaking near the vehicle. One casualty may deteriorate rapidly.",
        objectives: [
            ScenarioObjective(
                id: "survey",
                title: "Survey before entry",
                detail: "Build a verified 360° head-direction coverage map and identify hazards.",
                icon: "view.360"
            ),
            ScenarioObjective(
                id: "assess",
                title: "Assess spatially",
                detail: "Use sustained hand poses at anatomical markers to reveal findings.",
                icon: "hand.raised.fingers.spread.fill"
            ),
            ScenarioObjective(
                id: "prioritise",
                title: "Prioritise and act",
                detail: "Tag all casualties and protect time-critical treatment coverage.",
                icon: "tag.fill"
            ),
            ScenarioObjective(
                id: "coordinate",
                title: "Coordinate the response",
                detail: "Report hazards, request resources, and collaborate by assigned role.",
                icon: "person.3.fill"
            )
        ],
        casualties: [
            CasualtyTemplate(
                id: "casualty-a",
                name: "Alex",
                location: "Near the blue marker",
                initialFindings: [
                    .response: "Unresponsive to voice and pain.",
                    .breathing: "12 breaths/minute and regular.",
                    .perfusion: "Radial pulse present; skin warm.",
                    .injuries: "No visible external injury."
                ],
                deterioratedFindings: [:],
                correctInitialPriority: .p1,
                correctDeterioratedPriority: nil,
                initialHealth: 100,
                deteriorationProfile: .none
            ),
            CasualtyTemplate(
                id: "casualty-b",
                name: "Jordan",
                location: "Beside the purple marker",
                initialFindings: [
                    .response: "Unresponsive to voice and pain.",
                    .breathing: "Not breathing normally.",
                    .perfusion: "No palpable pulse or spontaneous circulation.",
                    .injuries: "No obvious external injury."
                ],
                deterioratedFindings: [
                    .response: "Unresponsive to voice and pain.",
                    .breathing: "Not breathing normally.",
                    .perfusion: "No palpable pulse or spontaneous circulation.",
                    .injuries: "Visible oxygen-deprivation signs are worsening."
                ],
                correctInitialPriority: .p1,
                correctDeterioratedPriority: .p1,
                initialHealth: 60,
                deteriorationProfile: .untreatedCardiacArrest(
                    neurologicalRiskAfter: ScenarioRules.neurologicalRiskAfter,
                    deathAfter: ScenarioRules.deathAfter
                )
            ),
            CasualtyTemplate(
                id: "casualty-c",
                name: "Sam",
                location: "Near the teal marker",
                initialFindings: [
                    .response: "Alert and follows commands.",
                    .breathing: "20 breaths/minute and regular.",
                    .perfusion: "Radial pulse present; capillary refill 2 seconds.",
                    .injuries: "Visible limb injury with controlled bleeding."
                ],
                deterioratedFindings: [:],
                correctInitialPriority: .p2,
                correctDeterioratedPriority: nil,
                initialHealth: 50,
                deteriorationProfile: .none
            )
        ],
        trainingBoundary: "Simulation coaching only — not clinical guidance, medical-device output, or certification. Follow local protocols and instructor direction."
    )
}

struct InstructorCompetencyResult: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let status: String
    let evidence: String
}

struct InstructorCasualtyResult: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let assignedPriority: TriagePriority?
    let expectedPriority: TriagePriority
    let completedAssessments: Set<Assessment>
    let effectiveCPRSeconds: TimeInterval
    let outcome: String
}

struct InstructorSessionReport: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let scenarioID: String
    let scenarioVersion: Int
    let scenarioTitle: String
    let trainingMode: TrainingMode
    let scenarioPace: ScenarioPace
    let exerciseElapsedSeconds: TimeInterval
    let score: ScoreBreakdown
    let responseTempo: ResponseTempo
    let surveyCoveragePercent: Int
    let coveredSurveyBins: [Int]
    let competencies: [InstructorCompetencyResult]
    let casualties: [InstructorCasualtyResult]
    let events: [SessionEvent]
    let decisionEvidence: [DecisionEvidence]
    let trainingBoundary: String
}
