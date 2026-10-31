import Foundation
import CryptoKit
import Vapor

public struct ApprovalHTTPAuthorization: Sendable {
    public static let cookieName = "remote-auth"
    private static let sessionLifetime = 60 * 60 * 24 * 90

    private let token: String
    private let sessionToken: String

    public init(token: String) {
        self.token = token
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data("remote-auth-v1".utf8),
            using: SymmetricKey(data: Data(token.utf8))
        )
        self.sessionToken = authenticationCode.map { String(format: "%02x", $0) }.joined()
    }

    public func validate(token candidate: String) -> Bool {
        constantTimeEquals(token, candidate)
    }

    public func isAuthorized(_ request: Request) -> Bool {
        if isBearerAuthorized(request) {
            return true
        }
        guard let cookie = request.cookies[Self.cookieName] else { return false }
        return constantTimeEquals(sessionToken, cookie.string)
    }

    public func isBearerAuthorized(_ request: Request) -> Bool {
        guard let bearer = request.headers.bearerAuthorization else { return false }
        return validate(token: bearer.token)
    }

    public func authorizedCookie() -> HTTPCookies.Value {
        HTTPCookies.Value(
            string: sessionToken,
            expires: Date(timeIntervalSinceNow: TimeInterval(Self.sessionLifetime)),
            maxAge: Self.sessionLifetime,
            domain: nil,
            path: "/",
            isSecure: false,
            isHTTPOnly: true,
            sameSite: .strict
        )
    }

    public func expiredCookie() -> HTTPCookies.Value {
        HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            domain: nil,
            path: "/",
            isSecure: false,
            isHTTPOnly: true,
            sameSite: .strict
        )
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }
}

public func configureApprovalHTTPRoutes(
    app: Application,
    service: ApprovalService,
    authorization: ApprovalHTTPAuthorization,
    claudeService: RemoteClaudeJobService? = nil
) {
    app.get { request in
        request.redirect(to: "/approvals")
    }

    app.get("health") { _ in
        ApprovalHealthResponse(status: "ok")
    }

    app.get("login") { request -> Response in
        if authorization.isAuthorized(request) {
            return request.redirect(to: "/approvals")
        }
        return htmlResponse(ApprovalWebPage.login())
    }

    app.post("login") { request -> Response in
        let login = try request.content.decode(ApprovalLoginRequest.self)
        guard authorization.validate(token: login.token) else {
            return htmlResponse(ApprovalWebPage.login(error: "Invalid token."), status: .unauthorized)
        }
        let response = request.redirect(to: "/approvals")
        response.cookies[ApprovalHTTPAuthorization.cookieName] = authorization.authorizedCookie()
        return response
    }

    app.post("logout") { request -> Response in
        let response = request.redirect(to: "/login")
        response.cookies[ApprovalHTTPAuthorization.cookieName] = authorization.expiredCookie()
        return response
    }

    app.get("approvals") { request -> Response in
        guard authorization.isAuthorized(request) else {
            return request.redirect(to: "/login")
        }
        return htmlResponse(ApprovalWebPage.approvals())
    }

    app.get("approvals", "pending") { request async throws -> ApprovalListResponse in
        try requireAuthorization(request, authorization: authorization)
        let approvals = try await service.pendingApprovals()
        return ApprovalListResponse(approvals: approvals.map(ApprovalResponse.init))
    }

    app.get("approvals", ":approvalID") { request async throws -> ApprovalResponse in
        try requireAuthorization(request, authorization: authorization)
        let id = try approvalID(from: request)
        guard let approval = try await service.approval(id: id) else {
            throw Abort(.notFound, reason: "Approval was not found.")
        }
        return ApprovalResponse(approval)
    }

    app.post("approvals", ":approvalID", "respond") { request async throws -> ApprovalResponse in
        try requireAuthorization(request, authorization: authorization)
        let id = try approvalID(from: request)
        let body = try request.content.decode(ApprovalSubmitResponse.self)
        do {
            let approval: Approval
            if let answers = body.answers {
                approval = try await service.respond(id: id, answers: answers)
            } else {
                let responses = body.responses ?? body.response.map { [$0] } ?? []
                approval = try await service.respond(id: id, responses: responses)
            }
            return ApprovalResponse(approval)
        } catch let error as ApprovalError {
            throw abort(for: error)
        }
    }

    app.get("claude") { request -> Response in
        guard authorization.isAuthorized(request) else {
            return request.redirect(to: "/login")
        }
        guard claudeService != nil else {
            return Response(status: .notFound)
        }
        return htmlResponse(ApprovalWebPage.claude())
    }

    app.get("claude", "jobs") { request async throws -> RemoteClaudeJobListResponse in
        try requireAuthorization(request, authorization: authorization)
        guard let claudeService else { throw Abort(.notFound) }
        return RemoteClaudeJobListResponse(jobs: try await claudeService.recentJobs())
    }

    app.get("claude", "jobs", ":jobID") { request async throws -> RemoteClaudeJobResponse in
        try requireAuthorization(request, authorization: authorization)
        guard let claudeService else { throw Abort(.notFound) }
        guard let rawID = request.parameters.get("jobID"),
              let id = UUID(uuidString: rawID)
        else {
            throw Abort(.badRequest, reason: "Invalid Claude job ID.")
        }
        guard let job = try await claudeService.job(id: id) else {
            throw Abort(.notFound, reason: "Claude job was not found.")
        }
        return RemoteClaudeJobResponse(job)
    }

    app.post("claude", "jobs") { request async throws -> RemoteClaudeJobResponse in
        try requireAuthorization(request, authorization: authorization)
        guard let claudeService else { throw Abort(.notFound) }
        let body = try request.content.decode(RemoteClaudeSubmitRequest.self)
        do {
            return RemoteClaudeJobResponse(try await claudeService.submit(prompt: body.prompt))
        } catch let error as RemoteClaudeJobError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }
    }
}

private func requireAuthorization(
    _ request: Request,
    authorization: ApprovalHTTPAuthorization
) throws {
    guard authorization.isAuthorized(request) else {
        throw Abort(.unauthorized, reason: "Authorization is required.")
    }
}

private func approvalID(from request: Request) throws -> UUID {
    guard let rawID = request.parameters.get("approvalID"),
          let id = UUID(uuidString: rawID)
    else {
        throw Abort(.badRequest, reason: "Invalid approval ID.")
    }
    return id
}

private func abort(for error: ApprovalError) -> Abort {
    switch error {
    case .notFound:
        Abort(.notFound, reason: error.localizedDescription)
    case .alreadyAnswered:
        Abort(.conflict, reason: error.localizedDescription)
    case .expired, .timedOut:
        Abort(.gone, reason: error.localizedDescription)
    case .cancelled:
        Abort(.conflict, reason: error.localizedDescription)
    case .emptyQuestion, .questionTooLong, .invalidQuestionCount, .invalidQuestionID,
         .duplicateQuestionIDs, .invalidOptionCount, .emptyOption,
         .optionTooLong, .duplicateOptions, .emptyResponse, .responseTooLong,
         .invalidResponse:
        Abort(.badRequest, reason: error.localizedDescription)
    }
}

private func htmlResponse(_ html: String, status: HTTPResponseStatus = .ok) -> Response {
    Response(
        status: status,
        headers: [
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "Pragma": "no-cache",
        ],
        body: .init(string: html)
    )
}

private struct ApprovalLoginRequest: Content {
    static let defaultContentType: HTTPMediaType = .urlEncodedForm
    let token: String
}

public struct ApprovalSubmitResponse: Content, Sendable {
    public let response: String?
    public let responses: [String]?
    public let answers: [ApprovalAnswer]?

    public init(
        response: String? = nil,
        responses: [String]? = nil,
        answers: [ApprovalAnswer]? = nil
    ) {
        self.response = response
        self.responses = responses
        self.answers = answers
    }
}

public struct ApprovalHealthResponse: Content, Sendable {
    public let status: String

    public init(status: String) {
        self.status = status
    }
}

public struct ApprovalListResponse: Content, Sendable {
    public let approvals: [ApprovalResponse]

    public init(approvals: [ApprovalResponse]) {
        self.approvals = approvals
    }
}

private struct RemoteClaudeSubmitRequest: Content, Sendable {
    let prompt: String
}

public struct RemoteClaudeJobListResponse: Content, Sendable {
    public let jobs: [RemoteClaudeJobResponse]

    public init(jobs: [RemoteClaudeJob]) {
        self.jobs = jobs.map(RemoteClaudeJobResponse.init)
    }
}

public struct RemoteClaudeJobResponse: Content, Sendable {
    public let id: UUID
    public let prompt: String
    public let workingDirectory: String
    public let status: RemoteClaudeJobStatus
    public let response: String?
    public let errorMessage: String?
    public let sessionID: String?
    public let createdAt: Date
    public let startedAt: Date?
    public let completedAt: Date?

    public init(_ job: RemoteClaudeJob) {
        id = job.id
        prompt = job.prompt
        workingDirectory = job.workingDirectory
        status = job.status
        response = job.response
        errorMessage = job.errorMessage
        sessionID = job.sessionID
        createdAt = job.createdAt
        startedAt = job.startedAt
        completedAt = job.completedAt
    }
}

public struct ApprovalResponse: Content, Sendable {
    public let id: UUID
    public let questions: [ApprovalQuestion]
    public let question: String
    public let kind: ApprovalKind
    public let options: [String]
    public let status: ApprovalStatus
    public let response: String?
    public let responses: [String]
    public let createdAt: Date
    public let expiresAt: Date
    public let answeredAt: Date?

    public init(_ approval: Approval) {
        self.id = approval.id
        self.questions = approval.questions
        self.question = approval.question
        self.kind = approval.kind
        self.options = approval.options
        self.status = approval.status
        self.response = approval.response
        self.responses = approval.responses
        self.createdAt = approval.createdAt
        self.expiresAt = approval.expiresAt
        self.answeredAt = approval.answeredAt
    }
}

private enum ApprovalWebPage {
    static func login(error: String? = nil) -> String {
        let errorMarkup = error.map { "<p class=\"error\">\($0)</p>" } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>Remote Login</title>
          <style>\(sharedStyles)</style>
        </head>
        <body>
          <main class="card login-card">
            <p class="eyebrow">Remote</p>
            <h1>Sign in</h1>
            <p class="muted">Enter the access token configured on your Mac.</p>
            \(errorMarkup)
            <form method="post" action="/login">
              <label for="username">Username</label>
              <input id="username" name="username" type="text" value="remote" autocomplete="username" autocapitalize="none" spellcheck="false" readonly>
              <label for="token">Access token</label>
              <input id="token" name="token" type="password" autocomplete="current-password" required autofocus>
              <button type="submit">Continue</button>
            </form>
          </main>
        </body>
        </html>
        """
    }

    static func approvals() -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>Pending Approvals</title>
          <style>\(sharedStyles)</style>
        </head>
        <body>
          <main class="shell">
            <header>
              <div><p class="eyebrow">Remote</p><h1>Pending approvals</h1></div>
              <nav><a class="secondary action-link" href="/claude">Claude</a><form method="post" action="/logout"><button class="secondary" type="submit">Sign out</button></form></nav>
            </header>
            <section id="state" class="card"><p class="muted">Loading…</p></section>
          </main>
          <script>
          const state = document.getElementById('state');
          let submitting = false;
          let renderedSignature = null;
          let formDirty = false;

          function node(tag, className, text) {
            const element = document.createElement(tag);
            if (className) element.className = className;
            if (text !== undefined) element.textContent = text;
            return element;
          }

          async function loadApprovals() {
            if (submitting) return;
            try {
              const response = await fetch('/approvals/pending', { credentials: 'same-origin' });
              if (response.status === 401) { window.location = '/login'; return; }
              if (!response.ok) throw new Error('Request failed');
              const payload = await response.json();
              const approvals = payload.approvals || [];
              const signature = JSON.stringify(approvals);
              if (signature === renderedSignature) return;
              if (formDirty && state.querySelector('form')) return;
              renderedSignature = signature;
              render(approvals);
            } catch (_) {
              if (!state.querySelector('form')) {
                state.replaceChildren(node('p', 'error', 'Unable to reach the approval service. Retrying…'));
              }
            }
          }

          function render(approvals) {
            state.replaceChildren();
            if (!approvals.length) {
              state.append(node('p', 'empty', 'No pending approvals'));
              state.append(node('p', 'muted', 'This page refreshes automatically.'));
              return;
            }
            approvals.forEach((approval) => {
              const article = node('article', 'approval');
              const form = node('form', 'options');
              approval.questions.forEach((question) => {
                const fieldset = node('fieldset', 'question-block');
                const textRequired = approval.questions.length === 1;
                const title = question.kind === 'text' && !textRequired
                  ? `${question.question} (optional)` : question.question;
                fieldset.append(node('legend', 'question', title));
                if (question.kind === 'text') {
                  const input = document.createElement('textarea');
                  input.name = question.id; input.required = textRequired; input.maxLength = 4000;
                  input.rows = 5; input.placeholder = 'Type your answer…';
                  fieldset.append(input);
                } else {
                  question.options.forEach((option, index) => {
                    const label = node('label', 'option');
                    const input = document.createElement('input');
                    input.type = question.kind === 'multi_select' ? 'checkbox' : 'radio';
                    input.name = question.id; input.value = option;
                    if (question.kind === 'single_select') {
                      input.required = true; if (index === 0) input.checked = true;
                    }
                    label.append(input, node('span', null, option));
                    fieldset.append(label);
                  });
                }
                form.append(fieldset);
              });
              const submit = node('button', null, 'Submit decision');
              submit.type = 'submit'; form.append(submit);
              form.addEventListener('focusin', () => { formDirty = true; });
              form.addEventListener('input', () => { formDirty = true; });
              form.addEventListener('change', () => { formDirty = true; });
              form.addEventListener('submit', (event) => submitDecision(event, approval, form, submit));
              article.append(form); state.append(article);
            });
          }

          async function submitDecision(event, approval, form, button) {
            event.preventDefault();
            const data = new FormData(form);
            const answers = [];
            for (const question of approval.questions) {
              const textValue = question.kind === 'text'
                ? String(data.get(question.id) || '').trim() : '';
              const responses = question.kind === 'text'
                ? (textValue ? [textValue] : []) : data.getAll(question.id).map(String);
              const responseRequired = question.kind !== 'text' || approval.questions.length === 1;
              if (responseRequired && (!responses.length || responses.some((value) => !value))) {
                form.prepend(node('p', 'error', question.kind === 'multi_select'
                  ? 'Select at least one option for every multi-select question.'
                  : 'Answer every question.'));
                return;
              }
              answers.push({ id: question.id, responses });
            }
            submitting = true; button.disabled = true; button.textContent = 'Submitting…';
            try {
              const result = await fetch(`/approvals/${approval.id}/respond`, {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ answers })
              });
              if (!result.ok) throw new Error('Submit failed');
              formDirty = false; renderedSignature = null;
              state.replaceChildren(node('p', 'success', 'Answers sent.'));
              setTimeout(loadApprovals, 900);
            } catch (_) {
              button.disabled = false; button.textContent = 'Submit decision';
              state.prepend(node('p', 'error', 'The decision could not be sent. It may have expired or already been answered.'));
            } finally { submitting = false; }
          }

          loadApprovals(); setInterval(loadApprovals, 3000);
          </script>
        </body>
        </html>
        """
    }

    static func claude() -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>Remote Claude</title>
          <style>\(sharedStyles)</style>
        </head>
        <body>
          <main class="shell">
            <header>
              <div><p class="eyebrow">Remote</p><h1>Claude</h1></div>
              <nav><a class="secondary action-link" href="/approvals">Approvals</a><form method="post" action="/logout"><button class="secondary" type="submit">Sign out</button></form></nav>
            </header>
            <section class="card composer">
              <form id="prompt-form">
                <label for="prompt">Request</label>
                <textarea id="prompt" name="prompt" maxlength="20000" rows="7" placeholder="Ask Claude to work on your Mac…" required></textarea>
                <button id="send" type="submit">Send to Claude</button>
                <p id="composer-message" class="muted" aria-live="polite"></p>
              </form>
            </section>
            <section id="jobs" class="job-list" aria-live="polite"><div class="card"><p class="muted">Loading…</p></div></section>
          </main>
          <script>
          const form = document.getElementById('prompt-form');
          const promptInput = document.getElementById('prompt');
          const sendButton = document.getElementById('send');
          const composerMessage = document.getElementById('composer-message');
          const jobsState = document.getElementById('jobs');
          let submittingPrompt = false;
          let renderedJobs = null;

          function node(tag, className, text) {
            const element = document.createElement(tag);
            if (className) element.className = className;
            if (text !== undefined) element.textContent = text;
            return element;
          }

          function formatDate(value) {
            if (!value) return '';
            try { return new Date(value).toLocaleString(); } catch (_) { return ''; }
          }

          async function loadJobs() {
            try {
              const response = await fetch('/claude/jobs', { credentials: 'same-origin' });
              if (response.status === 401) { window.location = '/login'; return; }
              if (!response.ok) throw new Error('Request failed');
              const payload = await response.json();
              const jobs = payload.jobs || [];
              const signature = JSON.stringify(jobs);
              if (signature === renderedJobs) return;
              renderedJobs = signature;
              renderJobs(jobs);
            } catch (_) {
              if (!jobsState.children.length) {
                jobsState.append(node('div', 'card error', 'Unable to load Claude requests. Retrying…'));
              }
            }
          }

          function renderJobs(jobs) {
            jobsState.replaceChildren();
            if (!jobs.length) {
              const empty = node('div', 'card');
              empty.append(node('p', 'empty', 'No Claude requests yet'));
              jobsState.append(empty);
              return;
            }
            jobs.forEach((job) => {
              const article = node('article', 'card job');
              const heading = node('div', 'job-heading');
              heading.append(
                node('span', `status status-${job.status}`, job.status),
                node('time', 'muted', formatDate(job.createdAt))
              );
              article.append(heading, node('h2', 'job-prompt', job.prompt));
              if (job.status === 'queued') {
                article.append(node('p', 'muted', 'Waiting for the local Claude worker…'));
              } else if (job.status === 'running') {
                article.append(node('p', 'muted', 'Claude is working. Approval questions will appear on the Approvals page.'));
              } else if (job.status === 'completed') {
                article.append(node('pre', 'job-response', job.response || 'Completed without a text response.'));
              } else if (job.status === 'failed') {
                article.append(node('pre', 'job-error', job.errorMessage || 'Claude failed.'));
              }
              jobsState.append(article);
            });
          }

          form.addEventListener('submit', async (event) => {
            event.preventDefault();
            if (submittingPrompt) return;
            const prompt = promptInput.value.trim();
            if (!prompt) return;
            submittingPrompt = true;
            sendButton.disabled = true;
            sendButton.textContent = 'Sending…';
            composerMessage.textContent = '';
            try {
              const response = await fetch('/claude/jobs', {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ prompt })
              });
              if (response.status === 401) { window.location = '/login'; return; }
              if (!response.ok) throw new Error('Submit failed');
              promptInput.value = '';
              composerMessage.textContent = 'Request queued.';
              renderedJobs = null;
              await loadJobs();
            } catch (_) {
              composerMessage.textContent = 'The request could not be queued.';
              composerMessage.className = 'error';
            } finally {
              submittingPrompt = false;
              sendButton.disabled = false;
              sendButton.textContent = 'Send to Claude';
            }
          });

          loadJobs(); setInterval(loadJobs, 2000);
          </script>
        </body>
        </html>
        """
    }

    private static let sharedStyles = """
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: #f2f4f7; color: #111827; padding: max(20px, env(safe-area-inset-top)) 16px max(24px, env(safe-area-inset-bottom)); }
    .shell, .login-card { width: min(100%, 680px); margin: 0 auto; }
    header { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 18px; }
    nav { display: flex; align-items: center; gap: 8px; }
    nav form { margin: 0; }
    h1 { margin: 2px 0 0; font-size: clamp(1.7rem, 7vw, 2.4rem); line-height: 1.1; }
    .eyebrow { margin: 0; color: #2563eb; font-size: .78rem; font-weight: 800; letter-spacing: .12em; text-transform: uppercase; }
    .card { background: white; border-radius: 20px; padding: 20px; box-shadow: 0 8px 30px rgba(15, 23, 42, .08); }
    .login-card { margin-top: 10vh; }
    label { display: block; font-weight: 650; margin: 18px 0 8px; }
    input[type=text], input[type=password], textarea { width: 100%; min-height: 50px; border: 1px solid #cbd5e1; border-radius: 12px; padding: 12px; font: inherit; }
    input[readonly] { background: #f8fafc; color: #475569; }
    textarea { margin-top: 14px; resize: vertical; }
    button { min-height: 50px; width: 100%; border: 0; border-radius: 13px; background: #2563eb; color: white; padding: 12px 16px; font-size: 1rem; font-weight: 750; margin-top: 16px; }
    button:disabled { opacity: .55; }
    button.secondary { width: auto; min-height: 42px; margin: 0; background: #e2e8f0; color: #1e293b; }
    .action-link { display: inline-flex; align-items: center; min-height: 42px; border-radius: 13px; padding: 10px 14px; background: #e2e8f0; color: #1e293b; font-weight: 750; text-decoration: none; }
    .approval + .approval { border-top: 1px solid #e2e8f0; margin-top: 24px; padding-top: 24px; }
    .question-block { border: 0; padding: 0; margin: 0; min-width: 0; }
    .question-block + .question-block { border-top: 1px solid #e2e8f0; margin-top: 24px; padding-top: 24px; }
    .question { margin: 0; padding: 0; font-size: 1.15rem; font-weight: 750; line-height: 1.45; white-space: pre-wrap; }
    .options { margin-top: 14px; }
    .option { display: flex; align-items: flex-start; gap: 12px; margin: 10px 0; padding: 14px; border: 1px solid #cbd5e1; border-radius: 14px; line-height: 1.35; }
    .option input { width: 22px; height: 22px; margin: 0; flex: 0 0 auto; }
    .muted { color: #64748b; line-height: 1.5; }
    .empty, .success { margin: 0; font-size: 1.15rem; font-weight: 750; }
    .success { color: #047857; }
    .error { color: #b91c1c; font-weight: 650; }
    .composer { margin-bottom: 18px; }
    .composer label { margin-top: 0; }
    .composer textarea { margin-top: 0; }
    .job-list { display: grid; gap: 14px; }
    .job-heading { display: flex; justify-content: space-between; align-items: center; gap: 12px; }
    .status { border-radius: 999px; padding: 5px 9px; font-size: .75rem; font-weight: 800; text-transform: uppercase; letter-spacing: .04em; }
    .status-queued { background: #fef3c7; color: #92400e; }
    .status-running { background: #dbeafe; color: #1d4ed8; }
    .status-completed { background: #d1fae5; color: #047857; }
    .status-failed { background: #fee2e2; color: #b91c1c; }
    .job-prompt { margin: 14px 0 0; font-size: 1rem; line-height: 1.5; white-space: pre-wrap; }
    .job-response, .job-error { margin: 16px 0 0; padding: 14px; border-radius: 12px; white-space: pre-wrap; overflow-wrap: anywhere; font: inherit; line-height: 1.5; }
    .job-response { background: #ecfdf5; color: #064e3b; }
    .job-error { background: #fef2f2; color: #991b1b; }
    @media (prefers-color-scheme: dark) {
      body { background: #0f172a; color: #f8fafc; }
      .card { background: #1e293b; box-shadow: none; }
      .muted { color: #94a3b8; }
      input[type=password], textarea, .option { border-color: #475569; background: #0f172a; color: #f8fafc; }
      button.secondary { background: #334155; color: #f8fafc; }
      .action-link { background: #334155; color: #f8fafc; }
      .job-response { background: #052e2b; color: #d1fae5; }
      .job-error { background: #450a0a; color: #fee2e2; }
    }
    """
}
