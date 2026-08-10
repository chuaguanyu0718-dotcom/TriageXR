import Foundation
import Combine

enum AICoachSource: Equatable {
    case localEvidence
    case groundedAI

    var title: String {
        switch self {
        case .localEvidence: "Local evidence coach"
        case .groundedAI: "AI coach · evidence grounded"
        }
    }

    var systemImage: String {
        switch self {
        case .localEvidence: "checkmark.shield.fill"
        case .groundedAI: "sparkles"
        }
    }
}

enum AICoachRelayError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case serverStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The coach relay URL is not a valid HTTPS endpoint."
        case .invalidResponse: "The coach relay returned an invalid response."
        case .responseTooLarge: "The coach relay response exceeded the safety limit."
        case let .serverStatus(status): "The coach relay returned status \(status)."
        }
    }
}

struct AICoachRelayClient {
    static let maximumResponseBytes = 64 * 1024

    let endpoint: URL

    init?(bundle: Bundle = .main) {
        guard let rawValue = bundle.object(forInfoDictionaryKey: "TRIAGEXRCoachURL") as? String else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        endpoint = url
    }

    init(endpoint: URL) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw AICoachRelayError.invalidEndpoint
        }
        self.endpoint = endpoint
    }

    func report(for coachRequest: AICoachRequest) async throws -> AICoachReport {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Client-Request-Id")
        request.httpBody = try JSONEncoder().encode(coachRequest)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AICoachRelayError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw AICoachRelayError.serverStatus(httpResponse.statusCode)
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw AICoachRelayError.responseTooLarge
        }

        let report = try JSONDecoder().decode(AICoachReport.self, from: data)
        return try report.validated(against: coachRequest)
    }
}

@MainActor
final class AICoachCoordinator: ObservableObject {
    @Published private(set) var report: AICoachReport?
    @Published private(set) var source: AICoachSource = .localEvidence
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage = "Building the evidence review…"

    private let relayClient: AICoachRelayClient?
    private var currentSignature: String?
    private var requestSessionID = UUID()

    var relayIsConfigured: Bool { relayClient != nil }

    init(relayClient: AICoachRelayClient? = AICoachRelayClient()) {
        self.relayClient = relayClient
    }

    func generate(for session: TrainingSession, force: Bool = false) async {
        let signature = Self.signature(for: session)
        guard force || signature != currentSignature else { return }

        if signature != currentSignature {
            requestSessionID = UUID()
        }
        currentSignature = signature

        let request = AICoachRequest(
            sessionID: requestSessionID,
            scenario: "\(session.scenario.title) · content v\(session.scenario.version)",
            trainingMode: session.trainingMode,
            scenarioPace: session.scenarioPace,
            score: session.score,
            evidence: session.decisionEvidence
        )

        do {
            report = try AICoachReport.localFallback(for: request)
            source = .localEvidence
        } catch {
            report = nil
            source = .localEvidence
            statusMessage = "No recorded decision evidence is available for coaching."
            isLoading = false
            return
        }

        guard let relayClient else {
            statusMessage = "Secure AI relay not configured — showing deterministic local coaching."
            isLoading = false
            return
        }

        isLoading = true
        statusMessage = "Rewriting verified findings into a concise grounded debrief…"
        defer { isLoading = false }

        do {
            report = try await relayClient.report(for: request)
            source = .groundedAI
            statusMessage = "Every coaching point is linked to the replay evidence below."
        } catch is CancellationError {
            statusMessage = "AI request cancelled — deterministic local coaching remains available."
        } catch {
            source = .localEvidence
            statusMessage = "AI relay unavailable — deterministic local coaching remains available."
        }
    }

    private static func signature(for session: TrainingSession) -> String {
        let lastID = session.decisionEvidence.last?.id.uuidString.lowercased() ?? "none"
        return "\(session.decisionEvidence.count)-\(lastID)-\(session.score.total)-\(session.trainingMode.rawValue)-\(session.scenarioPace.rawValue)"
    }
}
