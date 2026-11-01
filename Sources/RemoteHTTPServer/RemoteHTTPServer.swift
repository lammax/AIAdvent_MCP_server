import Foundation
import CryptoKit
import Shared
import Vapor

@main
enum RemoteHTTPServer {
    static func main() async throws {
        let configuration = try RemoteHTTPConfiguration.load()

        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)
        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = configuration.host
        app.http.server.configuration.port = configuration.port

        let repository = try SQLiteApprovalRepository(path: configuration.databasePath)
        let approvalService = ApprovalService(
            repository: repository,
            timeout: configuration.timeout
        )
        let claudeService = RemoteClaudeJobService(
            repository: repository,
            runner: ClaudeCLIRunner(executablePath: configuration.claudeExecutablePath),
            workingDirectory: configuration.claudeWorkingDirectory
        )
        try await claudeService.start()

        let authorization = ApprovalHTTPAuthorization(
            token: configuration.token,
            secureCookies: configuration.usesSecureCookies,
            publicOrigin: configuration.publicOrigin
        )

        let pushWorker: RemotePushWorker?
        let pushContext: RemotePushHTTPContext?
        if FileManager.default.fileExists(atPath: configuration.vapidConfigurationPath) {
            let sender = try RemoteWebPushSender(
                configurationPath: configuration.vapidConfigurationPath,
                logger: app.logger
            )
            let worker = RemotePushWorker(repository: repository, sender: sender)
            await worker.start()
            let fingerprint = SHA256.hash(data: Data(sender.publicKey.utf8))
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            let activeSubscriptionCount = try await repository.activePushSubscriptions().count
            app.logger.info(
                "Web Push is configured.",
                metadata: [
                    "active-subscriptions": "\(activeSubscriptionCount)",
                    "vapid-key-fingerprint": "\(fingerprint)",
                ]
            )
            pushWorker = worker
            pushContext = RemotePushHTTPContext(
                repository: repository,
                publicKey: sender.publicKey
            )
        } else {
            app.logger.warning(
                "Web Push is disabled because REMOTE_VAPID_FILE does not exist."
            )
            pushWorker = nil
            pushContext = nil
        }

        configureApprovalHTTPRoutes(
            app: app,
            service: approvalService,
            authorization: authorization,
            claudeService: claudeService,
            push: pushContext
        )

        do {
            try await app.execute()
            await pushWorker?.stop()
            try await app.asyncShutdown()
        } catch {
            await pushWorker?.stop()
            try? await app.asyncShutdown()
            throw error
        }
    }
}
