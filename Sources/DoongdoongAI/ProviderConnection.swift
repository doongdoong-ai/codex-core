import Foundation

/// Stable, vendor-neutral failures. No raw server messages or credentials cross
/// this boundary. Cancellation remains CancellationError, never an issue.
public struct ProviderConnectionIssue: LocalizedError, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case installationRequired, loginRequired, unsupportedAuthentication, configuration
        case network, serviceUnavailable, timedOut, usageLimited, invalidResponse, unknown
    }
    public enum Stage: String, Sendable { case installation, account, catalog, probe, login }
    public enum Retry: String, Sendable { case manual, afterUserAction, later, unknown }
    public let kind: Kind
    public let stage: Stage
    public let retry: Retry
    /// Only supplied when the provider reports a relevant reset time.
    public let retryAfter: Date?
    public init(_ kind: Kind, stage: Stage, retry: Retry = .unknown, retryAfter: Date? = nil) {
        self.kind = kind; self.stage = stage; self.retry = retry; self.retryAfter = retryAfter
    }
    /// Allowlisted fields only; safe to offer as copyable diagnostics.
    public var diagnosticSummary: String {
        "stage=\(stage.rawValue)\nreason=\(kind.rawValue)\nretry=\(retry.rawValue)"
    }
    public var errorDescription: String? {
        switch kind {
        case .installationRequired: "AI 연결 프로그램을 설치하거나 실행 경로를 확인해 주세요."
        case .loginRequired, .unsupportedAuthentication: "AI 계정을 다시 연결해 주세요."
        case .configuration: "선택한 AI 설정을 사용할 수 없습니다. 설정을 확인해 주세요."
        case .network: "인터넷 연결을 확인한 뒤 다시 시도해 주세요."
        case .serviceUnavailable: "AI 서비스가 응답하지 않습니다. 잠시 후 다시 시도해 주세요."
        case .timedOut: "AI 응답 시간이 초과되었습니다. 다시 시도해 주세요."
        case .usageLimited: "AI 사용 한도에 도달했습니다. 사용량이 회복된 뒤 다시 시도해 주세요."
        case .invalidResponse: "AI 응답을 확인하지 못했습니다. 다시 시도해 주세요."
        case .unknown: "AI 연결을 확인하지 못했습니다. 다시 시도해 주세요."
        }
    }
}

/// Readiness requires a bounded, real structured generation using the selected
/// model and effort. It proves availability now, not future quota or entitlement.
@MainActor public protocol ProviderConnectionChecking {
    func verifyConnection() async throws -> TextProviderIdentity
}
