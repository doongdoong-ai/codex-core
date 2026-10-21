import XCTest
import DoongdoongAI
@testable import DoongdoongCodex

final class ProviderTests: XCTestCase {
    private func fixture(login: String = "Logged in using ChatGPT", output: String = "{\"ok\":true}", delay: Bool = false, failure: String? = nil) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-codex")
        let loginJSON = String(decoding: try JSONEncoder().encode(login), as: UTF8.self)
        let outputJSON = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        let failureJSON = String(decoding: try JSONEncoder().encode(failure ?? ""), as: UTF8.self)
        let code = """
        #!/usr/bin/python3
        import sys,os,json,time,pathlib
        if sys.argv[1:] == ['login','status']:
            print(\(loginJSON)); sys.exit(0)
        assert not os.environ.get('OPENAI_API_KEY')
        assert '--ignore-user-config' in sys.argv
        assert '--json' in sys.argv
        assert 'model_reasoning_effort="high"' in sys.argv
        data=sys.stdin.read()
        assert 'original input' in data
        if \(failureJSON):
            print(\(failureJSON)); sys.exit(1)
        \(delay ? "time.sleep(60)" : "pass")
        path=sys.argv[sys.argv.index('--output-last-message')+1]
        pathlib.Path(path).write_text(\(outputJSON))
        """
        try Data(code.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (root, script)
    }
    private var request: StructuredTextRequest {
        .init(instructions: "Keep original words.", input: Data(#"{"text":"original input"}"#.utf8),
              schema: Data(#"{"type":"object"}"#.utf8))
    }
    @MainActor func testStructuredRequestUsesConfigurationAndCleansPrivateWorkspace() async throws {
        let (root, script) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = CodexTextProvider(configuration: .init(executable: script, reasoningEffort: .high), temporaryRoot: root)
        XCTAssertEqual(provider.identity.reasoningEffort, "high")
        let data = try await provider.generate(request)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true}"#)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["fake-codex"])
    }
    @MainActor func testAPIKeyLoginCannotGenerate() async throws {
        let (root, script) = try fixture(login: "Logged in using an API key"); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await CodexTextProvider(configuration: .init(executable: script, reasoningEffort: .high), temporaryRoot: root).generate(request)
            XCTFail("Expected rejection")
        } catch CodexModelDiscovery.DiscoveryError.loginRequired {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["fake-codex"])
    }
    @MainActor func testOversizedOrNonJSONResponseIsRejectedAndRemoved() async throws {
        for output in [String(repeating: "x", count: 80_001), "not JSON"] {
            let (root, script) = try fixture(output: output); defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try await CodexTextProvider(configuration: .init(executable: script, reasoningEffort: .high), temporaryRoot: root).generate(request)
                XCTFail("Expected invalid response")
            } catch {}
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["fake-codex"])
        }
    }
    @MainActor func testCancellationStopsChildAndRemovesRequestFiles() async throws {
        let (root, script) = try fixture(delay: true); defer { try? FileManager.default.removeItem(at: root) }
        let provider = CodexTextProvider(configuration: .init(executable: script, reasoningEffort: .high), temporaryRoot: root)
        let task = Task { try await provider.generate(request) }
        try await Task.sleep(for: .milliseconds(400)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["fake-codex"])
    }
    func testExplicitChoiceAndEffortNeverSilentlyFallback() throws {
        let catalog = CodexCatalog(models: [.init(model: .sol, reasoningEfforts: [.medium, .high]),
                                           .init(model: .luna, reasoningEfforts: [.low, .medium])])
        XCTAssertEqual(try catalog.select(), .sol)
        XCTAssertEqual(try catalog.select(preferred: .luna, effort: .low), .luna)
        XCTAssertThrowsError(try catalog.select(preferred: .luna, effort: .high))
        XCTAssertThrowsError(try catalog.select(preferred: CodexModel(rawValue: "unlisted")!))
    }

    @MainActor func testOnlyTerminalCapacityErrorsAllowSmallerRequests() async throws {
        for (event, capacity) in [
            (#"{"type":"turn.failed","error":{"code":"context_length_exceeded","message":"too long"}}"#, true),
            (#"{"type":"turn.failed","error":{"message":"Your input exceeds the context window of this model."}}"#, true),
            (#"{"type":"turn.failed","error":{"code":"rate_limit_exceeded","message":"Token quota exceeded"}}"#, false),
            (#"{"type":"turn.failed","error":{"message":"Connection failed"}}"#, false),
            (#"{"type":"item.completed","item":{"type":"agent_message","text":"context_length_exceeded"}}"#, false),
            ("context_length_exceeded", false)
        ] {
            let (root, script) = try fixture(failure: event); defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try await CodexTextProvider(configuration: .init(executable: script, reasoningEffort: .high), temporaryRoot: root).generate(request)
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error is TextGenerationError, capacity) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["fake-codex"])
        }
    }

    @MainActor func testInputAndOutputByteLimitsAreTypedCapacityFailures() async throws {
        let (root, script) = try fixture(output: String(repeating: "x", count: 80_001))
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CodexTextProvider(configuration: .init(executable: script, reasoningEffort: .high), temporaryRoot: root)
        let oversized = StructuredTextRequest(instructions: "", input: Data(repeating: 32, count: 512_001), schema: request.schema)
        for value in [oversized, request] {
            do { _ = try await provider.generate(value); XCTFail("Expected capacity error") }
            catch TextGenerationError.capacityExceeded {}
        }
    }
}
