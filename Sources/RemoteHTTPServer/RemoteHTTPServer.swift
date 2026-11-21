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
        let projectRegistry = try RemoteProjectRegistry.load(
            projectsPath: configuration.projectsPath,
            creationRootsPath: configuration.creationRootsPath
        )
        let projects = await projectRegistry.projects()
        let codexPath = ProcessInfo.processInfo.environment["REMOTE_CODEX_PATH"]
            ?? "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let conversations = RemoteConversationCatalog(
            reader: RemoteCLIConversationsReader(codexPath: codexPath, claudePath: configuration.claudeExecutablePath),
            repository: repository, projectRegistry: projectRegistry
        )
        let approvalService = ApprovalService(
            repository: repository,
            timeout: configuration.timeout,
            resumableTimeout: configuration.resumableTimeout,
            resumableWaitTimeout: configuration.resumableWaitTimeout
        )
        let claudeService = RemoteClaudeJobService(
            repository: repository,
            runner: RemoteAgentRunner(
                claude: ClaudeCLIRunner(executablePath: configuration.claudeExecutablePath),
                codexPath: codexPath,
                mcpServerPath: configuration.mcpServerPath,
                mcpDatabasePath: configuration.databasePath,
                projects: projects,
                projectRegistry: projectRegistry,
                conversations: conversations,
                repository: repository
            ),
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
            push: pushContext,
            agentRepository: repository,
            projects: projects,
            projectRegistry: projectRegistry,
            codexAppPath: codexPath,
            usage: RemoteUsageService(reader: RemoteCLIUsageReader(
                codexPath: codexPath, claudePath: configuration.claudeExecutablePath
            )),
            conversations: conversations
        )

        if let bridgeToken = configuration.bridgeToken, configuration.isLoopbackHost {
            let bridgeJobsPath = URL(fileURLWithPath: configuration.databasePath)
                .deletingLastPathComponent()
                .appendingPathComponent("agent-bridge-jobs.sqlite")
                .path
            let bridgeJobRepository = try SQLiteAgentBridgeJobRepository(path: bridgeJobsPath)
            let bridgeConversations = RemoteConversationCatalog(
                reader: RemoteCLIConversationsReader(codexPath: codexPath, claudePath: configuration.claudeExecutablePath),
                repository: bridgeJobRepository, projectRegistry: projectRegistry
            )
            let bridgeJobService = AgentBridgeJobService(
                repository: bridgeJobRepository,
                runner: RemoteAgentRunner(
                    claude: ClaudeCLIRunner(executablePath: configuration.claudeExecutablePath),
                    codexPath: codexPath,
                    mcpServerPath: configuration.mcpServerPath,
                    mcpDatabasePath: configuration.databasePath,
                    projects: projects,
                    projectRegistry: projectRegistry,
                    conversations: bridgeConversations,
                    repository: bridgeJobRepository
                ),
                workingDirectory: configuration.claudeWorkingDirectory
            )
            try await bridgeJobService.start()
            configureRemoteBridgeHTTPRoutes(
                app: app,
                claudeService: bridgeJobService,
                approvalService: approvalService,
                authorization: ApprovalHTTPAuthorization(token: bridgeToken),
                projects: projects,
                projectRegistry: projectRegistry,
                conversations: bridgeConversations,
                usage: RemoteUsageService(reader: RemoteCLIUsageReader(
                    codexPath: codexPath, claudePath: configuration.claudeExecutablePath
                ))
            )
            app.logger.info("Remote Agent Bridge is enabled on the local HTTP server.")
        } else if configuration.bridgeToken != nil {
            app.logger.error("Remote Agent Bridge is disabled because REMOTE_HOST is not loopback.")
        }

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
