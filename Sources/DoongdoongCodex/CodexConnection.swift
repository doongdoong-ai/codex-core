import Foundation
import DoongdoongAI

/// Account/catalog lookup and a synthetic probe are one cancellable operation.
/// The caller owns UI and first-run persistence; Codex owns failure semantics.
@MainActor public final class CodexConnection: ProviderConnectionChecking {
    public static let installationCommand = "brew install --cask codex"
    public private(set) var catalog: CodexCatalog?
    private let executable: URL
    private let preferredModel: CodexModel?
    private let effort: ReasoningEffort
    private let timeout: TimeInterval
    private let loadCatalog: @MainActor () async throws -> CodexCatalog
    private let generate: @MainActor (CodexConfiguration, StructuredTextRequest) async throws -> Data

    public convenience init(executable: URL, preferredModel: CodexModel? = nil,
                            reasoningEffort: ReasoningEffort = .medium, timeout: TimeInterval = 90) {
        self.init(executable: executable, preferredModel: preferredModel, reasoningEffort: reasoningEffort, timeout: timeout,
                  loadCatalog: { try await Self.readCatalog(executable: executable) },
                  generate: { try await CodexTextProvider(configuration: $0).generate($1) })
    }

    init(executable: URL, preferredModel: CodexModel? = nil, reasoningEffort: ReasoningEffort = .medium,
         timeout: TimeInterval = 90, loadCatalog: @escaping @MainActor () async throws -> CodexCatalog,
         generate: @escaping @MainActor (CodexConfiguration, StructuredTextRequest) async throws -> Data) {
        self.executable = executable; self.preferredModel = preferredModel; effort = reasoningEffort
        self.timeout = timeout; self.loadCatalog = loadCatalog; self.generate = generate
    }

    public func verifyConnection() async throws -> TextProviderIdentity {
        try Task.checkCancellation()
        catalog = nil
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProviderConnectionIssue(.installationRequired, stage: .installation, retry: .afterUserAction)
        }
        var stage: ProviderConnectionIssue.Stage = .account
        do {
            return try await connectionDeadline(timeout) { [self] in
                let available = try await loadCatalog()
                try Task.checkCancellation()
                catalog = available
                stage = .catalog
                let model = try available.select(preferred: preferredModel, effort: effort)
                stage = .probe
                let configuration = CodexConfiguration(executable: executable, model: model, reasoningEffort: effort, requestTimeout: timeout)
                let result: Data
                do { result = try await generate(configuration, Self.probe) }
                catch let issue as ProviderConnectionIssue where issue.kind == .usageLimited {
                    let reset = try? await Self.readResetTime(executable: executable)
                    try Task.checkCancellation()
                    throw ProviderConnectionIssue(.usageLimited, stage: .probe, retry: .later, retryAfter: reset)
                }
                try Task.checkCancellation()
                guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
                      object.count == 1, let ok = object["ok"] as? NSNumber,
                      CFGetTypeID(ok) == CFBooleanGetTypeID(), ok.boolValue else {
                    throw ProviderConnectionIssue(.invalidResponse, stage: .probe, retry: .manual)
                }
                return configuration.identity
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // Preserve an earlier, more precise stage (e.g. account auth vs catalog parsing).
            if let issue = error as? ProviderConnectionIssue { throw issue }
            throw CodexConnectionErrors.classify(error, stage: stage)
        }
    }

    static let probe = StructuredTextRequest(instructions: "Return exactly {\"ok\":true}. This is a connection check.",
        input: Data("{}".utf8),
        schema: Data(#"{"type":"object","properties":{"ok":{"type":"boolean","const":true}},"required":["ok"],"additionalProperties":false}"#.utf8),
        maximumResponseBytes: 128)

    private static func readResetTime(executable: URL) async throws -> Date? {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-limits-\(UUID().uuidString)")
        let client = CodexAccountClient()
        defer { client.stop(); try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try await client.start(executable: executable, workingDirectory: workspace)
        return resetTime(in: try await client.request(method: "account/rateLimits/read", params: [:], timeout: 10))
    }

    static func resetTime(in response: [String: Any], now: Date = Date()) -> Date? {
        // Other model buckets are not evidence of this request's reset time.
        let buckets = response["rateLimitsByLimitId"] as? [String: Any]
        guard let bucket = buckets?["codex"] as? [String: Any] ?? response["rateLimits"] as? [String: Any],
              bucket["limitId"] as? String == "codex" else { return nil }
        let exhausted = ["primary", "secondary"].compactMap { bucket[$0] as? [String: Any] }
            .filter { ($0["usedPercent"] as? Double ?? 0) >= 100 }
        guard !exhausted.isEmpty else { return nil }
        var dates: [Date] = []
        for window in exhausted {
            guard let timestamp = window["resetsAt"] as? Double, timestamp.isFinite,
                  timestamp > now.timeIntervalSince1970, timestamp < now.addingTimeInterval(366 * 86_400).timeIntervalSince1970 else { return nil }
            dates.append(Date(timeIntervalSince1970: timestamp))
        }
        return dates.max()
    }

    private static func readCatalog(executable: URL) async throws -> CodexCatalog {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-connect-\(UUID().uuidString)")
        let client = CodexAccountClient()
        defer { client.stop(); try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try await client.start(executable: executable, workingDirectory: workspace)
        return try await CodexModelDiscovery.readCatalog { method, params in
            var params = params
            if method == "account/read" { params["refreshToken"] = true }
            let stage: ProviderConnectionIssue.Stage = method == "account/read" ? .account : .catalog
            do {
                let result = try await client.request(method: method, params: params, timeout: 20)
                if method == "account/read" {
                    guard result.keys.contains("account") else { throw ProviderConnectionIssue(.invalidResponse, stage: stage, retry: .manual) }
                    if !(result["account"] is NSNull) {
                        guard let account = result["account"] as? [String: Any], let type = account["type"] as? String else {
                            throw ProviderConnectionIssue(.invalidResponse, stage: stage, retry: .manual)
                        }
                        if type != "chatgpt" { throw ProviderConnectionIssue(.unsupportedAuthentication, stage: stage, retry: .afterUserAction) }
                    }
                }
                return result
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw CodexConnectionErrors.classify(error, stage: stage)
            }
        }
    }
}

@MainActor func connectionDeadline<T: Sendable>(_ seconds: TimeInterval,
    operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    guard seconds.isFinite, (0...300).contains(seconds), seconds > 0 else {
        throw ProviderConnectionIssue(.configuration, stage: .probe, retry: .afterUserAction)
    }
    return try await withThrowingTaskGroup(of: T.self) { group in
        defer { group.cancelAll() }
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CodexProcessError.timedOut
        }
        return try await group.next()!
    }
}
