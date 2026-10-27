import Foundation
import DoongdoongAI

enum CodexConnectionErrors {
    static func classify(_ error: Error, stage: ProviderConnectionIssue.Stage) -> ProviderConnectionIssue {
        if let issue = error as? ProviderConnectionIssue {
            return .init(issue.kind, stage: stage, retry: issue.retry, retryAfter: issue.retryAfter)
        }
        if let discovery = error as? CodexModelDiscovery.DiscoveryError {
            switch discovery {
            case .loginRequired: return .init(.loginRequired, stage: stage, retry: .afterUserAction)
            case .noSupportedModel: return .init(.configuration, stage: stage, retry: .afterUserAction)
            case .invalidCatalog: return .init(.invalidResponse, stage: stage, retry: .manual)
            }
        }
        if let client = error as? ClientError {
            switch client {
            case .timedOut: return .init(.timedOut, stage: stage, retry: .manual)
            case .invalidMessage, .messageTooLarge, .unexpectedAction:
                return .init(.invalidResponse, stage: stage, retry: .afterUserAction)
            case .disconnected, .message: break // A dead helper is not proof of a network/auth failure.
            }
        }
        if case CodexProcessError.timedOut = error { return .init(.timedOut, stage: stage, retry: .manual) }
        if let url = error as? URLError {
            if url.code == .timedOut { return .init(.timedOut, stage: stage, retry: .manual) }
            if [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(url.code) {
                return .init(.network, stage: stage, retry: .manual)
            }
        }
        return .init(.unknown, stage: stage)
    }

    /// Only structured error codes are classified; prose and model output cannot
    /// turn an unknown error into an auth, billing, or configuration diagnosis.
    static func structured(_ error: [String: Any], stage: ProviderConnectionIssue.Stage) -> ProviderConnectionIssue {
        let info = error["codexErrorInfo"]
        let infoObject = info as? [String: Any]
        let code = error["code"] as? String ?? info as? String ?? infoObject?.keys.sorted().first ?? ""
        let normalized = code.replacingOccurrences(of: "_", with: "").lowercased()
        let status = error["httpStatusCode"] as? Int ?? infoObject?.values.compactMap { ($0 as? [String: Any])?["httpStatusCode"] as? Int }.first
        if ["unauthorized", "authenticationerror", "invalidapikey", "tokenexpired"].contains(normalized) || status == 401 {
            return .init(.loginRequired, stage: stage, retry: .afterUserAction)
        }
        if ["usagelimitexceeded", "insufficientquota"].contains(normalized) {
            return .init(.usageLimited, stage: stage, retry: .later)
        }
        if ["modelnotfound", "unsupportedmodel", "unsupportedreasoningeffort"].contains(normalized) {
            return .init(.configuration, stage: stage, retry: .afterUserAction)
        }
        if ["responsestreamconnectionfailed", "responsestreamdisconnected", "httpconnectionfailed"].contains(normalized) && status == nil {
            return .init(.network, stage: stage, retry: .manual)
        }
        if normalized == "timeout" || normalized == "requesttimeout" { return .init(.timedOut, stage: stage, retry: .manual) }
        if ["internalservererror", "ratelimitexceeded", "responsetoomanyfailedattempts"].contains(normalized) || status == 429 || (500...599).contains(status ?? 0) {
            return .init(.serviceUnavailable, stage: stage, retry: .later)
        }
        return .init(.unknown, stage: stage)
    }

    static func terminalIssue(in events: URL) -> ProviderConnectionIssue? {
        guard let handle = try? FileHandle(forReadingFrom: events) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: 10).reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if event["type"] as? String == "turn.completed" { return nil }
            if event["type"] as? String == "turn.failed", let error = event["error"] as? [String: Any] {
                return structured(error, stage: .probe)
            }
        }
        return nil
    }
}
