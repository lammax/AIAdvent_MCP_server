import Foundation
import Vapor

public struct ApprovalHTTPAuthorization: Sendable {
    private let token: String

    public init(token: String) {
        self.token = token
    }

    public func validate(token candidate: String) -> Bool {
        constantTimeEquals(token, candidate)
    }

    public func isAuthorized(_ request: Request) -> Bool {
        if isBearerAuthorized(request) {
            return true
        }
        return request.session.data["remote-authorized"] == "true"
    }

    public func isBearerAuthorized(_ request: Request) -> Bool {
        guard let bearer = request.headers.bearerAuthorization else { return false }
        return validate(token: bearer.token)
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
    authorization: ApprovalHTTPAuthorization
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
        request.session.data["remote-authorized"] = "true"
        return request.redirect(to: "/approvals")
    }

    app.post("logout") { request -> Response in
        request.session.destroy()
        return request.redirect(to: "/login")
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
            return ApprovalResponse(try await service.respond(id: id, response: body.response))
        } catch let error as ApprovalError {
            throw abort(for: error)
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
    case .emptyQuestion, .questionTooLong, .invalidOptionCount, .emptyOption,
         .optionTooLong, .duplicateOptions, .invalidResponse:
        Abort(.badRequest, reason: error.localizedDescription)
    }
}

private func htmlResponse(_ html: String, status: HTTPResponseStatus = .ok) -> Response {
    Response(
        status: status,
        headers: ["Content-Type": "text/html; charset=utf-8"],
        body: .init(string: html)
    )
}

private struct ApprovalLoginRequest: Content {
    static let defaultContentType: HTTPMediaType = .urlEncodedForm
    let token: String
}

public struct ApprovalSubmitResponse: Content, Sendable {
    public let response: String

    public init(response: String) {
        self.response = response
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

public struct ApprovalResponse: Content, Sendable {
    public let id: UUID
    public let question: String
    public let options: [String]
    public let status: ApprovalStatus
    public let response: String?
    public let createdAt: Date
    public let expiresAt: Date
    public let answeredAt: Date?

    public init(_ approval: Approval) {
        self.id = approval.id
        self.question = approval.question
        self.options = approval.options
        self.status = approval.status
        self.response = approval.response
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
              <form method="post" action="/logout"><button class="secondary" type="submit">Sign out</button></form>
            </header>
            <section id="state" class="card"><p class="muted">Loading…</p></section>
          </main>
          <script>
          const state = document.getElementById('state');
          let submitting = false;

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
              render(payload.approvals || []);
            } catch (_) {
              state.replaceChildren(node('p', 'error', 'Unable to reach the approval service. Retrying…'));
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
              article.append(node('p', 'question', approval.question));
              const form = node('form', 'options');
              approval.options.forEach((option, index) => {
                const label = node('label', 'option');
                const radio = document.createElement('input');
                radio.type = 'radio'; radio.name = 'response'; radio.value = option;
                radio.required = true; if (index === 0) radio.checked = true;
                label.append(radio, node('span', null, option));
                form.append(label);
              });
              const submit = node('button', null, 'Submit decision');
              submit.type = 'submit'; form.append(submit);
              form.addEventListener('submit', (event) => submitDecision(event, approval.id, form, submit));
              article.append(form); state.append(article);
            });
          }

          async function submitDecision(event, id, form, button) {
            event.preventDefault(); submitting = true; button.disabled = true; button.textContent = 'Submitting…';
            const response = new FormData(form).get('response');
            try {
              const result = await fetch(`/approvals/${id}/respond`, {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ response })
              });
              if (!result.ok) throw new Error('Submit failed');
              state.replaceChildren(node('p', 'success', `Decision sent: ${response}`));
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

    private static let sharedStyles = """
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: #f2f4f7; color: #111827; padding: max(20px, env(safe-area-inset-top)) 16px max(24px, env(safe-area-inset-bottom)); }
    .shell, .login-card { width: min(100%, 680px); margin: 0 auto; }
    header { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 18px; }
    h1 { margin: 2px 0 0; font-size: clamp(1.7rem, 7vw, 2.4rem); line-height: 1.1; }
    .eyebrow { margin: 0; color: #2563eb; font-size: .78rem; font-weight: 800; letter-spacing: .12em; text-transform: uppercase; }
    .card { background: white; border-radius: 20px; padding: 20px; box-shadow: 0 8px 30px rgba(15, 23, 42, .08); }
    .login-card { margin-top: 10vh; }
    label { display: block; font-weight: 650; margin: 18px 0 8px; }
    input[type=password] { width: 100%; min-height: 50px; border: 1px solid #cbd5e1; border-radius: 12px; padding: 12px; font-size: 1rem; }
    button { min-height: 50px; width: 100%; border: 0; border-radius: 13px; background: #2563eb; color: white; padding: 12px 16px; font-size: 1rem; font-weight: 750; margin-top: 16px; }
    button:disabled { opacity: .55; }
    button.secondary { width: auto; min-height: 42px; margin: 0; background: #e2e8f0; color: #1e293b; }
    .approval + .approval { border-top: 1px solid #e2e8f0; margin-top: 24px; padding-top: 24px; }
    .question { margin: 0; font-size: 1.15rem; font-weight: 750; line-height: 1.45; white-space: pre-wrap; }
    .options { margin-top: 14px; }
    .option { display: flex; align-items: flex-start; gap: 12px; margin: 10px 0; padding: 14px; border: 1px solid #cbd5e1; border-radius: 14px; line-height: 1.35; }
    .option input { width: 22px; height: 22px; margin: 0; flex: 0 0 auto; }
    .muted { color: #64748b; line-height: 1.5; }
    .empty, .success { margin: 0; font-size: 1.15rem; font-weight: 750; }
    .success { color: #047857; }
    .error { color: #b91c1c; font-weight: 650; }
    @media (prefers-color-scheme: dark) {
      body { background: #0f172a; color: #f8fafc; }
      .card { background: #1e293b; box-shadow: none; }
      .muted { color: #94a3b8; }
      input[type=password], .option { border-color: #475569; background: #0f172a; color: #f8fafc; }
      button.secondary { background: #334155; color: #f8fafc; }
    }
    """
}
