import Foundation

/// Provider identity is also part of the caller's cache identity.
public struct TextProviderIdentity: Codable, Equatable, Sendable {
    public let provider: String
    public let model: String
    public let reasoningEffort: String
    public init(provider: String, model: String, reasoningEffort: String) {
        self.provider = provider; self.model = model; self.reasoningEffort = reasoningEffort
    }
}

public struct StructuredTextRequest: Sendable {
    public let instructions: String
    public let input: Data
    public let schema: Data
    public let maximumResponseBytes: Int
    public init(instructions: String, input: Data, schema: Data, maximumResponseBytes: Int = 80_000) {
        self.instructions = instructions; self.input = input; self.schema = schema
        self.maximumResponseBytes = maximumResponseBytes
    }
}

/// Implement this boundary for another vendor. Prompts, semantic validation and
/// lecture progress remain caller-owned; the provider never edits source files.
@MainActor public protocol TextGenerationProvider {
    var identity: TextProviderIdentity { get }
    func checkConnection() async throws
    func generate(_ request: StructuredTextRequest) async throws -> Data
}
