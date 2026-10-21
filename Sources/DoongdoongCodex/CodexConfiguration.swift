import Foundation
import DoongdoongAI

public struct CodexModel: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.count <= 128,
              rawValue.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:").contains($0) }) else { return nil }
        self.rawValue = rawValue
    }
    public static let sol = CodexModel(rawValue: "gpt-6.1-sol")!
    public static let luna = CodexModel(rawValue: "gpt-6-luna")!
    public static let allCases = [sol, luna]
    public static let reasoningEffort = "medium"
    public var displayName: String {
        self == .sol ? "GPT-6.1 Sol" : self == .luna ? "GPT-6 Luna" : rawValue
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case none, minimal, low, medium, high, xhigh, max, ultra
}

public struct CodexConfiguration: Sendable {
    public let executable: URL
    public let model: CodexModel
    public let reasoningEffort: ReasoningEffort
    public let requestTimeout: TimeInterval
    public init(executable: URL, model: CodexModel = .sol,
                reasoningEffort: ReasoningEffort = .medium, requestTimeout: TimeInterval = 300) {
        self.executable = executable; self.model = model; self.reasoningEffort = reasoningEffort
        self.requestTimeout = requestTimeout
    }
    public var identity: TextProviderIdentity {
        .init(provider: "codex", model: model.rawValue, reasoningEffort: reasoningEffort.rawValue)
    }
}

public enum CodexError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
