import Combine
import Foundation
@preconcurrency import GroupActivities

struct TriageIncidentActivity: GroupActivity {
    var metadata: GroupActivityMetadata {
        get async {
            var metadata = GroupActivityMetadata()
            metadata.title = "TriageXR Incident Command"
            metadata.subtitle = "Train as a coordinated multi-casualty response team"
            metadata.type = .generic
            return metadata
        }
    }
}

extension ResponderRole: SpatialTemplateRole {}

enum CollaborationStatus: Equatable {
    case solo
    case preparing
    case waitingForSession
    case shared(host: Bool)
    case failed(String)

    var title: String {
        switch self {
        case .solo: "Solo incident"
        case .preparing: "Preparing SharePlay"
        case .waitingForSession: "Waiting for participants"
        case .shared(let host): host ? "Shared incident host" : "Shared incident responder"
        case .failed: "SharePlay unavailable"
        }
    }

    var isShared: Bool {
        if case .shared = self { return true }
        return false
    }
}

@MainActor
final class IncidentCollaborationCoordinator: ObservableObject {
    @Published private(set) var status: CollaborationStatus = .solo
    @Published private(set) var participantCount = 1
    @Published private(set) var participantRoles: [UUID: ResponderRole] = [:]
    @Published var localRole: ResponderRole = .incidentCommander {
        didSet { announceLocalRole() }
    }
    @Published var notice: String?

    private let trainingSession: TrainingSession
    private var groupSession: GroupSession<TriageIncidentActivity>?
    private var reliableMessenger: GroupSessionMessenger?
    private var stateMessenger: GroupSessionMessenger?
    private var sessionTask: Task<Void, Never>?
    private var reliableMessageTask: Task<Void, Never>?
    private var stateMessageTask: Task<Void, Never>?
    private var coordinatorTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var hasReceivedHostSnapshot = false
    private var lastBroadcastPhase: ScenarioPhase?

    init(trainingSession: TrainingSession) {
        self.trainingSession = trainingSession
        trainingSession.didChange = { [weak self] snapshot in
            self?.sessionDidChange(snapshot)
        }
        listenForSessions()
    }

    deinit {
        sessionTask?.cancel()
        reliableMessageTask?.cancel()
        stateMessageTask?.cancel()
        coordinatorTask?.cancel()
    }

    var isShared: Bool { status.isShared }

    var isHost: Bool {
        guard case .shared(let host) = status else { return false }
        return host
    }

    var canBeginIncident: Bool {
        !isShared || (isHost && (localRole == .incidentCommander || localRole == .instructor))
    }

    func activateSharePlay() async {
        notice = nil
        status = .preparing
        let activity = TriageIncidentActivity()

        switch await activity.prepareForActivation() {
        case .activationPreferred:
            do {
                let activated = try await activity.activate()
                status = activated ? .waitingForSession : .solo
                if !activated {
                    notice = "SharePlay was not started. The incident remains available in solo mode."
                }
            } catch {
                status = .failed("Could not start SharePlay.")
                notice = "SharePlay activation failed. Check FaceTime or nearby-sharing availability."
            }
        case .activationDisabled:
            status = .failed("Group Activities are disabled.")
            notice = "Enable SharePlay for this device, then try again."
        case .cancelled:
            status = .solo
            notice = "SharePlay invitation cancelled."
        @unknown default:
            status = .failed("Unexpected SharePlay state.")
        }
    }

    func leaveSharePlay() {
        groupSession?.leave()
        clearSession()
        notice = "Left the shared incident."
    }

    func submit(_ command: IncidentCommand) {
        notice = nil

        if isShared, command.isLocalNavigation {
            trainingSession.applyLocalNavigation(command)
            return
        }

        guard isShared else {
            trainingSession.apply(command, actorRole: localRole)
            return
        }

        guard command.isPermitted(for: localRole) else {
            notice = command.permissionDescription
            if isHost {
                trainingSession.recordRoleRejection(command, actorRole: localRole)
            } else {
                send(.command(command, localRole))
            }
            return
        }

        if isHost {
            trainingSession.apply(command, actorRole: localRole)
        } else {
            send(.command(command, localRole))
        }
    }

    private func listenForSessions() {
        sessionTask = Task { [weak self] in
            for await session in TriageIncidentActivity.sessions() {
                guard let self, !Task.isCancelled else { return }
                await configure(session)
            }
        }
    }

    private func configure(_ session: GroupSession<TriageIncidentActivity>) async {
        clearSession(leave: false, resumeLocalClock: false)
        groupSession = session
        reliableMessenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
        stateMessenger = GroupSessionMessenger(session: session, deliveryMode: .unreliable)
        status = .shared(host: session.isLocallyInitiated)
        participantRoles[session.localParticipant.id] = localRole

        session.$activeParticipants
            .receive(on: RunLoop.main)
            .sink { [weak self] participants in
                guard let self else { return }
                let activeIDs = Set(participants.map(\.id)).union([session.localParticipant.id])
                participantCount = activeIDs.count
                participantRoles = participantRoles.filter { activeIDs.contains($0.key) }
                participantRoles[session.localParticipant.id] = localRole
            }
            .store(in: &cancellables)

        session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                if case .invalidated = state {
                    self?.clearSession(leave: false)
                }
            }
            .store(in: &cancellables)

        reliableMessageTask = listenForMessages(on: reliableMessenger)
        stateMessageTask = listenForMessages(on: stateMessenger)

        if let systemCoordinator = await session.systemCoordinator {
            var configuration = SystemCoordinator.Configuration()
            configuration.supportsGroupImmersiveSpace = true
            configuration.spatialTemplatePreference = .surround
            systemCoordinator.configuration = configuration
            systemCoordinator.assignRole(localRole)
        } else {
            notice = "Shared incident state is available, but spatial Persona placement is unavailable."
        }

        session.join()
        announceLocalRole()
        if session.isLocallyInitiated {
            let snapshot = trainingSession.sharedSnapshot()
            lastBroadcastPhase = snapshot.phase
            sendReliable(.snapshot(snapshot))
        } else {
            sendReliable(.requestSnapshot)
        }
    }

    private func listenForMessages(
        on messenger: GroupSessionMessenger?
    ) -> Task<Void, Never>? {
        guard let messenger else { return nil }
        return Task { [weak self] in
            guard let self else { return }
            for await (message, context) in messenger.messages(of: IncidentMessage.self) {
                guard !Task.isCancelled else { return }
                handle(message, from: context.source)
            }
        }
    }

    private func handle(_ message: IncidentMessage, from participant: Participant) {
        switch message {
        case .command(let command, let announcedRole):
            guard isHost else { return }
            let role = participantRoles[participant.id] ?? announcedRole
            participantRoles[participant.id] = role
            guard command.isPermitted(for: role) else {
                trainingSession.recordRoleRejection(command, actorRole: role)
                notice = "\(role.title)'s request to \(command.actionTitle) was rejected."
                send(
                    .rejection(command.permissionDescription),
                    to: .only(participant)
                )
                return
            }
            trainingSession.apply(command, actorRole: role)

        case .snapshot(let snapshot):
            guard !isHost else { return }
            trainingSession.applySharedSnapshot(snapshot, force: !hasReceivedHostSnapshot)
            hasReceivedHostSnapshot = true

        case .requestSnapshot:
            guard isHost else { return }
            sendReliable(
                .snapshot(trainingSession.sharedSnapshot()),
                to: .only(participant)
            )

        case .announceRole(let announcement):
            participantRoles[participant.id] = announcement.role

        case .rejection(let message):
            notice = message
        }
    }

    private func announceLocalRole() {
        guard let session = groupSession else { return }
        participantRoles[session.localParticipant.id] = localRole
        send(
            .announceRole(
                RoleAnnouncement(role: localRole)
            )
        )

        coordinatorTask?.cancel()
        coordinatorTask = Task {
            guard let coordinator = await session.systemCoordinator else { return }
            coordinator.assignRole(localRole)
        }
    }

    private func sessionDidChange(_ snapshot: SharedIncidentSnapshot) {
        guard isShared, isHost else { return }
        let requiresReliableDelivery = IncidentSnapshotDeliveryPolicy
            .requiresReliableDelivery(
                previousPhase: lastBroadcastPhase,
                currentPhase: snapshot.phase
            )
        lastBroadcastPhase = snapshot.phase
        if requiresReliableDelivery {
            sendReliable(.snapshot(snapshot))
        } else {
            sendState(.snapshot(snapshot))
        }
    }

    private func send(
        _ message: IncidentMessage,
        to participants: Participants = .all
    ) {
        sendReliable(message, to: participants)
    }

    private func sendReliable(
        _ message: IncidentMessage,
        to participants: Participants = .all
    ) {
        send(message, to: participants, on: reliableMessenger)
    }

    private func sendState(
        _ message: IncidentMessage,
        to participants: Participants = .all
    ) {
        send(message, to: participants, on: stateMessenger)
    }

    private func send(
        _ message: IncidentMessage,
        to participants: Participants,
        on messenger: GroupSessionMessenger?
    ) {
        guard let messenger else { return }
        Task { [weak self] in
            do {
                try await messenger.send(message, to: participants)
            } catch is CancellationError {
                return
            } catch {
                self?.notice = "A shared incident update could not be delivered."
            }
        }
    }

    private func clearSession(
        leave: Bool = true,
        resumeLocalClock: Bool = true
    ) {
        if leave { groupSession?.leave() }
        cancellables.removeAll()
        reliableMessageTask?.cancel()
        reliableMessageTask = nil
        stateMessageTask?.cancel()
        stateMessageTask = nil
        coordinatorTask?.cancel()
        coordinatorTask = nil
        groupSession = nil
        reliableMessenger = nil
        stateMessenger = nil
        participantRoles = [:]
        participantCount = 1
        hasReceivedHostSnapshot = false
        lastBroadcastPhase = nil
        status = .solo
        if resumeLocalClock {
            trainingSession.resumeLocalClockIfNeeded()
        }
    }
}
