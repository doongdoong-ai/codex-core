import Foundation

enum CodexCapacity {
    /// Inspect terminal protocol events, never model text or arbitrary stderr.
    static func exceeded(in events: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: events) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)) != nil,
              let data = try? handle.readToEnd() else { return false }
        for line in data.split(separator: 10).reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            if type == "turn.completed" { return false }
            guard type == "turn.failed", let error = event["error"] as? [String: Any] else { continue }
            let codes = ["context_length_exceeded", "context_window_exceeded", "max_output_tokens_exceeded", "response_too_large"]
            if let code = error["code"] as? String { return codes.contains(code) }
            let message = (error["message"] as? String ?? "").lowercased()
            return ["exceeds the context window", "exceeded the context window", "context window exceeded",
                    "maximum context length", "maximum output tokens", "context_length_exceeded"].contains { message.contains($0) }
        }
        return false
    }
}
