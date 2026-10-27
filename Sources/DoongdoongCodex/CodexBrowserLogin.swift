import Foundation
import DoongdoongAI

/// User-initiated browser sign-in. The CLI hosts the callback and stores tokens;
/// the host app receives only an allowlisted URL and completion, never tokens.
@MainActor public enum CodexBrowserLogin {
    public static func signIn(executable: URL, timeout: TimeInterval = 180,
                              openBrowser: @escaping @MainActor (URL) -> Bool) async throws {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProviderConnectionIssue(.installationRequired, stage: .installation, retry: .afterUserAction)
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-login-\(UUID().uuidString)")
        let client = CodexAccountClient()
        defer { client.stop(); try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try await connectionDeadline(timeout) {
                try await client.start(executable: executable, workingDirectory: workspace)
                let completions = AsyncThrowingStream<(String, Bool), Error>(bufferingPolicy: .bufferingNewest(8)) { continuation in
                    client.onNotification = { method, params in
                        guard method == "account/login/completed", let id = params["loginId"] as? String else { return }
                        guard let success = params["success"] as? NSNumber, CFGetTypeID(success) == CFBooleanGetTypeID() else {
                            continuation.finish(throwing: ProviderConnectionIssue(.invalidResponse, stage: .login, retry: .manual)); return
                        }
                        continuation.yield((id, success.boolValue))
                    }
                    client.onFailure = { continuation.finish(throwing: $0) }
                }
                let response = try await client.request(method: "account/login/start", params: ["type": "chatgpt"], timeout: 20)
                guard response["type"] as? String == "chatgpt", let id = response["loginId"] as? String, !id.isEmpty,
                      let raw = response["authUrl"] as? String, let url = URL(string: raw), isAllowedLoginURL(url) else {
                    throw ProviderConnectionIssue(.invalidResponse, stage: .login, retry: .manual)
                }
                do {
                    try Task.checkCancellation()
                    guard openBrowser(url) else { throw ProviderConnectionIssue(.unknown, stage: .login) }
                    for try await (completedID, success) in completions where completedID == id {
                        try Task.checkCancellation()
                        guard success else { throw ProviderConnectionIssue(.loginRequired, stage: .login, retry: .afterUserAction) }
                        return
                    }
                    try Task.checkCancellation()
                    throw ProviderConnectionIssue(.unknown, stage: .login)
                } catch {
                    // Best-effort explicit cancel; closing this private server is the final
                    // bound if the CLI does not acknowledge it. Never logs out the account.
                    _ = await Task { @MainActor in
                        try? await client.request(method: "account/login/cancel", params: ["loginId": id], timeout: 1)
                    }.value
                    throw error
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw CodexConnectionErrors.classify(error, stage: .login)
        }
    }

    nonisolated static func isAllowedLoginURL(_ url: URL) -> Bool {
        url.scheme == "https" && ["auth.openai.com", "auth.chatgpt.com", "chatgpt.com"].contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
}
