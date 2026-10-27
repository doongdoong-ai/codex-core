import XCTest
import DoongdoongAI
@testable import DoongdoongCodex

final class ConnectionTests: XCTestCase {
    @MainActor func testCatalogAloneCannotVerifyConnectionAndProbeUsesSelection() async throws {
        var calls = 0
        let connection = CodexConnection(executable: URL(fileURLWithPath: "/usr/bin/true"), preferredModel: .luna, reasoningEffort: .high,
            loadCatalog: { .init(models: [.init(model: .luna, reasoningEfforts: [.high])]) }, generate: { config, request in
                calls += 1
                XCTAssertEqual(config.model, .luna); XCTAssertEqual(config.reasoningEffort, .high)
                XCTAssertEqual(String(decoding: request.input, as: UTF8.self), "{}")
                XCTAssertEqual(request.maximumResponseBytes, 128)
                return Data(#"{"ok":true}"#.utf8)
            })
        let identity = try await connection.verifyConnection()
        XCTAssertEqual(identity.model, CodexModel.luna.rawValue); XCTAssertEqual(calls, 1)
    }

    @MainActor func testInvalidProbeNeverSucceedsAndKeepsCatalogForRecovery() async throws {
        for response in [#"{"ok":false}"#, #"{"ok":1}"#, #"{"ok":true,"extra":1}"#, "bad", "{}"] {
            let connection = CodexConnection(executable: URL(fileURLWithPath: "/usr/bin/true"),
                loadCatalog: { .init(models: [.init(model: .sol, reasoningEfforts: [.medium])]) },
                generate: { _, _ in Data(response.utf8) })
            do { _ = try await connection.verifyConnection(); XCTFail("Invalid success") }
            catch let error as ProviderConnectionIssue { XCTAssertEqual(error.kind, .invalidResponse) }
            XCTAssertNotNil(connection.catalog)
        }
    }

    @MainActor func testMissingExecutableAndUnsupportedConfigurationDoNotGenerate() async throws {
        for path in ["/missing-codex", "/usr/bin/true"] {
            let connection = CodexConnection(executable: URL(fileURLWithPath: path), preferredModel: .luna,
                loadCatalog: { .init(models: [.init(model: .sol, reasoningEfforts: [.medium])]) },
                generate: { _, _ in XCTFail("Must not generate"); return Data() })
            do { _ = try await connection.verifyConnection(); XCTFail("Unexpected success") }
            catch let error as ProviderConnectionIssue { XCTAssertEqual(error.kind, path == "/missing-codex" ? .installationRequired : .configuration) }
        }
    }

    @MainActor func testBoundedTimeoutAndCancellationRemainDistinct() async throws {
        func connection(_ timeout: Double) -> CodexConnection {
            .init(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: timeout,
                  loadCatalog: { try await Task.sleep(for: .seconds(30)); return .init(models: []) },
                  generate: { _, _ in XCTFail("Must not generate"); return Data() })
        }
        do { _ = try await connection(0.05).verifyConnection(); XCTFail("Expected timeout") }
        catch let error as ProviderConnectionIssue { XCTAssertEqual(error.kind, .timedOut) }
        let task = Task { try await connection(10).verifyConnection() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
    }

    func testStructuredErrorsDoNotInferAuthOrQuotaFromProse() {
        let cases: [([String: Any], ProviderConnectionIssue.Kind)] = [
            (["code": "usage_limit_exceeded"], .usageLimited),
            (["codexErrorInfo": "usageLimitExceeded"], .usageLimited),
            (["codexErrorInfo": ["httpConnectionFailed": ["httpStatusCode": 401]]], .loginRequired),
            (["httpStatusCode": 429], .serviceUnavailable),
            (["httpStatusCode": 503], .serviceUnavailable),
            (["code": "unsupported_reasoning_effort"], .configuration),
            (["code": "future_error", "message": "unauthorized sk-private bearer-secret"], .unknown),
            (["message": "usage limit exceeded"], .unknown),
            (["code": "bad_request"], .unknown)
        ]
        for (payload, kind) in cases {
            let issue = CodexConnectionErrors.structured(payload, stage: .probe)
            XCTAssertEqual(issue.kind, kind)
            XCTAssertFalse(issue.diagnosticSummary.contains("private"))
            XCTAssertFalse(issue.diagnosticSummary.contains("secret"))
        }
        XCTAssertEqual(CodexConnectionErrors.classify(ClientError.disconnected, stage: .account).kind, .unknown)
    }

    @MainActor func testResetTimeRequiresRelevantExhaustedWindows() {
        let now = Date(timeIntervalSince1970: 1000)
        let bucket: [String: Any] = ["limitId": "codex",
            "primary": ["usedPercent": 100.0, "resetsAt": 1100.0],
            "secondary": ["usedPercent": 100.0, "resetsAt": 1200.0]]
        XCTAssertEqual(CodexConnection.resetTime(in: ["rateLimits": bucket], now: now), Date(timeIntervalSince1970: 1200))
        XCTAssertNil(CodexConnection.resetTime(in: ["rateLimitsByLimitId": ["other": bucket]], now: now))
        XCTAssertNil(CodexConnection.resetTime(in: ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 25.0, "resetsAt": 1100.0]]], now: now))
        XCTAssertNil(CodexConnection.resetTime(in: ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 100.0]]], now: now))
    }

    func testBrowserURLAllowlist() {
        for raw in ["https://auth.openai.com/authorize?state=abc", "https://chatgpt.com/oauth", "https://auth.chatgpt.com/oauth"] {
            XCTAssertTrue(CodexBrowserLogin.isAllowedLoginURL(URL(string: raw)!))
        }
        for raw in ["http://auth.openai.com/", "https://auth.openai.com.evil.test/", "file:///etc/passwd", "https://user@chatgpt.com/", "https://chatgpt.com:8443/"] {
            XCTAssertFalse(CodexBrowserLogin.isAllowedLoginURL(URL(string: raw)!))
        }
    }

    /// Real pipe/process integration with a deterministic CLI; no account or network.
    private func fakeCLI(account: String = #"{"type":"chatgpt"}"#, mode: String = "success") throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("codex")
        let code = """
        #!/usr/bin/python3
        import sys,json,pathlib,time
        mode=\(String(decoding: try JSONEncoder().encode(mode), as: UTF8.self))
        if sys.argv[1:]==['login','status']:
            print('Logged in using ChatGPT'); sys.exit(0)
        if sys.argv[1]=='exec':
            assert 'connection check' in ' '.join(sys.argv)
            assert '{}' in sys.stdin.read()
            pathlib.Path(sys.argv[sys.argv.index('--output-last-message')+1]).write_text('{"ok":true}')
            sys.exit(0)
        for line in sys.stdin:
            q=json.loads(line); method=q.get('method'); ident=q.get('id')
            if ident is None: continue
            result={}
            if method=='account/read':
                assert q['params']['refreshToken'] is True
                result={'account':json.loads(\(String(decoding: try JSONEncoder().encode(account), as: UTF8.self)))}
            if method=='model/list':
                result={'data':[{'model':'gpt-6.1-sol','supportedReasoningEfforts':[{'reasoningEffort':'medium'}]}]}
            if method=='account/login/start':
                if mode=='die': sys.exit(1)
                result={'type':'chatgpt','loginId':'matching','authUrl':'https://auth.openai.com/authorize'}
            print(json.dumps({'id':ident,'result':result}),flush=True)
            if method=='account/login/start' and mode!='wait':
                print(json.dumps({'method':'account/login/completed','params':{'loginId':'wrong','success':True}}),flush=True)
                print(json.dumps({'method':'account/login/completed','params':{'loginId':'matching','success':mode=='success'}}),flush=True)
        """
        try Data(code.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (root, script)
    }

    @MainActor func testRealCLIPathVerifiesProbeAndRejectsAPIKey() async throws {
        for account in [#"{"type":"chatgpt"}"#, #"{"type":"apiKey"}"#, "null"] {
            let (root, executable) = try fakeCLI(account: account)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let identity = try await CodexConnection(executable: executable).verifyConnection()
                XCTAssertTrue(account.contains("chatgpt")); XCTAssertEqual(identity.model, CodexModel.sol.rawValue)
            } catch let issue as ProviderConnectionIssue {
                XCTAssertEqual(issue.kind, account == "null" ? .loginRequired : .unsupportedAuthentication)
            }
        }
    }

    @MainActor func testBrowserCallbackProcessDeathAndTimeout() async throws {
        for mode in ["success", "failure", "die", "wait"] {
            let (root, executable) = try fakeCLI(mode: mode)
            defer { try? FileManager.default.removeItem(at: root) }
            var opened = false
            do {
                try await CodexBrowserLogin.signIn(executable: executable, timeout: mode == "wait" ? 1 : 5) { _ in opened = true; return true }
                XCTAssertEqual(mode, "success"); XCTAssertTrue(opened)
            } catch let issue as ProviderConnectionIssue {
                XCTAssertNotEqual(mode, "success")
                XCTAssertEqual(issue.kind, mode == "failure" ? .loginRequired : mode == "wait" ? .timedOut : .unknown)
            }
        }
    }

    @MainActor func testCancelBrowserLoginCannotBecomeUnknownFailure() async throws {
        let (root, executable) = try fakeCLI(mode: "wait")
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = expectation(description: "browser")
        let task = Task { try await CodexBrowserLogin.signIn(executable: executable) { _ in opened.fulfill(); return true } }
        await fulfillment(of: [opened], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
    }
}
