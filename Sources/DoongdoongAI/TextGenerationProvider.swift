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

/// Work description only. Each vendor owns the estimate and its calibration.
public struct TextGenerationWorkload: Equatable, Sendable {
    public enum Task: CaseIterable, Sendable { case correction, summary }
    public let task: Task
    public let characterCount: Int
    public init(task: Task, characterCount: Int) {
        self.task = task; self.characterCount = characterCount
    }
}

/// Implement this boundary for another vendor. Prompts, semantic validation and
/// progress presentation remain caller-owned; duration estimation is provider-owned.
/// The provider never edits source files.
@MainActor public protocol TextGenerationProvider {
    var identity: TextProviderIdentity { get }
    /// Must return finite, positive seconds without I/O or a generation request.
    /// Use a vendor-owned conservative estimate when calibration is unavailable.
    /// There is deliberately no default implementation shared by vendors.
    func estimatedDuration(for workload: TextGenerationWorkload) -> TimeInterval
    func checkConnection() async throws
    func generate(_ request: StructuredTextRequest) async throws -> Data
}
