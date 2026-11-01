import Foundation
import Logging
import WebPush

public struct RemoteWebPushPayload: Codable, Sendable {
    public struct Notification: Codable, Sendable {
        public let title: String
        public let body: String
        public let tag: String
        public let destination: String
    }

    public let notification: Notification
}

public final class RemoteWebPushSender: RemotePushSending, Sendable {
    public let publicKey: String
    private let manager: WebPushManager

    public init(configurationPath: String, logger: Logger) throws {
        let path = NSString(string: configurationPath).expandingTildeInPath
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0
        {
            throw RemoteWebPushError.insecureConfigurationPermissions
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let configuration = try JSONDecoder().decode(VAPID.Configuration.self, from: data)
        let manager = WebPushManager(
            vapidConfiguration: configuration,
            backgroundActivityLogger: logger
        )
        self.manager = manager
        self.publicKey = manager.nextVAPIDKeyID.description
    }

    public func send(
        _ notification: RemotePushNotification,
        to subscription: RemotePushSubscription
    ) async -> RemotePushSendResult {
        do {
            guard let endpoint = URL(string: subscription.endpoint),
                  endpoint.scheme?.lowercased() == "https",
                  let applicationServerKey = subscription.applicationServerKey
            else {
                return .permanentFailure("Invalid push subscription.")
            }
            let keyMaterial = try UserAgentKeyMaterial(
                publicKey: subscription.p256dh,
                authenticationSecret: subscription.auth
            )
            let encodedKey = try JSONEncoder().encode(applicationServerKey)
            let vapidKeyID = try JSONDecoder().decode(VAPID.Key.ID.self, from: encodedKey)
            let subscriber = Subscriber(
                endpoint: endpoint,
                userAgentKeyMaterial: keyMaterial,
                vapidKeyID: vapidKeyID
            )
            let payload = RemoteWebPushPayload(
                notification: .init(
                    title: notification.title,
                    body: notification.body,
                    tag: notification.tag,
                    destination: notification.destination
                )
            )
            try await manager.send(
                json: payload,
                to: subscriber,
                encodableDeduplicationTopic: notification.tag
            )
            return .delivered
        } catch is BadSubscriberError {
            return .invalidSubscription("The push subscription is no longer valid.")
        } catch let error as PushServiceError {
            let status = error.response.status.code
            if status == 404 || status == 410 {
                return .invalidSubscription(error.localizedDescription)
            }
            if status == 408 || status == 429 || status >= 500 {
                return .retryable(error.localizedDescription)
            }
            return .permanentFailure(error.localizedDescription)
        } catch is MessageTooLargeError {
            return .permanentFailure("Push payload is too large.")
        } catch {
            return .permanentFailure(String(describing: error))
        }
    }
}

public enum RemoteWebPushError: LocalizedError, Sendable {
    case insecureConfigurationPermissions

    public var errorDescription: String? {
        switch self {
        case .insecureConfigurationPermissions:
            "REMOTE_VAPID_FILE must not be readable or writable by group or other users."
        }
    }
}
