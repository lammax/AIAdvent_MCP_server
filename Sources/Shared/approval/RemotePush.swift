import Foundation

public struct RemotePushSubscription: Codable, Equatable, Sendable {
    public let id: UUID
    public let endpoint: String
    public let p256dh: String
    public let auth: String
    public let applicationServerKey: String?
    public let vapidKeyFingerprint: String?
    public let deviceLabel: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let active: Bool

    public init(
        id: UUID = UUID(),
        endpoint: String,
        p256dh: String,
        auth: String,
        applicationServerKey: String? = nil,
        vapidKeyFingerprint: String? = nil,
        deviceLabel: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        active: Bool = true
    ) {
        self.id = id
        self.endpoint = endpoint
        self.p256dh = p256dh
        self.auth = auth
        self.applicationServerKey = applicationServerKey
        self.vapidKeyFingerprint = vapidKeyFingerprint
        self.deviceLabel = deviceLabel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.active = active
    }
}

public enum RemotePushEventKind: String, Codable, Sendable {
    case approvalCreated = "approval_created"
    case test
}

public struct RemotePushNotification: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let eventKind: RemotePushEventKind
    public let approvalID: UUID?
    public let destination: String
    public let title: String
    public let body: String
    public let tag: String

    public init(
        eventID: UUID,
        eventKind: RemotePushEventKind,
        approvalID: UUID?,
        destination: String,
        title: String,
        body: String,
        tag: String
    ) {
        self.eventID = eventID
        self.eventKind = eventKind
        self.approvalID = approvalID
        self.destination = destination
        self.title = title
        self.body = body
        self.tag = tag
    }
}

public struct RemotePushDeliveryClaim: Sendable {
    public let deliveryID: UUID
    public let subscription: RemotePushSubscription
    public let notification: RemotePushNotification
    public let attemptCount: Int

    public init(
        deliveryID: UUID,
        subscription: RemotePushSubscription,
        notification: RemotePushNotification,
        attemptCount: Int
    ) {
        self.deliveryID = deliveryID
        self.subscription = subscription
        self.notification = notification
        self.attemptCount = attemptCount
    }
}

public enum RemotePushSendResult: Equatable, Sendable {
    case delivered
    case invalidSubscription(String?)
    case retryable(String?)
    case permanentFailure(String?)
}

public protocol RemotePushSending: Sendable {
    func send(
        _ notification: RemotePushNotification,
        to subscription: RemotePushSubscription
    ) async -> RemotePushSendResult
}

public protocol RemotePushRepository: Sendable {
    func upsertPushSubscription(
        endpoint: String,
        p256dh: String,
        auth: String,
        applicationServerKey: String?,
        deviceLabel: String?,
        now: Date
    ) async throws -> RemotePushSubscription
    func deactivatePushSubscription(endpoint: String, now: Date) async throws
    func activePushSubscriptions() async throws -> [RemotePushSubscription]
    func enqueueTestPush(now: Date) async throws -> UUID
    func claimNextPushDelivery(now: Date, leaseDuration: TimeInterval) async throws
        -> RemotePushDeliveryClaim?
    func completePushDelivery(id: UUID, now: Date) async throws
    func retryPushDelivery(
        id: UUID,
        now: Date,
        nextAttemptAt: Date,
        error: String?
    ) async throws
    func failPushDelivery(
        id: UUID,
        now: Date,
        error: String?,
        deactivateSubscription: Bool
    ) async throws
}

public actor RemotePushWorker {
    public struct Configuration: Sendable {
        public let pollInterval: Duration
        public let leaseDuration: TimeInterval
        public let maximumAttempts: Int

        public init(
            pollInterval: Duration = .seconds(2),
            leaseDuration: TimeInterval = 30,
            maximumAttempts: Int = 6
        ) {
            self.pollInterval = pollInterval
            self.leaseDuration = leaseDuration
            self.maximumAttempts = maximumAttempts
        }
    }

    private let repository: any RemotePushRepository
    private let sender: any RemotePushSending
    private let configuration: Configuration
    private var task: Task<Void, Never>?

    public init(
        repository: any RemotePushRepository,
        sender: any RemotePushSending,
        configuration: Configuration = .init()
    ) {
        self.repository = repository
        self.sender = sender
        self.configuration = configuration
    }

    public func start() {
        guard task == nil else { return }
        let repository = repository
        let sender = sender
        let configuration = configuration
        task = Task { @concurrent in
            while !Task.isCancelled {
                do {
                    if try await Self.processNext(
                        now: Date(),
                        repository: repository,
                        sender: sender,
                        configuration: configuration
                    ) {
                        continue
                    }
                    try await Task.sleep(for: configuration.pollInterval)
                } catch is CancellationError {
                    break
                } catch {
                    do {
                        try await Task.sleep(for: configuration.pollInterval)
                    } catch {
                        break
                    }
                }
            }
        }
    }

    @discardableResult
    public func processNext(now: Date = Date()) async throws -> Bool {
        try await Self.processNext(
            now: now,
            repository: repository,
            sender: sender,
            configuration: configuration
        )
    }

    public func stop() async {
        let runningTask = task
        task = nil
        runningTask?.cancel()
        await runningTask?.value
    }

    private nonisolated static func processNext(
        now: Date,
        repository: any RemotePushRepository,
        sender: any RemotePushSending,
        configuration: Configuration
    ) async throws -> Bool {
        guard let claim = try await repository.claimNextPushDelivery(
            now: now,
            leaseDuration: configuration.leaseDuration
        ) else {
            return false
        }
        let result = await sender.send(claim.notification, to: claim.subscription)
        try await record(
            result: result,
            claim: claim,
            now: now,
            repository: repository,
            configuration: configuration
        )
        return true
    }

    private nonisolated static func record(
        result: RemotePushSendResult,
        claim: RemotePushDeliveryClaim,
        now: Date,
        repository: any RemotePushRepository,
        configuration: Configuration
    ) async throws {
        switch result {
        case .delivered:
            try await repository.completePushDelivery(id: claim.deliveryID, now: now)
        case .invalidSubscription(let message):
            try await repository.failPushDelivery(
                id: claim.deliveryID,
                now: now,
                error: message,
                deactivateSubscription: true
            )
        case .permanentFailure(let message):
            try await repository.failPushDelivery(
                id: claim.deliveryID,
                now: now,
                error: message,
                deactivateSubscription: false
            )
        case .retryable(let message):
            if claim.attemptCount >= configuration.maximumAttempts {
                try await repository.failPushDelivery(
                    id: claim.deliveryID,
                    now: now,
                    error: message,
                    deactivateSubscription: false
                )
            } else {
                let exponent = min(max(claim.attemptCount - 1, 0), 8)
                let delay = min(pow(2.0, Double(exponent)), 300)
                try await repository.retryPushDelivery(
                    id: claim.deliveryID,
                    now: now,
                    nextAttemptAt: now.addingTimeInterval(delay),
                    error: message
                )
            }
        }
    }
}
