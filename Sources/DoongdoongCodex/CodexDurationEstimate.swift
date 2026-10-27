import Foundation
import DoongdoongAI

/// Codex-only UX heuristics, not measured throughput or a completion deadline.
/// All Codex models/efforts use these conservative baselines until calibrated.
enum CodexDurationEstimate {
    static func duration(for workload: TextGenerationWorkload) -> TimeInterval {
        let characters = Double(max(0, workload.characterCount))
        switch workload.task {
        case .correction:
            // Preserve the existing correction estimate (13,801 characters → 225.612s).
            return min(3600, max(120, 60 + characters * 0.012))
        case .summary:
            // Summaries emit less text. This is an initial conservative baseline.
            return min(3600, max(60, 45 + characters * 0.004))
        }
    }
}
