import Foundation

public struct CodexModelOption: Equatable, Sendable, Identifiable {
    public var id: String { model.rawValue }
    public let model: CodexModel
    public let displayName: String
    public let reasoningEfforts: [ReasoningEffort]
    public init(model: CodexModel, displayName: String? = nil, reasoningEfforts: [ReasoningEffort]) {
        self.model = model; self.displayName = displayName ?? model.displayName; self.reasoningEfforts = reasoningEfforts
    }
}

public struct CodexCatalog: Sendable {
    public let models: [CodexModelOption]
    public init(models: [CodexModelOption]) { self.models = models }
    /// A catalog is not an entitlement or remaining-quota check. Never silently
    /// change an explicit choice or turn transport errors into a fallback.
    public func select(preferred: CodexModel? = nil, effort: ReasoningEffort = .medium) throws -> CodexModel {
        let choices = preferred.map { [$0] } ?? CodexModel.allCases
        guard let model = choices.first(where: { choice in models.contains { $0.model == choice && $0.reasoningEfforts.contains(effort) } }) else {
            throw CodexModelDiscovery.DiscoveryError.noSupportedModel
        }
        return model
    }
}

@MainActor public enum CodexModelDiscovery {
    public enum DiscoveryError: LocalizedError {
        case loginRequired, noSupportedModel, invalidCatalog
        public var errorDescription: String? {
            switch self {
            case .loginRequired: "ChatGPT 계정으로 로그인해 주세요."
            case .noSupportedModel: "선택한 모델과 추론 강도를 현재 목록에서 확인하지 못했습니다."
            case .invalidCatalog: "모델 목록을 확인하지 못했습니다. 다시 연결해 주세요."
            }
        }
    }
    public static func resolve(executable: URL) async throws -> CodexModel {
        try await catalog(executable: executable).select()
    }
    public static func catalog(executable: URL) async throws -> CodexCatalog {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-codex-models-\(UUID().uuidString)")
        let client = CodexAccountClient()
        defer { client.stop(); try? FileManager.default.removeItem(at: workspace) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try await client.start(executable: executable, workingDirectory: workspace)
        return try await readCatalog { method, params in
            try await client.request(method: method, params: params, timeout: 20)
        }
    }
    static func discover(request: (String, [String: Any]) async throws -> [String: Any]) async throws -> CodexModel {
        try await readCatalog(request: request).select()
    }
    static func readCatalog(request: (String, [String: Any]) async throws -> [String: Any]) async throws -> CodexCatalog {
        try Task.checkCancellation()
        let account = try await request("account/read", ["refreshToken": false])
        guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else { throw DiscoveryError.loginRequired }
        var result: [CodexModelOption] = [], seenModels: Set<CodexModel> = []
        var cursor: String?, seenCursors: Set<String> = []
        for _ in 0..<10 {
            try Task.checkCancellation()
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let page = try await request("model/list", params)
            guard let entries = page["data"] as? [[String: Any]], entries.count <= 1000 else { throw DiscoveryError.invalidCatalog }
            for entry in entries {
                guard entry["hidden"] as? Bool != true, let name = entry["model"] as? String,
                      let model = CodexModel(rawValue: name),
                      let rawEfforts = entry["supportedReasoningEfforts"] as? [[String: Any]] else { continue }
                if let value = entry["inputModalities"] {
                    guard let modalities = value as? [String] else { throw DiscoveryError.invalidCatalog }
                    if !modalities.contains("text") { continue }
                }
                let available = Set(rawEfforts.compactMap { ($0["reasoningEffort"] as? String).flatMap(ReasoningEffort.init(rawValue:)) })
                let efforts = ReasoningEffort.allCases.filter { available.contains($0) }
                guard !efforts.isEmpty, seenModels.insert(model).inserted else { continue }
                let label = (entry["displayName"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(100)) }
                result.append(.init(model: model, displayName: label, reasoningEfforts: efforts))
            }
            let next = page["nextCursor"]
            if next == nil || next is NSNull { try Task.checkCancellation(); return .init(models: result) }
            guard let next = next as? String, !next.isEmpty, seenCursors.insert(next).inserted else { throw DiscoveryError.invalidCatalog }
            cursor = next
        }
        throw DiscoveryError.invalidCatalog
    }
}
