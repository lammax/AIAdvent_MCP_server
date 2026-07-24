# AGENTS.md - MCP_server

Rules for AI agents working in this repository.

This package is the shared local MCP server base for WorkHarness and related local AI tooling.

## Core Rule

Add new MCP servers strictly using the same package shape that existing servers use.

Do not introduce a second package layout, transport style, entrypoint style, or ad hoc server structure unless the user explicitly changes the architecture first.

## Existing Server Pattern

When adding a new MCP server:

- Add a matching `.executable` product in `Package.swift`.
- Add a matching `.executableTarget` in `Package.swift`.
- Name the target `<Name>MCPServer`.
- Place the entrypoint at `Sources/<Name>MCPServer/<Name>MCPServer.swift`.
- Depend on `Shared`, Vapor and MCP the same way existing executable targets do.
- Create the server through `MCP.Server(...)`.
- Register tools through `ListTools`.
- Execute tools through `CallTool`.
- Expose HTTP through Vapor with `StatelessHTTPServerTransport`.
- Mount the MCP endpoint at `POST /mcp`.
- Use `Shared/bridge/MCPHTTPBridge.swift` for Vapor/MCP request and response mapping.
- Keep reusable domain logic, DTOs, service helpers, bridges and database code in `Sources/Shared/...`.

Reference examples:

- `Sources/GitHubMCPServer/GitHubMCPServer.swift`
- `Sources/FileOperationsMCPServer/FileOperationsMCPServer.swift`
- `Sources/MobileAutomationMCPServer/MobileAutomationMCPServer.swift`
- `Sources/RAGMCPServer/RAGMCPServer.swift`
- `Sources/SupportMCPServer/SupportMCPServer.swift`
- `Sources/UtilityMCPServer/UtilityMCPServer.swift`
- `Sources/VisionBackendServer/VisionBackendServer.swift`

## WorkHarness Provider Rule

WorkHarness AI providers must integrate through MCP-backed provider adapters.

Provider-specific implementation details belong in this repository, not inside WorkHarness:

- Codex CLI execution.
- Cursor CLI execution.
- local LLM execution such as Ollama, Qwen or llama.cpp-style backends.
- provider HTTP payloads and retry/health behavior.
- model listing and capability mapping.

The existing local LLM implementation at `/Users/lammax/Documents/ThisIsMy/Programming/AI/LlamaLocalServer` should be migrated or wrapped into this package when local LLM MCP support is implemented.

## Safety

Tools that touch local files, git, shell commands, network calls, credentials or external processes must keep their behavior explicit and auditable.

Prefer project-root scoped paths and configuration through arguments/environment variables, following the existing server examples.

Do not add hidden background side effects to `ListTools`; execution belongs in `CallTool`.

## Validation

After Swift changes, run:

```bash
swift build
```

If a change affects an executable target, make sure that target still builds through the package.

Do not commit or push unless the user explicitly asks.
